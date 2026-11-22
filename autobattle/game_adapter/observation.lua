local item_snapshot = require("autobattle.game_adapter.item_snapshot")
local observation_builder = {}

local face_sort_field_names = {"rank", "suit", "enhancement", "edition", "seal"}

local function get_edition(game_card)
    if not game_card.edition then return nil end
    for _, edition_key in ipairs({"foil", "holo", "polychrome", "negative"}) do
        if game_card.edition[edition_key] then return edition_key end
    end
end

local function get_card_face(game_card)
    local card_center = game_card.config.center
    local is_stone_card = game_card.config.center_key == "m_stone"
    return {
        rank = not is_stone_card and game_card.base.value or "",
        suit = not is_stone_card and game_card.base.suit or "",
        enhancement = card_center.set == "Enhanced" and game_card.config.center_key or nil,
        edition = get_edition(game_card),
        seal = game_card.seal,
    }
end

local function compare_card_faces(first_face, second_face)
    for _, field_name in ipairs(face_sort_field_names) do
        local first_field_value = first_face[field_name] or ""
        local second_field_value = second_face[field_name] or ""
        if first_field_value ~= second_field_value then return first_field_value < second_field_value end
    end
    return false
end

local function any_card_being_dragged(cards)
    for _, card in ipairs(cards) do
        if card.states.drag.is then return true end
    end
    return false
end

