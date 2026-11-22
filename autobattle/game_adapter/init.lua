local observation_builder = require("autobattle.game_adapter.observation")
local turn_context = require("autobattle.game_adapter.context")
local commands = require("autobattle.game_adapter.commands")
local create_hand_evaluator_for_turn = require("autobattle.game_adapter.hand_evaluator")
local balatro_adapter = {}

---@param game GameLike
function balatro_adapter.new(game)
    local last_observation_id = 0
    return {
        is_paused = function()
            return game.SETTINGS and game.SETTINGS.paused or false
        end,
        capture = function()
            if not observation_builder.ready(game) then return nil end
            last_observation_id = last_observation_id + 1
            return turn_context.capture(game, last_observation_id)
        end,
        ---@param captured_turn CapturedTurn
        ---@param validated_step ValidatedStep
        apply = function(captured_turn, validated_step)
            return commands.apply(game, captured_turn, validated_step)
        end,
        bind_evaluator = function(captured_turn)
            return create_hand_evaluator_for_turn(game, captured_turn)
        end,
        ---@param captured_turn CapturedTurn
        ---@param action_receipt ActionReceipt
        poll = function(captured_turn, action_receipt)
            return commands.poll(game, captured_turn, action_receipt)
        end,
        same_context = turn_context.same_context,
    }
end

return balatro_adapter
