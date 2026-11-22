local turn_plan = require("autobattle.strategies.turn_plan")
local discard = {}

local discard_score_threshold_ratio = 0.75

local function discard_unselected_cards_when_score_is_low(observation, play_step, estimated_play_score)
    local round_snapshot = observation.round
    local available_actions = observation.actions
    if not play_step or not available_actions.discard or round_snapshot.hands_left <= 0 then return nil end
    local points_needed_per_hand = math.ceil((round_snapshot.target - round_snapshot.score) / round_snapshot.hands_left)
    if estimated_play_score >= points_needed_per_hand * discard_score_threshold_ratio then return nil end

    local max_replacement_cards = math.min(available_actions.max_discard_cards, #observation.deck_remaining)
    local keep_by_card_id = {}
    local discard_card_ids = {}
    for _, kept_card_id in ipairs(play_step.card_ids) do keep_by_card_id[kept_card_id] = true end
    for _, hand_card in ipairs(observation.hand) do
        if hand_card.forced then return nil end
        if #discard_card_ids < max_replacement_cards and not keep_by_card_id[hand_card.id] then
            discard_card_ids[#discard_card_ids + 1] = hand_card.id
        end
    end
    if #discard_card_ids > 0 then return {kind = "discard", card_ids = discard_card_ids} end
end

function discard.decide(observation, evaluate_hand)
    return turn_plan.create(observation, evaluate_hand, discard_unselected_cards_when_score_is_low)
end

return discard
