---@meta

---@alias ApplyStatus "accepted"|"rejected"
---@alias PollStatus "done"|"pending"|"invalidated"
---@alias ApplyReason "BUSY"|"STALE_OBSERVATION"|"SELECTION_REJECTED"|"ACTION_UNAVAILABLE"

---@alias CardActionKind "play"|"discard"
---@alias ActionKind CardActionKind|"reorder_jokers"

---@class CardActionStep
---@field kind CardActionKind
---@field card_ids string[]

---@class ReorderStep
---@field kind "reorder_jokers"
---@field joker_ids string[]

---@alias ValidatedStep CardActionStep|ReorderStep

---@alias RemainingActionsKey "hands_left"|"discards_left"
---@alias CompletedActionsKey "hands_played"|"discards_used"

---@class CardActionReceipt
---@field kind CardActionKind
---@field remaining_actions_key RemainingActionsKey
---@field remaining_actions_before integer
---@field completed_actions_key CompletedActionsKey
---@field completed_actions_before integer?

---@class ReorderReceipt
---@field kind "reorder_jokers"
---@field cards table[]

---@alias ActionReceipt CardActionReceipt|ReorderReceipt

---@class GameStates
---@field SELECTING_HAND integer
---@field HAND_PLAYED integer
---@field DRAW_TO_HAND integer
---@field NEW_ROUND integer
---@field ROUND_EVAL integer
---@field GAME_OVER integer

---@class CardArea
---@field cards table[]

---@class HandArea: CardArea
---@field highlighted table[]
---@field unhighlight_all fun(self: HandArea)
---@field add_to_highlighted fun(self: HandArea, card: table, silent: boolean)

---@class JokerArea: CardArea
---@field align_cards fun(self: JokerArea)

---@class RoundState
---@field hands_left integer
---@field discards_left integer
---@field hands_played integer?
---@field discards_used integer?

---@class RunState
---@field current_round RoundState
---@field blind table

---@class ActionEvent
---@field config {button: string?}

---@class GameLike
---@field STATE integer
---@field STATES GameStates
---@field STAGE integer
---@field STAGES {RUN: integer}
---@field GAME RunState # The active run when executing a step.
---@field SETTINGS {paused: boolean}?
---@field hand HandArea
---@field jokers JokerArea
---@field consumeables CardArea
---@field FUNCS table<string, fun(event: ActionEvent)> # The adapter calls the command callbacks through this table.

---@class CardSnapshot
---@field id string
---@field debuffed boolean
---@field forced boolean?
---@field face table?
---@field chip_bonus number?
---@field permanent_bonus number?

---@class ObservationActions
---@field play boolean
---@field discard boolean
---@field reorder_jokers boolean
---@field max_play_cards integer
---@field max_discard_cards integer

---@class Observation
---@field id integer
---@field round table
---@field hand CardSnapshot[]
---@field deck_remaining table[]
---@field jokers CardSnapshot[]
---@field consumables CardSnapshot[]
---@field vouchers string[]
---@field poker_hands table<string, table>
---@field actions ObservationActions

---@class TurnCards
---@field id integer
---@field cards_by_id table<string, table>
---@field id_by_card table<table, string>

---@class CapturedTurn: TurnCards
---@field run RunState
---@field round RoundState
---@field blind table
---@field highlighted table<table, boolean>
---@field observation Observation
