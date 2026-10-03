-- Core/Constants.lua
-- Every tunable number lives here, named, so a beta patch that moves one is a
-- one-line change rather than a hunt through a phase calculation (§11.5).

local ADDON_NAME, ns = ...

ns.ADDON_NAME = ADDON_NAME
ns.VERSION = "1.0.2-phase9"

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
-- Every eighth nameplate sweep asks whether this is an addon-restricted map: once
-- every two seconds at the default interval (section 4.2).
ns.RESTRICTION_SAMPLE_EVERY = 8
-- A refusal storm: this many refusals within this many seconds. Twenty is far
-- above any one panel change (a handful at most) and far below the 2026-10-02
-- storm's eight a second (section 6.2).
ns.STORM_REFUSALS = 20
ns.STORM_WINDOW_SECONDS = 10
ns.STORM_FUNCTION_CAPACITY = 16
