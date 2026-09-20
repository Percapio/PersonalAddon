-- Features/Nameplates.lua
-- Skinnier hostile and neutral nameplates, name repositioned, and aggro-based
-- colouring from a DPS perspective (Phase 2).
--
-- Restyle in place; own nothing. Blizzard's status bar is the only thing that
-- knows a unit's health and on this client likely the only thing that ever will,
-- so we resize and recolour ITS bar and move ITS name text. We create no frames,
-- textures or font strings, which is what makes the feature indifferent to
-- whether health is readable.
--
-- Everything we change is recorded in the style ledger first, scoped to one
-- occupancy of one frame, so disable puts it back and a recycled frame never
-- inherits the previous unit's geometry.

local ADDON_NAME, ns = ...

local FEATURE_ID = "nameplates"

local format, pcall, pairs, tonumber = string.format, pcall, pairs, tonumber

local SCOPE = { IN = "InScope", OUT = "OutOfScope", UNREACHABLE = "Unreachable" }
local AGGRO = {
    ON_PLAYER = "OnPlayer",
    ON_GROUP_OR_PET = "OnGroupOrPet",
    ELSEWHERE = "Elsewhere",
    UNKNOWN = "Unknown",
}

-- Blizzard re-sets plate geometry on its own schedule. The sweep re-asserts;
-- a hook, where one is available, only makes it react sooner.
local STALE_SWEEP_EVERY = 8

-- How long a plate stays watched per-frame after the last observed overwrite.
local CONTESTED_GRACE = 1.0

local state = {
    plates = {},
    -- Blizzard's update path is handed the unit frame, not the nameplate frame,
    -- so the hook needs a second index to find our record in O(1).
    byUnitFrame = {},
    reassertPending = false,
    -- Plates Blizzard is actively fighting us over. Bounded in practice to the
    -- player's current target, which is the only plate whose colour Blizzard
    -- writes on its own initiative.
    contested = {},
    contestedDriver = nil,
    contestedRunning = false,
    yieldSelectedTarget = false,
    plateCount = 0,
    ledger = nil,
    ticker = nil,
    sweepCount = 0,
    enabled = false,
    hookInstalled = false,
    tokens = {},
    aggroResolvedEver = false,
    aggroAttempts = 0,
    palette = {},
    colouringWanted = true,
    sweepInterval = 0.25,
}

-- Capability ------------------------------------------------------------------

local capability = {
    plateLookup = false,
    barRecolourable = nil,
}

local function namePlateApi()
    return C_NamePlate and C_NamePlate.GetNamePlateForUnit and C_NamePlate or nil
end

-- Config ----------------------------------------------------------------------

local function hexToColour(hex, fallbackRed, fallbackGreen, fallbackBlue)
    if type(hex) ~= "string" or #hex < 6 then
        return { red = fallbackRed, green = fallbackGreen, blue = fallbackBlue, alpha = 1 }
    end
    local red = tonumber(string.sub(hex, 1, 2), 16)
    local green = tonumber(string.sub(hex, 3, 4), 16)
    local blue = tonumber(string.sub(hex, 5, 6), 16)
    if not red or not green or not blue then
        return { red = fallbackRed, green = fallbackGreen, blue = fallbackBlue, alpha = 1 }
    end
    return { red = red / 255, green = green / 255, blue = blue / 255, alpha = 1 }
end

local function readSettings(config)
    local settings = config and config.settings
    if not settings then
        return
    end
    state.sweepInterval = settings.sweepInterval or state.sweepInterval
    state.colouringWanted = (settings.aggroColouring ~= false)
    state.yieldSelectedTarget = (settings.yieldSelectedTarget == true)
    state.palette[AGGRO.ON_PLAYER] = hexToColour(settings.colourOnPlayer, 1, 0.25, 0.25)
    state.palette[AGGRO.ON_GROUP_OR_PET] = hexToColour(settings.colourOnGroup, 0.25, 1, 0.25)
    state.palette[AGGRO.ELSEWHERE] = hexToColour(settings.colourElsewhere, 1, 1, 1)
end

-- Frame shape -----------------------------------------------------------------

