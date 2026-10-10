-- Core/Constants.lua
-- Every tunable number lives here, named, so a beta patch that moves one is a
-- one-line change rather than a hunt through a phase calculation (§11.5).

local ADDON_NAME, ns = ...

ns.ADDON_NAME = ADDON_NAME
ns.VERSION = "1.3.0-phase13"

ns.SAVED_VARIABLE = "PersonalAddonDB"
ns.QUARANTINE_KEY = "quarantinedStore"
ns.CHAT_PREFIX = "|cff66ccffPersonalAddon|r: "

ns.CURRENT_SCHEMA_VERSION = 1

-- The five-second rule's length is server behaviour we cannot query, so it is
-- an assumed value recorded in one place (Architecture section 11.5).
--
-- The tick period, energize correlation window and energize ring size are gone
-- with the tick-phase design: this client protects power values, so there is no
-- observable tick. See Architecture section 11.1a.
ns.FSR_WINDOW = 5.0

ns.FEATURE_STATE = {
    REGISTERED = "REGISTERED",
    DISABLED = "DISABLED",
    ENABLING = "ENABLING",
    ENABLED = "ENABLED",
    FAULTED = "FAULTED",
}

ns.DROP_POLICY = {
    SURFACE_AND_FAIL = "SURFACE_AND_FAIL",
    RECYCLE_OLDEST = "RECYCLE_OLDEST",
}

-- onConfigChanged return values (§6.2). RELOAD_REQUIRED is not a failure.
ns.CONFIG_RESULT = {
    APPLIED = "APPLIED",
    RELOAD_REQUIRED = "RELOAD_REQUIRED",
}

-- Two states, not three. UNKNOWN existed to model "the phase estimate is
-- unrecoverable"; with no phase to estimate, not-in-window IS regenerating.
ns.TRACKER_STATE = {
    REGENERATING = "REGENERATING",
    IN_FSR = "IN_FSR",
}

-- Enum.PowerType exists on the modern client codebase; 0 is the correct
-- fallback value for mana on every client that lacks it.
ns.POWER_TYPE_MANA = (Enum and Enum.PowerType and Enum.PowerType.Mana) or 0

-- Phase 8 (Architecture/20260927-Phase08.md) ----------------------------------

-- Toasts waiting for a free slot, beyond which a new one is dropped and counted.
ns.TOAST_QUEUE_CAPACITY = 10
-- The toast pool. Equal to the largest maximumVisible the schema allows, so the
-- visible toasts can never exhaust it (section 6.2).
ns.TOAST_POOL_CAPACITY = 5
-- Loot messages waiting for the next frame (section 6.3).
ns.LOOT_INBOX_CAPACITY = 20
-- Loot deliveries per session whose stack is read, to check that no Blizzard Lua
-- raised them (section 6.5).
ns.STACK_CHECK_DELIVERIES = 20
-- Skills window rows: two professions, three weapon slots and Defense fit in six.
ns.SKILL_ROW_CAPACITY = 8
-- How long a sale may take to settle before it is reported as it stands (7.2).
ns.VEND_SETTLE_SECONDS = 3
-- Blizzard's own Skills tab keeps this as a file-local, so it cannot be read by
-- name (Camelot/SkillsFrame.lua:34).
ns.DEFENSE_SKILL_LINE = 95
-- The icon Blizzard's pet bar uses for Defensive on this client (PetActionBar.lua:3).
ns.DEFENSE_ICON = "Interface\\Icons\\Ability_Defend"

-- Phase 9 (Architecture/20261002-Phase09.md) ----------------------------------

-- Diagnostics: UI loads kept in PersonalAddonDiagnostics, fault notes kept per UI
-- load, and the length each note is cut to (section 3.3).
ns.DIAGNOSTICS_FORMAT_VERSION = 1
ns.DIAGNOSTICS_SESSION_CAPACITY = 5
ns.DIAGNOSTICS_FAULT_NOTE_CAPACITY = 8
ns.DIAGNOSTICS_FAULT_NOTE_LENGTH = 300
-- The client's threat scale: 2 and 3 mean the unit is the mob's current target.
-- A client fact, not a preference (GAPBugs01 section 3.6).
ns.TANKING_STATUS = 2
-- Status 1: your threat is above the tank's and the mob is not on you yet. A
-- client fact (Phase 11 section 3).
ns.ABOUT_TO_PULL_STATUS = 1
-- Every eighth nameplate sweep asks whether this is an addon-restricted map: once
-- every two seconds at the default interval (section 4.2).
ns.RESTRICTION_SAMPLE_EVERY = 8
-- A refusal storm: this many refusals within this many seconds. Twenty is far
-- above any one panel change (a handful at most) and far below the 2026-10-02
-- storm's eight a second (section 6.2).
ns.STORM_REFUSALS = 20
ns.STORM_WINDOW_SECONDS = 10
ns.STORM_FUNCTION_CAPACITY = 16

