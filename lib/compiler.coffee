esprima = require 'esprima'
escodegen = require 'escodegen'
syntax = esprima.Syntax
debug = require 'debug'
path = require 'path'

{ Stack } = require 'stack'
{ Set } = require 'set'
{ NodeVisitor } = require 'nodevisitor'
closure_conversion = require 'closure-conversion'
{ genId, bold, reset } = require 'echo-util'

{ ExitableScope, TryExitableScope, SwitchExitableScope, LoopExitableScope } = require 'exitable-scope'

types = require 'types'
consts = require 'consts'
runtime = require 'runtime'

llvm = require 'llvm'
ir = llvm.IRBuilder

# set to true to inline more of the call sequence at call sites (we still have to call into the runtime to decompose the closure itself for now)
# disable this for now because it breaks more of the exception tests
decompose_closure_on_invoke = false

BUILTIN_PARAMS = [
  { type: syntax.Identifier, name: "%closure", llvm_type: types.EjsClosureEnv }
  { type: syntax.Identifier, name: "%this",    llvm_type: types.EjsValue }
  { type: syntax.Identifier, name: "%argc",    llvm_type: types.int32 }
]

hasOwn = Object::hasOwnProperty

class LLVMIRVisitor extends NodeVisitor
        constructor: (@module, @filename) ->

                # build up our runtime method table
                @ejs_intrinsics =
                        invokeClosure: @handleInvokeClosureIntrinsic
                        makeClosure: @handleMakeClosureIntrinsic
                        makeAnonClosure: @handleMakeAnonClosureIntrinsic
                        createArgScratchArea: @handleCreateArgScratchAreaIntrinsic
                        makeClosureEnv: @handleMakeClosureEnvIntrinsic
                        slot: @handleSlotIntrinsic

                @llvm_intrinsics =
                        gcroot: -> module.getOrInsertIntrinsic "@llvm.gcroot"
                
                @ejs_runtime = runtime.createInterface module

                @module_atoms = Object.create null
                @literalInitializationFunction = @module.getOrInsertFunction "_ejs_module_init_string_literals_#{@filename}", types.void, []

                # initialize the scope stack with the global (empty) scope
                @scope_stack = new Stack
                @scope_stack.push Object.create null

                entry_bb = new llvm.BasicBlock "entry", @literalInitializationFunction
                return_bb = new llvm.BasicBlock "return", @literalInitializationFunction

                @doInsideBlock entry_bb, =>
                        ir.createBr return_bb

                @doInsideBlock return_bb, =>
                        ir.createRetVoid()

                @literalInitializationBB = entry_bb

        # lots of helper methods

        # result should be the landingpad's value
        beginCatch: (result) -> ir.createCall @ejs_runtime.begin_catch, [(ir.createPointerCast result, types.int8Pointer, "")], "catchval"
        endCatch:            -> ir.createCall @ejs_runtime.end_catch, [], "endcatch"

        doInsideBlock: (b, f) ->
                saved = ir.getInsertBlock()
                ir.setInsertPoint b
                f()
                ir.setInsertPoint saved
        
        createLoad: (value, name) ->
                rv = ir.createLoad value, name
                rv
                
        loadBoolEjsValue: (n) ->
                boolval = @createLoad (if n then @ejs_runtime['true'] else @ejs_runtime['false']), "load_bool"
                boolval.is_constant = true
                boolval.constant_val = n
                boolval
                
        loadNullEjsValue: ->
                nullval = @createLoad @ejs_runtime['null'], "load_null"
                nullval.is_constant = true
                nullval.constant_val = null
                nullval
                
        loadUndefinedEjsValue: ->
                undef = @createLoad @ejs_runtime.undefined, "load_undefined"
                undef.is_constant = true
                undef.constant_val = undefined
                undef
                
        loadGlobal: -> @createLoad @ejs_runtime.global, "load_global"

        visitWithScope: (scope, children) ->
                @scope_stack.push scope
                @visit child for child in children
                @scope_stack.pop()

        findIdentifierInScope: (ident) ->
                for scope in @scope_stack.stack
                        if hasOwn.call scope, ident
                                return scope[ident]
                null

                                
        createAlloca: (func, type, name) ->
                saved_insert_point = ir.getInsertBlock()
                ir.setInsertPointStartBB func.entry_bb
                alloca = ir.createAlloca type, name

                # if EjsValue was a pointer value we would be able to use an the llvm gcroot intrinsic here.  but with the nan boxing
                # we kinda lose out as the llvm IR code doesn't permit non-reference types to be gc roots.
                # if type is types.EjsValue
                #        # EjsValues are rooted
                #        @createCall @llvm_intrinsics.gcroot(), [(ir.createPointerCast alloca, types.int8Pointer.pointerTo(), "rooted_alloca"), consts.null types.int8Pointer], ""

                ir.setInsertPoint saved_insert_point
                alloca

        createAllocas: (func, ids, scope) ->
                allocas = []
                new_allocas = []
                
                # the allocas are always allocated in the function entry_bb so the mem2reg opt pass can regenerate the ssa form for us
                saved_insert_point = ir.getInsertBlock()
                ir.setInsertPointStartBB func.entry_bb

                j = 0
                for i in [0...ids.length]
                        name = ids[i].id.name
                        if !hasOwn.call scope, name
                                allocas[j] = ir.createAlloca types.EjsValue, "local_#{name}"
                                scope[name] = allocas[j]
                                new_allocas[j] = true
                        else
                                allocas[j] = scope[name]
                                new_allocas[j] = false
                        j = j + 1
                                

                # reinstate the IRBuilder to its previous insert point so we can insert the actual initializations
                ir.setInsertPoint saved_insert_point

                { allocas: allocas, new_allocas: new_allocas }

        createPropertyStore: (obj,prop,rhs,computed) ->
                if computed
                        # we store obj[prop], prop can be any value
                        prop_alloca = @createAlloca @currentFunction, types.EjsValue, "prop_alloca"
                        ir.createStore (@visit prop), prop_alloca
                        @createCall @ejs_runtime.object_setprop, [obj, (@createLoad prop_alloca, "%prop_alloca"), rhs], "propstore_computed"
                else
                        # we store obj.prop, prop is an id
                        if prop.type is syntax.Identifier
                                pname = prop.name
                        else # prop.type is syntax.Literal
                                pname = prop.value

                        c = @getAtom pname

                        debug.log -> "createPropertyStore #{obj}[#{pname}]"
                        
                        @createCall @ejs_runtime.object_setprop, [obj, c, rhs], "propstore_#{pname}"
                
        createPropertyLoad: (obj,prop,computed,canThrow = true) ->
                if computed
                        # we load obj[prop], prop can be any value
                        loadprop = @visit prop
                        pname = "computed"
                        @createCall @ejs_runtime.object_getprop, [obj, loadprop], "getprop_#{pname}", canThrow
                else
                        # we load obj.prop, prop is an id
                        pname = @getAtom prop.name
                        @createCall @ejs_runtime.object_getprop, [obj, pname], "getprop_#{prop.name}", canThrow
                

        createLoadThis: () ->
                _this = @findIdentifierInScope "%this"
                return @createLoad _this, "load_this"


        visitOrNull: (n) -> (@visit n) || @loadNullEjsValue()
        visitOrUndefined: (n) -> (@visit n) || @loadUndefinedEjsValue()
        
        visitProgram: (n) ->
                # by the time we make it here the program has been
                # transformed so that there is nothing at the toplevel
                # but function declarations.
                @visit func for func in n.body

        visitBlock: (n) ->
                new_scope = Object.create null

                iife_rv = null
                iife_bb = null
                
                if n.fromIIFE
                        insertBlock = ir.getInsertBlock()
                        insertFunc = insertBlock.parent
                        
                        iife_rv = @createAlloca @currentFunction, types.EjsValue, "%iife_rv"
                        iife_bb = new llvm.BasicBlock "iife_dest", insertFunc

                @iifeStack.push iife_rv: iife_rv, iife_dest_bb: iife_bb

                @visitWithScope new_scope, n.body

                @iifeStack.pop()
                if iife_bb
                        ir.createBr iife_bb
                        ir.setInsertPoint iife_bb
                        rv = @createLoad iife_rv, "%iife_rv_load"
                        rv
                else
                        n

        visitSwitch: (n) ->
                insertBlock = ir.getInsertBlock()
                insertFunc = insertBlock.parent

                switch_bb = new llvm.BasicBlock "switch", insertFunc

                ir.createBr switch_bb
                ir.setInsertPoint switch_bb
                
                # find the default: case first
                defaultCase = null
                (if not _case.test then defaultCase = _case) for _case in n.cases

                # for each case, create 2 basic blocks
                for _case in n.cases
                        if _case isnt defaultCase
                                _case.dest_check = new llvm.BasicBlock "case_dest_check_bb", insertFunc

                for _case in n.cases
                        _case.bb = new llvm.BasicBlock "case_bb", insertFunc

                merge_bb = new llvm.BasicBlock "switch_merge", insertFunc

                discr = @visit n.discriminant

                case_checks = []
                for _case in n.cases
                        if defaultCase isnt _case
                                case_checks.push test: _case.test, dest_check: _case.dest_check, body: _case.bb

                case_checks.push dest_check: if defaultCase? then defaultCase.bb else merge_bb

                scope = new SwitchExitableScope merge_bb
                scope.enter()

                # insert all the code for the tests
                ir.createBr case_checks[0].dest_check
                ir.setInsertPoint case_checks[0].dest_check
                for casenum in [0...case_checks.length-1]
                        test = @visit case_checks[casenum].test
                        eqop = @ejs_runtime["binop==="]
                        discTest = @createCall eqop, [discr, test], "test", !eqop.doesNotThrow
                        disc_truthy = @createCall @ejs_runtime.truthy, [discTest], "disc_truthy"
                        disc_cmp = ir.createICmpEq disc_truthy, consts.false(), "disccmpresult"
                        ir.createCondBr disc_cmp, case_checks[casenum+1].dest_check, case_checks[casenum].body
                        ir.setInsertPoint case_checks[casenum+1].dest_check


                case_bodies = []
                
                # now insert all the code for the case consequents
                for _case in n.cases
                        case_bodies.push bb:_case.bb, consequent:_case.consequent

                case_bodies.push bb:merge_bb
                
                for casenum in [0...case_bodies.length-1]
                        ir.setInsertPoint case_bodies[casenum].bb
                        for c of case_bodies[casenum].consequent
                                @visit case_bodies[casenum].consequent[c]
                        ir.createBr case_bodies[casenum+1].bb
                        
                ir.setInsertPoint merge_bb

                scope.leave()

                merge_bb
                
        visitCase: (n) ->
                throw "we shouldn't get here, case statements are handled in visitSwitch"
                        
                
        visitLabeledStatement: (n) ->
                n.body.label = n.label.name
                @visit n.body

        visitBreak: (n) ->
                return ExitableScope.scopeStack.exitAft true, n.label?.name

        visitContinue: (n) ->
                return ExitableScope.scopeStack.exitFore n.label?.name

        generateCondBr: (exp, then_bb, else_bb) ->
                exp_value = @visit exp
                cond_truthy = @createCall @ejs_runtime.truthy, [exp_value], "cond_truthy"
                cmp = ir.createICmpEq cond_truthy, consts.false(), "cmpresult"
                ir.createCondBr cmp, else_bb, then_bb
                exp_value
                
        visitFor: (n) ->
                insertBlock = ir.getInsertBlock()
                insertFunc = insertBlock.parent

                init_bb = new llvm.BasicBlock "for_init", insertFunc
                test_bb = new llvm.BasicBlock "for_test", insertFunc
                body_bb = new llvm.BasicBlock "for_body", insertFunc
                update_bb = new llvm.BasicBlock "for_update", insertFunc
                merge_bb = new llvm.BasicBlock "for_merge", insertFunc

                ir.createBr init_bb

                @doInsideBlock init_bb, =>
                        @visit n.init
                        ir.createBr test_bb

                @doInsideBlock test_bb, =>
                        if n.test
                                @generateCondBr n.test, body_bb, merge_bb
                        else
                                ir.createBr body_bb

                scope = new LoopExitableScope n.label, update_bb, merge_bb
                scope.enter()

                @doInsideBlock body_bb, =>
                        @visit n.body
                        ir.createBr update_bb

                @doInsideBlock update_bb, =>
                        @visit n.update
                        ir.createBr test_bb

                scope.leave()

                ir.setInsertPoint merge_bb
                merge_bb

        visitDo: (n) ->
                insertBlock = ir.getInsertBlock()
                insertFunc = insertBlock.parent
                
                body_bb = new llvm.BasicBlock "do_body", insertFunc
                merge_bb = new llvm.BasicBlock "do_merge", insertFunc

                ir.createBr body_bb

                scope = new LoopExitableScope n.label, body_bb, merge_bb
                scope.enter()
                
                @doInsideBlock body_bb, =>
                        @visit n.body
                        @generateCondBr n.test, body_bb, merge_bb

                scope.leave()
                                
                ir.setInsertPoint merge_bb
                merge_bb

                                
        visitWhile: (n) ->
                insertBlock = ir.getInsertBlock()
                insertFunc = insertBlock.parent
                
                while_bb  = new llvm.BasicBlock "while_start", insertFunc
                body_bb = new llvm.BasicBlock "while_body", insertFunc
                merge_bb = new llvm.BasicBlock "while_merge", insertFunc

                ir.createBr while_bb

                @doInsideBlock while_bb, =>
                        @generateCondBr n.test, body_bb, merge_bb

                scope = new LoopExitableScope n.label, while_bb, merge_bb
                scope.enter()
                
                @doInsideBlock body_bb, =>
                        @visit n.body
                        ir.createBr while_bb

                scope.leave()
                                
                ir.setInsertPoint merge_bb
                merge_bb

        visitForIn: (n) ->
                insertBlock = ir.getInsertBlock()
                insertFunc = insertBlock.parent

                iterator = @createCall @ejs_runtime.prop_iterator_new, [@visit n.right], "iterator"

                # make sure we get an alloca if there's a "var"
                if n.left[0]?
                        @visit n.left
                        lhs = n.left[0].declarations[0].id
                else
                        lhs = n.left
                
                forin_bb  = new llvm.BasicBlock "forin_start", insertFunc
                body_bb   = new llvm.BasicBlock "forin_body",  insertFunc
                merge_bb  = new llvm.BasicBlock "forin_merge", insertFunc
                                
                ir.createBr forin_bb

                scope = new LoopExitableScope n.label, forin_bb, merge_bb
                scope.enter()

                @doInsideBlock forin_bb, =>
                        moreleft = @createCall @ejs_runtime.prop_iterator_next, [iterator, consts.true()], "moreleft"
                        cmp = ir.createICmpEq moreleft, consts.false(), "cmpmoreleft"
                        ir.createCondBr cmp, merge_bb, body_bb

                @doInsideBlock body_bb, =>
                        current = @createCall @ejs_runtime.prop_iterator_current, [iterator], "iterator_current"
                        @storeValueInDest current, lhs
                        @visit n.body
                        ir.createBr forin_bb

                scope.leave()

                ir.setInsertPoint merge_bb
                merge_bb
                
                
        visitUpdateExpression: (n) ->
                result = @createAlloca @currentFunction, types.EjsValue, "%update_result"
                argument = @visit n.argument
                
                one = @createLoad @ejs_runtime['one'], "load_one"
                
                if not n.prefix
                        # postfix updates store the argument before the op
                        ir.createStore argument, result

                # argument = argument $op 1
                update_op = @ejs_runtime["binop#{if n.operator is '++' then '+' else '-'}"]
                temp = @createCall update_op, [argument, one], "update_temp", !update_op.doesNotThrow
                
                @storeValueInDest temp, n.argument
                
                # return result
                if n.prefix
                        argument = @visit n.argument
                        # prefix updates store the argument after the op
                        ir.createStore argument, result
                @createLoad result, "%update_result_load"

        visitConditionalExpression: (n) ->
                @visitIfOrCondExp n, true
                        
        visitIf: (n) ->
                @visitIfOrCondExp n, false

        visitIfOrCondExp: (n, load_result) ->

                if load_result
                        cond_val = @createAlloca @currentFunction, types.EjsValue, "%cond_val"
                
                insertBlock = ir.getInsertBlock()
                insertFunc = insertBlock.parent

                then_bb  = new llvm.BasicBlock "then", insertFunc
                else_bb  = new llvm.BasicBlock "else", insertFunc if n.alternate?
                merge_bb = new llvm.BasicBlock "merge", insertFunc

                @generateCondBr n.test, then_bb, (if else_bb? then else_bb else merge_bb)

                @doInsideBlock then_bb, =>
                        then_val = @visit n.consequent
                        ir.createStore then_val, cond_val if load_result
                        ir.createBr merge_bb

                if n.alternate?
                        @doInsideBlock else_bb, =>
                                else_val = @visit n.alternate
                                ir.createStore else_val, cond_val if load_result
                                ir.createBr merge_bb

                ir.setInsertPoint merge_bb
                if load_result
                        @createLoad cond_val, "cond_val_load"
                else
                        merge_bb
                
        visitReturn: (n) ->
                debug.log "visitReturn"
                if @iifeStack.top.iife_rv?
                        if n.argument?
                                ir.createStore (@visit n.argument), @iifeStack.top.iife_rv
                        else
                                ir.createStore @loadUndefinedEjsValue(), @iifeStack.top.iife_rv
                        ir.createBr @iifeStack.top.iife_dest_bb
                else
                        rv = if n.argument? then (@visit n.argument) else @loadUndefinedEjsValue()
                        
                        if @finallyStack.length > 0
                                @returnValueAlloca = @createAlloca @currentFunction, types.EjsValue, "returnValue" unless @returnValueAlloca?
                                ir.createStore rv, @returnValueAlloca
                                ir.createStore (consts.int32 ExitableScope.REASON_RETURN), @currentFunction.cleanup_reason
                                ir.createBr @finallyStack[0]
                        else
                                return_alloca = @createAlloca @currentFunction, types.EjsValue, "return_alloca"
                                ir.createStore rv, return_alloca
                        
                                ir.createRet @createLoad return_alloca, "return_load"
                                                

        visitVariableDeclaration: (n) ->
                if n.kind is "var"
                        # vars are hoisted to the containing function's toplevel scope
                        scope = @currentFunction.topScope

                        {allocas,new_allocas} = @createAllocas @currentFunction, n.declarations, scope
                        for i in [0...n.declarations.length]
                                if not n.declarations[i].init?
                                        # there was not an initializer. we only store undefined
                                        # if the alloca is newly allocated.
                                        if new_allocas[i]
                                                initializer = @visitOrUndefined n.declarations[i].init
                                                ir.createStore initializer, allocas[i]
                                else
                                        initializer = @visitOrUndefined n.declarations[i].init
                                        ir.createStore initializer, allocas[i]
                else if n.kind is "let"
                        # lets are not hoisted to the containing function's toplevel, but instead are bound in the lexical block they inhabit
                        scope = @scope_stack.top

                        {allocas,new_allocas} = @createAllocas @currentFunction, n.declarations, scope
                        for i in [0...n.declarations.length]
                                if not n.declarations[i].init?
                                        # there was not an initializer. we only store undefined
                                        # if the alloca is newly allocated.
                                        if new_allocas[i]
                                                initializer = @visitOrUndefined n.declarations[i].init
                                                ir.createStore initializer, allocas[i]
                                else
                                        initializer = @visitOrUndefined n.declarations[i].init
                                        ir.createStore initializer, allocas[i]
                else if n.kind is "const"
                        for i in [0...n.declarations.length]
                                u = n.declarations[i]
                                initializer_ir = @visit u.init
                                # XXX bind the initializer to u.name in the current basic block and mark it as constant

        visitMemberExpression: (n) ->
                obj_result = @createAlloca @currentFunction, types.EjsValue, "result_obj"
                obj_visit = @visit n.object
                ir.createStore obj_visit, obj_result
                obj_load = @createLoad obj_result, "obj_load"
                rv = @createPropertyLoad obj_load, n.property, n.computed
                load_result = @createAlloca @currentFunction, types.EjsValue, "load_result"
                ir.createStore rv, load_result
                if not n.result_not_used
                        @createLoad load_result, "rv"

        storeValueInDest: (rhvalue, lhs) ->
                if lhs.type is syntax.Identifier
                        dest = @findIdentifierInScope lhs.name
                        if dest?
                                result = ir.createStore rhvalue, dest
                        else
                                result = @createPropertyStore @loadGlobal(), lhs, rhvalue, false
                        result
                else if lhs.type is syntax.MemberExpression
                        object_alloca = @createAlloca @currentFunction, types.EjsValue, "object_alloca"
                        ir.createStore (@visit lhs.object), object_alloca
                        result = @createPropertyStore (@createLoad object_alloca, "load_object"), lhs.property, rhvalue, lhs.computed
                else if lhs.type is syntax.CallExpression and lhs.callee.name is "%slot"
                        ir.createStore rhvalue, (@handleSlotRefIntrinsic lhs)
                else
                        throw "unhandled lhs #{escodegen.generate lhs}"

        visitAssignmentExpression: (n) ->
                lhs = n.left
                rhs = n.right

                rhvalue = @visit rhs
                if n.operator.length is 2
                        # cribbed from visitBinaryExpression
                        builtin = "binop#{n.operator[0]}"
                        callee = @ejs_runtime[builtin]
                        if not callee
                                throw "Internal error: unhandled binary operator '#{n.operator}'"
                        rhvalue = @createCall callee, [(@visit lhs), rhvalue], "result_#{builtin}", !callee.doesNotThrow
                
                @storeValueInDest rhvalue, lhs

                # we need to visit lhs after the store so that we load the value, but only if it's used
                if not n.result_not_used
                        rhvalue

        visitFunction: (n) ->
                debug.log -> "        function #{n.ir_name} at #{@filename}:#{if n.loc? then n.loc.start.line else '<unknown>'}" if not n.toplevel?
                
                # save off the insert point so we can get back to it after generating this function
                insertBlock = ir.getInsertBlock()

                for param in n.params
                        debug.log param.type
                        if param.type is syntax.MemberExpression
                                debug.log param.object.type
                                debug.log param.property.name
                        if param.type isnt syntax.Identifier
                                debug.log "we don't handle destructured/defaulted parameters yet"
                                console.warn JSON.stringify param
                                throw "we don't handle destructured/defaulted parameters yet"

                # XXX this methods needs to be augmented so that we can pass actual types (or the builtin args need
                # to be reflected in jsllvm.cpp too).  maybe we can pass the names to this method and it can do it all
                # there?

                ir_func = n.ir_func
                ir_args = n.ir_func.args
                debug.log ""
                #debug.log -> "ir_func = #{ir_func}"

                #debug.log -> "param #{param.llvm_type} #{param.name}" for param in n.params

                @currentFunction = ir_func

                # Create a new basic block to start insertion into.
                entry_bb = new llvm.BasicBlock "entry", ir_func

                ir.setInsertPoint entry_bb

                new_scope = Object.create null

                # we save off the top scope and entry_bb of the function so that we can hoist vars there
                ir_func.topScope = new_scope
                ir_func.entry_bb = entry_bb

                ir_func.literalAllocas = Object.create null

                allocas = []

                # create allocas for the builtin args
                for i in [0...BUILTIN_PARAMS.length]
                        alloca = ir.createAlloca BUILTIN_PARAMS[i].llvm_type, "local_#{n.params[i].name}"
                        new_scope[n.params[i].name] = alloca
                        allocas.push alloca

                # create an alloca to store our 'EJSValue** args' parameter, so we can pull the formal parameters out of it
                args_alloca = ir.createAlloca types.EjsValue.pointerTo(), "local_%args"
                new_scope["%args"] = args_alloca
                allocas.push args_alloca

                # now create allocas for the formal parameters
                for param in n.params[BUILTIN_PARAMS.length..]
                        if param.type is syntax.Identifier
                                alloca = @createAlloca @currentFunction, types.EjsValue, "local_#{param.name}"
                                new_scope[param.name] = alloca
                                allocas.push alloca
                        else
                                debug.log "we don't handle destructured args at the moment."
                                console.warn JSON.stringify param
                                throw "we don't handle destructured args at the moment."

                debug.log -> "alloca #{alloca}" for alloca in allocas
        
                # now store the arguments (use .. to include our args array) onto the stack
                for i in [0..BUILTIN_PARAMS.length]
                        store = ir.createStore ir_args[i], allocas[i]
                        debug.log -> "store #{store} *builtin"

                # initialize all our named parameters to undefined
                args_load = @createLoad args_alloca, "args_load"
                if n.params.length > BUILTIN_PARAMS.length
                        for i in [BUILTIN_PARAMS.length...n.params.length]
                                store = ir.createStore @loadUndefinedEjsValue(), allocas[i+1]
                        
                body_bb = new llvm.BasicBlock "body", ir_func
                ir.setInsertPoint body_bb

                if n.toplevel?
                        ir.createCall @literalInitializationFunction, [], ""

                insertFunc = body_bb.parent
        
                # now pull the named parameters from our args array for the ones that were passed in.
                # any arg that isn't specified isn't pulled in, and is only accessible via the arguments object.
                if n.params.length > BUILTIN_PARAMS.length
                        load_argc = @createLoad allocas[2], "argc" # FIXME, magic number alert
                
                        for i in [BUILTIN_PARAMS.length...n.params.length]
                                then_bb  = new llvm.BasicBlock "arg_then", insertFunc
                                else_bb  = new llvm.BasicBlock "arg_else", insertFunc
                                merge_bb = new llvm.BasicBlock "arg_merge", insertFunc

                                cmp = ir.createICmpSGt load_argc, (consts.int32 i-BUILTIN_PARAMS.length), "argcmpresult"
                                ir.createCondBr cmp, then_bb, else_bb
                        
                                ir.setInsertPoint then_bb
                                arg_ptr = ir.createGetElementPointer args_load, [(consts.int32 i-BUILTIN_PARAMS.length)], "arg#{i-BUILTIN_PARAMS.length}_ptr"
                                debug.log -> "arg_ptr = #{arg_ptr}"
                                arg = @createLoad arg_ptr, "arg#{i-BUILTIN_PARAMS.length-1}_load"
                                store = ir.createStore arg, allocas[i+1]
                                debug.log -> "store #{store}"
                                ir.createBr merge_bb

                                ir.setInsertPoint else_bb
                                ir.createBr merge_bb

                                ir.setInsertPoint merge_bb

                @iifeStack = new Stack

                @finallyStack = []
                
                @visitWithScope new_scope, [n.body]

                # XXX more needed here - this lacks all sorts of control flow stuff.
                # Finish off the function.
                ir.createRet @loadUndefinedEjsValue()

                # insert an unconditional branch from entry_bb to body here, now that we're
                # sure we're not going to be inserting allocas into the entry_bb anymore.
                ir.setInsertPoint entry_bb
                ir.createBr body_bb
                        
                @currentFunction = null

                ir.setInsertPoint insertBlock

                return ir_func

        visitUnaryExpression: (n) ->
                debug.log -> "operator = '#{n.operator}'"

                builtin = "unop#{n.operator}"
                callee = @ejs_runtime[builtin]
        
                if n.operator is "delete"
                        if n.argument.type is syntax.MemberExpression
                                fake_literal =
                                        type: syntax.Literal
                                        value: n.argument.property.name
                                        raw: "'#{n.argument.property.name}'"
                                return @createCall callee, [(@visitOrNull n.argument.object), (@visit fake_literal)], "result"
                        else
                                throw "unhandled delete syntax"
                else
                        if not callee
                                throw "Internal error: unary operator '#{n.operator}' not implemented"
                        @createCall callee, [@visitOrNull n.argument], "result"
                

        visitSequenceExpression: (n) ->
                rv = null
                for exp in n.expressions
                        rv = @visit exp
                rv
                
        visitBinaryExpression: (n) ->
                debug.log -> "operator = '#{n.operator}'"
                builtin = "binop#{n.operator}"
                callee = @ejs_runtime[builtin]
                if not callee
                        throw "Internal error: unhandled binary operator '#{n.operator}'"

                left_alloca = @createAlloca @currentFunction, types.EjsValue, "binop_left"
                left_visited = @visit n.left
                ir.createStore left_visited, left_alloca
                
                right_alloca = @createAlloca @currentFunction, types.EjsValue, "binop_right"
                right_visited = @visit n.right
                ir.createStore right_visited, right_alloca

                if n.left.is_constant? and n.right.is_constant?
                        console.warn "we could totally evaluate this at compile time, yo"
                        

                if left_visited.literal? and right_visited.literal?
                        if typeof left_visited.literal.value is "number" and typeof right_visited.literal.value is "number"
                                if n.operator is "<"
                                        return @loadBoolEjsValue left_visited.literal.value < right_visited.literal.value
                                        
                # call the actual runtime binaryop method
                @createCall callee, [(@createLoad left_alloca, "binop_left_load"), (@createLoad right_alloca, "binop_right_load")], "result_#{builtin}", !callee.doesNotThrow

        visitLogicalExpression: (n) ->
                debug.log -> "operator = '#{n.operator}'"
                result = @createAlloca @currentFunction, types.EjsValue, "result_#{n.operator}"

                insertBlock = ir.getInsertBlock()
                insertFunc = insertBlock.parent
        
                left_bb  = new llvm.BasicBlock "cond_left", insertFunc
                right_bb  = new llvm.BasicBlock "cond_right", insertFunc
                merge_bb = new llvm.BasicBlock "cond_merge", insertFunc

                # we invert the test here - check if the condition is false/0
                left_visited = @generateCondBr n.left, left_bb, right_bb

                @doInsideBlock left_bb, =>
                        # inside the else branch, left was truthy
                        if n.operator is "||"
                                # for || we short circuit out here
                                ir.createStore left_visited, result
                        else if n.operator is "&&"
                                # for && we evaluate the second and store it
                                ir.createStore (@visit n.right), result
                        else
                                throw "Internal error 99.1"
                        ir.createBr merge_bb

                @doInsideBlock right_bb, =>
                        # inside the then branch, left was falsy
                        if n.operator is "||"
                                # for || we evaluate the second and store it
                                ir.createStore (@visit n.right), result
                        else if n.operator is "&&"
                                # for && we short circuit out here
                                ir.createStore left_visited, result
                        else
                                throw "Internal error 99.1"
                        ir.createBr merge_bb

                ir.setInsertPoint merge_bb
                @createLoad result, "result_#{n.operator}_load"

        visitArgsForCall: (callee, pullThisFromArg0, args) ->
                argv = []

                args_offset = 0
                if callee.takes_builtins
                        args_offset = 1
                        if pullThisFromArg0 and args[0].type is syntax.MemberExpression
                                thisArg = @visit args[0].object
                                closure = @createPropertyLoad thisArg, args[0].property, args[0].computed
                        else
                                thisArg = @loadUndefinedEjsValue()
                                closure = @visit args[0]
                        
                        argv.push closure                                                   # %closure
                        argv.push thisArg                                                   # %this
                        argv.push consts.int32 args.length-1    # %argc. -1 because we pulled out the first arg to send as the closure

                if args.length > args_offset
                        argv.push @visitOrNull args[i] for i in [args_offset...args.length]

                argv

        visitArgsForConstruct: (callee, args) ->
                argv = []

                ctor = @visit args[0]

                proto = @createPropertyLoad ctor, { name: "prototype" }, false

                create = @ejs_runtime.object_create
                thisArg = @createCall create, [proto], "objtmp", !create.doesNotThrow
                                                
                argv.push ctor                                                      # %closure
                argv.push thisArg                                                   # %this
                argv.push consts.int32 args.length-1    # %argc. -1 because we pulled out the first arg to send as the closure

                if args.length > 1
                        argv.push @visitOrNull args[i] for i in [1...args.length]

                argv
                                                                
        visitCallExpression: (n) ->
                debug.log -> "visitCall #{JSON.stringify n}"
                debug.log -> "          arguments length = #{n.arguments.length}"
                debug.log -> "          arguments[#{i}] =  #{JSON.stringify n.arguments[i]}" for i in [0...n.arguments.length]

                intrinsicHandler = @ejs_intrinsics[n.callee.name.slice 1]
                if not intrinsicHandler?
                        throw "Internal error: callee should not be null in visitCallExpression (callee = #{n.callee.name}, arguments = #{n.arguments.length})"

                intrinsicHandler.call @, n
                
        visitNewExpression: (n) ->
                if n.callee.type isnt syntax.Identifier or n.callee.name[0] isnt '%'
                        throw "invalid ctor #{JSON.stringify n.callee}"

                if n.callee.name isnt "%invokeClosure"
                        throw "new expressions may only have a callee of %invokeClosure, callee = #{n.callee.name}"
                        
                intrinsicHandler = @ejs_intrinsics[n.callee.name.slice 1]
                if not intrinsicHandler
                        throw "Internal error: ctor should not be null"

                intrinsicHandler.call @, n, true

        visitThisExpression: (n) ->
                debug.log "visitThisExpression"
                @createLoadThis()

        visitIdentifier: (n) ->
                debug.log -> "identifier #{n.name}"
                val = n.name
                source = @findIdentifierInScope val
                if source?
                        debug.log -> "found identifier in scope, at #{source}"
                        rv = @createLoad source, "load_#{val}"
                        return rv

                # special handling of the arguments object here, so we
                # only initialize/create it if the function is
                # actually going to use it.
                if val is "arguments"
                        arguments_alloca = @createAlloca @currentFunction, types.EjsValue, "local_arguments_object"
                        saved_insert_point = ir.getInsertBlock()
                        ir.setInsertPoint @currentFunction.entry_bb

                        load_argc = @createLoad @currentFunction.topScope["%argc"], "argc_load"
                        load_args = @createLoad @currentFunction.topScope["%args"], "args_load"

                        args_new = @ejs_runtime.arguments_new
                        arguments_object = @createCall args_new, [load_argc, load_args], "argstmp", !args_new.doesNotThrow
                        ir.createStore arguments_object, arguments_alloca
                        @currentFunction.topScope["arguments"] = arguments_alloca

                        ir.setInsertPoint saved_insert_point
                        rv = @createLoad arguments_alloca, "load_arguments"
                        return rv

                rv = null
                debug.log -> "calling getFunction for #{val}"
                rv = @module.getFunction val

                if not rv
                        debug.log -> "Symbol '#{val}' not found in current scope"
                        rv = @createPropertyLoad @loadGlobal(), n, false, false

                debug.log -> "returning #{rv}"
                rv

        visitObjectExpression: (n) ->
                object_create = @ejs_runtime.object_create
                obj = @createCall object_create, [@loadNullEjsValue()], "objtmp", !object_create.doesNotThrow
                for property in n.properties
                        val = @visit property.value
                        key = if property.key.type is syntax.Identifier then @getAtom property.key.name else @visit property.key

                        @createCall @ejs_runtime.object_define_value_prop, [obj, key, val, consts.int32 0x77], "define_value_prop_#{property.key}"
                        #@createPropertyStore obj, key, val, false
                obj

        visitArrayExpression: (n) ->
                obj = @createCall @ejs_runtime.array_new, [consts.int32 0], "arrtmp", !@ejs_runtime.array_new.doesNotThrow
                i = 0;
                for el in n.elements
                        val = @visit el
                        index = type: syntax.Literal, value: i
                        @createPropertyStore obj, index, val, true
                        i = i + 1
                obj
                
        visitExpressionStatement: (n) ->
                n.expression.result_not_used = true
                @visit n.expression

        generateUCS2: (id, jsstr) ->
                ucsArrayType = llvm.ArrayType.get types.jschar, jsstr.length+1
                array_data = []
                (array_data.push consts.jschar jsstr.charCodeAt i) for i in [0...jsstr.length]
                array_data.push consts.jschar 0
                array = llvm.ConstantArray.get ucsArrayType, array_data
                arrayglobal = new llvm.GlobalVariable @module, ucsArrayType, "ucs2-#{id}", array
                arrayglobal

        generateEJSPrimString: (id, len) ->
                strglobal = new llvm.GlobalVariable @module, types.EjsPrimString, "primstring-#{id}", llvm.Constant.getAggregateZero types.EjsPrimString
                strglobal

        generateEJSValueForString: (id) ->
                name = "ejsval-string-#{id}"
                strglobal = new llvm.GlobalVariable @module, types.EjsValue, name, llvm.Constant.getAggregateZero types.EjsValue
                @module.getOrInsertGlobal name, types.EjsValue
                
        addStringLiteralInitialization: (name, ucs2, primstr, val, len) ->
                saved_insert_point = ir.getInsertBlock()

                ir.setInsertPointStartBB @literalInitializationBB
                strname = ir.createGlobalStringPtr name, "strname"

                arg0 = strname
                arg1 = val
                arg2 = primstr
                arg3 = ir.createInBoundsGetElementPointer ucs2, [(consts.int32 0), (consts.int32 0)], "ucs2"

                ir.createCall @ejs_runtime.init_string_literal, [arg0, arg1, arg2, arg3, consts.int32 len], ""

                ir.setInsertPoint saved_insert_point

        getAtom: (str) ->
                # check if it's an atom (a runtime library constant) first of all
                atom_name = "atom-#{str}"
                if @ejs_runtime[atom_name]?
                        return @createLoad @ejs_runtime[atom_name], "%str_atom_load"

                # if it's not, we create a constant and embed it in this module
        
                literal_key = "string-" + str
                if not @module_atoms[literal_key]?
                        literalId = genId()
                        ucs2_data = @generateUCS2 literalId, str
                        primstring = @generateEJSPrimString literalId, str.length
                        @module_atoms[literal_key] = @generateEJSValueForString literalId
                        @addStringLiteralInitialization str, ucs2_data, primstring, @module_atoms[literal_key], str.length

                strload = @createLoad @module_atoms[literal_key], "%literal_load"
                        
        visitLiteral: (n) ->
                # null literals, load _ejs_null
                if n.value is null
                        debug.log "literal: null"
                        return @loadNullEjsValue()

                        
                # undefined literals, load _ejs_undefined
                if n.value is undefined
                        debug.log "literal: undefined"
                        return @loadUndefinedEjsValue()

                # string literals
                if typeof n.raw is "string" and (n.raw[0] is '"' or n.raw[0] is "'")
                        debug.log -> "literal string: #{n.value}"

                        strload = @getAtom n.value
                        
                        strload.literal = n
                        debug.log -> "strload = #{strload}"
                        return strload

                # regular expression literals
                if typeof n.raw is "string" and n.raw[0] is '/'
                        debug.log -> "literal regexp: #{n.raw}"

                        source = ir.createGlobalStringPtr n.value.source, "regexpsource"
                        flags = ir.createGlobalStringPtr "#{if n.value.global then 'g' else ''}#{if n.value.multiline then 'm' else ''}#{if n.value.ignoreCase then 'i' else ''}", "regexpflags"
                        
                        regexp_new_utf8 = @ejs_runtime.regexp_new_utf8
                        regexpcall = @createCall regexp_new_utf8, [source, flags], "regexptmp", !regexp_new_utf8.doesNotThrow
                        debug.log -> "regexpcall = #{regexpcall}"
                        return regexpcall

                # number literals
                if typeof n.value is "number"
                        debug.log -> "literal number: #{n.value}"
                        if n.value is 0
                                numload = @createLoad @ejs_runtime['zero'], "load_zero"
                        else if n.value is 1
                                numload = @createLoad @ejs_runtime['one'], "load_one"
                        else
                                literal_key = "num-" + n.value
                                if @currentFunction.literalAllocas[literal_key]
                                        num_alloca = @currentFunction.literalAllocas[literal_key]
                                else
                                        # only create 1 instance of num literals used in a function, and allocate them in the entry block
                                        @doInsideBlock @currentFunction.entry_bb, =>
                                                num_alloca = ir.createAlloca types.EjsValue, "num-alloca-#{n.value}"
                                                c = llvm.ConstantFP.getDouble n.value
                                                number_new = @ejs_runtime.number_new
                                                call = @createCall number_new, [c], "numconst-#{n.value}", !number_new.doesNotThrow
                                                ir.createStore call, num_alloca
                                                @currentFunction.literalAllocas[literal_key] = num_alloca
                                        
                                numload = @createLoad num_alloca, "%num_alloca"
                        numload.literal = n
                        debug.log -> "numload = #{numload}"
                        return numload

                # boolean literals
                if typeof n.value is "boolean"
                        debug.log -> "literal boolean: #{n.value}"
                        return @loadBoolEjsValue n.value

                throw "Internal error: unrecognized literal of type #{typeof n.value}"

        createCall: (callee, argv, callname, canThrow=true) ->
                # if we're inside a try block we have to use createInvoke, and pass two basic blocks:
                #   the normal block, which is basically this IR instruction's continuation
                #   the unwind block, where we land if the call throws an exception.
                #
                # Although for builtins we know won't throw, we can still use createCall.
                if TryExitableScope.unwindStack.depth is 0 or callee.doesNotThrow or not canThrow
                        calltmp = ir.createCall callee, argv, callname
                        calltmp.setDoesNotThrow() if callee.doesNotThrow
                        calltmp.setDoesNotAccessMemory() if callee.doesNotAccessMemory
                        calltmp.setOnlyReadsMemory() if not callee.doesNotAccessMemory and callee.onlyReadsMemory
                else
                        insertBlock = ir.getInsertBlock()
                        insertFunc = insertBlock.parent
                        normal_block  = new llvm.BasicBlock "normal", insertFunc
                        calltmp = ir.createInvoke callee, argv, normal_block, TryExitableScope.unwindStack.top.getLandingPadBlock(), callname
                        calltmp.setDoesNotThrow() if callee.doesNotThrow
                        calltmp.setDoesNotAccessMemory() if callee.doesNotAccessMemory
                        calltmp.setOnlyReadsMemory() if not callee.doesNotAccessMemory and callee.onlyReadsMemory
                        # after we've made our call we need to change the insertion point to our continuation
                        ir.setInsertPoint normal_block
                calltmp
        
        visitThrow: (n) ->
                arg = @visit n.argument
                @createCall @ejs_runtime.throw, [arg], "", true
                ir.createUnreachable()

        visitTry: (n) ->
                insertBlock = ir.getInsertBlock()
                insertFunc = insertBlock.parent

                # the alloca that stores the reason we ended up in the finally block
                @currentFunction.cleanup_reason = @createAlloca @currentFunction, types.int32, "cleanup_reason" unless @currentFunction.cleanup_reason?

                if n.finalizer?
                        finally_block = new llvm.BasicBlock "finally_bb", insertFunc
                        @finallyStack.unshift finally_block

                # the merge bb where everything branches to after falling off the end of a catch/finally block
                merge_block = new llvm.BasicBlock "try_merge", insertFunc

                # if we have a finally clause, create finally_block
                if finally_block?
                        branch_target = finally_block
                else
                        branch_target = merge_block

                scope = new TryExitableScope @currentFunction.cleanup_reason, branch_target, (-> new llvm.BasicBlock "exception", insertFunc), finally_block?
                scope.enter()

                @visit n.block

                if n.finalizer?
                        @finallyStack.shift()
                
                # at the end of the try block branch to our branch_target (either the finally block or the merge block after the try{}) with REASON_FALLOFF
                scope.exitAft false

                scope.leave()

                if scope.landing_pad_block? and n.handlers.length > 0
                        catch_block = new llvm.BasicBlock "catch_bb", insertFunc


                if scope.landing_pad_block?
                        # the scope's landingpad block is created if needed by @createCall (using that function we pass in as the last argument to TryExitableScope's ctor.)
                        # if a try block includes no calls, there's no need for an landing pad block as nothing can throw, and we don't bother generating any code for the
                        # catch clause.
                        @doInsideBlock scope.landing_pad_block, =>

                                landing_pad_type = llvm.StructType.create "", [types.int8Pointer, types.int32]
                                # XXX is it an error to have multiple catch handlers, as JS doesn't allow you to filter by type?
                                clause_count = if n.handlers.length > 0 then 1 else 0
                        
                                casted_personality = ir.createPointerCast @ejs_runtime.personality, types.int8Pointer, "personality"
                                caught_result = ir.createLandingPad landing_pad_type, casted_personality, clause_count, "caught_result"
                                caught_result.addClause ir.createPointerCast @ejs_runtime.exception_typeinfo, types.int8Pointer, ""
                                caught_result.setCleanup true

                                exception = ir.createExtractValue caught_result, 0, "exception"
                                
                                if catch_block?
                                        ir.createBr catch_block
                                else if finally_block?
                                        ir.createBr finally_block
                                else
                                        throw "this shouldn't happen.  a try{} without either a catch{} or finally{}"

                                # if we have a catch clause, create catch_bb
                                if n.handlers.length > 0
                                        @doInsideBlock catch_block, =>
                                                # call _ejs_begin_catch to return the actual exception
                                                catchval = @beginCatch exception
                                
                                                # create a new scope which maps the catch parameter name (the "e" in "try { } catch (e) { }") to catchval
                                                catch_scope = Object.create null
                                                if n.handlers[0].param?.name?
                                                        catch_name = n.handlers[0].param.name
                                                        alloca = @createAlloca @currentFunction, types.EjsValue, "local_catch_#{catch_name}"
                                                        catch_scope[catch_name] = alloca
                                                        ir.createStore catchval, alloca

                                                @visitWithScope catch_scope, [n.handlers[0]]

                                                # unsure about this one - we should likely call end_catch if another exception is thrown from the catch block?
                                                @endCatch()

                                                # if we make it to the end of the catch block, branch unconditionally to the branch target (either this try's
                                                # finally block or the merge pointer after the try)
                                                ir.createBr branch_target

                                ###
                                # Unwind Resume Block (calls _Unwind_Resume)
                                unwind_resume_block = new llvm.BasicBlock "unwind_resume", insertFunc
                                @doInsideBlock unwind_resume_block, =>
                                        ir.createResume caught_result
                                ###

                # Finally Block
                if n.finalizer?
                        @doInsideBlock finally_block, =>
                                @visit n.finalizer

                                cleanup_reason = @createLoad @currentFunction.cleanup_reason, "cleanup_reason_load"

                                if @returnValueAlloca?
                                        return_tramp = new llvm.BasicBlock "return_tramp", insertFunc
                                        @doInsideBlock return_tramp, =>
                                
                                                if @finallyStack.length > 0
                                                        ir.createStore (consts.int32 ExitableScope.REASON_RETURN), @currentFunction.cleanup_reason
                                                        ir.createBr @finallyStack[0]
                                                else
                                                        rv = @createLoad @returnValueAlloca, "rv"
                                                        ir.createRet rv
                        
                                switch_stmt = ir.createSwitch cleanup_reason, merge_block, scope.destinations.length + 1
                                if @returnValueAlloca?
                                        switch_stmt.addCase (consts.int32 ExitableScope.REASON_RETURN), return_tramp

                                falloff_tramp = new llvm.BasicBlock "falloff_tramp", insertFunc
                                @doInsideBlock falloff_tramp, =>
                                        ir.createBr merge_block
                                switch_stmt.addCase (consts.int32 TryExitableScope.REASON_FALLOFF_TRY), falloff_tramp

                                for s in [0...scope.destinations.length]
                                        dest_tramp = new llvm.BasicBlock "dest_tramp", insertFunc
                                        dest = scope.destinations[s]
                                        @doInsideBlock dest_tramp, =>
                                                if dest.reason == TryExitableScope.REASON_BREAK
                                                        dest.scope.exitAft true
                                                else if dest.reason == TryExitableScope.REASON_CONTINUE
                                                        dest.scope.exitFore()
                                        switch_stmt.addCase dest.id, dest_tramp
                                        
                                        
                                switch_stmt
                        
                ir.setInsertPoint merge_block

        handleInvokeClosureIntrinsic: (exp, ctor_context= false) ->
                if ctor_context
                        argv = @visitArgsForConstruct @ejs_runtime.invoke_closure, exp.arguments
                else
                        argv = @visitArgsForCall @ejs_runtime.invoke_closure, true, exp.arguments

                modified_argv = (argv[n] for n in [0...BUILTIN_PARAMS.length])

                if argv.length > BUILTIN_PARAMS.length
                        argv = argv.slice BUILTIN_PARAMS.length
                        argv.forEach (a,i) =>
                                gep = ir.createGetElementPointer @currentFunction.scratch_area, [(consts.int32 0), (consts.int64 i)], "arg_gep_#{i}"
                                store = ir.createStore argv[i], gep, "argv[#{i}]-store"

                        argsCast = ir.createGetElementPointer @currentFunction.scratch_area, [(consts.int32 0), (consts.int64 0)], "call_args_load"
                                                
                        modified_argv[BUILTIN_PARAMS.length] = argsCast

                else
                        modified_argv[BUILTIN_PARAMS.length] = consts.null types.EjsValue.pointerTo()
                                
                argv = modified_argv
                call_result = @createAlloca @currentFunction, types.EjsValue, "call_result"

                if decompose_closure_on_invoke
                        insertBlock = ir.getInsertBlock()
                        insertFunc = insertBlock.parent

                        # inline decomposition of the closure (with a fallback to the runtime invoke if there are bound args)
                        # and direct call
                        runtime_invoke_bb = new llvm.BasicBlock "runtime_invoke_bb", insertFunc
                        direct_invoke_bb = new llvm.BasicBlock "direct_invoke_bb", insertFunc
                        invoke_merge_bb = new llvm.BasicBlock "invoke_merge_bb", insertFunc

                        func_alloca = @createAlloca @currentFunction, types.EjsClosureFunc, "direct_invoke_func"
                        env_alloca  = @createAlloca @currentFunction, types.EjsClosureEnv, "direct_invoke_env"
                        this_alloca = @createAlloca @currentFunction, types.EjsValue, "direct_invoke_this"

                        # provide the default "this" for decompose_closure.  if one was bound it'll get overwritten
                        ir.createStore argv[1], this_alloca
                        
                        decompose_args = [ argv[0], func_alloca, env_alloca, this_alloca ]
                        decompose_rv = @createCall @ejs_runtime.decompose_closure, decompose_args, "decompose_rv", true
                        cmp = ir.createICmpEq decompose_rv, consts.false(), "cmpresult"
                        ir.createCondBr cmp, runtime_invoke_bb, direct_invoke_bb

                        # if there were bound args we have to fall back to the runtime invoke method (since we can't
                        # guarantee enough room in our scratch area -- should we inline a check here or pass the length
                        # of the scratch area to decompose?  perhaps...FIXME)
                        #
                        @doInsideBlock runtime_invoke_bb, =>
                                calltmp = @createCall @ejs_runtime.invoke_closure, argv, "calltmp", true
                                store = ir.createStore calltmp, call_result
                                ir.createBr invoke_merge_bb

                        # in the successful case we modify our argv with the responses and directly invoke the closure func
                        @doInsideBlock direct_invoke_bb, =>
                                direct_args = [ (@createLoad env_alloca, "env"), (@createLoad this_alloca, "this"), argv[2], argv[3] ]
                                calltmp = @createCall (@createLoad func_alloca, "func"), direct_args, "calltmp"
                                store = ir.createStore calltmp, call_result
                                ir.createBr invoke_merge_bb

                        ir.setInsertPoint invoke_merge_bb
                else
                        calltmp = @createCall @ejs_runtime.invoke_closure, argv, "calltmp", true
                        store = ir.createStore calltmp, call_result
        
                if ctor_context
                        argv[1]
                else
                        @createLoad call_result, "call_result_load"
                        
        handleMakeClosureIntrinsic: (exp, ctor_context= false) ->
                argv = @visitArgsForCall @ejs_runtime.make_closure, false, exp.arguments
                closure_result = @createAlloca @currentFunction, types.EjsValue, "closure_result"
                calltmp = ir.createCall @ejs_runtime.make_closure, argv, "closure_tmp"
                store = ir.createStore calltmp, closure_result
                @createLoad closure_result, "closure_result_load"

        handleMakeAnonClosureIntrinsic: (exp, ctor_context= false) ->
                argv = @visitArgsForCall @ejs_runtime.make_anon_closure, false, exp.arguments
                closure_result = @createAlloca @currentFunction, types.EjsValue, "closure_result"
                calltmp = ir.createCall @ejs_runtime.make_anon_closure, argv, "closure_tmp"
                store = ir.createStore calltmp, closure_result
                @createLoad closure_result, "closure_result_load"
                
        handleCreateArgScratchAreaIntrinsic: (exp, ctor_context= false) ->
                argsArrayType = llvm.ArrayType.get types.EjsValue, exp.arguments[0].value
                @currentFunction.scratch_area = @createAlloca @currentFunction, argsArrayType, "args_scratch_area"

        handleMakeClosureEnvIntrinsic: (exp, ctor_context= false) ->
                size = exp.arguments[0].value
                ir.createCall @ejs_runtime.make_closure_env, [consts.int32 size], "env_tmp"

        handleSlotIntrinsic: (exp) ->
                env = @visitOrNull exp.arguments[0]
                slotnum = exp.arguments[1].value
                ir.createCall @ejs_runtime.get_env_slot_val, [env, (consts.int32 slotnum)], "slot_val_tmp"

        handleSlotRefIntrinsic: (exp) ->
                env = @visitOrNull exp.arguments[0]
                slotnum = exp.arguments[1].value
                ir.createCall @ejs_runtime.get_env_slot_ref, [env, (consts.int32 slotnum)], "slot_ref_tmp"