-- Resolved rather than assumed: every falsified Phase 1 assumption was a
-- well-known API this client arranges differently.
local function resolveParts(frame)
    local unitFrame = frame.UnitFrame or frame.unitFrame or frame
    local healthBar = unitFrame.healthBar or unitFrame.HealthBar or unitFrame.healthbar
    return unitFrame, healthBar
end

-- Scope -----------------------------------------------------------------------

local function classifyScope(unitToken, frame)
    if not frame then
        return SCOPE.UNREACHABLE
    end

    local ok, isPlayer = pcall(UnitIsUnit, unitToken, "player")
    if ok and isPlayer then
        return SCOPE.OUT
    end

    local readable, attackable = pcall(UnitCanAttack, "player", unitToken)
    if not readable then
        return SCOPE.UNREACHABLE
    end
    if attackable then
        return SCOPE.IN
    end
    return SCOPE.OUT
end

-- Aggro -----------------------------------------------------------------------

-- Every comparison must distinguish "no" from "could not tell".
--
-- This used to read `select(2, pcall(UnitIsUnit, a, b))`, which returns the
-- error MESSAGE when the call fails -- and a message is truthy. A failed
-- comparison therefore read as "yes, it is targeting the player" and painted the
-- plate red while another player held aggro. Returns nil for unknown.
local function unitsAreSame(leftUnit, rightUnit)
    local ok, same = pcall(UnitIsUnit, leftUnit, rightUnit)
    if not ok then
        return nil
    end
    return same == true
end

-- Returns true, false, or nil when no membership test could be completed.
local function groupMembership(unit)
    local answered = false

    if UnitInParty then
        local ok, inParty = pcall(UnitInParty, unit)
        if ok then
            answered = true
            if inParty then
                return true
            end
        end
    end

    if UnitInRaid then
        local ok, inRaid = pcall(UnitInRaid, unit)
        if ok then
            answered = true
            if inRaid then
                return true
            end
        end
    end

    -- Explicit comparison against the four party slots as a backstop, because
    -- UnitInParty is not reliable for a nameplate's target token on every
    -- client. Four extra predicate calls per plate is affordable; getting the
    -- second puller's colour wrong is not.
    for index = 1, 4 do
        local same = unitsAreSame(unit, "party" .. index)
        if same == true then
            return true
        end
        if same ~= nil then
            answered = true
        end
    end

    if not answered then
        return nil
    end
    return false
end

-- An unresolvable target and no target at all present identically. Combat state
-- is the discriminator: a mob in combat necessarily has a target, so if we
-- cannot see one the client is withholding it (section 9.2).
local function classifyUnresolvedTarget(unitToken)
    local ok, inCombat = pcall(UnitAffectingCombat, unitToken)
    if not ok or inCombat == nil then
        return AGGRO.UNKNOWN
    end
    if inCombat then
        return AGGRO.UNKNOWN
    end
    return AGGRO.ELSEWHERE
end

-- With yieldSelectedTarget set, the plate the player is attacking is reported as
-- Unknown, which restores Blizzard's colour and stops us contesting it. The white
-- target outline still identifies it; what is given up is the aggro colour on the
-- one plate where Blizzard has its own claim on the property.
local function isSelectedTarget(unitToken)
    return unitsAreSame(unitToken, "target") == true
end

local function classifyAggro(unitToken)
    if state.yieldSelectedTarget and isSelectedTarget(unitToken) then
        return AGGRO.UNKNOWN
    end

    local mobTarget = unitToken .. "target"

    local resolved, exists = pcall(UnitExists, mobTarget)
    if not resolved then
        return AGGRO.UNKNOWN
    end
    if not exists then
        return classifyUnresolvedTarget(unitToken)
    end

    -- A comparison we cannot make is Unknown, never a guess. Unknown restores
    -- the original colour, so the cost of not knowing is an uncoloured plate
    -- rather than a confidently wrong one.
    local isPlayer = unitsAreSame(mobTarget, "player")
    if isPlayer == nil then
        return AGGRO.UNKNOWN
    end
    if isPlayer then
        state.aggroResolvedEver = true
        return AGGRO.ON_PLAYER
    end

    -- A nil here is benign rather than unknown: with no pet summoned the "pet"
    -- token does not resolve, and that is a legitimate "no".
    if unitsAreSame(mobTarget, "pet") == true then
        state.aggroResolvedEver = true
        return AGGRO.ON_GROUP_OR_PET
    end

    local inGroup = groupMembership(mobTarget)
    if inGroup == nil then
        return AGGRO.UNKNOWN
    end

    state.aggroResolvedEver = true
    if inGroup then
        return AGGRO.ON_GROUP_OR_PET
    end
    return AGGRO.ELSEWHERE
