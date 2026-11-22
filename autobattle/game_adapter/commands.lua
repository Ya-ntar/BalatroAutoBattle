local observation_builder = require("autobattle.game_adapter.observation")
local turn_context = require("autobattle.game_adapter.context")

local statuses = {
    accepted = "accepted",
    rejected = "rejected",
    pending = "pending",
    done = "done",
    invalidated = "invalidated",
}

local reasons = {
    stale = "STALE_OBSERVATION",
    busy = "BUSY",
    selection = "SELECTION_REJECTED",
    unavailable = "ACTION_UNAVAILABLE",
}

---@alias CardActionCallbacks {can_execute: string, execute: string, remaining_key: RemainingActionsKey, completed_key: CompletedActionsKey}
---@type table<CardActionKind, CardActionCallbacks>
local card_actions = {
    play = {
        can_execute = "can_play",
        execute = "play_cards_from_highlighted",
        remaining_key = "hands_left",
        completed_key = "hands_played",
    },
    discard = {
        can_execute = "can_discard",
        execute = "discard_cards_from_highlighted",
        remaining_key = "discards_left",
        completed_key = "discards_used",
    },
}

---@param hand_area HandArea
---@param target_card_set table<table, boolean>
local function set_selection(hand_area, target_card_set)
    hand_area:unhighlight_all()
    local remaining_selection = turn_context.selection(hand_area)
    for _, card in ipairs(hand_area.cards) do
        if target_card_set[card] and not remaining_selection[card] then
            hand_area:add_to_highlighted(card, true)
        end
    end
end

---@param hand_area HandArea
---@param target_card_set table<table, boolean>
---@param previous_selection table<table, boolean>
---@return boolean
local function try_select_cards(hand_area, target_card_set, previous_selection)
    set_selection(hand_area, target_card_set)
    if turn_context.matches_selection(hand_area, target_card_set) then return true end

    -- Forced highlights and selection limits can leave a partially applied selection.
    set_selection(hand_area, previous_selection)
    return false
end

local function resolve_card_set(captured_turn, card_ids)
    local card_set = {}
    for _, card in ipairs(turn_context.resolve_cards(captured_turn, card_ids)) do card_set[card] = true end
    return card_set
end

---@param game GameLike
---@param captured_turn CapturedTurn
---@return "BUSY"|"STALE_OBSERVATION"|nil reason
---@return string? wait_reason
local function preflight_apply(game, captured_turn)
    if not turn_context.is_current_turn(game, captured_turn) or game.STATE ~= game.STATES.SELECTING_HAND then
        return reasons.stale
    end
    local ready, wait_reason = observation_builder.ready(game)
    if not ready then return reasons.busy, wait_reason end

    -- The strategy chose card IDs and actions from this snapshot before the execution delay.
    if not turn_context.get_current_snapshot(game, captured_turn) then return reasons.stale end
end

local function can_execute_action(game, action, button_event)
    game.FUNCS[action.can_execute](button_event)
    return button_event.config.button == action.execute
end

local function execute_action(game, action, button_event)
    game.FUNCS[action.execute](button_event)
end

---@param captured_turn CapturedTurn
---@param action_kind CardActionKind
---@param action CardActionCallbacks
---@return CardActionReceipt
local function create_action_receipt(captured_turn, action_kind, action)
    local round = captured_turn.round
    return {
        kind = action_kind,
        remaining_actions_key = action.remaining_key,
        remaining_actions_before = round[action.remaining_key],
        completed_actions_key = action.completed_key,
        completed_actions_before = round[action.completed_key],
    }
end

---@param captured_turn CapturedTurn
---@param ordered_cards table[]
---@return CardSnapshot[]
local function expected_joker_order(captured_turn, ordered_cards)
    local snapshot_by_card = {}
    for _, snapshot in ipairs(captured_turn.observation.jokers) do
        snapshot_by_card[captured_turn.cards_by_id[snapshot.id]] = snapshot
    end

    local expected_order = {}
    for index, card in ipairs(ordered_cards) do expected_order[index] = snapshot_by_card[card] end
    return expected_order
end

---@generic T
---@param source T
---@return T
local function shallow_copy(source)
    local copy = {}
    for key, value in pairs(source) do copy[key] = value end
    return copy
end

local function matches_expected_joker_order(game, captured_turn, expected_order)
    local expected_turn = shallow_copy(captured_turn)
    expected_turn.observation = shallow_copy(captured_turn.observation)
    expected_turn.observation.jokers = expected_order
    return not not turn_context.get_current_snapshot(game, expected_turn)
end

local function action_counters_advanced(round, receipt)
    if round[receipt.remaining_actions_key] < receipt.remaining_actions_before then return true end

    -- The completed-action counter can confirm execution even if the allowance is replenished.
    local completed_before = receipt.completed_actions_before
    local completed_now = round[receipt.completed_actions_key]
    return completed_before ~= nil and completed_now ~= nil and completed_now > completed_before
end