class AddFunctionsVisitor extends NodeVisitor
        constructor: (@module) ->
                super

        visitFunction: (n) ->
                n.ir_name = "_ejs_anonymous"
                if n?.id?.name?
                        n.ir_name = n.id.name

                # at this point point n.params includes %env as its first param, and is followed by all the formal parameters from the original
                # script source.  we insert %this and %argc between these.  the LLVMIR phase later removes the actual formal parameters and
                # adds the "EJSValue** args" array, loading the formal parameter values from that.

                n.params[0].llvm_type = BUILTIN_PARAMS[0].llvm_type
                n.params.splice 1, 0, BUILTIN_PARAMS[1]
                n.params.splice 2, 0, BUILTIN_PARAMS[2]

                # set the types of all later arguments to be types.EjsValue
                param.llvm_type = types.EjsValue for param in n.params[BUILTIN_PARAMS.length..]

                # the LLVMIR func we allocate takes the proper EJSValue** parameter in the 4th spot instead of all the parameters
                n.ir_func = types.takes_builtins @module.getOrInsertFunction n.ir_name, types.EjsValue, (param.llvm_type for param in BUILTIN_PARAMS).concat [types.EjsValue.pointerTo()]

                # enable shadow stack map for gc roots
                #n.ir_func.setGC "shadow-stack"
                
                ir_args = n.ir_func.args
                (ir_args[i].setName n.params[i].name) for i in [0...BUILTIN_PARAMS.length]
                ir_args[BUILTIN_PARAMS.length].setName "%args"

                # we don't need to recurse here since we won't have nested functions at this point
                n

