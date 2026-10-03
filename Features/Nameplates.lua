-- Features/Nameplates.lua
-- Hostile and neutral nameplates coloured from a DPS perspective: by who the
-- monster is attacking (Phase 2), and by whether you can get credit for it or it
-- is merely neutral (Phase 7 section 5).
--
-- Who a monster is attacking comes from threat since Phase 9
-- (Architecture/20261002-Phase09.md section 4, GAPBugs01 section 3). Phase 2 asked
-- the client whether the monster's target was you or a group member, with
-- UnitIsUnit("nameplate1target", ...). On an addon-restricted map -- a dungeon or
-- a raid -- the client makes every comparison involving a compound token secret,
-- the comparison raised outside its pcall, and every sweep stopped at the first
-- monster in combat: 7,843 times in the 2026-10-01 dungeon. Threat between you, or
-- an ally, and a nameplate is "generally not secret" per the client's own docs, and
-- it does not flicker when a monster retargets for a tick (Phase 2 section 4.8).
-- Every value the client returns here goes through ClientRead (README rule 10).
--
-- Restyle in place; own nothing. Blizzard's status bar is the only thing that
-- knows a unit's health and on this client likely the only thing that ever will,
-- so we recolour ITS bar. We create no frames, textures or font strings, which is
-- what makes the feature indifferent to whether health is readable.
--
-- Everything we change is recorded in the style ledger first, scoped to one
-- occupancy of one frame, so disable puts it back and a recycled frame never
-- inherits the previous unit's geometry.

local ADDON_NAME, ns = ...

local FEATURE_ID = "nameplates"

local format, pcall, pairs, tonumber = string.format, pcall, pairs, tonumber

local ClientRead = ns.ClientRead
local PLAIN, ABSENT, WITHHELD = ClientRead.PLAIN, ClientRead.ABSENT, ClientRead.WITHHELD
local bump = ns.Diagnostics.Bump

-- The allies whose threat makes a monster green: your pet first, then the party
-- or the raid. Built once, so a sweep concatenates no strings (Phase 9 section 4).
local PARTY_ALLIES = { "pet", "party1", "party2", "party3", "party4" }
local RAID_ALLIES = { "pet" }
for index = 1, 40 do
    RAID_ALLIES[#RAID_ALLIES + 1] = "raid" .. index
end

local SCOPE = { IN = "InScope", OUT = "OutOfScope", UNREACHABLE = "Unreachable" }
local AGGRO = {
    ON_PLAYER = "OnPlayer",
    ON_GROUP_OR_PET = "OnGroupOrPet",
    ELSEWHERE = "Elsewhere",
    UNKNOWN = "Unknown",
}

-- A unit's standing is independent of whom it is attacking (Phase 7 section 5.3).
local DISPOSITION = {
    TAP_DENIED = "TapDenied",
    NEUTRAL = "Neutral",
    HOSTILE = "Hostile",
    UNREADABLE = "Unreadable",
}

-- What the bar should show. CEDED hands the bar back to Blizzard: the recorded
-- original is restored and we stop contesting it. It is Phase 2's Unknown
-- behaviour, renamed here because two different causes now lead to it.
local VERDICT = {
    ON_PLAYER = "OnPlayer",
    TAP_DENIED = "TapDenied",
    ON_GROUP_OR_PET = "OnGroupOrPet",
    NEUTRAL = "Neutral",
    ELSEWHERE = "Elsewhere",
    CEDED = "Ceded",
}

local STANDING = {
    NOT_YET_READ = "NotYetRead",
    READABLE = "Readable",
    WITHHELD = "Withheld",
}

-- The client's reaction scale; 4 is neutral, which is what Blizzard paints yellow.
local NEUTRAL_REACTION = 4

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
    palette = {},
    colouringWanted = true,
    sweepInterval = 0.25,
    -- This UI load's diagnostics table (Phase 9 section 4.3). A detached table until
    -- enable binds it, so nothing here ever indexes nil.
    counters = {},
    -- The client's enum value for the map restriction, resolved once at enable
    -- through ClientRead (Phase 9 audit finding 4).
    mapTypeKind = WITHHELD,
    mapType = nil,
}

-- Capability ------------------------------------------------------------------

