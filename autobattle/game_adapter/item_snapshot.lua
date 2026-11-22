local item_snapshot = {}

local ability_field_names = {
    "mult", "x_mult", "t_mult", "t_chips", "h_size", "d_size", "type",
    "eternal", "perishable", "perish_tally", "rental", "money",
    "to_do_poker_hand", "loyalty_remaining", "invis_rounds", "caino_xmult", "yorick_discards",
    "driver_tally", "steel_tally", "nine_tally", "stone_tally", "blueprint_compat",
}
local consumable_field_names = {
    "hand_type", "min_highlighted", "max_highlighted", "suit_conv", "mod_conv", "remove_card",
    "planets", "tarots",
}
local target_round_field_by_joker_key = {
    j_idol = "idol_card", j_mail = "mail_card", j_ancient = "ancient_card", j_castle = "castle_card",
}

local function copy_scalar(snapshot_fields, field_key, field_value)
    local value_type = type(field_value)
    if value_type == "number" or value_type == "string" or value_type == "boolean" then
        snapshot_fields[field_key] = field_value
    end
end

function item_snapshot.capture(game_card, card_id, get_edition, run_state)
    local snapshot = {id = card_id, debuffed = not not game_card.debuff}
    if game_card.facing ~= "front" then return snapshot end

    local ability = game_card.ability
    local item_key = game_card.config.center_key
    local visible_values = {}
    snapshot.key = item_key
    snapshot.edition = get_edition(game_card)
    snapshot.set = ability.set
    snapshot.name = ability.name
    snapshot.pinned = not not game_card.pinned
    snapshot.sell_cost = game_card.sell_cost
    snapshot.values = visible_values
    for _, field_key in ipairs(ability_field_names) do copy_scalar(visible_values, field_key, ability[field_key]) end
    if type(ability.extra) == "table" then
        visible_values.extra = {}
        for field_key, field_value in pairs(ability.extra) do
            if type(field_key) == "number" or type(field_key) == "string" then
                copy_scalar(visible_values.extra, field_key, field_value)
            end
        end
    else
        copy_scalar(visible_values, "extra", ability.extra)
    end

    local target_round_field_name = target_round_field_by_joker_key[item_key]
    local target_card_traits = target_round_field_name and run_state.current_round[target_round_field_name]
    if target_card_traits then
        visible_values.target_rank = target_card_traits.rank
        visible_values.target_suit = target_card_traits.suit
    end
    local consumable_ability = ability.consumeable
    if consumable_ability then
        for _, field_key in ipairs(consumable_field_names) do
            copy_scalar(visible_values, field_key, consumable_ability[field_key])
        end
        if consumable_ability.max_highlighted then
            visible_values.min_highlighted = consumable_ability.min_highlighted or 1
            visible_values.max_highlighted = consumable_ability.mod_num or consumable_ability.max_highlighted
        end
        if item_key == "c_fool" then visible_values.last_tarot_planet = run_state.last_tarot_planet end
        snapshot.can_use_now = not not game_card:can_use_consumeable()
    end
    return snapshot
end

return item_snapshot
