local poker_recognizer_card_methods = {
    get_id = function(recognizer_card)
        return recognizer_card.poker_rank_id
    end,
    get_nominal = function(recognizer_card)
        return recognizer_card.nominal
    end,
    matches_suit_for_flush = function(recognizer_card, suit_name)
        return recognizer_card.counts_as_suit_for_flush[suit_name]
    end,
}
poker_recognizer_card_methods.is_suit = poker_recognizer_card_methods.matches_suit_for_flush

local poker_recognizer_card_metatable = {__index = poker_recognizer_card_methods}
local suit_names = {"Spades", "Hearts", "Clubs", "Diamonds"}

local function copy_card_for_recognition(game_card, observed_card, hand_position)
    local is_stone_card = game_card.ability.effect == "Stone Card"
    local poker_rank_id
    if is_stone_card and not game_card.vampired then
        poker_rank_id = -hand_position
    else
        poker_rank_id = game_card:get_id()
    end

    local counts_as_suit_for_flush = {}
    for _, suit_name in ipairs(suit_names) do
        counts_as_suit_for_flush[suit_name] = game_card:is_suit(suit_name, nil, true)
    end

    return setmetatable({
        id = observed_card.id,
        hand_position = hand_position,
        chips = observed_card.chip_bonus,
        is_stone_card = is_stone_card,
        poker_rank_id = poker_rank_id,
        nominal = game_card:get_nominal(),
        counts_as_suit_for_flush = counts_as_suit_for_flush,
    }, poker_recognizer_card_metatable)
end

local function comes_first_in_hand(first_card, second_card)
    return first_card.hand_position < second_card.hand_position
end

local function snapshot_blind(blind)
    local blind_snapshot = {name = blind.name, disabled = blind.disabled, only_hand = blind.only_hand}
    if blind.debuff then
        blind_snapshot.debuff = {
            hand = blind.debuff.hand,
            h_size_ge = blind.debuff.h_size_ge,
            h_size_le = blind.debuff.h_size_le,
        }
    end
    if blind.hands then
        blind_snapshot.hands = {}
        for poker_hand_key, was_played in pairs(blind.hands) do blind_snapshot.hands[poker_hand_key] = was_played end
    end
    return blind_snapshot
end

local function create_hand_evaluator_for_turn(game, captured_turn)
    local recognizer_cards_by_id = {}
    local base_scoring_by_hand_key = {}
    local max_play_cards = captured_turn.observation.actions.max_play_cards
    local recognize_poker_hand = game.FUNCS.get_poker_hand_info
    local blind_snapshot = snapshot_blind(game.GAME.blind)
    local check_blind_debuff = game.GAME.blind.debuff_hand
    for hand_index, hand_card_snapshot in ipairs(captured_turn.observation.hand) do
        recognizer_cards_by_id[hand_card_snapshot.id] = hand_card_snapshot.face
            and copy_card_for_recognition(captured_turn.cards_by_id[hand_card_snapshot.id], hand_card_snapshot, hand_index)
            or false
    end
    for poker_hand_key, poker_hand_state in pairs(game.GAME.hands) do
        base_scoring_by_hand_key[poker_hand_key] = {chips = poker_hand_state.chips, mult = poker_hand_state.mult}
    end

    local function evaluate_card_selection(selected_card_ids)
        if type(selected_card_ids) ~= "table" or #selected_card_ids < 1 or #selected_card_ids > max_play_cards then
            return nil, "INVALID_TARGETS"
        end
        local selected_recognizer_cards = {}
        local selected_card_set = {}
        for index = 1, #selected_card_ids do
            local recognizer_card = recognizer_cards_by_id[selected_card_ids[index]]
            if recognizer_card == nil or selected_card_set[recognizer_card] then return nil, "INVALID_TARGETS" end
            if not recognizer_card then return nil, "HIDDEN_CARD" end
            selected_card_set[recognizer_card] = true
            selected_recognizer_cards[index] = recognizer_card
        end
        table.sort(selected_recognizer_cards, comes_first_in_hand)

        local poker_hand_key,
            _,
            combinations_by_hand_key,
            scoring_cards = recognize_poker_hand(selected_recognizer_cards)
        local base_scoring = base_scoring_by_hand_key[poker_hand_key]
        if not base_scoring then return nil, "UNKNOWN_HAND" end
        local preview_only = true
        local is_blocked_by_blind = check_blind_debuff(
            blind_snapshot, selected_recognizer_cards, combinations_by_hand_key, poker_hand_key, preview_only
        )
        local scoring_card_set = {}
        for _, recognizer_card in ipairs(scoring_cards) do scoring_card_set[recognizer_card] = true end
        for _, recognizer_card in ipairs(selected_recognizer_cards) do
            if recognizer_card.is_stone_card and not scoring_card_set[recognizer_card] then
                scoring_cards[#scoring_cards + 1] = recognizer_card
            end
        end

        local total_chips = base_scoring.chips
        local scoring_card_ids = {}
        local matched_by_hand_key = {}
        for index, recognizer_card in ipairs(scoring_cards) do
            total_chips = total_chips + recognizer_card.chips
            scoring_card_ids[index] = recognizer_card.id
        end
        for matched_hand_key, hand_combinations in pairs(combinations_by_hand_key) do
            if matched_hand_key ~= "top" and next(hand_combinations) then matched_by_hand_key[matched_hand_key] = true end
        end
        return {
            kind = poker_hand_key, scoring_ids = scoring_card_ids, matches = matched_by_hand_key,
            blocked_by_blind = not not is_blocked_by_blind,
            base_chips = base_scoring.chips, base_mult = base_scoring.mult, estimate = total_chips * base_scoring.mult,
        }
    end
    return evaluate_card_selection
end

return create_hand_evaluator_for_turn