local capability = {
    plateLookup = false,
    barRecolourable = nil,
    -- Checked on the first standing read of the session and cached (Phase 2
    -- section 4.7): a refusal can arrive as a log line and a nil, not an error.
    standing = STANDING.NOT_YET_READ,
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
    state.palette[VERDICT.ON_PLAYER] = hexToColour(settings.colourOnPlayer, 1, 0.25, 0.25)
    state.palette[VERDICT.TAP_DENIED] = hexToColour(settings.colourTapDenied, 0.9, 0.9, 0.9)
    state.palette[VERDICT.ON_GROUP_OR_PET] = hexToColour(settings.colourOnGroup, 0.25, 1, 0.25)
    state.palette[VERDICT.NEUTRAL] = hexToColour(settings.colourNeutral, 1, 1, 0)
    state.palette[VERDICT.ELSEWHERE] = hexToColour(settings.colourElsewhere, 1, 1, 1)
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

-- A withheld "is this the player's own plate?" falls through to UnitCanAttack:
-- the player cannot attack themselves, so that read settles it either way.
local function classifyScope(unitToken, frame)
    if not frame then
        return SCOPE.UNREACHABLE
    end

    local playerKind, isPlayer = ClientRead.Call(UnitIsUnit, "boolean", unitToken, "player")
    if playerKind == PLAIN and isPlayer then
        return SCOPE.OUT
    end
    if playerKind == WITHHELD then
        bump(state.counters, "comparisonReadsWithheld")
    end

    local attackKind, attackable = ClientRead.Call(UnitCanAttack, "boolean", "player", unitToken)
    if attackKind == WITHHELD then
        return SCOPE.UNREACHABLE
    end
    if attackable then
        return SCOPE.IN
    end
    return SCOPE.OUT
end

-- Aggro -----------------------------------------------------------------------

-- Every read must distinguish "no" from "could not tell": a value the client
-- withheld is Unknown, never a guess. Unknown cedes the plate to Blizzard's colour,
-- so the cost of not knowing is an uncoloured plate rather than a confidently
-- wrong one.

-- With yieldSelectedTarget set, the plate the player is attacking is ceded, which
-- restores Blizzard's colour and stops us contesting it. The white target outline
-- still identifies it; what is given up is our colour on the one plate where
-- Blizzard has its own claim on the property. A withheld comparison also cedes:
-- yielding claims nothing, so it is the safe answer to "could not tell".
local function shouldYield(unitToken)
    local kind, same = ClientRead.Call(UnitIsUnit, "boolean", unitToken, "target")
    if kind == PLAIN then
        return same == true
    end
    if kind == ABSENT then
        return false
    end
    bump(state.counters, "comparisonReadsWithheld")
    return true
end

-- The group's shape, read once per sweep. A raid, a party, or nobody; when the
-- roster functions are absent or withheld, a party is assumed, which costs four
-- reads of possibly empty tokens and claims nothing.
local function allyTokens()
    local raidKind, inRaid = ClientRead.Call(IsInRaid, "boolean")
    if raidKind == PLAIN and inRaid then
        local sizeKind, size = ClientRead.Call(GetNumGroupMembers, "number")
        if sizeKind == PLAIN and size >= 1 then
            return RAID_ALLIES, math.min(size, 40) + 1
        end
        return PARTY_ALLIES, #PARTY_ALLIES
    end
    local groupKind, inGroup = ClientRead.Call(IsInGroup, "boolean")
    if groupKind == PLAIN and not inGroup then
        return PARTY_ALLIES, 1
    end
    return PARTY_ALLIES, #PARTY_ALLIES
end

-- One threat read, counted by result. 2 and 3 mean the unit is the mob's current
-- target; nil means the unit is not on the mob's threat list at all.
local function readThreat(unit, mobToken)
    local kind, status = ClientRead.Call(UnitThreatSituation, "number", unit, mobToken)
    local counters = state.counters
    if kind == PLAIN then
        bump(counters, "threatReadsPlain")
    elseif kind == ABSENT then
        bump(counters, "threatReadsAbsent")
    else
        bump(counters, "threatReadsWithheld")
    end
    return kind, status
end

-- Who the monster on this plate is attacking, from threat, never from its target
-- (GAPBugs01 section 3.6). A mob has one current target, so an ally found tanking
-- settles it even when the player's own read was withheld. Reading stops at the
-- first unit found tanking. Returns the classification and how many reads were
-- withheld.
local function classifyAggro(unitToken, allies, allyCount)
    local withheld = 0
    local kind, status = readThreat("player", unitToken)
    if kind == PLAIN and status >= ns.TANKING_STATUS then
        return AGGRO.ON_PLAYER, 0
    end
    if kind == WITHHELD then
        withheld = withheld + 1
    end

    for index = 1, allyCount do
        local allyKind, allyStatus = readThreat(allies[index], unitToken)
        if allyKind == PLAIN and allyStatus >= ns.TANKING_STATUS then
            return AGGRO.ON_GROUP_OR_PET, withheld
        end
        if allyKind == WITHHELD then
            withheld = withheld + 1
        end
    end

    if withheld > 0 then
        return AGGRO.UNKNOWN, withheld
    end
    return AGGRO.ELSEWHERE, 0
end

-- Standing --------------------------------------------------------------------

-- Tapped and neutral are what Blizzard's own plates already paint grey and yellow
-- (CompactUnitFrame_UpdateHealthColor). Our Elsewhere white painted over both;
-- Phase 7 puts them back under our priority.
--
-- None of the three reads carries a secret-return flag in this client's generated
-- API documentation, and Blizzard's plates make the first two on every colour
-- update. Documentation is evidence, not proof, so each value goes through
-- ClientRead before it is compared: testing a secret value is itself an error for
-- insecure code. Absent (nil) is accepted as "no", the direction that claims
-- nothing.

-- Returns tapDenied, playerControlled, reaction, readable.
local function readStanding(unitToken)
    local tapKind, tapDenied = ClientRead.Call(UnitIsTapDenied, "boolean", unitToken)
    local controlKind, controlled = ClientRead.Call(UnitPlayerControlled, "boolean", unitToken)
    local reactionKind, reaction = ClientRead.Call(UnitReaction, "number", "player", unitToken)
    if tapKind == WITHHELD or controlKind == WITHHELD or reactionKind == WITHHELD then
        bump(state.counters, "standingReadsWithheld")
        return nil, nil, nil, false
    end
    return tapDenied == true, controlled == true, reaction, true
end

-- Once per session, on the first in-scope plate the sweep reaches.
local function checkDispositionCapability(unitToken)
    local present = type(UnitIsTapDenied) == "function"
        and type(UnitPlayerControlled) == "function"
        and type(UnitReaction) == "function"
    local readable = present and select(4, readStanding(unitToken))
    if readable then
        capability.standing = STANDING.READABLE
        return
    end
    capability.standing = STANDING.WITHHELD
    ns.Log.Once("plates:standingwithheld",
        "this client withholds whether a nameplate unit is tapped or neutral; those plates keep the aggro colours")
end

-- Pre: the capability is not withheld; standingOf is the only caller.
local function classifyDisposition(unitToken)
    local tapDenied, controlled, reaction, readable = readStanding(unitToken)
    if not readable then
        -- Never claim a standing we did not read (Phase 2 section 9.0).
        return DISPOSITION.UNREADABLE
    end
    -- Mirrors CompactUnitFrame_IsTapDenied: a player or pet is never tap-denied.
    if tapDenied and not controlled then
        return DISPOSITION.TAP_DENIED
    end
    if reaction == NEUTRAL_REACTION then
        return DISPOSITION.NEUTRAL
    end
    return DISPOSITION.HOSTILE
end

local function standingOf(unitToken)
    if capability.standing == STANDING.NOT_YET_READ then
        checkDispositionCapability(unitToken)
    end
    if capability.standing == STANDING.WITHHELD then
        return DISPOSITION.UNREADABLE
    end
    return classifyDisposition(unitToken)
end

-- The one place bar colour is decided (Phase 7 section 5.4). Priority: on you,
-- then tapped, then group or pet, then neutral, then hostile. Grey never hides a
-- mob that is hitting you.
--
-- Tapped is shown even when aggro is Unknown, because Blizzard paints tapped grey
-- ahead of its own threat red, so grey is exactly what ceding would show. Neutral
-- is not: there Blizzard's colour carries threat-list membership we could not
-- read, and yellow would claim "not on you". Unreadable behaves as Hostile.
local function resolveColourVerdict(aggro, disposition)
    if aggro == AGGRO.ON_PLAYER then
        return VERDICT.ON_PLAYER
    end
    if disposition == DISPOSITION.TAP_DENIED then
        return VERDICT.TAP_DENIED
    end
    if aggro == AGGRO.ON_GROUP_OR_PET then
        return VERDICT.ON_GROUP_OR_PET
    end
    if aggro == AGGRO.UNKNOWN then
        return VERDICT.CEDED
    end
    if disposition == DISPOSITION.NEUTRAL then
        return VERDICT.NEUTRAL
    end
    return VERDICT.ELSEWHERE
end

-- The map-restriction state, as words for chat. Read on demand: it changes only
-- with the map, and nothing about a verdict depends on it.
local function restrictedMapNow()
    if state.mapTypeKind ~= PLAIN then
        return "unreadable"
    end
    local kind, active = ClientRead.Call(C_RestrictedActions and C_RestrictedActions.IsAddOnRestrictionActive,
        "boolean", state.mapType)
    if kind ~= PLAIN then
        return "unreadable"
    end
    return active and "yes" or "no"
end

-- A withheld threat read is surfaced once, with whether this is a restricted map,
-- because that is what someone reading it next needs to know (Phase 9 section 4).
local function noteWithheldThreat()
    ns.Log.Once("plates:threatwithheld", format(
        "threat reads were withheld (restricted map: %s); those plates keep Blizzard's colours",
        restrictedMapNow()))
end

local function verdictFor(plate, allies, allyCount)
    local unitToken = plate.unitToken
    if state.yieldSelectedTarget and shouldYield(unitToken) then
        return VERDICT.CEDED
    end

    local aggro, withheld = classifyAggro(unitToken, allies, allyCount)
    if withheld > 0 then
        noteWithheldThreat()
    end
    return resolveColourVerdict(aggro, standingOf(unitToken))
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
-- A bar whose colour the client withholds is neither written nor contested this
-- frame: its colour came from a secret, and a per-frame write against a value we
-- cannot read would be a fight with no way to tell who is winning.
local function reassertColour(plate)
    local desired = plate.desiredColour
    if not desired or not plate.healthBar then
        return false
    end
    local kind, current = ns.StyleLedger.Reads(state.ledger, plate.healthBar, "BarColour")
    if kind ~= PLAIN then
        if kind == WITHHELD and current == ClientRead.SECRET_VALUE then
            bump(state.counters, "barColourReadsWithheld")
        end
        return false
    end
    if coloursMatch(current, desired) then
        return false
    end
    if not ns.StyleLedger.Reapply(state.ledger, plate.healthBar, "BarColour", desired) then
        -- The record was dropped, most likely by a Ceded verdict. Re-take it.
        ns.StyleLedger.Apply(state.ledger, plate.healthBar, "BarColour", desired)
    end
    markContested(plate)
    return true
end

-- Counted on change, not per sweep, so the session record shows what happened
-- rather than how often the sweep ran (Phase 9 section 4.3).
local function noteVerdictChange(verdict)
    bump(state.counters, "verdictChangedTo" .. verdict)
end

local function applyColourVerdict(plate, verdict)
    if verdict == VERDICT.CEDED then
        if plate.lastVerdict ~= VERDICT.CEDED then
            -- Never hold a claim we can no longer support (Phase 2 section 9.3).
            if ns.StyleLedger.HasRecord(state.ledger, plate.healthBar, "BarColour") then
                ns.StyleLedger.RestoreProperty(state.ledger, plate.healthBar, "BarColour")
            end
            plate.lastVerdict = verdict
            plate.desiredColour = nil
            -- A ceded bar is Blizzard's again, so there is nothing left to contest.
            state.contested[plate] = nil
            noteVerdictChange(verdict)
        end
        return
    end

    local colour = state.palette[verdict]
    if not colour then
        return
    end

    if plate.lastVerdict == verdict then
        -- Same verdict, but Blizzard may have overwritten us since.
        plate.desiredColour = colour
        reassertColour(plate)
        return
    end

    local ok, reason = ns.StyleLedger.Apply(state.ledger, plate.healthBar, "BarColour", colour)
    if reason == "ORIGINAL_WITHHELD" then
        -- Blizzard coloured this bar from a secret. Not evidence that the client
        -- refuses recolouring: the plate keeps Blizzard's colour and is retried on
        -- the next sweep.
        bump(state.counters, "barColourReadsWithheld")
        return
    end
    if capability.barRecolourable == nil then
        capability.barRecolourable = ok and true or false
        if not ok then
            ns.Log.Once("plates:barnotcolourable",
                "this client refuses to recolour nameplate health bars; nameplate colouring is off")
        end
    end
    if ok then
        plate.lastVerdict = verdict
        plate.desiredColour = colour
        noteVerdictChange(verdict)
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
    plate.lastVerdict = nil
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
        lastVerdict = nil,
        desiredColour = nil,
    }

    state.plates[frame] = plate
    if unitFrame then
        state.byUnitFrame[unitFrame] = plate
    end
    state.plateCount = state.plateCount + 1
    if state.plateCount > (state.counters.maxTrackedPlates or 0) then
        state.counters.maxTrackedPlates = state.plateCount
    end

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
        local kind, exists = ClientRead.Call(UnitExists, "boolean", plate.unitToken)
        if kind ~= PLAIN or not exists then
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