---@param game GameLike
---@param captured_turn CapturedTurn
---@param step ReorderStep
---@return ApplyStatus status
---@return ReorderReceipt|ApplyReason receipt_or_reason
---@return string? wait_reason
local function apply_reorder_jokers(game, captured_turn, step)
    local rejection_reason, wait_reason = preflight_apply(game, captured_turn)
    if rejection_reason then return statuses.rejected, rejection_reason, wait_reason end

    local ordered_cards = turn_context.resolve_cards(captured_turn, step.joker_ids)
    for index, card in ipairs(ordered_cards) do game.jokers.cards[index] = card end
    game.jokers:align_cards()
    return statuses.accepted, {kind = step.kind, cards = ordered_cards}
end

---@param game GameLike
---@param captured_turn CapturedTurn
---@param step CardActionStep
---@param action CardActionCallbacks
---@return ApplyStatus status
---@return CardActionReceipt|ApplyReason receipt_or_reason
---@return string? wait_reason
local function apply_card_action(game, captured_turn, step, action)
    local rejection_reason, wait_reason = preflight_apply(game, captured_turn)
    if rejection_reason then return statuses.rejected, rejection_reason, wait_reason end

    local target_card_set = resolve_card_set(captured_turn, step.card_ids)
    local previous_selection = turn_context.selection(game.hand)
    if not try_select_cards(game.hand, target_card_set, previous_selection) then
        return statuses.rejected, reasons.selection
    end

    ---@type ActionEvent
    local button_event = {config = {}}
    if not can_execute_action(game, action, button_event) then
        set_selection(game.hand, previous_selection)
        return statuses.rejected, reasons.unavailable
    end

    local receipt = create_action_receipt(captured_turn, step.kind, action)
    execute_action(game, action, button_event)
    return statuses.accepted, receipt
end

---@param game GameLike
---@param captured_turn CapturedTurn
---@param receipt ReorderReceipt
---@return PollStatus status
---@return "STALE_OBSERVATION"? reason
---@return string? wait_reason
local function poll_reorder_jokers(game, captured_turn, receipt)
    if not turn_context.is_current_turn(game, captured_turn) or game.STATE ~= game.STATES.SELECTING_HAND then
        return statuses.invalidated, reasons.stale
    end
    local ready, wait_reason = observation_builder.ready(game)
    if not ready then return statuses.pending, nil, wait_reason end

    -- Reordering consumes no action. The next step can reuse this turn if only the joker order changed.
    local expected_order = expected_joker_order(captured_turn, receipt.cards)
    if not matches_expected_joker_order(game, captured_turn, expected_order) then
        return statuses.invalidated, reasons.stale
    end

    captured_turn.observation.jokers = expected_order
    return statuses.done
end

---@param game GameLike
---@param captured_turn CapturedTurn
---@param receipt CardActionReceipt
---@return PollStatus status
---@return "STALE_OBSERVATION"? reason
---@return string? wait_reason
local function poll_card_action(game, captured_turn, receipt)
    if not turn_context.is_current_turn(game, captured_turn) then return statuses.invalidated, reasons.stale end

    local game_state = game.STATE
    local game_states = game.STATES
    local is_round_finished = game_state == game_states.NEW_ROUND or game_state == game_states.ROUND_EVAL
        or game_state == game_states.GAME_OVER

    local can_wait_for_action = game_state == game_states.SELECTING_HAND or game_state == game_states.HAND_PLAYED
        or game_state == game_states.DRAW_TO_HAND or is_round_finished
    if not can_wait_for_action then return statuses.invalidated, reasons.stale end

    local round = captured_turn.round
    if action_counters_advanced(round, receipt) then
        if is_round_finished then return statuses.done end
        local ready, wait_reason = observation_builder.ready(game)
        if ready then return statuses.done end
        return statuses.pending, nil, wait_reason
    end

    local remaining_key = receipt.remaining_actions_key
    local completed_key = receipt.completed_actions_key
    local wait_reason = string.format("WAITING_FOR_ACTION_COUNTERS %s=%s->%s %s=%s->%s",
        remaining_key, tostring(receipt.remaining_actions_before), tostring(round[remaining_key]),
        completed_key, tostring(receipt.completed_actions_before), tostring(round[completed_key]))
    return statuses.pending, nil, wait_reason
end

local commands = {}

---@param game GameLike
---@param captured_turn CapturedTurn
---@param step ValidatedStep
---@return ApplyStatus status
---@return ActionReceipt|ApplyReason receipt_or_reason Receipt on acceptance, reason on rejection.
---@return string? wait_reason Only present when busy.
function commands.apply(game, captured_turn, step)
    if step.kind == "reorder_jokers" then
        return apply_reorder_jokers(game, captured_turn, step)
    end
    local action = card_actions[step.kind]
    if action then return apply_card_action(game, captured_turn, step, action) end
    return statuses.rejected, reasons.unavailable
end

---@param game GameLike
---@param captured_turn CapturedTurn
---@param receipt ActionReceipt
---@return PollStatus status
---@return ("STALE_OBSERVATION"|"ACTION_UNAVAILABLE")? reason Only present when invalidated.
---@return string? wait_reason Only present when pending.
function commands.poll(game, captured_turn, receipt)
    if receipt.kind == "reorder_jokers" then
        return poll_reorder_jokers(game, captured_turn, receipt)
    end
    if card_actions[receipt.kind] then return poll_card_action(game, captured_turn, receipt) end
    return statuses.invalidated, reasons.unavailable
end

return commands
