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
-- The threat reads, the standing reads and the verdict live in Core/Threat.lua
-- since Phase 11 (Architecture/20261005-Phase11.md section 2), so the threat panel
-- colours a mob exactly as its plate is coloured. What stays here is everything
-- about plates: scope, styling, the ledger, the contest and the sweep.
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

local format, pcall, pairs = string.format, pcall, pairs

local ClientRead = ns.ClientRead
local PLAIN, ABSENT, WITHHELD = ClientRead.PLAIN, ClientRead.ABSENT, ClientRead.WITHHELD
local bump = ns.Diagnostics.Bump

local Threat = ns.Threat
local VERDICT = Threat.VERDICT

local SCOPE = { IN = "InScope", OUT = "OutOfScope", UNREACHABLE = "Unreachable" }

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
    hookTargets = nil,
    tokens = {},
    palette = {},
    colouringWanted = true,
    sweepInterval = 0.25,
    -- Phase 14. 1 writes nothing; the feature is inert until the slider moves.
    barHeightFraction = 1.0,
    lastBarBase = nil,
    lastBarHeight = nil,
    -- Phase 15. Off by default: it puts text on every player's nameplate.
    guildNames = false,
    guildFontSize = 10,
    guildPool = nil,
    -- What GetHeight last gave back, so /pa plates can show the round-trip.
    lastBarRead = nil,
    -- This UI load's diagnostics table (Phase 9 section 4.3). A detached table until
    -- enable binds it, so nothing here ever indexes nil.
    counters = {},
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

local function readSettings(config)
    local settings = config and config.settings
    if not settings then
        return
    end
    state.sweepInterval = settings.sweepInterval or state.sweepInterval
    state.barHeightFraction = settings.barHeightFraction or state.barHeightFraction
    state.guildNames = (settings.guildNames == true)
    state.guildFontSize = settings.guildFontSize or state.guildFontSize
    state.colouringWanted = (settings.aggroColouring ~= false)
    state.yieldSelectedTarget = (settings.yieldSelectedTarget == true)
    state.palette = Threat.PaletteFrom(settings)
end

-- Frame shape -----------------------------------------------------------------

-- Resolved rather than assumed: every falsified Phase 1 assumption was a
-- well-known API this client arranges differently.
local function resolveParts(frame)
    local unitFrame = frame.UnitFrame or frame.unitFrame or frame
    local healthBar = unitFrame.healthBar or unitFrame.HealthBar or unitFrame.healthbar
    -- Phase 14: the bar's height is written on its CONTAINER, not on the bar.
    -- The bar carries two vertical anchors and discards a height; the container
    -- carries two BOTTOM anchors and an explicit height, which is the difference
    -- Phase 2 section 4.9 missed.
    local container = unitFrame.HealthBarsContainer or unitFrame.healthBarsContainer
    return unitFrame, healthBar, container
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

-- The map-restriction state, as words for chat. Read on demand: it changes only
-- with the map, and nothing about a verdict depends on it. The read itself lives in
-- core since Phase 10 (section 7.1).
local MAP_WORDS = {
    [ns.MapRestriction.RESTRICTED] = "yes",
    [ns.MapRestriction.UNRESTRICTED] = "no",
    [ns.MapRestriction.UNREADABLE] = "unreadable",
}

local function restrictedMapNow()
    return MAP_WORDS[ns.MapRestriction.Read()]
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

    local counters = state.counters
    local aggro, withheld = Threat.ClassifyAggro(unitToken, allies, allyCount, counters)
    if withheld > 0 then
        noteWithheldThreat()
    end
    return Threat.ResolveVerdict(aggro, Threat.Disposition(unitToken, counters))
end