-- Records whether this sweep ran on an addon-restricted map (Phase 9 section 4.2).
-- The enum value was resolved through ClientRead at enable, so an absent Enum
-- cannot raise here; the answer never changes a verdict.
local function sampleRestrictedMap()
    local counters = state.counters
    if state.mapTypeKind ~= PLAIN then
        bump(counters, "restrictedMapUnreadable")
        return
    end
    local kind, active = ClientRead.Call(C_RestrictedActions and C_RestrictedActions.IsAddOnRestrictionActive,
        "boolean", state.mapType)
    if kind ~= PLAIN then
        bump(counters, "restrictedMapUnreadable")
    elseif active then
        bump(counters, "restrictedMapSamples")
        counters.restrictedMapSeen = true
    end
end

local function paintPlate(plate, allies, allyCount)
    if not plate.styleApplied then
        styleIfInScope(plate)
    end
    if colouringActive() then
        applyColourVerdict(plate, verdictFor(plate, allies, allyCount))
    else
        reassertColour(plate)
    end
end

-- After a fault, the plate is handed back to Blizzard: whatever we had applied is
-- restored and nothing contests it. The next sweep tries it afresh.
local function cedeFaultedPlate(plate)
    if plate.healthBar and ns.StyleLedger.HasRecord(state.ledger, plate.healthBar, "BarColour") then
        pcall(ns.StyleLedger.RestoreProperty, state.ledger, plate.healthBar, "BarColour")
    end
    plate.lastVerdict = VERDICT.CEDED
    plate.desiredColour = nil
    state.contested[plate] = nil