end

-- Styling ---------------------------------------------------------------------

-- Nameplate size is not adjustable on this client ----------------------------
--
-- Two mechanisms were tried and both failed, in ways worth keeping written down
-- because each one looked like it worked.
--
-- 1. healthBar:SetHeight -- accepted and discarded. The bar carries two vertical
--    anchors, so the next layout pass recomputes the height. Phase 2's probe wrote
--    the bar's CURRENT height back to itself and reported "resizable", which tests
--    only that the call is permitted.
--
-- 2. C_NamePlate.SetNamePlateSize -- accepted, and GetNamePlateSize reads the new
--    value back, and nothing changes on screen. It sizes the plate's anchor region
--    while the client's nameplate driver keeps laying out the visible bar from its
--    own inputs. Read-back is a better test than the call returning, and it was
--    still the wrong thing to verify.
--
-- What both have in common: the addon could confirm its own write and could not
-- confirm the effect. Nothing here sizes a plate now. What this feature does is
-- colour, which is verifiable by looking at it.

local COLOUR_TOLERANCE = 0.01

local function coloursMatch(left, right)
    if not left or not right then
        return false
    end
    return math.abs((left.red or 0) - (right.red or 0)) <= COLOUR_TOLERANCE
        and math.abs((left.green or 0) - (right.green or 0)) <= COLOUR_TOLERANCE
        and math.abs((left.blue or 0) - (right.blue or 0)) <= COLOUR_TOLERANCE
end

local markContested

-- Blizzard is the other writer on this property: it paints the player's current
-- target red on its own schedule. Re-asserting only when our CLASSIFICATION
-- changed let those writes stand -- a plate we had painted green went red the
-- moment the player cast at it and stayed red, because our state had not moved.
--
-- So the comparison is desired-versus-actual, exactly as the geometry re-assert
-- does, rather than desired-versus-previously-desired.
--
-- Returns true when it actually had to write, which means someone else wrote
-- first. That is the signal that this plate is contested.
local function reassertColour(plate)
    local desired = plate.desiredColour
    if not desired or not plate.healthBar then
        return false
    end
    local current = ns.StyleLedger.Reads(state.ledger, plate.healthBar, "BarColour")
    if coloursMatch(current, desired) then
        return false
    end
    if not ns.StyleLedger.Reapply(state.ledger, plate.healthBar, "BarColour", desired) then
        -- The record was dropped, most likely by an Unknown transition. Re-take it.
        ns.StyleLedger.Apply(state.ledger, plate.healthBar, "BarColour", desired)
    end
    markContested(plate)
    return true
end

local function applyAggroColour(plate, aggroState)
    if aggroState == AGGRO.UNKNOWN then
        if plate.lastAggro ~= AGGRO.UNKNOWN then
            -- Never hold a claim we can no longer support (section 9.3).
            if ns.StyleLedger.HasRecord(state.ledger, plate.healthBar, "BarColour") then
                ns.StyleLedger.RestoreProperty(state.ledger, plate.healthBar, "BarColour")
            end
            plate.lastAggro = aggroState
            plate.desiredColour = nil
        end
        return
    end

    local colour = state.palette[aggroState]
    if not colour then
        return
    end

    if plate.lastAggro == aggroState then
        -- Same verdict, but Blizzard may have overwritten us since.
        plate.desiredColour = colour
        reassertColour(plate)
        return
    end

    local ok = ns.StyleLedger.Apply(state.ledger, plate.healthBar, "BarColour", colour)
    if capability.barRecolourable == nil then
        capability.barRecolourable = ok and true or false
        if not ok then
            ns.Log.Once("plates:barnotcolourable",
                "this client refuses to recolour nameplate health bars; aggro colouring is off")
        end
    end
    if ok then
        plate.lastAggro = aggroState
        plate.desiredColour = colour
    end
