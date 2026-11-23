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
--
-- Phase 22 (Architecture/20261122-Phase22.md) adds a fourth restyled property: a
-- player's name, red when either of you can attack the other and light orange
-- otherwise. Blizzard rewrites it in CompactUnitFrame_UpdateName on every soft-target
-- change, so it gets a post-hook of its own (section 4.3).
--
-- Patch 03 (Architecture/20261122-Patch03.md): light orange is for a player of the
-- other faction only, and your own faction keeps the game's white (section 3); the
-- bar colours follow the role, DPS, Tank or Auto (section 5).

local ADDON_NAME, ns = ...

local FEATURE_ID = "nameplates"

local format, pcall, pairs = string.format, pcall, pairs

local ClientRead = ns.ClientRead
local PLAIN, ABSENT, WITHHELD = ClientRead.PLAIN, ClientRead.ABSENT, ClientRead.WITHHELD
local bump = ns.Diagnostics.Bump

local Threat = ns.Threat
local VERDICT = Threat.VERDICT

local SCOPE = { IN = "InScope", OUT = "OutOfScope", UNREACHABLE = "Unreachable" }

-- Whether NPC roles can be read this UI load (Architecture/20261104-Patch02.md section
-- 4.6). Off while the setting is off; StoodDown when QuestieDB is missing or unusable,
-- which cannot change before /reload, so no plate asks again.
local ROLE_CAPABILITY = { OFF = "Off", AVAILABLE = "Available", STOOD_DOWN = "StoodDown" }
-- The id the bridge lists under "what is off" when QuestieDB is missing (section 4.4).
local ROLE_CONSUMER = "nameplates.npcRoles"

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
    -- Phase 20 section 7. Off by default, for Phase 15's reason: text on plates.
    npcRoles = false,
    -- Patch 02 section 4.6: decided at enable and whenever npcRoles changes.
    roleCapability = ROLE_CAPABILITY.OFF,
    roleCapabilityReason = nil,
    -- Phase 20 section 8. Off by default: it changes how Blizzard's own plate looks.
    nameAlignLeft = false,
    -- Whether this client lets us set, and see, the name's alignment. Probed once on
    -- the first eligible plate (section 8.4).
    alignCapability = "NotYetProbed",
    -- Phase 22 section 3. Off by default (D7): it changes how Blizzard's own plate looks.
    playerNameColours = false,
    -- Verdict -> { red, green, blue }, from the two colour settings.
    namePalette = {},
    -- Whether this client lets us set, and see, a name's colour (section 4.2).
    nameColourCapability = "NotYetProbed",
    nameHookInstalled = false,
    -- Section 5.2: the plates UNIT_FACTION named this frame. plates holds tracked
    -- records only, and untrackPlate removes its own, so the set is bounded by the
    -- plate count. generation is bumped by disable, which turns a pending flush into
    -- a no-op (C_Timer.After cannot be cancelled).
    factionWork = { plates = {}, all = false, scheduled = false, generation = 0 },
    -- Patch 03 section 5.5: the stored choice, and the role and Auto reading the last
    -- sweep resolved. The attach and the hooks use these, so they make no test read.
    roleChoice = Threat.ROLE_CHOICE.DPS,
    role = Threat.ROLE.DPS,
    auto = Threat.AUTO_READING.NOT_ASKED,
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

-- Phase 22 section 8.2. A stored value that is not six hex digits falls back to the
-- declared default rather than to ConfigSchema.HexToRgb's white, which would look like
-- the feature doing nothing.
local NAME_COLOUR_DEFAULTS = { CanFight = "ff4040", OtherPlayer = "ffc04d" }
local NAME_COLOUR_KEYS = { CanFight = "nameColourCanFight", OtherPlayer = "nameColourOtherPlayer" }

local function colourFromHex(value, fallback)
    local hex = fallback
    if type(value) == "string" and #value == 6 and tonumber(value, 16) then
        hex = value
    end
    local red, green, blue = ns.ConfigSchema.HexToRgb(hex)
    return { red = red, green = green, blue = blue }
end

local function namePaletteFrom(settings)
    local palette = {}
    for verdict, key in pairs(NAME_COLOUR_KEYS) do
        palette[verdict] = colourFromHex(settings and settings[key], NAME_COLOUR_DEFAULTS[verdict])
    end
    return palette
end

local function readSettings(config)
    local settings = config and config.settings
    if not settings then
        return
    end
    state.sweepInterval = settings.sweepInterval or state.sweepInterval
    state.barHeightFraction = settings.barHeightFraction or state.barHeightFraction
    state.guildNames = (settings.guildNames == true)
    state.guildFontSize = settings.guildFontSize or state.guildFontSize
    state.npcRoles = (settings.npcRoles == true)
    state.nameAlignLeft = (settings.nameAlignLeft == true)
    state.playerNameColours = (settings.playerNameColours == true)
    state.namePalette = namePaletteFrom(settings)
    state.colouringWanted = (settings.aggroColouring ~= false)
    state.yieldSelectedTarget = (settings.yieldSelectedTarget == true)
    state.palette = Threat.PaletteFrom(settings)
    state.roleChoice = Threat.RoleChoiceFrom(settings)
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
    -- Phase 20 section 8.2. Blizzard's own name font string, which the alignment
    -- setting writes one property of and never anchors.
    local nameRegion = unitFrame.name
    return unitFrame, healthBar, container, nameRegion
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
    return Threat.ResolveVerdict(aggro, Threat.Disposition(unitToken, counters), state.role)
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
--
-- PHASE 20 (Architecture/20261021-Phase20.md section 7): the same slot carries an NPC's
-- role -- <Innkeeper>, <Weapon Merchant> -- from QuestieDB's subName. A player has a
-- guild and an NPC a role, so a plate carries at most one label. The decision is made
-- per plate by wantedLabel, never per source: before it, a PLAYER_GUILD_UPDATE
-- anywhere in view would have released every NPC's role.

local GUILD_READING = {
    PLAIN = "Plain",
    NO_GUILD = "NoGuild",
    WITHHELD = "Withheld",
    UNAVAILABLE = "Unavailable",
}

local LABEL_SOURCE = { GUILD = "Guild", ROLE = "Role" }

-- The guild name for one unit already known to be a player. UnitIsPlayer is asked by
-- wantedLabel, once per plate, before this: two thirds of the plates in a city have
-- no guild and six in ten of those are NPCs, and it is the cheaper question
-- (Phase 15 section 3.3).
local function readGuild(unitToken)
    local fn = _G.GetGuildInfo
    if type(fn) ~= "function" then
        return GUILD_READING.UNAVAILABLE, "GetGuildInfo is missing from this client"
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
        -- Phase 20: one pool for guild and role labels alike (section 7.6).
        poolName = "plateLabels",
        capacity = ns.PLATE_LABEL_POOL_CAPACITY,
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

-- Phase 18 section 2. SetTextHeight changes the height and nothing else, so there
-- is no outline in it to turn on: the flag lives in SetFont's third argument,
-- which means the font's FILE has to be supplied along with it. The file comes
-- from GetFont, whose fontFile is documented Nilable, and SetFont requires a valid
-- font asset -- so a nil file is never passed on.
--
-- SetFont REPORTS REFUSAL BY RETURN VALUE (success: bool) rather than by raising,
-- and carries SecretArguments = "AllowedWhenUntainted", so it can refuse when our
-- execution is tainted. Reading "did not raise" as success is how a silently
-- unstyled label would be reported as outlined, which is the same defect shape as
-- the cache in Core/QuestieDBBridge.lua: a non-answer read as an answer.
--
-- The two calls go to two different objects. The pool hands out a Frame carrying
-- the height, with its font string at frame.text carrying the font.
local function styleGuildLabel(label)
    local points = state.guildFontSize
    -- The size first, and unconditionally: the label is readable whether or not
    -- the outline lands.
    label:SetHeight(points + 2)
    label.text:SetTextHeight(points)

    local fontKind, fontFile = ClientRead.Call(label.text.GetFont, "string", label.text)
    if fontKind ~= ClientRead.PLAIN or fontFile == nil then
        bump(state.counters, "guildOutlineFallbacks")
        ns.Log.Once("plates:guildoutline", format(
            "the guild label's font file could not be read (%s), so the name is drawn without an outline",
            tostring(fontKind)))
        return
    end

    local ok, applied = pcall(label.text.SetFont, label.text,
        fontFile, points, ns.GUILD_LABEL_OUTLINE_FLAG)
    if not ok or applied ~= true then
        bump(state.counters, "guildOutlineFallbacks")
        ns.Log.Once("plates:guildoutline", format(
            "this client would not set an outline on the guild label (%s), so the name is drawn without one",
            ok and "SetFont returned false" or "SetFont raised"))
        return
    end
    bump(state.counters, "guildOutlined")
end

