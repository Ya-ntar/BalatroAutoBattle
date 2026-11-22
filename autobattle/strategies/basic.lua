local turn_plan = require("autobattle.strategies.turn_plan")
local basic = {}

function basic.decide(observation, evaluate_hand)
    return turn_plan.create(observation, evaluate_hand)
end

return basic