end

-- One plate's fault never stops the sweep (Phase 9 section 4.6). Before Phase 9 a
-- single plate's error ended every sweep, and four re-assert paths kept the stale
-- colours of the plates it never reached. The message goes to the diagnostics log
-- rather than to the client's error handler: without BugGrabber, that handler
-- opens Blizzard's error window from our execution, which is GAPBugs01 G1's trigger.
local function sweep()
    if not state.enabled then
        return
    end

    state.sweepCount = state.sweepCount + 1
    bump(state.counters, "sweeps")

    state.reassertPending = false

    local allies, allyCount = allyTokens()
    for _, plate in pairs(state.plates) do
        if plate.scope == SCOPE.IN then
            local ok, fault = ns.Isolation.Call(paintPlate, plate, allies, allyCount)
            if not ok then
                bump(state.counters, "plateFaults")
                cedeFaultedPlate(plate)
                ns.Diagnostics.NoteFault(FEATURE_ID, fault)
                ns.Log.OnceError("plates:fault",
                    "a nameplate faulted and was handed back to Blizzard's colour; /pa diag shows the message")
            end
        end
    end

    if state.sweepCount % STALE_SWEEP_EVERY == 0 then
        sweepStalePlates()
    end
    if state.sweepCount % ns.RESTRICTION_SAMPLE_EVERY == 0 then
        sampleRestrictedMap()
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