local function build_available_actions(game, boss_rules)
    local round_state = game.GAME.current_round
    local blind = game.GAME.blind
    local selection_card_limit = math.min(5, #game.hand.cards, game.hand.config.highlighted_limit)
    local max_play_cards = math.min(selection_card_limit, boss_rules and boss_rules.max_play_cards or selection_card_limit)
    local max_discard_cards = math.min(selection_card_limit, game.discard.config.card_limit)
    local can_play = max_play_cards > 0 and round_state.hands_left > 0 and not blind.block_play
    local can_discard = max_discard_cards > 0 and round_state.discards_left > 0
    local can_reorder_jokers = #game.jokers.cards >= 2
    for _, joker_card in ipairs(game.jokers.cards) do
        if joker_card.pinned then can_reorder_jokers = false end
    end
    return {
        play = can_play,
        discard = can_discard,
        reorder_jokers = can_reorder_jokers,
        max_play_cards = can_play and max_play_cards or 0,
        max_discard_cards = can_discard and max_discard_cards or 0,
    }
end

local required_card_areas = {"hand", "deck", "play", "discard", "jokers", "consumeables"}

---@return boolean ready
---@return string? wait_reason
function observation_builder.ready(game)
    if game.STAGE ~= game.STAGES.RUN then return false, "OUTSIDE_RUN" end
    if game.STATE ~= game.STATES.SELECTING_HAND then
        local state_name = tostring(game.STATE)
        for name, state in pairs(game.STATES) do
            if state == game.STATE then
                state_name = name
                break
            end
        end
        return false, "WAITING_FOR_SELECTING_HAND state=" .. state_name
    end
    if not game.STATE_COMPLETE then return false, "STATE_NOT_COMPLETE" end

    local run_state = game.GAME
    if not run_state then return false, "MISSING_RUN" end
    if not run_state.facing_blind then return false, "BLIND_NOT_ACTIVE" end
    if not run_state.blind then return false, "MISSING_BLIND" end
    if not run_state.current_round then return false, "MISSING_ROUND" end

    local input_controller = game.CONTROLLER
    if not input_controller then return false, "MISSING_CONTROLLER" end
    if not game.buttons then return false, "MISSING_ACTION_BUTTONS" end
    for _, area in ipairs(required_card_areas) do
        if not game[area] then return false, "MISSING_CARD_AREA area=" .. area end
    end

    if #game.hand.cards == 0 then return false, "HAND_EMPTY" end
    if #game.play.cards > 0 then return false, "PLAY_AREA_NOT_EMPTY" end
    if game.SETTINGS.paused then return false, "GAME_PAUSED" end
    if input_controller.locked then return false, "CONTROLLER_LOCKED" end
    if input_controller.locks.frame then return false, "FRAME_LOCKED" end
    if (run_state.STOP_USE or 0) ~= 0 then return false, "STOP_USE_ACTIVE" end
    if game.OVERLAY_MENU then return false, "OVERLAY_OPEN" end
    if game.screenwipe then return false, "SCREEN_TRANSITION" end
    if game.deck_preview then return false, "DECK_PREVIEW_OPEN" end
    local deck_view_area = game.view_deck and game.view_deck[1]
    if deck_view_area and deck_view_area.cards then return false, "DECK_VIEW_OPEN" end
    if any_card_being_dragged(game.hand.cards) then return false, "HAND_CARD_DRAGGED" end
    if any_card_being_dragged(game.jokers.cards) then return false, "JOKER_DRAGGED" end
    return true
end

local function build_boss_snapshot(blind, round_state, blind_key)
    if not blind.boss then return nil end
    local boss_snapshot = {
        name = blind.loc_name ~= "" and blind.loc_name or blind.name,
        description = blind.disabled and "" or blind:get_loc_debuff_text(),
    }
    if blind.disabled then return boss_snapshot end

    if blind.debuff then
        boss_snapshot.min_play_cards = blind.debuff.h_size_ge
        boss_snapshot.max_play_cards = blind.debuff.h_size_le
        boss_snapshot.blocked_hand = blind.debuff.hand
    end
    if blind_key == "bl_mouth" then
        boss_snapshot.required_hand = blind.only_hand or nil
    elseif blind_key == "bl_eye" then
        boss_snapshot.used_hands = {}
        for poker_hand_key, was_played in pairs(blind.hands or {}) do
            if was_played then boss_snapshot.used_hands[#boss_snapshot.used_hands + 1] = poker_hand_key end
        end
        table.sort(boss_snapshot.used_hands)
    elseif blind_key == "bl_ox" then
        boss_snapshot.penalty_hand = round_state.most_played_poker_hand
    end
    return boss_snapshot
end

---@param game table
---@param captured_turn TurnCards
---@return Observation
function observation_builder.build(game, captured_turn)
    local run_state = game.GAME
    local card_id_by_object = captured_turn.id_by_card
    local round_state = run_state.current_round
    local blind_key = run_state.blind.config.blind.key or "unknown"
    local boss_snapshot = build_boss_snapshot(run_state.blind, round_state, blind_key)
    local observation = {
        id = captured_turn.id,
        round = {
            blind_key = blind_key,
            blind_disabled = not not run_state.blind.disabled,
            boss = boss_snapshot,
            score = run_state.chips,
            target = run_state.blind.chips,
            hands_left = round_state.hands_left,
            discards_left = round_state.discards_left,
            dollars = run_state.dollars,
        },
        hand = {}, deck_remaining = {}, jokers = {}, consumables = {},
        vouchers = {}, poker_hands = {},
        actions = build_available_actions(game, boss_snapshot),
    }
    for deck_index, deck_card in ipairs(game.deck.cards) do observation.deck_remaining[deck_index] = get_card_face(deck_card) end
    table.sort(observation.deck_remaining, compare_card_faces)
    for hand_index, hand_card in ipairs(game.hand.cards) do
        local is_face_up = hand_card.facing == "front"
        local permanent_chip_bonus = hand_card.ability.perma_bonus
        observation.hand[hand_index] = {
            id = card_id_by_object[hand_card],
            face = is_face_up and get_card_face(hand_card) or nil,
            chip_bonus = is_face_up and hand_card:get_chip_bonus() or nil,
            permanent_bonus = is_face_up and permanent_chip_bonus ~= 0 and permanent_chip_bonus or nil,
            debuffed = not not hand_card.debuff,
            forced = not not hand_card.ability.forced_selection,
        }
    end
    for joker_index, joker_card in ipairs(game.jokers.cards) do
        observation.jokers[joker_index] = item_snapshot.capture(joker_card, card_id_by_object[joker_card], get_edition, run_state)
    end
    for consumable_index, consumable_card in ipairs(game.consumeables.cards) do
        observation.consumables[consumable_index] = item_snapshot.capture(consumable_card, card_id_by_object[consumable_card], get_edition, run_state)
    end
    for voucher_key, is_used in pairs(run_state.used_vouchers) do
        if is_used == true then observation.vouchers[#observation.vouchers + 1] = voucher_key end
    end
    table.sort(observation.vouchers)
    for poker_hand_key, poker_hand_state in pairs(run_state.hands) do
        if poker_hand_state.visible == true then
            observation.poker_hands[poker_hand_key] = {
                level = poker_hand_state.level, chips = poker_hand_state.chips, mult = poker_hand_state.mult,
                played = poker_hand_state.played, played_this_round = poker_hand_state.played_this_round,
            }
        end
    end
    return observation
end

return observation_builder
