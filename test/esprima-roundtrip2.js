// skip-if: true
// revisit the esprima tests now that we have the es6 modules

import esprima   from 'esprima-es6';
import escodegen from 'escodegen-es6';

var str = "Set.prototype.member = function (el) { return hasOwn.call(this.set, el); };"

console.log (escodegen.generate(esprima.parse(str, { loc: true })));
console.log ("---");
console.log (escodegen.generate(esprima.parse(str, { raw: true })));