-- The map-restriction enum, resolved once. Nothing is indexed outside ClientRead,
-- so a client without Enum.AddOnRestrictionType cannot raise here
-- (Phase 9 audit finding 4).
local function resolveMapRestrictionType()
    local typesKind, types = ClientRead.Field(_G.Enum, "AddOnRestrictionType", "table")
    if typesKind ~= PLAIN then
        return typesKind, types
    end
    return ClientRead.Field(types, "Map", "number")
end

local function enable(config)
    readSettings(config)

    local api = namePlateApi()
    if not api then
        return nil, "this client exposes no nameplate lookup API, so plates cannot be reached"
    end
    capability.plateLookup = true

    state.counters = ns.Diagnostics.CountersFor(FEATURE_ID)
    state.mapTypeKind, state.mapType = resolveMapRestrictionType()
    if not ClientRead.Available(UnitThreatSituation) then
        ns.Log.Once("plates:nothreat",
            "this client has no UnitThreatSituation, so who a monster is attacking cannot be read; plates keep Blizzard's colours except tapped ones")
    end

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
            plate.lastVerdict = nil
        end
        sweep()
        return ns.CONFIG_RESULT.APPLIED
    end

    if changedKey == "aggroColouring" and not state.colouringWanted then
        stopContesting()
        for _, plate in pairs(state.plates) do
            if plate.lastVerdict and plate.healthBar then
                ns.StyleLedger.RestoreProperty(state.ledger, plate.healthBar, "BarColour")
                plate.lastVerdict = nil
            end
        end
        return ns.CONFIG_RESULT.APPLIED
    end

    -- Palette changes land on the next sweep, which is under a quarter of a
    -- second away; forcing one now makes it feel immediate.
    for _, plate in pairs(state.plates) do
        plate.lastVerdict = nil
    end
    sweep()
    return ns.CONFIG_RESULT.APPLIED
