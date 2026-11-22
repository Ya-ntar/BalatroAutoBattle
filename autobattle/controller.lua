local controller = {}

local function deep_copy(value)
    if type(value) ~= "table" then return value end
    local copied_table = {}
    for key, entry_value in pairs(value) do copied_table[key] = deep_copy(entry_value) end
    return copied_table
end

local function dense_list_length(list)
    if type(list) ~= "table" then return nil end
    local list_length = #list
    local actual_entry_count = 0
    for index in pairs(list) do
        if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > list_length then
            return nil
        end
        actual_entry_count = actual_entry_count + 1
    end
    return actual_entry_count == list_length and list_length or nil
end

local function valid_card_ids(requested_card_ids, zone_cards, min_card_count, max_card_count, must_include_forced_cards)
    local requested_card_count = dense_list_length(requested_card_ids)
    if not requested_card_count or requested_card_count < min_card_count or requested_card_count > max_card_count then return false end

    local unrequested_cards_by_id = {}
    for _, card in ipairs(zone_cards) do unrequested_cards_by_id[card.id] = card end
    for _, card_id in ipairs(requested_card_ids) do
        if not unrequested_cards_by_id[card_id] then return false end
        unrequested_cards_by_id[card_id] = nil
    end
    if must_include_forced_cards then
        for _, card in pairs(unrequested_cards_by_id) do
            if card.forced then return false end
        end
    end
    return true
end

---@param plan any
---@param observation Observation
---@return ValidatedStep[]?
local function validate_plan_steps(plan, observation)
    if type(plan) ~= "table" or plan.observation_id ~= observation.id then return nil end
    local plan_step_count = dense_list_length(plan.steps)
    if not plan_step_count or plan_step_count > 2 then return nil end
    ---@type ValidatedStep[]
    local validated_steps = {}
    if plan_step_count == 0 then return validated_steps end

    local available_actions = observation.actions
    if plan_step_count == 2 then
        local reorder_step = plan.steps[1]
        local joker_count = #observation.jokers
        if type(reorder_step) ~= "table" or reorder_step.kind ~= "reorder_jokers"
            or not available_actions.reorder_jokers
            or not valid_card_ids(reorder_step.joker_ids, observation.jokers, joker_count, joker_count) then
            return nil
        end
        validated_steps[1] = {kind = reorder_step.kind, joker_ids = deep_copy(reorder_step.joker_ids)}
    end

    local final_step = plan.steps[plan_step_count]
    if type(final_step) ~= "table" then return nil end
    local action_kind = final_step.kind
    if (action_kind ~= "play" and action_kind ~= "discard") or not available_actions[action_kind] then return nil end
    local boss_rules = observation.round.boss
    local min_card_count = action_kind == "play" and boss_rules and boss_rules.min_play_cards or 1
    if not valid_card_ids(final_step.card_ids, observation.hand, min_card_count, available_actions["max_" .. action_kind .. "_cards"], true) then
        return nil
    end
    validated_steps[plan_step_count] = {kind = action_kind, card_ids = deep_copy(final_step.card_ids)}
    return validated_steps
end

function controller.new(game_adapter, decide_plan, timing_config, report_status)
    assert(timing_config.step_delay_seconds >= 0 and timing_config.action_timeout_seconds > 0, "Invalid timing")
    local is_enabled = false
    local execution_phase = "idle"
    local validated_steps
    local active_turn
    local action_receipt
    local rejected_turn_context
    local current_step_index
    local step_delay_remaining_seconds
    local action_wait_elapsed_seconds

    local function reset()
        execution_phase = "idle"
        validated_steps = nil
        active_turn = nil
        action_receipt = nil
        current_step_index = nil
        step_delay_remaining_seconds = nil
        action_wait_elapsed_seconds = nil
    end

    local function stop(status_code, status_detail)
        is_enabled = false
        rejected_turn_context = nil
        reset()
        report_status(status_code, status_detail)
    end

    local function reject(status_code)
        rejected_turn_context = active_turn
        reset()
        if status_code then report_status(status_code) end
    end

    local function wait(delta_seconds, wait_reason)
        action_wait_elapsed_seconds = action_wait_elapsed_seconds + delta_seconds
        if action_wait_elapsed_seconds >= timing_config.action_timeout_seconds then
            local action_kind = validated_steps[current_step_index].kind
            local detail = string.format("phase=%s action=%s reason=%s", execution_phase, action_kind, wait_reason)
            stop("ACTION_TIMEOUT", detail)
        end
    end

    local function advance_frame(delta_seconds)
        if game_adapter.is_paused() then return end
        if execution_phase == "idle" then
            local observation,
                captured_turn = game_adapter.capture()
            if not observation
                or (rejected_turn_context and game_adapter.same_context(rejected_turn_context, captured_turn)) then
                return
            end
            rejected_turn_context = nil
            active_turn = captured_turn
            local bound_hand_evaluator = game_adapter.bind_evaluator(captured_turn)
            local function evaluate_hand(requested_card_ids)
                if not bound_hand_evaluator then return nil, "STALE_OBSERVATION" end
                return bound_hand_evaluator(requested_card_ids)
            end
            local strategy_succeeded,
                plan_or_error = pcall(decide_plan, deep_copy(observation), evaluate_hand)
            bound_hand_evaluator = nil
            if not strategy_succeeded then return stop("STRATEGY_ERROR", plan_or_error) end
            validated_steps = validate_plan_steps(plan_or_error, observation)
            if not validated_steps then return reject("INVALID_PLAN") end
            if #validated_steps == 0 then return reject() end
            current_step_index = 1
            action_wait_elapsed_seconds = 0
            step_delay_remaining_seconds = 0
            execution_phase = "send"
        elseif execution_phase == "send" then
            step_delay_remaining_seconds = step_delay_remaining_seconds - delta_seconds
            if step_delay_remaining_seconds > 0 then return end
            local apply_status, receipt_or_reason, wait_reason =
                game_adapter.apply(active_turn, validated_steps[current_step_index])
            if apply_status == "accepted" then
                action_receipt = receipt_or_reason
                action_wait_elapsed_seconds = 0
                execution_phase = "await"
            elseif receipt_or_reason == "BUSY" then
                wait(delta_seconds, wait_reason or receipt_or_reason)
            else
                reject(receipt_or_reason)
            end
        else
            local poll_status, invalidation_reason, wait_reason = game_adapter.poll(active_turn, action_receipt)
            if poll_status == "pending" then
                wait(delta_seconds, wait_reason or "PENDING")
            elseif poll_status == "invalidated" then
                reject(invalidation_reason)
            elseif current_step_index == #validated_steps then
                reset()
            else
                current_step_index = current_step_index + 1
                step_delay_remaining_seconds = timing_config.step_delay_seconds
                action_wait_elapsed_seconds = 0
                action_receipt = nil
                execution_phase = "send"
            end
        end
    end

    return {
        update = function(delta_seconds)
            if not is_enabled then return end
            local update_succeeded,
                error_message = pcall(advance_frame, delta_seconds)
            if not update_succeeded then stop("ADAPTER_ERROR", error_message) end
        end,
        toggle = function()
            is_enabled = not is_enabled
            rejected_turn_context = nil
            reset()
            report_status(is_enabled and "ENABLED" or "DISABLED")
            return is_enabled
        end,
    }
end

return controller