-- Phase 11 (Architecture/20261005-Phase11.md) ---------------------------------

-- The threat panel's row pool, built at enable. Above the largest maximumRows the
-- schema allows (10), so no setting can exhaust it during a fight (section 5.5).
ns.THREAT_ROW_CAPACITY = 16

-- Phase 12 (Architecture/20261006-Phase12.md) ---------------------------------

-- The pages of the settings menu, in the order they appear under PersonalAddon
-- (section 3.1). General is the parent page itself. A feature names its page in
-- its registration; one that names none goes on the parent page.
ns.SETTINGS_PAGE = {
    GENERAL = "General",
    COMBAT = "Combat",
    NAMEPLATES = "Nameplates",
    BAGS_AND_LOOT = "BagsAndLoot",
    CONSUMABLES = "Consumables",
}
-- After every declared settingsOrder, so an unplaced feature sorts last, in
-- registration order.
ns.SETTINGS_UNPLACED_ORDER = 1000

-- Phase 13 (Architecture/20261009-Phase13.md) ---------------------------------

-- The windows the preview knows, and the places on screen they are drawn in
-- (section 2.2). The static table that maps one to the other lives in
-- Core/Preview.lua; these are the names both it and the features use.
ns.PREVIEW_PANEL = {
    THREAT_PANEL = "ThreatPanel",
    DAMAGE_BREAKDOWN = "DamageBreakdown",
    EQUIPPED_SKILLS = "EquippedSkills",
    TOASTS = "Toasts",
}
ns.PREVIEW_GROUP = {
    PLAYER_FRAME = "PlayerFrame",
    BAGS = "Bags",
    SCREEN = "Screen",
}
-- Which window the player-frame group shows before anything has been adjusted.
-- The threat panel: it has the most geometry to set, and it is the one Phase 13
-- exists for (section 2.5).
ns.PREVIEW_INITIAL_FOCUS = ns.PREVIEW_PANEL.THREAT_PANEL
-- Above Blizzard's settings window, which is HIGH (section 3.1).
ns.PREVIEW_STRATA = "DIALOG"
-- The skills window's preview draws a fixed six rows. Its live height is what
-- you have equipped, behind reads that can be withheld, and width is what this
-- phase adjusts (section 5.4).
ns.PREVIEW_SKILL_ROWS = 6
-- Two samples: enough to show the stacking, few enough that the default
-- maximumVisible of 3 leaves a slot free, so the first real toast evicts
-- nothing (section 5.5).
ns.PREVIEW_TOAST_SAMPLES = 2

-- The threat panel's narrowest width: 10% under the player frame's health bar.
-- That bar is 124 x 20, declared in XML at
-- Blizzard_UnitFrame/Mainline/PlayerFrame.xml lines 124 and 173 and resized
-- nowhere in Lua, so 124 * 0.9 rounds to 112 (section 6.1, decision D7). The
-- fact about Blizzard's bar is in the patch check's register as
-- PLAYER-HEALTH-BAR-WIDTH, because this number is only right while it holds.
ns.THREAT_PANEL_MINIMUM_WIDTH = 112
ns.THREAT_PANEL_MAXIMUM_WIDTH = 400
-- A CONSEQUENCE of the line above, not a judgement about how narrow a bar may
-- usefully be: at the minimum width, with the level tag shown, this is what is
-- left for the bar.
ns.THREAT_BAR_MINIMUM = 22
-- Below this much bar the mob name is hidden rather than truncated to nothing.
-- Roughly six characters at GameFontHighlightSmall. A legibility floor, not a
-- preference (section 6.3, decision D8).
ns.THREAT_NAME_MINIMUM_BAR = 40

-- The skills window's width bounds. The minimum is padding, icon, gap and the
-- least the rank text can have; the maximum is generous for
-- "Blacksmithing 300 / 300" (section 6.1).
ns.SKILL_PANEL_MINIMUM_WIDTH = 74
ns.SKILL_PANEL_MAXIMUM_WIDTH = 240
ns.SKILL_TEXT_MINIMUM = 44
