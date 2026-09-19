-- Core/Constants.lua
-- Every tunable number lives here, named, so a beta patch that moves one is a
-- one-line change rather than a hunt through a phase calculation (§11.5).

local ADDON_NAME, ns = ...

ns.ADDON_NAME = ADDON_NAME
ns.VERSION = "0.1.0-phase1"

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
