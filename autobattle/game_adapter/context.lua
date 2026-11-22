local observation_builder = require("autobattle.game_adapter.observation")
local turn_context = {}

local observation_zone_keys = {"hand", "jokers", "consumables"}

local function values_match(first_value, second_value, ignore_id_fields)
    if first_value == second_value then return true end
    if type(first_value) ~= "table" or type(second_value) ~= "table" then return false end
    for key, value in pairs(first_value) do
        if not (ignore_id_fields and key == "id") and not values_match(value, second_value[key], ignore_id_fields) then
            return false
        end
    end
    for key in pairs(second_value) do
        if not (ignore_id_fields and key == "id") and first_value[key] == nil then return false end
    end
    return true
end

local function make_set(list_items)
    local item_set = {}
    for _, item in ipairs(list_items) do item_set[item] = true end
    return item_set
end

---@param captured_turn TurnCards
---@param cards table[]
---@param card_id_prefix string
local function register_cards(captured_turn, cards, card_id_prefix)
    for zone_index, card in ipairs(cards) do
        local card_id = card_id_prefix .. zone_index
        captured_turn.id_by_card[card] = card_id
        captured_turn.cards_by_id[card_id] = card
    end
end

---@param hand_area HandArea
---@return table<table, boolean>
function turn_context.selection(hand_area)
    return make_set(hand_area.highlighted)
end

---@param hand_area HandArea
---@param expected_highlighted_card_set table<table, boolean>
---@return boolean
function turn_context.matches_selection(hand_area, expected_highlighted_card_set)
    return values_match(turn_context.selection(hand_area), expected_highlighted_card_set)
end

---@param captured_turn CapturedTurn
---@param card_ids string[]
---@return table[]
function turn_context.resolve_cards(captured_turn, card_ids)
    local resolved_cards = {}
    for index, card_id in ipairs(card_ids) do resolved_cards[index] = captured_turn.cards_by_id[card_id] end
    return resolved_cards
end

---@param first_turn CapturedTurn
---@param second_turn CapturedTurn
---@return boolean
function turn_context.same_context(first_turn, second_turn)
    if first_turn.run ~= second_turn.run or first_turn.round ~= second_turn.round or first_turn.blind ~= second_turn.blind
        or not values_match(first_turn.highlighted, second_turn.highlighted)
        or not values_match(first_turn.observation, second_turn.observation, true) then
        return false
    end
    for _, zone_key in ipairs(observation_zone_keys) do
        for zone_index, first_card_snapshot in ipairs(first_turn.observation[zone_key]) do
            local second_card_snapshot = second_turn.observation[zone_key][zone_index]
            if first_turn.cards_by_id[first_card_snapshot.id] ~= second_turn.cards_by_id[second_card_snapshot.id] then
                return false
            end
        end
    end
    return true
end

---@param game GameLike
---@param captured_turn CapturedTurn
---@return boolean
function turn_context.is_current_turn(game, captured_turn)
    return game.STAGE == game.STAGES.RUN and game.GAME == captured_turn.run
        and game.GAME.current_round == captured_turn.round and game.GAME.blind == captured_turn.blind
end

---@param game GameLike
---@param captured_turn CapturedTurn
---@return Observation?
function turn_context.get_current_snapshot(game, captured_turn)
    if not turn_context.matches_selection(game.hand, captured_turn.highlighted) then return nil end
    local live_observation = observation_builder.build(game, captured_turn)
    if values_match(captured_turn.observation, live_observation) then return live_observation end
end

---@param game GameLike
---@param observation_id integer
---@return Observation observation
---@return CapturedTurn captured_turn
function turn_context.capture(game, observation_id)
    local captured_turn = {
        id = observation_id, run = game.GAME, round = game.GAME.current_round, blind = game.GAME.blind,
        cards_by_id = {}, id_by_card = {}, highlighted = turn_context.selection(game.hand),
    }
    register_cards(captured_turn, game.hand.cards, "h")
    register_cards(captured_turn, game.jokers.cards, "j")
    register_cards(captured_turn, game.consumeables.cards, "u")
    captured_turn.observation = observation_builder.build(game, captured_turn)
    ---@cast captured_turn CapturedTurn
    return captured_turn.observation, captured_turn
end

return turn_context
