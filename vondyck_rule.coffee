{RewriteRuleset, knuthBendix} = require "./knuth_bendix.coffee"
{vdRule} = require "./vondyck_rewriter.coffee"

#compute the rewriter
#

r = vdRule 15, 15

r1 = knuthBendix r

console.log "ruleset after elimintaion:"
console.log(r1)
