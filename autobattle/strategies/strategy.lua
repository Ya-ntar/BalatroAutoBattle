local basic = require("autobattle.strategies.basic")
local discard = require("autobattle.strategies.discard")

return {
    basic = basic.decide,
    discard = discard.decide,
    decide = discard.decide,
}