end

-- Previously "geometry has been written to this plate". Plate size is now a
-- client-wide setting, so what remains per-plate is only the colour, and this
-- means "we have taken responsibility for this plate".
local function styleIfInScope(plate)
    if plate.scope ~= SCOPE.IN then
        return
    end
    plate.styleApplied = true
end

-- Records are dropped the instant a plate detaches, before the client can
-- recycle the frame to a different unit (section 5.1).
local function unstylePlate(plate)
    if plate.healthBar then
        ns.StyleLedger.RestoreWidget(state.ledger, plate.healthBar)
    end
    plate.styleApplied = false
    plate.lastAggro = nil
    plate.desiredColour = nil
end

-- Lifecycle -------------------------------------------------------------------

local function untrackPlate(frame)
    local plate = state.plates[frame]
    if not plate then
        return false
    end
    unstylePlate(plate)
    if plate.unitFrame then
        state.byUnitFrame[plate.unitFrame] = nil
    end
    state.plates[frame] = nil
    state.plateCount = state.plateCount - 1
    return true
end

local function trackPlate(unitToken)
    local api = namePlateApi()
    if not api then
        return
    end

    local ok, frame = pcall(api.GetNamePlateForUnit, unitToken)
    if not ok or not frame then
        return
    end
    if state.plates[frame] then
        untrackPlate(frame)
    end

    local unitFrame, healthBar = resolveParts(frame)
    local plate = {
        frame = frame,
        unitFrame = unitFrame,
        healthBar = healthBar,
        unitToken = unitToken,
        scope = classifyScope(unitToken, frame),
        styleApplied = false,
        lastAggro = nil,
        desiredColour = nil,
    }

    state.plates[frame] = plate
    if unitFrame then
        state.byUnitFrame[unitFrame] = plate
    end
    state.plateCount = state.plateCount + 1

    if plate.scope == SCOPE.UNREACHABLE then
        ns.Log.Once("plates:unreachable",
            "at least one nameplate frame is unreachable on this client; those plates are skipped")
        return
    end
    styleIfInScope(plate)
end

-- Scope is not fixed for a plate's lifetime: a PvP flag, mind control or a
-- faction change can move a unit in or out of scope while its plate is up.
local function rescopePlate(plate)
    local newScope = classifyScope(plate.unitToken, plate.frame)
    if newScope == plate.scope then
        return
    end

    local wasIn = (plate.scope == SCOPE.IN)
    plate.scope = newScope

    if newScope == SCOPE.IN then
        styleIfInScope(plate)
    elseif wasIn then
        unstylePlate(plate)
    end
end