-- Kept as the old name so every existing call site reads the same. Styling lives
-- in the sizing path deliberately: it runs on every attach and on every font-size
-- change, so a one-off refusal is retried the next time the label is used rather
-- than leaving that plate plain for the session.
local sizeGuildLabel = styleGuildLabel

-- The plate's one label released, and every field that described it cleared.
local function releasePlateLabel(plate)
    if plate.label then
        ns.FramePool.Release(state.guildPool, plate.label)
        plate.label = nil
    end
    plate.guild = nil
    plate.role = nil
    plate.labelSource = nil
end

-- Puts our label under one plate's health bar with the given text. Guild or role,
-- the frame, size, outline, fade, anchor and gap are Phase 15's, unchanged.
local function attachPlateLabel(plate, text, source)
    if not plate.container then
        return false
    end
    if not plate.label then
        local label, poolError = ns.FramePool.Acquire(ensureGuildPool())
        if not label then
            bump(state.counters, "guildPoolExhausted")
            ns.Log.OnceError("plates:guildpool", format(
                "the nameplate label pool was exhausted (%s); the cap is wrong",
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
    -- Player-chosen or third-party text, so every pipe is doubled before it reaches
    -- the font string: that is what makes the escape codes inert. A guild name is
    -- the server's word for a player's choice; a role is QuestieDB's, whose
    -- RegisterCorrection any addon can call (section 7.6).
    label.text:SetText(ns.EscapeGuard.Neutralize(text))
    label:Show()
    if source == LABEL_SOURCE.ROLE then
        bump(state.counters, "roleLabelsAttached")
    else
        bump(state.counters, "guildLabelsAttached")
    end
    return true
end

-- The role half of wantedLabel, for a unit already known not to be a player
-- (section 7.2). Friendly is the client's own answer for the character playing now --
-- the test Blizzard gives a plate its friendly options by -- so the same code serves
-- Alliance and Horde, and nothing here knows a faction.
local function wantedRole(unitToken)
    -- Patch 02 section 4.6: a missing provider cannot appear before /reload, so a
    -- stood-down capability answers every plate here, without a single read.
    if state.roleCapability ~= ROLE_CAPABILITY.AVAILABLE then
        return nil
    end
    local friendKind, friendly = ClientRead.Call(_G.UnitIsFriend, "boolean", "player", unitToken)
    if friendKind == WITHHELD then
        bump(state.counters, "roleReadsWithheld")
        return nil
    end
    if friendly ~= true then
        bump(state.counters, "roleSkippedNotFriendly")
        return nil
    end

    local reading, npcId = ns.UnitIdentity.NpcIdFor(unitToken)
    if reading == ns.UnitIdentity.READING.WITHHELD then
        bump(state.counters, "roleReadsWithheld")
        return nil
    end
    if reading ~= ns.UnitIdentity.READING.RESOLVED then
        -- A pet, a player-controlled vehicle, or a GUID with no id: no role to have.
        return nil
    end

    local Bridge = ns.QuestieDBBridge
    local roleReading, text = Bridge.NpcRole(npcId)
    if roleReading == Bridge.ROLE.PLAIN then
        bump(state.counters, "roleReadsPlain")
        return LABEL_SOURCE.ROLE, text
    end
    if roleReading == Bridge.ROLE.NO_ROLE then
        bump(state.counters, "roleReadsNone")
        return nil
    end
    -- Patch 02 section 4.6: the provider is there -- the capability says so -- but this
    -- one NPC's read did not answer, a raising getter say. No label, nothing cached
    -- (the bridge's rule), and no chat line: the bridge counts readFailed as well.
    bump(state.counters, "roleReadsFailed")
    return nil
end

-- Whether NPC roles can be read this UI load (Patch 02 section 4.6). Off while the
-- setting is off, and then QuestieDB is not asked at all (audit finding 8). Otherwise
-- the bridge's answer, through Require, which prints the one QuestieDB line if it is
-- missing. Called from enable and whenever npcRoles changes; StoodDown is counted once
-- per transition into it.
local function resolveRoleCapability()
    if not state.npcRoles then
        state.roleCapability, state.roleCapabilityReason = ROLE_CAPABILITY.OFF, nil
        return state.roleCapability
    end
    local Bridge = ns.QuestieDBBridge
    if Bridge.Require(ROLE_CONSUMER) == Bridge.STATE.AVAILABLE then
        state.roleCapability, state.roleCapabilityReason = ROLE_CAPABILITY.AVAILABLE, nil
        return state.roleCapability
    end
    if state.roleCapability ~= ROLE_CAPABILITY.STOOD_DOWN then
        bump(state.counters, "roleCapabilityStoodDown")
    end
    state.roleCapability, state.roleCapabilityReason = ROLE_CAPABILITY.STOOD_DOWN, Bridge.Describe()
    return state.roleCapability
end

-- What label one plate should carry (section 7.3, audit finding 12). Returns the
-- source and the text, or nil. Nothing is read when both toggles are off (Phase 15's
-- "no label, no read"). UnitIsPlayer is read once; a withheld answer is counted for
-- each toggle that is on and asks nothing more; an NPC counts as "no guild" while
-- guild names are on, exactly as Phase 15 counted it, and is never asked its guild.
local function wantedLabel(plate)
    local guildOn, rolesOn = state.guildNames, state.npcRoles
    local unitToken = plate.unitToken
    if not (guildOn or rolesOn) or not unitToken then
        return nil
    end

    local playerKind, isPlayer = ClientRead.Call(_G.UnitIsPlayer, "boolean", unitToken)
    if playerKind == WITHHELD then
        -- "Could not tell whether this is a player" is not grounds for asking about
        -- its guild, nor its role.
        if guildOn then
            countGuildReading(GUILD_READING.WITHHELD)
        end
        if rolesOn then
            bump(state.counters, "roleReadsWithheld")
        end
        return nil
    end

    if playerKind == PLAIN and isPlayer == true then
        if not guildOn then
            return nil
        end
        local reading, value = readGuild(unitToken)
        countGuildReading(reading)
        if reading == GUILD_READING.UNAVAILABLE then
            ns.Log.Once("plates:noguildapi", format(
                "%s, so guild names cannot be shown", tostring(value)))
            return nil
        end
        if reading ~= GUILD_READING.PLAIN then
            return nil
        end
        return LABEL_SOURCE.GUILD, value
    end

    if guildOn then
        countGuildReading(GUILD_READING.NO_GUILD)
    end
    if not rolesOn then
        return nil
    end
    return wantedRole(unitToken)
end

-- Brings one plate's label to what wantedLabel says now. The one place either kind
-- of label is decided, so attach, refresh and the toggles cannot drift apart.
local function applyPlateLabel(plate)
    local source, text = wantedLabel(plate)
    if not source then
        releasePlateLabel(plate)
        return
    end
    if plate.labelSource == source and plate.label
        and ((source == LABEL_SOURCE.GUILD and plate.guild == text)
            or (source == LABEL_SOURCE.ROLE and plate.role == text)) then
        return
    end
    plate.labelSource = source
    if source == LABEL_SOURCE.GUILD then
        plate.guild, plate.role = text, nil
    else
        plate.role, plate.guild = text, nil
    end
    attachPlateLabel(plate, text, source)
end

-- PLAYER_GUILD_UPDATE: a player can join, leave or be kicked from a guild while
-- their plate is on screen, so a label read only at attach would go stale. The
-- event names a unit, but as a UnitTokenVariant that need not be the nameplateN
-- token our records are keyed by, and matching it would cost a read per plate
-- anyway, so every tracked plate is re-read. Bounded by the plate cap. A role comes
-- from the bridge's cache, so for an NPC this is a table lookup.
local function refreshPlateLabels()
    bump(state.counters, "guildRefreshes")
    if not (state.guildNames or state.npcRoles) then
        return 0
    end
    local touched = 0
    for _, plate in pairs(state.plates) do
        applyPlateLabel(plate)
        touched = touched + 1
    end
    return touched
end

local function releaseAllPlateLabels()
    if not state.guildPool then
        return
    end
    for _, plate in pairs(state.plates) do
        releasePlateLabel(plate)
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

-- Name alignment (Phase 20 section 8) -----------------------------------------
--
-- On the Thin and Cast Focus styles Blizzard lays the name out ABOVE the bar,
-- anchored from the bar's left end to its right end, and Camelot centres it
-- (nameJustificationWhenAboveHealthBar = "CENTER"). So "the name at the left end of
-- the bar" is one property -- SetJustifyH("LEFT") -- and no anchor is touched. Phase
-- 2 section 4.7's restriction is on anchoring (GetPoint is SecretWhenAnchoringSecret);
-- justification is not anchoring, but it has never been tried on a nameplate name,
-- so the first eligible plate is PROBED: written, read back, and the verdict kept.
--
-- UpdateAnchors rewrites the alignment on every layout pass, so like the bar colour
-- and the container height the value has two writers and is re-asserted -- from
-- trackPlate, from the existing post-hooks, from every sweep, and when the setting
-- turns on. No hook is added. No Blizzard code reads the name's justification back,
-- so nothing of ours reaches Blizzard's execution through it.

local ALIGN_CAPABILITY = {
    NOT_YET_PROBED = "NotYetProbed",
    VERIFIED = "Verified",
    REFUSED = "Refused",
    UNVERIFIABLE = "Unverifiable",
}

local ALIGN_SKIP = {
    STYLE_NOT_ABOVE = "StyleNotAbove",
    STYLE_UNREADABLE = "StyleUnreadable",
    NAME_ONLY = "NameOnly",
    NO_NAME_REGION = "NoNameRegion",
}

-- Each skip lands on one counter (audit finding 16). Off and CapabilityDown are
-- checked before any per-plate work and counted nowhere.
local ALIGN_SKIP_COUNTER = {
    StyleNotAbove = "nameAlignSkippedStyle",
    StyleUnreadable = "nameAlignSkippedStyle",
    NameOnly = "nameAlignSkippedNameOnly",
    NoNameRegion = "nameAlignSkippedNoRegion",
}

-- Where Blizzard lays plate names out for the current Style (Phase 22 section 3.4).
-- One read serves alignment and player name colours, made only by a caller that
-- wants it, so with both off nothing here is read (audit finding 5).
local ANCHOR = {
    ABOVE_SPANNING = "AboveSpanning",
    ABOVE_CENTRED = "AboveCentred",
    INSIDE_BAR = "InsideBar",
    UNREADABLE = "Unreadable",
}

-- The style is compared with whichever of the three constants read: one that does not
-- is skipped, never fatal. Camelot never uses CenteredAboveHealthBar, and no premise
-- pins it (audit finding 4). Unreadable when the style or the table does not read, or
-- the style matches nothing readable. Both fields change only with the Style.
local function readNameAnchor()
    local styleKind, style = ClientRead.Field(_G.NamePlateSetupOptions, "unitNameAnchorStyle", "number")
    if styleKind ~= PLAIN then
        return ANCHOR.UNREADABLE
    end
    local stylesKind, styles = ClientRead.Field(_G.NamePlateConstants, "NAME_ANCHOR_STYLES", "table")
    if stylesKind ~= PLAIN then
        return ANCHOR.UNREADABLE
    end
    local aboveKind, above = ClientRead.Field(styles, "AboveHealthBar", "number")
    if aboveKind == PLAIN and style == above then
        return ANCHOR.ABOVE_SPANNING
    end
    local insideKind, inside = ClientRead.Field(styles, "InsideHealthBar", "number")
    if insideKind == PLAIN and style == inside then
        return ANCHOR.INSIDE_BAR
    end
    local centredKind, centred = ClientRead.Field(styles, "CenteredAboveHealthBar", "number")
    if centredKind == PLAIN and style == centred then
        return ANCHOR.ABOVE_CENTRED
    end
    return ANCHOR.UNREADABLE
end

-- Phase 20's answer for alignment, from the one read: true above the bar, spanning
-- it; false for any other style; nil when unreadable. Both skips it can lead to land
-- on one counter, so alignment's outcomes do not change.
local function styleAboveFrom(anchor)
    if anchor == nil or anchor == ANCHOR.UNREADABLE then
        return nil
    end
    return anchor == ANCHOR.ABOVE_SPANNING
end

-- Why a plate is not eligible, or nil when it is (section 8.2). showOnlyName is
-- provisional while Blizzard's OnUnitSet runs (audit finding 14): a plate judged
-- eligible from a hook during attach is healed by the next pass that sees it final.
local function alignIneligibility(plate, styleAbove)
    if styleAbove == nil then
        return ALIGN_SKIP.STYLE_UNREADABLE
    end
    if not styleAbove then
        return ALIGN_SKIP.STYLE_NOT_ABOVE
    end
    if not plate.nameRegion then
        return ALIGN_SKIP.NO_NAME_REGION
    end
    local onlyKind, onlyName = ClientRead.Field(plate.unitFrame, "showOnlyName", "boolean")
    if onlyKind == WITHHELD or (onlyKind == PLAIN and onlyName == true) then
        return ALIGN_SKIP.NAME_ONLY
    end
    return nil
end

local function noteAlignCapability(verdict)
    state.alignCapability = verdict
    -- A counter NAME, not a string value: Diagnostics rejects a non-number counter
    -- and would discard the whole saved log (section 11).
    bump(state.counters, "nameAlignCapability" .. verdict)
end

-- The first eligible plate: write, read back, keep the verdict (section 8.4). At most
-- three calls, so at most one complaint line whatever the client does.
local function probeNameAlignment(plate)
    local region = plate.nameRegion
    local firstKind, original = ClientRead.Call(region.GetJustifyH, "string", region)
    if firstKind ~= PLAIN then
        noteAlignCapability(ALIGN_CAPABILITY.UNVERIFIABLE)
        ns.Log.Once("plates:alignunverifiable",
            "this client will not show a nameplate name's alignment, so the left-align setting cannot tell whether it worked and stays off")
        return ALIGN_CAPABILITY.UNVERIFIABLE
    end
    local wrote = pcall(region.SetJustifyH, region, ns.NAME_ALIGN_JUSTIFY)
    local backKind, back = ClientRead.Call(region.GetJustifyH, "string", region)
    if wrote and backKind == PLAIN and back == ns.NAME_ALIGN_JUSTIFY then
        noteAlignCapability(ALIGN_CAPABILITY.VERIFIED)
        plate.nameAligned = true
        if original ~= ns.NAME_ALIGN_JUSTIFY then
            bump(state.counters, "nameAlignWrites")
        end
        return ALIGN_CAPABILITY.VERIFIED
    end
    pcall(region.SetJustifyH, region, original)
    noteAlignCapability(ALIGN_CAPABILITY.REFUSED)
    ns.Log.Once("plates:alignrefused",
        "this client did not keep a nameplate name's alignment, so the left-align setting stays off")
    return ALIGN_CAPABILITY.REFUSED
end

-- Keeps one eligible plate's name at the left end of its bar. Read before write: it
-- is what tells a refused write from an accepted one. A write that raises stands the
-- setting down rather than being retried four times a second.
local function reassertNameAlignment(plate)
    local region = plate.nameRegion
    local kind, current = ClientRead.Call(region.GetJustifyH, "string", region)
    if kind == PLAIN and current == ns.NAME_ALIGN_JUSTIFY then
        plate.nameAligned = true
        bump(state.counters, "nameAlignUnchanged")
        return
    end
    if not pcall(region.SetJustifyH, region, ns.NAME_ALIGN_JUSTIFY) then
        bump(state.counters, "nameAlignWriteFailed")
        noteAlignCapability(ALIGN_CAPABILITY.REFUSED)
        ns.Log.Once("plates:alignrefused",
            "this client did not keep a nameplate name's alignment, so the left-align setting stays off")
        return
    end
    plate.nameAligned = true
    bump(state.counters, "nameAlignWrites")
end

-- The one alignment entry point (section 8.3), for trackPlate, the hooks, the sweep
-- and the setting turning on. styleAbove is styleAboveFrom(readNameAnchor()).
local function alignPlateName(plate, styleAbove)
    if not state.nameAlignLeft then
        return
    end
    local verdict = state.alignCapability
    if verdict == ALIGN_CAPABILITY.REFUSED or verdict == ALIGN_CAPABILITY.UNVERIFIABLE then
        return
    end
    local why = alignIneligibility(plate, styleAbove)
    if why then
        -- The layout pass that made it ineligible already rewrote its alignment, so
        -- nothing is written; the mark and the counters converge here.
        plate.nameAligned = false
        bump(state.counters, ALIGN_SKIP_COUNTER[why])
        return
    end
    if verdict == ALIGN_CAPABILITY.NOT_YET_PROBED then
        probeNameAlignment(plate)
        return
    end
    reassertNameAlignment(plate)
end

-- Every tracked plate, outside the colour sweep's SCOPE.IN filter: a friendly plate's
-- name is as much the user's as an enemy's (Phase 19's lesson). anchor is the sweep's
-- one read for the pass; the setting turning on reads its own.
local function alignAllPlateNames(anchor)
    if not state.nameAlignLeft then
        return
    end
    local styleAbove = styleAboveFrom(anchor or readNameAnchor())
    for _, plate in pairs(state.plates) do
        alignPlateName(plate, styleAbove)
    end
end

-- Hands every aligned name back to Blizzard's own alignment (section 8.5). That option
-- is the original by construction: it is what UpdateAnchors writes on an eligible
-- plate. When it does not read, nothing is written and Blizzard's next layout pass
-- restores the value. Returns how many were written back.
local function restoreNameAlignment()
    local kind, original = ClientRead.Field(_G.NamePlateSetupOptions,
        "nameJustificationWhenAboveHealthBar", "string")
    local restored = 0
    for _, plate in pairs(state.plates) do
        if plate.nameAligned then
            plate.nameAligned = false
            if kind == PLAIN and plate.nameRegion
                and pcall(plate.nameRegion.SetJustifyH, plate.nameRegion, original) then
                restored = restored + 1
            end
        end
    end
    return restored
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

-- Player name colours (Phase 22) -----------------------------------------------
--
-- Red when either of you can attack the other; light orange for every other player
-- (Architecture/20261122-Phase22.md sections 3-5). NPCs, your own plate and names
-- drawn inside the bar (Large, Block) are left to Blizzard, as is a friendly player
-- while Blizzard's class-colour option is on (D10). Patch 03 section 3: light orange
-- only for the other faction; your own faction's players are left to the game's white.
--
-- Two fields per plate, and they are different facts (audit findings 1 and 2):
-- nameDecision is what the last decision answered, for the counters and the view;
-- namePainted is the verdict whose colour is on the name now, held only while a
-- NameColour ledger record is. The hook re-asserts namePainted, never a bare decision,
-- so a write that did not land can never send it after a record that does not exist.

local NAME_CAPABILITY = {
    NOT_YET_PROBED = "NotYetProbed",
    VERIFIED = "Verified",
    REFUSED = "Refused",
    UNVERIFIABLE = "Unverifiable",
}

local IDENTITY = { PLAYER = "Player", YOU = "You", NOT_A_PLAYER = "NotAPlayer", UNREADABLE = "Unreadable" }

local NAME_VERDICT = { CAN_FIGHT = "CanFight", OTHER_PLAYER = "OtherPlayer" }

-- Every decision is one string, a verdict or one of these reasons, so deciding
-- allocates nothing and its counter is "nameColourDecidedTo" .. decision.
local NAME_SKIP = {
    NOT_PLAYER = "NotPlayer",
    YOURSELF = "Yourself",
    PLAYER_UNREADABLE = "PlayerUnreadable",
    NO_NAME_REGION = "NoNameRegion",
    INSIDE_BAR = "InsideBar",
    STYLE_UNREADABLE = "StyleUnreadable",
    ATTACK_UNREADABLE = "AttackUnreadable",
    CLASS_COLOUR_WINS = "ClassColourWins",
    CLASS_COLOUR_UNREADABLE = "ClassColourUnreadable",
    -- Patch 03 section 3.3.
    SAME_FACTION = "SameFaction",
    FACTION_UNREADABLE = "FactionUnreadable",
}

local NAME_OUTCOME = {
    PAINTED = "Painted",
    UNCHANGED = "Unchanged",
    RELEASED = "Released",
    LEFT_ALONE = "LeftAlone",
    REFUSED = "Refused",
    UNREADABLE = "Unreadable",
}

-- Every Blizzard write of a plate name's colour is in this function (premises
-- 100-102), so its post-hook corrects the name in the same call (section 4.3).
local NAME_HOOK_TARGET = "CompactUnitFrame_UpdateName"

local function isPaint(decision)
    return decision == NAME_VERDICT.CAN_FIGHT or decision == NAME_VERDICT.OTHER_PLAYER
end

local function nameColourOf(verdict)
    return state.namePalette[verdict] or colourFromHex(nil, NAME_COLOUR_DEFAULTS[verdict])
end

-- On, and not stood down. Every name path checks this before it reads anything
-- (audit findings 2c, 6 and 7).
local function nameColoursActive()
    if not state.playerNameColours then
        return false
    end
    local verdict = state.nameColourCapability
    return verdict == NAME_CAPABILITY.NOT_YET_PROBED or verdict == NAME_CAPABILITY.VERIFIED
end

-- Whether a plate shows a player, and whether that player is you (section 3.2).
-- Asked once per occupancy: a unit does not stop being a player, or you, while its
-- plate is up. A Plain answer is kept; a Withheld one is asked again next pass. A
-- Withheld self comparison counts as "not you" for this pass only: the personal
-- display hides its name, so a wrong paint there is never seen.
local function resolvePlayerIdentity(plate)
    if plate.identity then
        return plate.identity
    end
    local playerKind, isPlayer = ClientRead.Call(_G.UnitIsPlayer, "boolean", plate.unitToken)
    if playerKind == WITHHELD then
        bump(state.counters, "nameColourPlayerWithheld")
        return IDENTITY.UNREADABLE
    end
    if not (playerKind == PLAIN and isPlayer == true) then
        plate.identity = IDENTITY.NOT_A_PLAYER
        return plate.identity
    end
    local youKind, isYou = ClientRead.Call(UnitIsUnit, "boolean", plate.unitToken, "player")
    if youKind == PLAIN and isYou == true then
        plate.identity = IDENTITY.YOU
        return plate.identity
    end
    if youKind == WITHHELD then
        return IDENTITY.PLAYER
    end
    plate.identity = IDENTITY.PLAYER
    return plate.identity
end

-- Why a player's name may not be coloured on this plate, or nil when it may (D9).
-- Inside the bar a light orange name has no contrast; a name-only plate has no bar
-- behind its name, so it is eligible on every style. showOnlyName is read only when
-- the style puts names inside the bar or is unreadable.
local function nameIneligibility(plate, anchor)
    if not plate.nameRegion then
        return NAME_SKIP.NO_NAME_REGION
    end
    if anchor == ANCHOR.ABOVE_SPANNING or anchor == ANCHOR.ABOVE_CENTRED then
        return nil
    end
    local onlyKind, onlyName = ClientRead.Field(plate.unitFrame, "showOnlyName", "boolean")
    if onlyKind == PLAIN and onlyName == true then
        return nil
    end
    if anchor == ANCHOR.INSIDE_BAR then
        return NAME_SKIP.INSIDE_BAR
    end
    return NAME_SKIP.STYLE_UNREADABLE
end

-- A plate's faction, read once per occupancy (Patch 03 section 3.2): a unit cannot
-- change faction while its plate is up. A Plain, non-empty tag is kept on the record,
-- which is rebuilt on every attach; anything else is counted and asked again.
local function resolvePlateFaction(plate)
    if plate.faction then
        return plate.faction
    end
    local kind, tag = ClientRead.Call(_G.UnitFactionGroup, "string", plate.unitToken)
    if kind == PLAIN and tag ~= "" then
        plate.faction = tag
        return tag
    end
    bump(state.counters, "nameColourFactionUnread")
    return nil
end

-- Your own faction, once per batch: an attach, a pass, a faction flush or a settings
-- change, beside that batch's one anchor read (Patch 03 section 3.4). Not cached
-- across batches, so it needs no invalidation rule. false when it does not read.
local function readYourFaction()
    local kind, tag = ClientRead.Call(_G.UnitFactionGroup, "string", "player")
    if kind == PLAIN and tag ~= "" then
        return tag
    end
    bump(state.counters, "nameColourFactionUnread")
    return false
end

-- What one plate's name should show now (section 3.5). Red when either of you can
-- attack the other, by the client's own UnitCanAttack asked both ways (D2): that
-- covers the flag, duels, arenas, free-for-all areas and mind control. A Withheld
-- read is never taken as false (rule 10); the name is left to Blizzard, which claims
-- nothing. The class-colour field is read only for a player who would be light
-- orange, because red outranks Blizzard's decoration.
--
-- Patch 03 section 3.3: after the attack reads, the faction. Red comes first (D2), so a
-- duel with your own faction is still red. Your own faction is left to the game's
-- white (D1); a faction that does not read is left too, never taken as either.
local function decideNameColour(plate, anchor, yourFaction)
    local identity = resolvePlayerIdentity(plate)
    if identity == IDENTITY.UNREADABLE then
        return NAME_SKIP.PLAYER_UNREADABLE
    end
    if identity == IDENTITY.NOT_A_PLAYER then
        return NAME_SKIP.NOT_PLAYER
    end
    if identity == IDENTITY.YOU then
        return NAME_SKIP.YOURSELF
    end
    local ineligible = nameIneligibility(plate, anchor)
    if ineligible then
        return ineligible
    end
    local token = plate.unitToken
    local youKind, youAttack = ClientRead.Call(UnitCanAttack, "boolean", "player", token)
    local theyKind, theyAttack = ClientRead.Call(UnitCanAttack, "boolean", token, "player")
    if (youKind == PLAIN and youAttack == true) or (theyKind == PLAIN and theyAttack == true) then
        return NAME_VERDICT.CAN_FIGHT
    end
    if youKind == WITHHELD or theyKind == WITHHELD then
        bump(state.counters, "nameColourAttackWithheld")
        return NAME_SKIP.ATTACK_UNREADABLE
    end
    local theirFaction = resolvePlateFaction(plate)
    if not yourFaction or not theirFaction then
        return NAME_SKIP.FACTION_UNREADABLE
    end
    if theirFaction == yourFaction then
        return NAME_SKIP.SAME_FACTION
    end
    local classKind, byClass = ClientRead.Field(plate.unitFrame, "colorNameWithClassColor", "boolean")
    if classKind == WITHHELD then
        return NAME_SKIP.CLASS_COLOUR_UNREADABLE
    end
    if classKind == PLAIN and byClass == true then
        return NAME_SKIP.CLASS_COLOUR_WINS
    end
    return NAME_VERDICT.OTHER_PLAYER
end

-- Hands one plate's name back: its record restored and dropped, namePainted cleared.
-- Returns whether a record was held.
local function releaseNameColour(plate)
    plate.namePainted = nil
    local region = plate.nameRegion
    if not (state.ledger and region and ns.StyleLedger.HasRecord(state.ledger, region, "NameColour")) then
        return false
    end
    ns.StyleLedger.RestoreProperty(state.ledger, region, "NameColour")
    bump(state.counters, "nameColourReleased")
    return true
end

-- Every tracked plate's name back to Blizzard (section 4.5): on turning off, on
-- disable, and on a stand-down. The original is the colour read before our first
-- write, so Blizzard's next CompactUnitFrame_UpdateName is what makes it exact.
local function restoreNameColours()
    local restored = 0
    for _, plate in pairs(state.plates) do
        if releaseNameColour(plate) then
            restored = restored + 1
        end
        plate.nameDecision = nil
    end
    return restored
end

local NAME_CAPABILITY_LINE = {
    Refused = "this client did not keep a nameplate name's colour, so player name colours stay off until /reload",
    Unverifiable = "this client will not show a nameplate name's colour, so player name colours cannot tell whether they worked and stay off until /reload",
}

-- Records a capability verdict (section 4.5). Refused and Unverifiable stand the
-- setting down: one line, said once per verdict, and every painted name restored at
-- once, so no record outlives the stand-down (audit finding 7). Only disable or
-- /reload lifts it; turning the setting off and on does not.
local function noteNameCapability(verdict)
    state.nameColourCapability = verdict
    -- A counter NAME, not a string value: Diagnostics rejects a non-number counter
    -- (Phase 20 section 11).
    bump(state.counters, "nameColourCapability" .. verdict)
    local line = NAME_CAPABILITY_LINE[verdict]
    if line then
        ns.Log.Once("plates:namecolour" .. verdict, line)
        restoreNameColours()
    end
end

-- Keeps a painted name painted, or moves it to another verdict's colour (section
-- 4.3). The target comes from verdict, never from nameDecision (audit finding 2a).
-- An unreadable name is not written: a write we cannot check is a contest we cannot
-- see. NOT_RECORDED is told apart from a refused write, so a lost record can never
-- stand the setting down (audit finding 1). O(1).
local function reassertNameColour(plate, verdict)
    local region = plate.nameRegion
    local colour = nameColourOf(verdict)
    local kind, current = ns.StyleLedger.Reads(state.ledger, region, "NameColour")
    if kind ~= PLAIN then
        bump(state.counters, "nameColourReadsWithheld")
        return NAME_OUTCOME.UNREADABLE
    end
    if coloursMatch(current, colour) then
        plate.namePainted = verdict
        bump(state.counters, "nameColourUnchanged")
        return NAME_OUTCOME.UNCHANGED
    end
    local ok, reason = ns.StyleLedger.Reapply(state.ledger, region, "NameColour", colour)
    if ok then
        plate.namePainted = verdict
        bump(state.counters, "nameColourWrites")
        return NAME_OUTCOME.PAINTED
    end
    if reason == "NOT_RECORDED" then
        plate.namePainted = nil
        return NAME_OUTCOME.LEFT_ALONE
    end
    bump(state.counters, "nameColourWriteFailed")
    return NAME_OUTCOME.REFUSED
end

-- Whether this client lets us set a plate name's colour, and lets us see it (section
-- 4.2). Apply's own read of the original is the probe's first read, so at most two
-- reads and two writes (audit finding 3). Returns the verdict for the caller to note.
local function probeNameColour(plate, verdict)
    local region = plate.nameRegion
    local colour = nameColourOf(verdict)
    local ok, reason = ns.StyleLedger.Apply(state.ledger, region, "NameColour", colour)
    if not ok then
        if reason == "WRITE_REFUSED" then
            bump(state.counters, "nameColourWriteFailed")
            return NAME_CAPABILITY.REFUSED
        end
        return NAME_CAPABILITY.UNVERIFIABLE
    end
    bump(state.counters, "nameColourWrites")
    local kind, current = ns.StyleLedger.Reads(state.ledger, region, "NameColour")
    if kind == PLAIN and coloursMatch(current, colour) then
        plate.namePainted = verdict
        return NAME_CAPABILITY.VERIFIED
    end
    ns.StyleLedger.RestoreProperty(state.ledger, region, "NameColour")
    if kind == PLAIN then
        return NAME_CAPABILITY.REFUSED
    end
    return NAME_CAPABILITY.UNVERIFIABLE
end

-- Brings one plate's name to its decision (section 4.4). Does nothing, and reads
-- nothing, unless colours are active (audit finding 2c). Only an outcome that leaves
-- a record held sets namePainted: Painted, or Unchanged.
local function applyNameColour(plate, decision)
    if not nameColoursActive() then
        return NAME_OUTCOME.LEFT_ALONE
    end
    if plate.nameDecision ~= decision then
        plate.nameDecision = decision
        bump(state.counters, "nameColourDecidedTo" .. decision)
    end
    if not isPaint(decision) then
        if releaseNameColour(plate) then
            return NAME_OUTCOME.RELEASED
        end
        return NAME_OUTCOME.LEFT_ALONE
    end

    if state.nameColourCapability == NAME_CAPABILITY.NOT_YET_PROBED then
        local verdict = probeNameColour(plate, decision)
        noteNameCapability(verdict)
        if verdict == NAME_CAPABILITY.VERIFIED then
            return NAME_OUTCOME.PAINTED
        end
        if verdict == NAME_CAPABILITY.UNVERIFIABLE then
            return NAME_OUTCOME.UNREADABLE
        end
        return NAME_OUTCOME.REFUSED
    end

    local region = plate.nameRegion
    if ns.StyleLedger.HasRecord(state.ledger, region, "NameColour") then
        local outcome = reassertNameColour(plate, decision)
        if outcome == NAME_OUTCOME.REFUSED then
            noteNameCapability(NAME_CAPABILITY.REFUSED)
        end
        return outcome
    end

    local ok, reason = ns.StyleLedger.Apply(state.ledger, region, "NameColour", nameColourOf(decision))
    if ok then
        plate.namePainted = decision
        bump(state.counters, "nameColourWrites")
        return NAME_OUTCOME.PAINTED
    end
    if reason == "WRITE_REFUSED" then
        bump(state.counters, "nameColourWriteFailed")
        noteNameCapability(NAME_CAPABILITY.REFUSED)
        return NAME_OUTCOME.REFUSED
    end
    -- The original did not read. Not a refusal: nothing written, no record, the
    -- capability kept, and the next pass tries again (audit finding 1).
    bump(state.counters, "nameColourReadsWithheld")
    return NAME_OUTCOME.UNREADABLE
end

-- One plate's decision and paint, for every caller but the hook. yourFaction is the
-- batch's readYourFaction() (Patch 03 section 3.4).
local function colourPlateName(plate, anchor, yourFaction)
    if not nameColoursActive() then
        return NAME_OUTCOME.LEFT_ALONE
    end
    return applyNameColour(plate, decideNameColour(plate, anchor, yourFaction))
end

-- The same, isolated: one plate's fault never stops the others (Phase 9 section 4.6).
-- A faulted name is handed back to Blizzard and tried afresh next pass.
local function colourPlateNameIsolated(plate, anchor, yourFaction)
    local ok, outcome = ns.Isolation.Call(colourPlateName, plate, anchor, yourFaction)
    if ok then
        return outcome
    end
    bump(state.counters, "nameColourFaults")
    pcall(releaseNameColour, plate)
    plate.nameDecision = nil
    ns.Diagnostics.NoteFault(FEATURE_ID, outcome)
    ns.Log.OnceError("plates:namefault",
        "a nameplate's name colour faulted and was handed back to the game's colour; /pa diag shows the message")
    return nil
end

-- Blizzard's name update, followed in the same call (section 4.3). O(1): one table
-- lookup, then at most one read and one write. Raid and party frames pass through
-- here on every health tick and return at the lookup with nothing read, written or
-- flagged. No unit read and no style read: eligibility is the attach's and the
-- sweep's to judge.
local function onNameUpdated(updatedFrame)
    if not state.enabled or not state.playerNameColours
        or state.nameColourCapability ~= NAME_CAPABILITY.VERIFIED then
        return
    end
    local plate = updatedFrame and state.byUnitFrame[updatedFrame]
    if not plate or not plate.namePainted then
        return
    end
    if reassertNameColour(plate, plate.namePainted) == NAME_OUTCOME.REFUSED then
        noteNameCapability(NAME_CAPABILITY.REFUSED)
    end
end

-- Every player plate not waiting for a faction flush (section 5.3). A flush covering
-- every plate skips the whole pass, so a change the sweep finds is one no event
-- announced.
local function colourAllPlayerNames(anchor, yourFaction)
    local work = state.factionWork
    if work.all then
        return
    end
    for _, plate in pairs(state.plates) do
        if plate.identity ~= IDENTITY.NOT_A_PLAYER and not work.plates[plate] then
            local before = plate.nameDecision
            colourPlateNameIsolated(plate, anchor, yourFaction)
            local after = plate.nameDecision
            if before ~= nil and after ~= nil and after ~= before then
                bump(state.counters, "nameColourChangedBySweep")
            end
        end
    end
end

-- Lifecycle -------------------------------------------------------------------

local function untrackPlate(frame)
    local plate = state.plates[frame]
    if not plate then
        return false
    end
    unstylePlate(plate)
    -- Before the record goes, while the label is still reachable: a label left on
    -- a recycled plate would show the previous unit's guild, or role.
    releasePlateLabel(plate)
    -- Phase 20 section 8.5: nothing to write back. The plate's next occupancy runs
    -- Blizzard's UpdateAnchors before anything is drawn.
    plate.nameAligned = false
    -- Phase 22 section 4.5: the name's record goes back with the bar's, before it
    -- drops, so a recycled plate never starts with our colour. unstylePlate stays
    -- bar-only: rescopePlate calls it, and the name colour does not follow that scope.
    releaseNameColour(plate)
    plate.nameDecision = nil
    state.factionWork.plates[plate] = nil
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

    local unitFrame, healthBar, container, nameRegion = resolveParts(frame)
    local plate = {
        frame = frame,
        unitFrame = unitFrame,
        healthBar = healthBar,
        container = container,
        -- Phase 20 section 8.2.
        nameRegion = nameRegion,
        nameAligned = false,
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
    -- every player's plate, friendly or hostile. Phase 20: so does a friendly NPC's
    -- role, and friendly NPCs are SCOPE.OUT by definition.
    applyPlateLabel(plate)
    -- Phase 20 section 8.3, audit finding 14: an attach is judged HERE. Blizzard's
    -- OnUnitSet re-lays the name out after the setup-time hooks have returned, so the
    -- hooks cannot be the attach path; this handler, run after Blizzard's driver, sees
    -- the final layout and showOnlyName decided.
    -- Phase 22 section 3.4 (audit finding 5): one anchor read, made only when alignment
    -- or player name colours want it, and shared by both.
    local coloursOn = nameColoursActive()
    local anchor = (state.nameAlignLeft or coloursOn) and readNameAnchor() or nil
    alignPlateName(plate, styleAboveFrom(anchor))
    -- Phase 22 section 5.1: the attach decides the name, for the reason it judges the
    -- alignment. Before the UNREACHABLE return: such a plate has no name region, and
    -- the decision says so (NoNameRegion).
    if coloursOn then
        colourPlateNameIsolated(plate, anchor, readYourFaction())
    end

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

    -- Phase 20 section 7.5. A unit turning hostile loses its role here, and one
    -- turning friendly gains it.
    applyPlateLabel(plate)
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
    -- Phase 20 section 8.3: outside it for the same reason. A layout pass on an
    -- attached plate reaches here in the same frame as Blizzard's reset.
    -- Phase 22 audit finding 5: the anchor is read only while alignment is on. The
    -- name colour is not re-asserted here; it has its own hook (section 4.3).
    if state.nameAlignLeft then
        alignPlateName(plate, styleAboveFrom(readNameAnchor()))
    end

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

-- UNIT_FACTION, a frame later (Phase 22 section 5.2) ---------------------------
--
-- The handler marks and schedules; this settles the marked plates in our own
-- execution. The rescope and the name step are isolated apart (audit finding 6b): a
-- rescope fault is the bar's and cedes the bar, a name fault is the name's and
-- releases the name, and neither costs the other.

local function settleFactionPlate(plate, anchor, yourFaction)
    local ok, fault = ns.Isolation.Call(rescopePlate, plate)
    if not ok then
        bump(state.counters, "plateFaults")
        cedeFaultedPlate(plate)
        ns.Diagnostics.NoteFault(FEATURE_ID, fault)
        ns.Log.OnceError("plates:fault",
            "a nameplate faulted and was handed back to Blizzard's colour; /pa diag shows the message")
    end
    if anchor then
        colourPlateNameIsolated(plate, anchor, yourFaction)
    end
end

-- A no-op once a disable has moved the generation on, so a flush scheduled before it
-- does nothing (Phase 21 audit finding 8's lesson).
local function flushFactionChanges(generation)
    local work = state.factionWork
    if generation ~= work.generation or not state.enabled then
        return
    end
    local all, named = work.all, work.plates
    work.all, work.plates, work.scheduled = false, {}, false
    bump(state.counters, "factionFlushes")
    if all then
        bump(state.counters, "factionFlushAll")
    end
    -- One anchor read for the whole flush, and none unless colours are active (audit
    -- finding 6a). A stand-down part-way leaves the rest with nothing to do: each
    -- plate's name step checks "active" before it reads.
    local anchor = nameColoursActive() and readNameAnchor() or nil
    -- Patch 03 section 3.4: your faction once per flush, beside the anchor.
    local yourFaction = anchor and readYourFaction() or nil
    if all then
        for _, plate in pairs(state.plates) do
            settleFactionPlate(plate, anchor, yourFaction)
        end
        return
    end
    for plate in pairs(named) do
        if state.plates[plate.frame] == plate then
            settleFactionPlate(plate, anchor, yourFaction)
        end
    end
end

-- Without C_Timer.After the flush runs at once, inside the event, and one line says
-- so: SettingsPanel's trade (Features/SettingsPanel.lua:360-373), because a faction
-- change that never takes effect is worse than one handled inline (audit finding 6c).
-- Deliberately not cached, as there.
local function scheduleFactionFlush()
    local work = state.factionWork
    if work.scheduled then
        return
    end
    work.scheduled = true
    local generation = work.generation
    if not (C_Timer and type(C_Timer.After) == "function") then
        ns.Log.Once("plates:nofactiondefer",
            "this client has no C_Timer.After, so a faction change is handled inside the event rather than a frame later")
        flushFactionChanges(generation)
        return
    end
    C_Timer.After(0, function()
        flushFactionChanges(generation)
    end)
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
    -- Patch 03 section 5.5: the role once per pass, before any plate's verdict, and
    -- only while the bars are coloured. Under Auto this is the pass's one test read.
    if colouringActive() then
        state.role, state.auto = Threat.ResolveRole(state.roleChoice, state.counters)
    end
    -- Phase 22 section 5.3: one anchor read for the pass, and none unless alignment or
    -- player name colours want it.
    local coloursOn = nameColoursActive()
    local anchor = (state.nameAlignLeft or coloursOn) and readNameAnchor() or nil
    -- Phase 20 section 8.3: every plate, outside the scope filter below, for the
    -- paths that re-lay a name out after the hooks have run.
    alignAllPlateNames(anchor)
    -- Phase 22 section 5.3: every player plate, outside the scope filter too. Patch 03
    -- section 3.4: your faction once per pass, beside the anchor.
    if coloursOn then
        colourAllPlayerNames(anchor, readYourFaction())
    end
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

-- Phase 22 section 4.3: one more post-hook, on the function that writes the name's
-- colour, with a body of its own. Running reassertPlate from it would triple a health
-- tick's work: UpdateHealth -> UpdateName -> UpdateHealthColor passes three hooks.
-- Installed at most once, like the others.
local function installNameHook()
    if state.nameHookInstalled or not hooksecurefunc then
        return
    end
    if type(_G[NAME_HOOK_TARGET]) ~= "function" then
        return
    end
    if pcall(hooksecurefunc, NAME_HOOK_TARGET, onNameUpdated) then
        state.nameHookInstalled = true
        state.hookTargets = state.hookTargets and (state.hookTargets .. ", " .. NAME_HOOK_TARGET)
            or NAME_HOOK_TARGET
    end
end

-- Said only while the setting is on, so a user who never turns it on hears nothing.
-- Without the hook the sweep re-asserts every pass, a quarter second behind.
local function noteMissingNameHook()
    if state.playerNameColours and not state.nameHookInstalled then
        ns.Log.Once("plates:nonamehook", format(
            "%s is missing on this client, so a player's name can show the game's colour for up to a quarter second after each update",
            NAME_HOOK_TARGET))
    end
end

-- Signals ---------------------------------------------------------------------

local function onGuildUpdate()
    refreshPlateLabels()
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

-- UNIT_FACTION (Phase 22 section 5.2): mark and schedule, nothing more; the rescope
-- and the name decision run a frame later. "player" names every plate, because your
-- own PvP state changes who is attackable; Blizzard's plate listens for it too
-- (premise 105). A token no tracked plate carries changes nothing.
local function onUnitFaction(unitToken)
    if not unitToken or not state.enabled then
        return
    end
    local work = state.factionWork
    if unitToken == "player" then
        work.all = true
        scheduleFactionFlush()
        return
    end
    for _, plate in pairs(state.plates) do
        if plate.unitToken == unitToken then
            work.plates[plate] = true
            scheduleFactionFlush()
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
      lost = "a unit changing attackability is missed until its plate is replaced, and a player's name colour until the next sweep" },
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
    -- Patch 02 section 4.6. Before any plate is adopted, so the first label decision
    -- is made against the provider as it is, and a missing one is said once, here,
    -- rather than discovered on every friendly plate.
    resolveRoleCapability()

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
    -- Phase 22 section 4.3.
    installNameHook()
    noteMissingNameHook()
    startTicker()

    return true
end

-- Every step is guarded: disable cleans up after a failed enable, which may not
-- have created the ledger or tracked anything.
local function disable()
    state.enabled = false
    -- Phase 22 section 5.2: a flush scheduled before this does nothing.
    local work = state.factionWork
    work.generation = work.generation + 1
    work.plates, work.all, work.scheduled = {}, false, false
    stopTicker()
    stopContesting()

    -- Before the plates are untracked, while their containers are still to hand.
    -- Blizzard would restore these itself on its next layout pass; this only
    -- makes it immediate (section 5.5).
    restoreBarHeights()
    -- Phase 20 section 8.5, for the same reason and at the same moment.
    restoreNameAlignment()
    -- A disable is the cheapest moment to let the probe run again, and the only way
    -- back to an unprobed state inside a UI load.
    state.alignCapability = ALIGN_CAPABILITY.NOT_YET_PROBED
    -- Phase 22 section 4.5, at the same moment and for the same reasons.
    restoreNameColours()
    state.nameColourCapability = NAME_CAPABILITY.NOT_YET_PROBED

    releaseAllPlateLabels()
    -- Patch 02 section 4.6: decided again at the next enable.
    state.roleCapability, state.roleCapabilityReason = ROLE_CAPABILITY.OFF, nil

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

    -- Phase 20 section 7.5: either toggle re-decides every plate's one label, which
    -- leaves the other kind's labels as they were. Patch 02 section 4.6: the roles
    -- toggle decides the capability first, so turning roles on asks QuestieDB once.
    if changedKey == "guildNames" or changedKey == "npcRoles" then
        if changedKey == "npcRoles" then
            resolveRoleCapability()
        end
        for _, plate in pairs(state.plates) do
            applyPlateLabel(plate)
        end
        return ns.CONFIG_RESULT.APPLIED
    end

    -- Phase 22 section 5.1 (audit finding 7). On: while active, every tracked plate at
    -- once, against one anchor read; while stood down, nothing at all. Off: handed back,
    -- with the capability left as it is, so off and on again never re-probes.
    if changedKey == "playerNameColours" then
        if state.playerNameColours then
            noteMissingNameHook()
            if nameColoursActive() then
                local anchor = readNameAnchor()
                local yourFaction = readYourFaction()
                for _, plate in pairs(state.plates) do
                    colourPlateNameIsolated(plate, anchor, yourFaction)
                end
            end
        else
            restoreNameColours()
        end
        return ns.CONFIG_RESULT.APPLIED
    end

    -- A colour changed: while Verified, every painted name repaints in the new colour.
    -- NotYetProbed has painted nothing, and a stand-down holds no record. The first
    -- refusal stops the loop and stands the setting down. Returns before the bar
    -- palette's reset below, which these keys have nothing to do with.
    if changedKey == "nameColourCanFight" or changedKey == "nameColourOtherPlayer" then
        if nameColoursActive() and state.nameColourCapability == NAME_CAPABILITY.VERIFIED then
            for _, plate in pairs(state.plates) do
                if plate.namePainted
                    and reassertNameColour(plate, plate.namePainted) == NAME_OUTCOME.REFUSED then
                    noteNameCapability(NAME_CAPABILITY.REFUSED)
                    break
                end
            end
        end
        return ns.CONFIG_RESULT.APPLIED
    end

    -- Phase 20 section 8.3: on, every tracked plate at once; off, handed back.
    if changedKey == "nameAlignLeft" then
        if state.nameAlignLeft then
            alignAllPlateNames()
        else
            restoreNameAlignment()
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
-- Phase 20: off by default, for Phase 15's reason (section 10.2).
defaultSettings.npcRoles = false
defaultSettings.nameAlignLeft = false
-- Phase 22 section 8.2: off by default (D7), for Phase 20's reason: it changes how
-- Blizzard's own plate looks.
defaultSettings.playerNameColours = false
defaultSettings.nameColourCanFight = NAME_COLOUR_DEFAULTS.CanFight
defaultSettings.nameColourOtherPlayer = NAME_COLOUR_DEFAULTS.OtherPlayer
-- Patch 03 section 6.6 (D30): what the bar colours are for, written by the role box
-- under the skills window and by /pa role. DPS by default (D16).
defaultSettings.threatRole = Threat.ROLE_CHOICE.DPS
-- Phase 19's rarityRings, rarityRingSize and rarityRingOffsetX/Y are gone with the
-- ring (Patch 02 section 5). ConfigStore prunes them from a stored config at
-- hydration, once, because no default claims them any more (section 5.4).

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
            description = "Red: it is attacking you. Orange: you are about to pull it. Grey: tagged by a player outside your group. Green: attacking your group or pet. Yellow: neutral. White: hostile, attacking neither. Tank (the switch beside your bags, or Auto while the game counts you as tanking): green when you hold it, orange when it is about to change hands, red when it is on your group.",
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
        -- Phase 20 section 8. Blizzard's own name, re-aligned; no anchor is moved.
        nameAlignLeft = {
            kind = ns.ConfigSchema.KIND.TOGGLE, label = "Names at the left end of the bar", order = 3,
            description = "Moves each nameplate's name from the middle of the bar to its left end. For the Thin and Cast Focus styles; Large and Block already put the name inside the bar on the left.",
        },
        -- Phase 15. A guild name encodes nothing, unlike the six colours below,
        -- so it gets no colour of its own: one faded white is the right amount
        -- of emphasis for a label.
        guildNames = {
            kind = ns.ConfigSchema.KIND.TOGGLE, label = "Show guild names", order = 4,
            description = "Under the health bar, for every player who has one. Nothing is shown for a player with no guild, or for a monster.",
        },
        -- Phase 20 section 7: the same place, size, outline and fade as a guild name,
        -- with a switch of its own (decision D5).
        npcRoles = {
            kind = ns.ConfigSchema.KIND.TOGGLE, label = "Show NPC roles", order = 5,
            description = "Under the health bar of friendly NPCs, such as Innkeeper or Weapon Merchant, from QuestieDB. Needs QuestieDB and friendly NPC nameplates; nothing is shown in dungeons and raids.",
        },
        guildFontSize = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Guild name and role size", order = 6,
            unit = ns.ConfigSchema.UNIT.PIXELS,
            minimum = ns.GUILD_FONT_MINIMUM, maximum = ns.GUILD_FONT_MAXIMUM, step = 1,
        },
        -- Orders 7 to 10 were Phase 19's ring controls, retired by Patch 02 section 5:
        -- Blizzard's own rarity icon is the setting now (Options > Nameplates).
        -- Phase 22 section 8.2 takes order 7, beside the other name toggles.
        playerNameColours = {
            kind = ns.ConfigSchema.KIND.TOGGLE, label = "Colour player names", order = 7,
            description = "Red: a player who can fight you, or whom you can fight, of either faction. Light orange: a player of the other faction who can't. Your own faction and NPC names stay the game's. Not on the Large and Block styles, where the name sits inside the bar.",
        },
        yieldSelectedTarget = {
            kind = ns.ConfigSchema.KIND.TOGGLE, label = "Leave your target's colour alone", order = 11,
            description = "Stops contesting the bar colour on the unit you have selected. Turn this on if that plate flickers.",
        },
        colourOnPlayer = {
            kind = ns.ConfigSchema.KIND.COLOUR, label = "It is attacking you", order = 12,
            group = "Colours, highest priority first",
            groupDescription = "The threat panel's bars use these colours too.",
        },
        -- R7 (Phase 11 section 3).
        colourAboutToPull = {
            kind = ns.ConfigSchema.KIND.COLOUR, label = "You are about to pull it", order = 13,
            group = "Colours, highest priority first",
            description = "Your threat is above the tank's, and the mob is not on you yet",
        },
        colourTapDenied = {
            kind = ns.ConfigSchema.KIND.COLOUR, label = "Tagged by a player outside your group", order = 14,
            group = "Colours, highest priority first",
        },
        colourOnGroup = {
            kind = ns.ConfigSchema.KIND.COLOUR, label = "It is attacking your group or pet", order = 15,
            group = "Colours, highest priority first",
        },
        colourNeutral = {
            kind = ns.ConfigSchema.KIND.COLOUR, label = "Neutral, and on neither you nor your group", order = 16,
            group = "Colours, highest priority first",
        },
        colourElsewhere = {
            kind = ns.ConfigSchema.KIND.COLOUR, label = "Hostile, and attacking neither", order = 17,
            group = "Colours, highest priority first",
        },
        -- Phase 22 section 8.2. After the threat colours, under a header of their own: a
        -- key with no group does not close the header above it, so an earlier order would
        -- put "Leave your target's colour alone" under this one.
        nameColourCanFight = {
            kind = ns.ConfigSchema.KIND.COLOUR, label = "Can fight you, or you them", order = 18,
            group = "Player names",
            groupDescription = "Used by \"Colour player names\".",
        },
        nameColourOtherPlayer = {
            kind = ns.ConfigSchema.KIND.COLOUR, label = "The other faction", order = 19,
            group = "Player names",
        },
        -- Patch 03 section 6.6: not curated (D17). The settings page draws a Choice only
        -- when it has two values, and this one has three; the role box and /pa role set it.
        threatRole = {
            kind = ns.ConfigSchema.KIND.CHOICE, label = "Threat colours for", curated = false,
            choices = {
                { value = "Dps", label = "DPS" },
                { value = "Tank", label = "Tank" },
                { value = "Auto", label = "Auto" },
            },
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

    -- Phase 22 section 7.3. The two draw-distance settings as the client reports them,
    -- for /pa plates only: never a sweep, a hook, an event or Inspect. Reads only;
    -- nothing here can write a CVar. Each field is its own read, because
    -- GetCVarInfo's returns differ in type.
    DistanceSettings = function()
        local out = {}
        local reader = C_CVar and C_CVar.GetCVarInfo
        local entries = ns.PLATE_DISTANCE_CVARS or {}
        for index = 1, #entries do
            local entry = entries[index]
            local setting = { name = entry.name, label = entry.label, readable = false }
            local valueKind, value = ClientRead.CallNth(reader, 1, "string", entry.name)
            if valueKind == PLAIN then
                setting.readable = true
                setting.yards = tonumber(value)
                local defaultKind, defaultValue = ClientRead.CallNth(reader, 2, "string", entry.name)
                if defaultKind == PLAIN then
                    setting.defaultYards = tonumber(defaultValue)
                end
                local accountKind, perAccount = ClientRead.CallNth(reader, 3, "boolean", entry.name)
                if accountKind == PLAIN then
                    setting.perAccount = perAccount
                end
                local characterKind, perCharacter = ClientRead.CallNth(reader, 4, "boolean", entry.name)
                if characterKind == PLAIN then
                    setting.perCharacter = perCharacter
                end
                local lockedKind, locked = ClientRead.CallNth(reader, 5, "boolean", entry.name)
                if lockedKind == PLAIN then
                    setting.locked = locked
                end
                local secureKind, secure = ClientRead.CallNth(reader, 6, "boolean", entry.name)
                if secureKind == PLAIN then
                    setting.secure = secure
                end
            end
            out[#out + 1] = setting
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
            -- Plates whose one label shows a guild; roleLabels counts the others.
            guildLabels = (function()
                local count = 0
                for _, plate in pairs(state.plates) do
                    if plate.label and plate.labelSource == LABEL_SOURCE.GUILD then
                        count = count + 1
                    end
                end
                return count
            end)(),
            -- Kept under its Phase 15 name (audit finding 13): one pool for both kinds.
            guildPoolCapacity = ns.PLATE_LABEL_POOL_CAPACITY,
            -- Phase 20 section 11.
            labelPoolCapacity = ns.PLATE_LABEL_POOL_CAPACITY,
            npcRoles = state.npcRoles,
            roleLabels = (function()
                local count = 0
                for _, plate in pairs(state.plates) do
                    if plate.label and plate.labelSource == LABEL_SOURCE.ROLE then
                        count = count + 1
                    end
                end
                return count
            end)(),
            roleReadsPlain = counters.roleReadsPlain or 0,
            roleReadsNone = counters.roleReadsNone or 0,
            roleReadsWithheld = counters.roleReadsWithheld or 0,
            roleSkippedNotFriendly = counters.roleSkippedNotFriendly or 0,
            -- Patch 02 section 4.6: the provider's half is the capability, the per-NPC
            -- half is roleReadsFailed. roleBridgeUnavailable is retired.
            roleReadsFailed = counters.roleReadsFailed or 0,
            roleCapability = state.roleCapability,
            roleCapabilityReason = state.roleCapabilityReason,
            roleCapabilityStoodDown = counters.roleCapabilityStoodDown or 0,
            roleLabelsAttached = counters.roleLabelsAttached or 0,
            roleBridge = ns.QuestieDBBridge.Describe(),
            nameAlignLeft = state.nameAlignLeft,
            nameAlignCapability = state.alignCapability,
            nameAlignedNow = (function()
                local count = 0
                for _, plate in pairs(state.plates) do
                    if plate.nameAligned then count = count + 1 end
                end
                return count
            end)(),
            nameAlignWrites = counters.nameAlignWrites or 0,
            nameAlignUnchanged = counters.nameAlignUnchanged or 0,
            nameAlignSkippedStyle = counters.nameAlignSkippedStyle or 0,
            nameAlignSkippedNameOnly = counters.nameAlignSkippedNameOnly or 0,
            nameAlignSkippedNoRegion = counters.nameAlignSkippedNoRegion or 0,
            nameAlignWriteFailed = counters.nameAlignWriteFailed or 0,
            -- Phase 22 section 9. red and lightOrange count namePainted: what is on
            -- screen, not what was meant. left counts each Leave reason by decision.
            playerNames = (function()
                local red, lightOrange, recorded, left = 0, 0, 0, {}
                for _, plate in pairs(state.plates) do
                    if plate.namePainted == NAME_VERDICT.CAN_FIGHT then
                        red = red + 1
                    elseif plate.namePainted == NAME_VERDICT.OTHER_PLAYER then
                        lightOrange = lightOrange + 1
                    end
                    -- Names holding a ledger record: what disable or off would restore.
                    if state.ledger and plate.nameRegion
                        and ns.StyleLedger.HasRecord(state.ledger, plate.nameRegion, "NameColour") then
                        recorded = recorded + 1
                    end
                    local decision = plate.nameDecision
                    if decision and not isPaint(decision) then
                        left[decision] = (left[decision] or 0) + 1
                    end
                end
                local nameCounters = {}
                for key, value in pairs(counters) do
                    if type(key) == "string" and type(value) == "number"
                        and (key:find("^nameColour") or key:find("^factionFlush")) then
                        nameCounters[key] = value
                    end
                end
                return {
                    on = state.playerNameColours,
                    capability = state.nameColourCapability,
                    hookInstalled = state.nameHookInstalled,
                    red = red,
                    lightOrange = lightOrange,
                    recorded = recorded,
                    left = left,
                    flushPending = state.factionWork.scheduled,
                    counters = nameCounters,
                }
            end)(),
            guildReadsPlain = counters.guildReadsPlain or 0,
            guildReadsNoGuild = counters.guildReadsNoGuild or 0,
            guildReadsWithheld = counters.guildReadsWithheld or 0,
            guildReadsUnavailable = counters.guildReadsUnavailable or 0,
            guildLabelsAttached = counters.guildLabelsAttached or 0,
            guildPoolExhausted = counters.guildPoolExhausted or 0,
            guildRefreshes = counters.guildRefreshes or 0,
            -- Phase 18 section 2: all fallbacks and no outlines is how a client
            -- that will not accept the OUTLINE flag shows up.
            guildOutlined = counters.guildOutlined or 0,
            guildOutlineFallbacks = counters.guildOutlineFallbacks or 0,
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
            -- Patch 03 section 9: the stored choice, and the role and Auto reading the
            -- last sweep resolved.
            roleChoice = state.roleChoice,
            role = state.role,
            auto = state.auto,
            autoRoleReadsPlain = counters.autoRoleReadsPlain or 0,
            autoRoleReadsUnread = counters.autoRoleReadsUnread or 0,
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
