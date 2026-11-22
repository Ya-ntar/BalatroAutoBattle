local hand_choice = require("autobattle.strategies.hand_choice")
local turn_plan = {}

local function select_cards_for_blind_constraint(observation)
    local available_actions = observation.actions
    local boss_rules = observation.round.boss
    if not available_actions.play then return nil end

    local minimum_play_cards = boss_rules and boss_rules.min_play_cards or 1
    local selected_card_ids = {}
    local candidate_card_ids = {}
    local visible_card_count = 0
    local has_hidden_forced_card = false
    for _, hand_card in ipairs(observation.hand) do
        if hand_card.face then visible_card_count = visible_card_count + 1 end
        if hand_card.forced then
            selected_card_ids[#selected_card_ids + 1] = hand_card.id
            if not hand_card.face then has_hidden_forced_card = true end
        else
            candidate_card_ids[#candidate_card_ids + 1] = hand_card.id
        end
    end
    if not has_hidden_forced_card and visible_card_count >= minimum_play_cards then return nil end
    if math.max(#selected_card_ids, minimum_play_cards) > available_actions.max_play_cards
        or #observation.hand < minimum_play_cards then
        return nil
    end

    for index = 1, minimum_play_cards - #selected_card_ids do
        selected_card_ids[#selected_card_ids + 1] = candidate_card_ids[index]
    end
    return {kind = "play", card_ids = selected_card_ids}
end

local function same_scoring_card_ids(first_scoring_ids, second_scoring_ids)
    if #first_scoring_ids ~= #second_scoring_ids then return false end
    for index, scoring_card_id in ipairs(first_scoring_ids) do
        if scoring_card_id ~= second_scoring_ids[index] then return false end
    end
    return true
end

local function fill_play_without_changing_score(observation, evaluate_hand, play_step, original_hand_evaluation)
    if not original_hand_evaluation then return play_step end
    local selected_card_ids = play_step.card_ids
    local max_play_cards = observation.actions.max_play_cards
    local round_snapshot = observation.round
    if #selected_card_ids >= max_play_cards
        or (round_snapshot.blind_key == "bl_tooth" and not round_snapshot.blind_disabled) then
        return play_step
    end
    for _, joker_snapshot in ipairs(observation.jokers) do
        if not joker_snapshot.debuffed and (not joker_snapshot.key or joker_snapshot.key == "j_splash") then return play_step end
    end

    local selected_by_card_id = {}
    local filler_card_candidates = {}
    for _, selected_card_id in ipairs(selected_card_ids) do selected_by_card_id[selected_card_id] = true end
    for hand_index, hand_card in ipairs(observation.hand) do
        local card_face = hand_card.face
        if not selected_by_card_id[hand_card.id] and card_face and not card_face.enhancement and not card_face.edition
            and not card_face.seal and not hand_card.permanent_bonus then
            filler_card_candidates[#filler_card_candidates + 1] = {
                id = hand_card.id, chips = hand_card.chip_bonus or 0, index = hand_index,
            }
        end
    end
    table.sort(filler_card_candidates, function(first_candidate, second_candidate)
        if first_candidate.chips == second_candidate.chips then return first_candidate.index < second_candidate.index end
        return first_candidate.chips < second_candidate.chips
    end)

    for _, filler_card in ipairs(filler_card_candidates) do
        if #selected_card_ids == max_play_cards then break end
        selected_card_ids[#selected_card_ids + 1] = filler_card.id
        local padded_hand_evaluation = evaluate_hand(selected_card_ids)
        if not padded_hand_evaluation or padded_hand_evaluation.blocked_by_blind
            or padded_hand_evaluation.kind ~= original_hand_evaluation.kind
            or not same_scoring_card_ids(original_hand_evaluation.scoring_ids, padded_hand_evaluation.scoring_ids) then
            selected_card_ids[#selected_card_ids] = nil
        end
    end
    return play_step
end

local function discard_forced_or_first_card(observation)
    local available_actions = observation.actions
    if not available_actions.discard or available_actions.max_discard_cards < 1 then return nil end

    local discard_card_ids = {}
    for _, hand_card in ipairs(observation.hand) do
        if hand_card.forced then discard_card_ids[#discard_card_ids + 1] = hand_card.id end
    end
    if #discard_card_ids > available_actions.max_discard_cards then return nil end
    if #discard_card_ids == 0 and observation.hand[1] then discard_card_ids[1] = observation.hand[1].id end
    if #discard_card_ids > 0 then return {kind = "discard", card_ids = discard_card_ids} end
end

function turn_plan.create(observation, evaluate_hand, choose_discard)
    local play_step,
        estimated_play_score,
        hand_evaluation = hand_choice.best_play(observation, evaluate_hand)
    if not play_step then
        play_step = select_cards_for_blind_constraint(observation)
        estimated_play_score = 0
    end

    local discard_step = choose_discard and choose_discard(observation, play_step, estimated_play_score)
    local selected_action = discard_step
        or fill_play_without_changing_score(observation, evaluate_hand, play_step, hand_evaluation)
        or discard_forced_or_first_card(observation)
    return {observation_id = observation.id, steps = selected_action and {selected_action} or {}}
end

return turn_plan