local function sweepStalePlates()
    local doomed = nil
    for frame, plate in pairs(state.plates) do
        local ok, exists = pcall(UnitExists, plate.unitToken)
        if not ok or not exists then
            doomed = doomed or {}
            doomed[#doomed + 1] = frame
        end
    end
    if not doomed then
        return 0
    end
    for index = 1, #doomed do
        untrackPlate(doomed[index])
    end
    return #doomed
end

-- Sweep -----------------------------------------------------------------------

-- Blizzard paints the player's selected target red on its own initiative, so on
-- exactly one plate -- the one you are attacking while someone else holds aggro --
-- our colour and its colour disagree and both of us keep writing.
--
-- The interval sweep alone makes that visible: Blizzard's write stands for up to
-- one sweep period, which reads as an oscillation rather than a colour. So a
-- contested plate is re-asserted every frame until it settles, which collapses
-- the disagreement to at most one frame. The set is bounded by how many plates
-- Blizzard is actually fighting us over, which is one.
local function onContestedFrame()
    local now = GetTime()
    local watching = false

    for plate, lastDriftAt in pairs(state.contested) do
        local stillOurs = state.plates[plate.frame] == plate
            and plate.scope == SCOPE.IN
            and plate.styleApplied
        if not stillOurs then
            state.contested[plate] = nil
        elseif reassertColour(plate) then
            watching = true
        elseif now - lastDriftAt > CONTESTED_GRACE then
            state.contested[plate] = nil
        else
            watching = true
        end
    end

    if not watching and state.contestedDriver then
        state.contestedDriver:SetScript("OnUpdate", nil)
        state.contestedRunning = false
    end
end

function markContested(plate)
    state.contested[plate] = GetTime()
    if state.contestedRunning or not state.enabled then
        return
    end
    state.contestedDriver = state.contestedDriver or CreateFrame("Frame")
    state.contestedDriver:SetScript("OnUpdate", onContestedFrame)
    state.contestedRunning = true
end

local function stopContesting()
    if state.contestedDriver then
        state.contestedDriver:SetScript("OnUpdate", nil)
    end
    state.contestedRunning = false
    state.contested = {}
end

-- Everything one plate needs re-asserted, with no classification. Cheap enough
-- to run from Blizzard's own update path.
local function reassertPlate(plate)
    if plate.scope ~= SCOPE.IN or not plate.styleApplied then
        return
    end
    reassertColour(plate)
end

local function colouringActive()
    return state.colouringWanted and capability.barRecolourable ~= false
end

local function sweep()
    if not state.enabled then
        return
    end

    state.sweepCount = state.sweepCount + 1

    state.reassertPending = false

    for _, plate in pairs(state.plates) do
        if plate.scope == SCOPE.IN then
            if not plate.styleApplied then
                styleIfInScope(plate)
            end
            if colouringActive() then
                state.aggroAttempts = state.aggroAttempts + 1
                applyAggroColour(plate, classifyAggro(plate.unitToken))
            else
                reassertColour(plate)
            end
        end
    end

    if state.sweepCount % STALE_SWEEP_EVERY == 0 then
        sweepStalePlates()
    end

    -- Surface once if the client appears to withhold aggro data entirely.
    if colouringActive() and not state.aggroResolvedEver and state.aggroAttempts > 200 then
        ns.Log.Once("plates:noaggrodata",
            "no nameplate target has resolved after 200 attempts; this client appears to withhold aggro data, so colouring conveys nothing")
    end
end

local function startTicker()
    if state.ticker then
        return
    end
    if C_Timer and C_Timer.NewTicker then
        state.ticker = C_Timer.NewTicker(state.sweepInterval, sweep)
    end
end

local function stopTicker()
    if state.ticker and state.ticker.Cancel then
        state.ticker:Cancel()
    end
    state.ticker = nil
end

-- Re-application hook ---------------------------------------------------------

-- A secure post-hook cannot be removed for the session, so it is installed at
-- most once and its body returns immediately when the feature is disabled
-- (section 7.2). It only accelerates the sweep; it never styles anything itself,
-- which keeps it indifferent to the hooked function's signature.
-- Every one of these that exists is hooked, not just the first. The colour-
-- specific paths matter most: a post-hook on the function that writes the colour
-- re-asserts in the SAME frame as Blizzard's write, which is the difference
-- between a corrected pixel and a visible flicker.
local HOOK_CANDIDATES = {
    "CompactUnitFrame_UpdateHealthColor",
    "CompactUnitFrame_UpdateHealth",
    "CompactUnitFrame_UpdateAll",
    "CompactUnitFrame_SetUnit",
    "DefaultCompactNamePlateFrameSetup",
}

local function installReassertHook()
    if state.hookInstalled or not hooksecurefunc then
        return
    end

    local installed = {}
    for index = 1, #HOOK_CANDIDATES do
        local name = HOOK_CANDIDATES[index]
        if type(_G[name]) == "function" then
            -- The hook must be O(1). Blizzard's update path fires per plate per
            -- health change, so calling the full sweep from here was O(n) per
            -- fire and O(n^2) per health tick across a crowded pull.
            local ok = pcall(hooksecurefunc, name, function(updatedFrame)
                if not state.enabled then
                    return
                end
                local plate = updatedFrame and state.byUnitFrame[updatedFrame]
                if plate then
                    reassertPlate(plate)
                    return
                end
                -- Unrecognised argument: coalesce into the next tick rather than
                -- sweeping synchronously on a call we cannot attribute.
                state.reassertPending = true
            end)
            if ok then
                installed[#installed + 1] = name
            end
        end
    end

    if #installed > 0 then
        state.hookInstalled = true
        ns.Log.Info(format("nameplate re-assert hooks installed on %s",
            table.concat(installed, ", ")))
        return
    end

    ns.Log.Once("plates:nohook",
        "no nameplate update path available to hook; re-assertion falls back to the sweep alone")
end

-- Signals ---------------------------------------------------------------------

local function onPlateAdded(unitToken)
    if unitToken then
        trackPlate(unitToken)
    end
end

local function onPlateRemoved(unitToken)
    local api = namePlateApi()
    if not api or not unitToken then
        return
    end
    local ok, frame = pcall(api.GetNamePlateForUnit, unitToken)
    if ok and frame and state.plates[frame] then
        untrackPlate(frame)
        return
    end
    -- The frame lookup can fail on removal; fall back to matching by token.
    for trackedFrame, plate in pairs(state.plates) do
        if plate.unitToken == unitToken then
            untrackPlate(trackedFrame)
            return
        end
    end
end

local function onUnitFaction(unitToken)
    if not unitToken then
        return
    end
    for _, plate in pairs(state.plates) do
        if plate.unitToken == unitToken then
            rescopePlate(plate)
            return
        end
    end
end

local function onEnteringWorld()
    sweepStalePlates()
end

local SIGNALS = {
    { event = "NAME_PLATE_UNIT_ADDED", handler = onPlateAdded, required = true,
      lost = "no nameplate can be tracked, so nothing can be styled" },
    { event = "NAME_PLATE_UNIT_REMOVED", handler = onPlateRemoved, required = false,
      lost = "plates are released by the stale sweep instead, up to one sweep late" },
    { event = "UNIT_FACTION", handler = onUnitFaction, required = false,
      lost = "a unit changing attackability is missed until its plate is replaced" },
    { event = "PLAYER_ENTERING_WORLD", handler = onEnteringWorld, required = false,
      lost = "stale plates are released by the interval sweep instead" },
}

-- Lifecycle -------------------------------------------------------------------

local function enable(config)
    readSettings(config)

    local api = namePlateApi()
    if not api then
        return nil, "this client exposes no nameplate lookup API, so plates cannot be reached"
    end
    capability.plateLookup = true

    state.ledger = state.ledger or ns.StyleLedger.Create("nameplates")

    local tokens = state.tokens
    for index = 1, #SIGNALS do
        local signal = SIGNALS[index]
        local token = ns.Dispatch.Subscribe(FEATURE_ID, signal.event, signal.handler)
        if token then
            tokens[#tokens + 1] = token
        elseif signal.required then
            return nil, format("this client does not deliver %s, so %s",
                signal.event, signal.lost)
        else
            ns.Log.Once("plates:missing:" .. signal.event, format(
                "%s is unavailable on this client; %s", signal.event, signal.lost))
        end
    end

    state.enabled = true

    -- Adopt plates already on screen: enabling mid-session must not wait for the
    -- next spawn.
    if api.GetNamePlates then
        local ok, existing = pcall(api.GetNamePlates)
        if ok and type(existing) == "table" then
            for index = 1, #existing do
                local entry = existing[index]
                local token = entry and (entry.namePlateUnitToken or entry.unitToken)
                if token then
                    trackPlate(token)
                end
            end
        end
    end

    installReassertHook()
    startTicker()

    return true
end

-- Every step is guarded: disable cleans up after a failed enable, which may not
-- have created the ledger or tracked anything.
local function disable()
    state.enabled = false
    stopTicker()
    stopContesting()

    for frame in pairs(state.plates) do
        untrackPlate(frame)
    end
    state.plates = {}
    state.byUnitFrame = {}
    state.reassertPending = false
    state.plateCount = 0

    if state.ledger then
        ns.StyleLedger.RestoreAll(state.ledger)
    end

    for index = #state.tokens, 1, -1 do
        ns.Dispatch.Unsubscribe(state.tokens[index])
        state.tokens[index] = nil
    end

    state.sweepCount = 0
end

local function onConfigChanged(config, changedKey)
    readSettings(config)

    if changedKey == "sweepInterval" then
        stopTicker()
        startTicker()
        return ns.CONFIG_RESULT.APPLIED
    end

    if changedKey == "yieldSelectedTarget" then
        stopContesting()
        for _, plate in pairs(state.plates) do
            plate.lastAggro = nil
        end
        sweep()
        return ns.CONFIG_RESULT.APPLIED
    end

    if changedKey == "aggroColouring" and not state.colouringWanted then
        stopContesting()
        for _, plate in pairs(state.plates) do
            if plate.lastAggro and plate.healthBar then
                ns.StyleLedger.RestoreProperty(state.ledger, plate.healthBar, "BarColour")
                plate.lastAggro = nil
            end
        end
        return ns.CONFIG_RESULT.APPLIED
    end

    -- Geometry and palette changes land on the next sweep, which is under a
    -- quarter of a second away; forcing one now makes it feel immediate.
    for _, plate in pairs(state.plates) do
        plate.lastAggro = nil
    end
    sweep()
    return ns.CONFIG_RESULT.APPLIED
end

ns.Registry.Register(FEATURE_ID, {
    enabledByDefault = true,
    label = "Nameplates",
    description = "Slimmer hostile nameplates, coloured by who the monster is attacking.",
    settings = {
        aggroColouring = true,
        -- Set true to stop contesting the bar colour on your current target and
        -- let Blizzard's selected-target red stand. Guaranteed stable, at the
        -- cost of no aggro colour on the one plate you are attacking.
        yieldSelectedTarget = false,
        colourOnPlayer = "ff4040",
        colourOnGroup = "40ff40",
        colourElsewhere = "ffffff",
        sweepInterval = 0.25,
    },
    schema = {
        aggroColouring = {
            kind = ns.ConfigSchema.KIND.TOGGLE, label = "Colour by who has aggro",
            description = "Red when it is on you, green when a party member or your pet has it, white otherwise.",
        },
        yieldSelectedTarget = {
            kind = ns.ConfigSchema.KIND.TOGGLE, label = "Leave your target's colour alone",
            description = "Stops contesting the bar colour on the unit you have selected. Turn this on if that plate flickers.",
        },
        colourOnPlayer = {
            kind = ns.ConfigSchema.KIND.COLOUR, label = "It is attacking you",
        },
        colourOnGroup = {
            kind = ns.ConfigSchema.KIND.COLOUR, label = "It is attacking your group or pet",
        },
        colourElsewhere = {
            kind = ns.ConfigSchema.KIND.COLOUR, label = "It is attacking neither",
        },
        -- Not curated: a frame-rate decision dressed as a preference.
        sweepInterval = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Sweep interval",
            minimum = 0.05, maximum = 2.0, curated = false,
        },
    },
}, {
    enable = enable,
    disable = disable,
    onConfigChanged = onConfigChanged,
})

ns.Nameplates = {
    Inspect = function()
        local inScope, outOfScope, unreachable, coloured = 0, 0, 0, 0
        for _, plate in pairs(state.plates) do
            if plate.scope == SCOPE.IN then
                inScope = inScope + 1
                if plate.lastAggro and plate.lastAggro ~= AGGRO.UNKNOWN then
                    coloured = coloured + 1
                end
            elseif plate.scope == SCOPE.OUT then
                outOfScope = outOfScope + 1
            else
                unreachable = unreachable + 1
            end
        end

        local held, restored, gone, refused = 0, 0, 0, 0
        if state.ledger then
            held, restored, gone, refused = ns.StyleLedger.Stats(state.ledger)
        end

        return {
            tracked = state.plateCount,
            inScope = inScope,
            outOfScope = outOfScope,
            unreachable = unreachable,
            coloured = coloured,
            sweeps = state.sweepCount,
            hookInstalled = state.hookInstalled,
            colouringActive = colouringActive(),
            reassertPending = state.reassertPending,
            contested = (function()
                local count = 0
                for _ in pairs(state.contested) do count = count + 1 end
                return count
            end)(),
            contestedRunning = state.contestedRunning,
            yieldSelectedTarget = state.yieldSelectedTarget,
            aggroResolvedEver = state.aggroResolvedEver,
            ledgerWidgets = held,
            ledgerRestored = restored,
            ledgerWidgetGone = gone,
            ledgerWriteRefused = refused,
            barRecolourable = capability.barRecolourable,
        }
    end,
}