-- Guild names (Phase 15) ------------------------------------------------------
--
-- Blizzard's nameplate name cannot be measured, let alone moved or extended
-- (Phase 2 section 4.7: GetPoint on it fails with "Can't measure restricted
-- regions"), and the plate carries no guild font string to borrow. So the text
-- is OURS: a frame per plate under UIParent, anchored to the plate's health bar
-- container and never parented to it (rule 6).
--
-- A guild name is player-chosen text delivered by the server, so it crosses a
-- trust boundary on its way to a font string. EscapeGuard.Neutralize is applied
-- at that crossing, every time. This is the consumer Phase 2 section 13 said
-- EscapeGuard was waiting for.
--
-- NOTHING RE-ASSERTS IT. The label is ours and Blizzard never writes it, which is
-- what makes this phase smaller than the colour or the height. The guild is read
-- when a plate attaches, and again when the client says a guild changed.

local GUILD_READING = {
    PLAIN = "Plain",
    NO_GUILD = "NoGuild",
    WITHHELD = "Withheld",
    UNAVAILABLE = "Unavailable",
}

-- The guild name for one unit. UnitIsPlayer is asked first because two thirds of
-- the plates in a city have no guild and six in ten of those are NPCs, and it is
-- the cheaper question (section 3.3).
local function readGuild(unitToken)
    local fn = _G.GetGuildInfo
    if type(fn) ~= "function" then
        return GUILD_READING.UNAVAILABLE, "GetGuildInfo is missing from this client"
    end

    local playerKind, isPlayer = ClientRead.Call(_G.UnitIsPlayer, "boolean", unitToken)
    if playerKind == WITHHELD then
        -- "Could not tell whether this is a player" is not grounds for asking
        -- about its guild.
        return GUILD_READING.WITHHELD
    end
    if playerKind ~= PLAIN or isPlayer ~= true then
        return GUILD_READING.NO_GUILD
    end

    local kind, name = ClientRead.Call(fn, "string", unitToken)
    -- ABSENT is a READABLE nil: this player has no guild. WITHHELD is "could not
    -- tell", and rule 10 forbids reading it as "no".
    if kind == ClientRead.ABSENT then
        return GUILD_READING.NO_GUILD
    end
    if kind == WITHHELD then
        return GUILD_READING.WITHHELD
    end
    if kind ~= PLAIN or name == "" then
        return GUILD_READING.NO_GUILD
    end
    return GUILD_READING.PLAIN, name
end

local function countGuildReading(reading)
    if reading == GUILD_READING.PLAIN then
        bump(state.counters, "guildReadsPlain")
    elseif reading == GUILD_READING.NO_GUILD then
        bump(state.counters, "guildReadsNoGuild")
    elseif reading == GUILD_READING.WITHHELD then
        bump(state.counters, "guildReadsWithheld")
    else
        bump(state.counters, "guildReadsUnavailable")
    end
end

local function ensureGuildPool()
    if state.guildPool then
        return state.guildPool
    end
    state.guildPool = ns.FramePool.Create({
        poolName = "guildLabels",
        capacity = ns.GUILD_LABEL_POOL_CAPACITY,
        dropPolicy = ns.DROP_POLICY.SURFACE_AND_FAIL,
        factory = function()
            -- UIParent, never the plate: SmartNavigation post-hooks CreateFrame
            -- and rebuilds a panel's navigation, in whoever's code is running,
            -- when a new frame's parent chain reaches a panel it tracks
            -- (Patch 01 section 0.2). A child of ours under a nameplate would
            -- put our taint there.
            local frame = CreateFrame("Frame", nil, _G.UIParent)
            frame:EnableMouse(false)
            frame.text = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            frame.text:SetAllPoints(frame)
            frame.text:SetJustifyH("CENTER")
            frame.text:SetWordWrap(false)
            frame.text:SetAlpha(ns.GUILD_LABEL_ALPHA)
            frame:Hide()
            return frame
        end,
        reset = function(frame)
            frame:Hide()
            frame:ClearAllPoints()
            frame.text:SetText("")
        end,
    })
    return state.guildPool
end

-- Both halves of the size matter: the font so the text is the chosen size, and
-- the frame so a larger size is not clipped by the box it sits in.
local function sizeGuildLabel(label)
    local points = state.guildFontSize
    label:SetHeight(points + 2)
    label.text:SetTextHeight(points)
end

local function releaseGuildLabel(plate)
    if not plate.label then
        return
    end
    ns.FramePool.Release(state.guildPool, plate.label)
    plate.label = nil
end

local function attachGuildLabel(plate, guildName)
    if not plate.container then
        return false
    end
    if not plate.label then
        local label, poolError = ns.FramePool.Acquire(ensureGuildPool())
        if not label then
            bump(state.counters, "guildPoolExhausted")
            ns.Log.OnceError("plates:guildpool", format(
                "the guild label pool was exhausted (%s); the cap is wrong",
                tostring(poolError)))
            return false
        end
        plate.label = label
    end

    local label = plate.label
    sizeGuildLabel(label)
    local widthKind, width = ClientRead.Call(plate.container.GetWidth, "number", plate.container)
    label:SetWidth((widthKind == PLAIN and width and width > 0) and width or 120)
    label:ClearAllPoints()
    label:SetPoint("TOP", plate.container, "BOTTOM", 0, -ns.GUILD_LABEL_GAP)
    -- Player-chosen text, so every pipe is doubled before it reaches the font
    -- string: that is what makes the escape codes inert.
    label.text:SetText(ns.EscapeGuard.Neutralize(guildName))
    label:Show()
    bump(state.counters, "guildLabelsAttached")
    return true
end

-- Brings one plate's label to whatever its guild reads as now. The one place the
-- guild is read, so attach and refresh cannot drift apart.
local function applyGuild(plate)
    if not state.guildNames or not plate.unitToken then
        releaseGuildLabel(plate)
        plate.guild = nil
        return
    end

    local reading, value = readGuild(plate.unitToken)
    countGuildReading(reading)

    if reading == GUILD_READING.UNAVAILABLE then
        ns.Log.Once("plates:noguildapi", format(
            "%s, so guild names cannot be shown", tostring(value)))
        releaseGuildLabel(plate)
        plate.guild = nil
        return
    end

    if reading ~= GUILD_READING.PLAIN then
        releaseGuildLabel(plate)
        plate.guild = nil
        return
    end

    if plate.guild == value and plate.label then
        return
    end
    plate.guild = value
    attachGuildLabel(plate, value)
end

-- PLAYER_GUILD_UPDATE: a player can join, leave or be kicked from a guild while
-- their plate is on screen, so a label read only at attach would go stale. The
-- event names a unit, but as a UnitTokenVariant that need not be the nameplateN
-- token our records are keyed by, and matching it would cost a read per plate
-- anyway, so every tracked plate is re-read. Bounded by the plate cap.
local function refreshGuildLabels()
    bump(state.counters, "guildRefreshes")
    if not state.guildNames then
        return 0
    end
    local touched = 0
    for _, plate in pairs(state.plates) do
        applyGuild(plate)
        touched = touched + 1
    end
    return touched
end

local function releaseAllGuildLabels()
    if not state.guildPool then
        return
    end
    for _, plate in pairs(state.plates) do
        releaseGuildLabel(plate)
        plate.guild = nil
    end
end

-- Every label the pool has built, free and live alike: the live ones so the
-- slider is visibly live, the free ones so a label released and re-acquired does
-- not come back at the old size (Phase 14 section 14 learned this about rows).
local function applyGuildFontSize()
    if not state.guildPool then
        return
    end
    ns.FramePool.ForEach(state.guildPool, sizeGuildLabel)
end

-- Bar height (Phase 14) -------------------------------------------------------
--
-- Blizzard writes the bar's height on every layout pass:
-- NamePlateUnitFrameMixin:UpdateAnchors does
-- HealthBarsContainer:SetHeight(setupOptions.healthBarHeight). So the height is
-- a value with two writers, like the colour, and it is re-asserted on the same
-- post-hook.
--
-- THE BASE COMES FROM BLIZZARD'S OPTIONS TABLE, NOT FROM THE FRAME. Reading the
-- frame's current height and multiplying would be correct only if the hook fired
-- just after a layout pass. It does not: CompactUnitFrame_SetUnit is also called
-- from ClearUnit, and CompactUnitFrame_UpdateHealth and UpdateHealthColor are on
-- the same hook list and fire on every health change with no layout at all. The
-- second fire would scale our own value again, and the bar would reach
-- MINIMUM_BAR_PIXELS within a few health ticks. Taking the base from Blizzard's
-- field makes the write IDEMPOTENT: the target depends on Blizzard's setting and
-- the user's percentage, never on what is on the frame.
--
-- It is a READ of a Blizzard table, which rule 2 does not forbid; writing that
-- field is what rule 2 forbids, and Phase 14 section 6.1 declines it.

local BAR_HEIGHT_OPTION = "healthBarHeight"

-- Blizzard's base height for every plate, or nil when it cannot be read.
local function blizzardBarHeight()
    local options = _G.NamePlateSetupOptions
    if type(options) ~= "table" then
        return nil, "NamePlateSetupOptions is missing on this client"
    end
    local kind, value = ClientRead.Field(options, BAR_HEIGHT_OPTION, "number")
    if kind ~= PLAIN or not value or value <= 0 then
        return nil, "the client would not show its own nameplate bar height"
    end
    return value
end

-- A height written through SetHeight does not read back equal through GetHeight,
-- so comparing with == meant the "already correct" branch never fired once in
-- four play sessions: barHeightUnchanged stayed at zero against 6,800 writes,
-- and every hook fire rewrote the bar. Phase 2 learned the same thing about
-- colour and answered it with COLOUR_TOLERANCE; Phase 14 shipped == and lost the
-- optimisation.
--
-- The tolerance has to separate "still ours" from "Blizzard reset it to base".
-- The smallest gap between the two is base * (1 - fraction), which at the
-- smallest base this client produces (8px, Classic at Small scale) and the
-- largest fraction below 1 (0.95) is 0.4. So anything under 0.4 is safe by
-- construction, and 0.1 leaves room for sub-pixel rounding.
--
-- If barHeightUnchanged is still zero after this, the discrepancy is larger than
-- sub-pixel: /pa plates now prints the height last READ beside the one last
-- written, and this constant moves to fit the evidence.
local BAR_HEIGHT_TOLERANCE = 0.1

local function barHeightsMatch(left, right)
    return math.abs(left - right) <= BAR_HEIGHT_TOLERANCE
end

local function wantedBarHeight(base)
    local wanted = base * state.barHeightFraction
    if wanted < ns.MINIMUM_BAR_PIXELS then
        return ns.MINIMUM_BAR_PIXELS
    end
    return wanted
end

-- Brings one plate's bar to the configured share of Blizzard's height. O(1), and
-- idempotent: firing this a hundred times writes the same value once.
local function reassertBarHeight(plate)
    if state.barHeightFraction >= 1 or not plate.container then
        return
    end

    local base, reason = blizzardBarHeight()
    if not base then
        bump(state.counters, "barHeightBaseWithheld")
        ns.Log.Once("plates:nobarbase", format(
            "%s, so the health bar height setting does nothing", tostring(reason)))
        return
    end

    local wanted = wantedBarHeight(base)

    -- The comparison is an optimisation: the hook fires on every health change,
    -- and a bar already at the wanted height needs no write. A height that will
    -- not read does not stop the write, because `wanted` does not depend on it.
    local kind, current = ClientRead.Call(plate.container.GetHeight, "number", plate.container)
    if kind == PLAIN then
        state.lastBarRead = current
        if barHeightsMatch(current, wanted) then
            bump(state.counters, "barHeightUnchanged")
            return
        end
    else
        bump(state.counters, "barHeightCompareWithheld")
    end

    if pcall(plate.container.SetHeight, plate.container, wanted) then
        bump(state.counters, "barHeightWrites")
        state.lastBarHeight = wanted
        state.lastBarBase = base
    else
        bump(state.counters, "barHeightRefused")
    end
end

-- Puts every tracked plate back to Blizzard's own height. Blizzard restores it
-- by itself on the next layout pass, so this only makes it immediate.
local function restoreBarHeights()
    local base = blizzardBarHeight()
    if not base then
        return 0
    end
    local restored = 0
    for _, plate in pairs(state.plates) do
        if plate.container and pcall(plate.container.SetHeight, plate.container, base) then
            restored = restored + 1
        end
    end
    state.lastBarHeight = nil
    return restored
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
-- confirm the effect. Confirming the call was insufficient and confirming the
-- stored value was also insufficient; the only sufficient check was a person
-- looking at a nameplate.
--
-- PHASE 14 FOUND THE THIRD MECHANISM, and it works: the bar's height is written
-- on its CONTAINER, which carries both its anchors at the bottom, so a height of
-- ours is not recomputed away. See the bar-height section above. Neither of the
-- two attempts recorded here became possible; a frame neither of them touched
-- did.

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
    -- Before the record goes, while the label is still reachable: a label left on
    -- a recycled plate would show the previous unit's guild.
    releaseGuildLabel(plate)
    plate.guild = nil
    -- Phase 17 section 4.1. Same moment and same reason as the guild label: a
    -- marker left on a recycled plate would sit over the wrong mob.
    if ns.QuestMarkers then
        ns.QuestMarkers.OnPlateDetached(plate)
    end
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

    local unitFrame, healthBar, container = resolveParts(frame)
    local plate = {
        frame = frame,
        unitFrame = unitFrame,
        healthBar = healthBar,
        container = container,
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

    -- Applied here as well as on the hook: Blizzard's driver and our event
    -- handler both run on NAME_PLATE_UNIT_ADDED and the order between them is
    -- not ours to choose, so a plate that was laid out before we tracked it
    -- would otherwise keep Blizzard's height until its next layout pass. The
    -- write is idempotent, so doing it twice costs one comparison.
    reassertBarHeight(plate)
    -- Phase 15. Outside the scope guard, like the height: a guild name belongs on
    -- every player's plate, friendly or hostile, and NPCs are excluded by having
    -- no guild rather than by scope.
    applyGuild(plate)

    if plate.scope == SCOPE.UNREACHABLE then
        ns.Log.Once("plates:unreachable",
            "at least one nameplate frame is unreachable on this client; those plates are skipped")
        return
    end

    -- Phase 17 section 4.1. Outside the scope check for the same reason the guild
    -- label is: SCOPE.IN/OUT classifies a plate for the COLOUR feature, from a
    -- damage dealer's point of view, and a quest mob is often neutral -- which
    -- classifyScope makes SCOPE.OUT. Inside the guard this would silently drop
    -- markers from every neutral quest mob. After the UNREACHABLE return, because
    -- such a plate has no container to anchor to.
    if ns.QuestMarkers then
        ns.QuestMarkers.OnPlateAttached(plate)
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
    -- Height first, and outside the scope guard: it applies to every nameplate,
    -- friendly ones included, because a bar that were short on enemies and tall
    -- on friends would read as a defect rather than a setting (section 5.4).
    reassertBarHeight(plate)

    if plate.scope ~= SCOPE.IN or not plate.styleApplied then
        return
    end
    reassertColour(plate)
end

local function colouringActive()
    return state.colouringWanted and capability.barRecolourable ~= false
end

-- Records whether this sweep ran on an addon-restricted map (Phase 9 section 4.2).
-- MapRestriction resolves the enum through ClientRead, so an absent Enum cannot
-- raise here; the answer never changes a verdict.
local function sampleRestrictedMap()
    local counters = state.counters
    local reading = ns.MapRestriction.Read()
    if reading == ns.MapRestriction.UNREADABLE then
        bump(counters, "restrictedMapUnreadable")
    elseif reading == ns.MapRestriction.RESTRICTED then
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

    local allies, allyCount = Threat.Allies()
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
        -- Which hooks took is in /pa plates, which is where someone looking for it
        -- would look. Saying it in chat at every login is noise.
        state.hookTargets = table.concat(installed, ", ")
        return
    end

    ns.Log.Once("plates:nohook",
        "no nameplate update path available to hook; re-assertion falls back to the sweep alone")
end

-- Signals ---------------------------------------------------------------------

local function onGuildUpdate()
    refreshGuildLabels()
end

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
    -- Phase 15. Not required: without it a guild label is correct when the plate
    -- attaches and stale only if that unit's guild changes before the plate
    -- recycles.
    { event = "PLAYER_GUILD_UPDATE", handler = onGuildUpdate, required = false,
      lost = "a guild name is not refreshed if it changes while the plate is in view" },
}

-- Lifecycle -------------------------------------------------------------------

local function enable(config)
    readSettings(config)

    local api = namePlateApi()
    if not api then
        return nil, "this client exposes no nameplate lookup API, so plates cannot be reached"
    end
    capability.plateLookup = true

    state.counters = ns.Diagnostics.CountersFor(FEATURE_ID)
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

    -- Before the plates are untracked, while their containers are still to hand.
    -- Blizzard would restore these itself on its next layout pass; this only
    -- makes it immediate (section 5.5).
    restoreBarHeights()

    releaseAllGuildLabels()

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

    if changedKey == "guildNames" then
        if state.guildNames then
            for _, plate in pairs(state.plates) do
                applyGuild(plate)
            end
        else
            releaseAllGuildLabels()
        end
        return ns.CONFIG_RESULT.APPLIED
    end

    if changedKey == "guildFontSize" then
        applyGuildFontSize()
        return ns.CONFIG_RESULT.APPLIED
    end

    if changedKey == "barHeightFraction" then
        if state.barHeightFraction >= 1 then
            restoreBarHeights()
        else
            for _, plate in pairs(state.plates) do
                reassertBarHeight(plate)
            end
        end
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

-- The colour defaults come from Core/Threat.lua, which the threat panel paints
-- with too, so the two cannot disagree (Phase 11 section 2.2). The tapped grey and
-- the neutral yellow are Blizzard's own colours, so by default neither contests
-- the bar: e6 is 0.902, inside COLOUR_TOLERANCE of Blizzard's 0.9 grey.
local defaultSettings = Threat.PaletteDefaults()
defaultSettings.aggroColouring = true
-- Set true to stop contesting the bar colour on your current target and let
-- Blizzard's selected-target red stand. Guaranteed stable, at the cost of no aggro
-- colour on the one plate you are attacking.
defaultSettings.yieldSelectedTarget = false
defaultSettings.sweepInterval = 0.25
-- Phase 14: a fraction of Blizzard's own bar height. 1.0 writes nothing, so an
-- existing user sees no change until they move the slider.
defaultSettings.barHeightFraction = 1.0
-- Phase 15: off by default, because it puts text on every player's nameplate.
defaultSettings.guildNames = false
defaultSettings.guildFontSize = ns.GUILD_FONT_DEFAULT

ns.Registry.Register(FEATURE_ID, {
    enabledByDefault = true,
    label = "Nameplates",
    description = "Hostile and neutral nameplates, coloured by who the monster is attacking.",
    settingsPage = ns.SETTINGS_PAGE.NAMEPLATES,
    settingsOrder = 10,
    settings = defaultSettings,
    -- The colours are ordered by the verdict priority of Phase 11 section 2.3, so the
    -- page reads in the order the colours win.
    schema = {
        aggroColouring = {
            kind = ns.ConfigSchema.KIND.TOGGLE, label = "Colour nameplates", order = 1,
            description = "Red: it is attacking you. Orange: you are about to pull it. Grey: tagged by a player outside your group. Green: attacking your group or pet. Yellow: neutral. White: hostile, attacking neither.",
        },
        -- Phase 14. A percentage of the game's own height, not a pixel count: the
        -- game's base depends on the Style and Global Scale the user chose, so a
        -- stored pixel count would be half the bar on one Style and a third on
        -- another, and would not follow Global Scale (section 5.1).
        barHeightFraction = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Health bar height", order = 2,
            unit = ns.ConfigSchema.UNIT.FRACTION,
            description = "As a share of the game's own height. Everything else on the nameplate stays the game's, so a shorter bar lowers the name with it.",
            minimum = 0.3, maximum = 1.0, step = 0.05,
        },
        -- Phase 15. A guild name encodes nothing, unlike the six colours below,
        -- so it gets no colour of its own: one faded white is the right amount
        -- of emphasis for a label.
        guildNames = {
            kind = ns.ConfigSchema.KIND.TOGGLE, label = "Show guild names", order = 3,
            description = "Under the health bar, for every player who has one. Nothing is shown for a player with no guild, or for a monster.",
        },
        guildFontSize = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Guild name size", order = 4,
            unit = ns.ConfigSchema.UNIT.PIXELS,
            minimum = ns.GUILD_FONT_MINIMUM, maximum = ns.GUILD_FONT_MAXIMUM, step = 1,
        },
        yieldSelectedTarget = {
            kind = ns.ConfigSchema.KIND.TOGGLE, label = "Leave your target's colour alone", order = 5,
            description = "Stops contesting the bar colour on the unit you have selected. Turn this on if that plate flickers.",
        },
        colourOnPlayer = {
            kind = ns.ConfigSchema.KIND.COLOUR, label = "It is attacking you", order = 10,
            group = "Colours, highest priority first",
            groupDescription = "The threat panel's bars use these colours too.",
        },
        -- R7 (Phase 11 section 3).
        colourAboutToPull = {
            kind = ns.ConfigSchema.KIND.COLOUR, label = "You are about to pull it", order = 11,
            group = "Colours, highest priority first",
            description = "Your threat is above the tank's, and the mob is not on you yet",
        },
        colourTapDenied = {
            kind = ns.ConfigSchema.KIND.COLOUR, label = "Tagged by a player outside your group", order = 12,
            group = "Colours, highest priority first",
        },
        colourOnGroup = {
            kind = ns.ConfigSchema.KIND.COLOUR, label = "It is attacking your group or pet", order = 13,
            group = "Colours, highest priority first",
        },
        colourNeutral = {
            kind = ns.ConfigSchema.KIND.COLOUR, label = "Neutral, and on neither you nor your group", order = 14,
            group = "Colours, highest priority first",
        },
        colourElsewhere = {
            kind = ns.ConfigSchema.KIND.COLOUR, label = "Hostile, and attacking neither", order = 15,
            group = "Colours, highest priority first",
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
    -- Phase 17 section 4.1. The plate records currently tracked, for a decoration
    -- that enabled after some plates were already up and so never saw their attach
    -- call-out. Read-only by contract: the table is ours and the caller must not
    -- hold it past the call.
    TrackedPlates = function()
        local out = {}
        for _, plate in pairs(state.plates) do
            out[#out + 1] = plate
        end
        return out
    end,

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
            -- Phase 14. barHeightFraction of 1 means the feature is inert.
            barHeightFraction = state.barHeightFraction,
            barHeightBase = state.lastBarBase,
            barHeightWritten = state.lastBarHeight,
            barHeightRead = state.lastBarRead,
            barHeightTolerance = BAR_HEIGHT_TOLERANCE,
            guildNames = state.guildNames,
            guildFontSize = state.guildFontSize,
            guildLabels = (function()
                local count = 0
                for _, plate in pairs(state.plates) do
                    if plate.label then count = count + 1 end
                end
                return count
            end)(),
            guildPoolCapacity = ns.GUILD_LABEL_POOL_CAPACITY,
            guildReadsPlain = counters.guildReadsPlain or 0,
            guildReadsNoGuild = counters.guildReadsNoGuild or 0,
            guildReadsWithheld = counters.guildReadsWithheld or 0,
            guildReadsUnavailable = counters.guildReadsUnavailable or 0,
            guildLabelsAttached = counters.guildLabelsAttached or 0,
            guildPoolExhausted = counters.guildPoolExhausted or 0,
            guildRefreshes = counters.guildRefreshes or 0,
            barHeightWrites = counters.barHeightWrites or 0,
            barHeightUnchanged = counters.barHeightUnchanged or 0,
            barHeightBaseWithheld = counters.barHeightBaseWithheld or 0,
            barHeightCompareWithheld = counters.barHeightCompareWithheld or 0,
            barHeightRefused = counters.barHeightRefused or 0,
            inScope = inScope,
            outOfScope = outOfScope,
            unreachable = unreachable,
            coloured = coloured,
            verdicts = verdicts,
            standingCapability = Threat.StandingCapability(),
            sweeps = state.sweepCount,
            hookInstalled = state.hookInstalled,
            hookTargets = state.hookTargets,
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