end

ns.Registry.Register(FEATURE_ID, {
    enabledByDefault = true,
    label = "Nameplates",
    description = "Hostile and neutral nameplates, coloured by who the monster is attacking.",
    settings = {
        aggroColouring = true,
        -- Set true to stop contesting the bar colour on your current target and
        -- let Blizzard's selected-target red stand. Guaranteed stable, at the
        -- cost of no aggro colour on the one plate you are attacking.
        yieldSelectedTarget = false,
        colourOnPlayer = "ff4040",
        colourOnGroup = "40ff40",
        colourElsewhere = "ffffff",
        -- Both are Blizzard's own colours, so by default neither contests the
        -- bar: e6 is 0.902, inside COLOUR_TOLERANCE of Blizzard's 0.9 grey.
        colourTapDenied = "e6e6e6",
        colourNeutral = "ffff00",
        sweepInterval = 0.25,
    },
    schema = {
        aggroColouring = {
            kind = ns.ConfigSchema.KIND.TOGGLE, label = "Colour nameplates",
            description = "Red: it is attacking you. Grey: tagged by a player outside your group. Green: attacking your group or pet. Yellow: neutral. White: hostile, attacking neither.",
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
            kind = ns.ConfigSchema.KIND.COLOUR, label = "Hostile, and attacking neither",
        },
        colourTapDenied = {
            kind = ns.ConfigSchema.KIND.COLOUR, label = "Tagged by a player outside your group",
        },
        colourNeutral = {
            kind = ns.ConfigSchema.KIND.COLOUR, label = "Neutral, and on neither you nor your group",
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
        local verdicts = {}
        for _, name in pairs(VERDICT) do
            verdicts[name] = 0
        end
        for _, plate in pairs(state.plates) do
            if plate.scope == SCOPE.IN then
                inScope = inScope + 1
                local verdict = plate.lastVerdict
                if verdict then
                    verdicts[verdict] = (verdicts[verdict] or 0) + 1
                    if verdict ~= VERDICT.CEDED then
                        coloured = coloured + 1
                    end
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
        local counters = state.counters

        return {
            tracked = state.plateCount,
            inScope = inScope,
            outOfScope = outOfScope,
            unreachable = unreachable,
            coloured = coloured,
            verdicts = verdicts,
            standingCapability = capability.standing,
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
            threatReadsPlain = counters.threatReadsPlain or 0,
            threatReadsAbsent = counters.threatReadsAbsent or 0,
            threatReadsWithheld = counters.threatReadsWithheld or 0,
            comparisonReadsWithheld = counters.comparisonReadsWithheld or 0,
            standingReadsWithheld = counters.standingReadsWithheld or 0,
            barColourReadsWithheld = counters.barColourReadsWithheld or 0,
            plateFaults = counters.plateFaults or 0,
            restrictedMapNow = restrictedMapNow(),
            ledgerWidgets = held,
            ledgerRestored = restored,
            ledgerWidgetGone = gone,
            ledgerWriteRefused = refused,
            barRecolourable = capability.barRecolourable,
        }
    end,
}