sanitize_with_regexp = (filename) ->
        filename.replace /[.,-\/\\]/g, "_" # this is insanely inadequate

sanitize_with_replace = (filename) ->
        replace_all = (str, from, to) ->
                while (str.indexOf from) > -1
                        str = str.replace from, to
                str

        filename = replace_all filename, ".", "_"
        filename = replace_all filename, ",", "_"
        filename = replace_all filename, "-", "_"
        filename = replace_all filename, "/", "_"
        filename = replace_all filename, "\\", "_"
        
insert_toplevel_func = (tree, filename) ->
        toplevel =
                type: syntax.FunctionDeclaration,
                id:
                        type: syntax.Identifier
                        name: "_ejs_toplevel_#{sanitize_with_regexp filename}"
                params: [
                        { type: syntax.Identifier, name: "%env_unused" }
                ]
                body:
                        type: syntax.BlockStatement
                        body: tree.body
                toplevel: true
        tree.body = [toplevel]
        tree

exports.compile = (tree, base_output_filename, source_filename) ->
        console.warn "#{bold()}COMPILE#{reset()} #{source_filename} -> #{base_output_filename}"
        
        tree = insert_toplevel_func tree, source_filename

        debug.log -> escodegen.generate tree

        toplevel_name = tree.body[0].id.name
        
        debug.log 1, "before closure conversion"
        debug.log 1, -> escodegen.generate tree
        
        tree = closure_conversion.convert tree, path.basename source_filename

        debug.log 1, "after closure conversion"
        debug.log 1, -> escodegen.generate tree
        
        module = new llvm.Module "compiled-#{base_output_filename}"

        module.toplevel_name = toplevel_name

        visitor = new AddFunctionsVisitor module
        tree = visitor.visit tree

        debug.log -> escodegen.generate tree

        visitor = new LLVMIRVisitor module, source_filename
        visitor.visit tree

        module
