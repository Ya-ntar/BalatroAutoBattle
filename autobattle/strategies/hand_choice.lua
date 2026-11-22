local hand_choice = {}

function hand_choice.best_play(observation, evaluate_hand)
    local available_actions = observation.actions
    if not available_actions.play then return nil end

    local max_play_cards = available_actions.max_play_cards
    local selected_card_ids = {}
    local candidate_card_ids = {}
    for _, hand_card in ipairs(observation.hand) do
        if hand_card.forced then
            if not hand_card.face then return nil end
            selected_card_ids[#selected_card_ids + 1] = hand_card.id
        elseif hand_card.face then
            candidate_card_ids[#candidate_card_ids + 1] = hand_card.id
        end
    end

    local best_card_ids
    local best_estimated_score
    local best_hand_evaluation
    local function search_card_combinations(first_candidate_index, remaining_card_count)
        if remaining_card_count == 0 then
            local hand_evaluation = evaluate_hand(selected_card_ids)
            if hand_evaluation and not hand_evaluation.blocked_by_blind then
                local estimated_score = hand_evaluation.estimate
                if not best_card_ids or estimated_score > best_estimated_score
                    or (estimated_score == best_estimated_score and #selected_card_ids < #best_card_ids) then
                    best_card_ids = {unpack(selected_card_ids)}
                    best_estimated_score = estimated_score
                    best_hand_evaluation = hand_evaluation
                end
            end
            return
        end
        for candidate_index = first_candidate_index, #candidate_card_ids - remaining_card_count + 1 do
            selected_card_ids[#selected_card_ids + 1] = candidate_card_ids[candidate_index]
            search_card_combinations(candidate_index + 1, remaining_card_count - 1)
            selected_card_ids[#selected_card_ids] = nil
        end
    end

    local forced_card_count = #selected_card_ids
    for play_card_count = math.max(1, forced_card_count), math.min(max_play_cards, forced_card_count + #candidate_card_ids) do
        search_card_combinations(1, play_card_count - forced_card_count)
    end
    return best_card_ids and {kind = "play", card_ids = best_card_ids}, best_estimated_score, best_hand_evaluation
end

return hand_choice
