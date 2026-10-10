-- Spikes/GuildNameProbe.lua
-- Spike G: can a guild name be read for a nameplate's unit, and can a font string
-- of ours be drawn under that plate's health bar?
--
-- TEMPORARY. Deleted with its `/pa probe guild` route and PersonalAddonSpikeLog
-- once the Phase 15 design records the answers, as Phase 14's BarHeightProbe was.
-- An internal feature, off by default, that switches itself on at the first
-- command and calls nothing until then.
--
-- WHY A PROBE. Two unknowns, and the cheap one is not the interesting one.
--
-- 1. THE DATA. No documented function returns a guild name for an arbitrary unit.
--    C_GuildInfo is all player-side guild management; its one per-unit call,
--    GetGuildTabardInfo, returns tabard colours and no name. That leaves
--    GetGuildInfo(unitToken), which is undocumented, which Blizzard itself calls
--    only with "player" in all seven of its own uses, and which therefore carries
--    no SecretReturns or restriction flag to reason from. It has to be tried.
--
-- 2. THE DISPLAY. Phase 2 section 4.7 established that Blizzard's own nameplate
--    name cannot even be measured: GetPoint on it fails with "Can't measure
--    restricted regions". So the text must be ours, on a frame of ours, anchored
--    to the plate and never parented to it (rule 6). That path has never been
--    walked on this client, and a frame that draws in the wrong place or survives
--    a plate recycling is the thing to find out about now rather than in a phase.
--
-- WHAT IT DOES NOT DO. It installs no hook and keeps no timer. It reads and draws
-- when a command is typed, and it reports what it found.

local ADDON_NAME, ns = ...

local FEATURE_ID = "guildNameProbe"

local format, type, tostring, pairs = string.format, type, tostring, pairs
local ClientRead = ns.ClientRead
local PLAIN = ClientRead.PLAIN

-- Our own label, anchored under the plate's health bar. One per plate, from our
-- own pool, parented to UIParent and never to the plate (rule 6).
local LABEL_HEIGHT = 10
local LABEL_FONT = "GameFontHighlightSmall"

local state = {
    enabled = false,
    pool = nil,
    labels = {},
    labelCount = 0,
}

local function currentPlates()
    local api = _G.C_NamePlate
    if not (api and ClientRead.Available(api.GetNamePlates)) then
        return nil, "C_NamePlate.GetNamePlates is missing on this client"
    end
    local ok, plates = pcall(api.GetNamePlates)
    if not ok or type(plates) ~= "table" then
        return nil, "C_NamePlate.GetNamePlates would not answer"
    end
    return plates
end

local function resolveParts(plate)
    local unitFrame = plate.UnitFrame or plate.unitFrame or plate
    return unitFrame, unitFrame.HealthBarsContainer or unitFrame.healthBarsContainer
end

-- G1 and G2: the guild name for one unit, and whether this client will show it.
local function readGuild(unitToken)
    local fn = _G.GetGuildInfo
    if type(fn) ~= "function" then
        return "Unavailable", "GetGuildInfo is missing from this client"
    end
    local kind, name = ClientRead.Call(fn, "string", unitToken)
    -- Absent is a READABLE nil: this unit has no guild. Withheld is "could not
    -- tell", and rule 10 forbids reading it as "no".
    if kind == ClientRead.ABSENT then
        return "NoGuild"
    end
    if kind ~= PLAIN then
        return "Withheld", tostring(name)
    end
    if name == "" then
        return "NoGuild"
    end
    return "Plain", name
end

-- The report, written so it survives a reload: chat history does not.
local function recordRun(label, rows, summary)
    local log = _G.PersonalAddonSpikeLog
    if type(log) ~= "table" then
        log = { runs = {} }
        _G.PersonalAddonSpikeLog = log
    end
    if type(log.runs) ~= "table" then
        log.runs = {}
    end
    log.runs[#log.runs + 1] = {
        label = label,
        at = (type(time) == "function" and time()) or 0,
        clientBuild = select(2, GetBuildInfo()),
        summary = summary,
        plates = rows,
    }
    while #log.runs > 12 do
        table.remove(log.runs, 1)
    end
end

-- What one plate is, for the report: its token, whether it is a player, friendly,
-- the player's own, and what its guild read gave.
local function describePlate(plate)
    local row = {}
    local tokenKind, token = ClientRead.Field(plate, "unitToken", "string")
    if tokenKind ~= PLAIN then
        row.tokenReadable = false
        return row
    end
    row.token = token
    row.tokenReadable = true

    local kind, value = ClientRead.Call(_G.UnitIsPlayer, "boolean", token)
    row.isPlayer = (kind == PLAIN) and value or nil
    kind, value = ClientRead.Call(_G.UnitIsFriend, "boolean", "player", token)
    row.isFriend = (kind == PLAIN) and value or nil
    kind, value = ClientRead.Call(_G.UnitIsUnit, "boolean", token, "player")
    row.isSelf = (kind == PLAIN) and value or nil
    kind, value = ClientRead.Call(_G.UnitName, "string", token)
    row.name = (kind == PLAIN) and value or nil

    row.guildKind, row.guild = readGuild(token)
    return row
end

-- G1, G2 and G3 ---------------------------------------------------------------

local function commandRead()
    local plates, reason = currentPlates()
    if not plates then
        ns.Log.Error(reason)
        return
    end

    local seen, withGuild, withheld, noGuild, players = 0, 0, 0, 0, 0
    local rows = {}
    for _, plate in pairs(plates) do
        seen = seen + 1
        local row = describePlate(plate)
        rows[#rows + 1] = row
        if row.isPlayer then
            players = players + 1
        end
        if row.guildKind == "Plain" then
            withGuild = withGuild + 1
            ns.Log.Info(format("  %s%s: <%s>", tostring(row.name or row.token),
                row.isFriend and "" or " (hostile)",
                ns.EscapeGuard.Neutralize(tostring(row.guild))))
        elseif row.guildKind == "Withheld" then
            withheld = withheld + 1
            ns.Log.Warn(format("  %s: guild NOT readable (%s)",
                tostring(row.name or row.token), tostring(row.guild)))
        elseif row.guildKind == "NoGuild" then
            noGuild = noGuild + 1
        end
    end

    local summary = format("%d plate(s), %d player(s); %d guild name(s), %d withheld, %d with no guild",
        seen, players, withGuild, withheld, noGuild)
    ns.Log.Info("G1/G2: " .. summary)
    recordRun("read", rows, summary)
    if seen == 0 then
        ns.Log.Warn("no nameplates on screen")
    elseif players == 0 then
        ns.Log.Warn("no PLAYER plates on screen; stand near other players, a city is ideal")
    end
    ns.Log.Info("saved to PersonalAddonSpikeLog, so it survives /reload")
end

-- G4: our own font string, under the bar ---------------------------------------

local function ensurePool()
    if state.pool then
        return
    end
    state.pool = ns.FramePool.Create({
        poolName = "guildProbeLabels",
        capacity = 20,
        dropPolicy = ns.DROP_POLICY.SURFACE_AND_FAIL,
        factory = function()
            -- Parented to UIParent, NEVER to the nameplate: the Gamepad UI
            -- rebuilds a panel's navigation when a frame is created under it,
            -- in whoever's code is running (rule 6).
            local frame = CreateFrame("Frame", nil, _G.UIParent)
            frame:SetHeight(LABEL_HEIGHT)
            frame:EnableMouse(false)
            frame.text = frame:CreateFontString(nil, "OVERLAY", LABEL_FONT)
            frame.text:SetAllPoints(frame)
            frame.text:SetJustifyH("CENTER")
            frame:Hide()
            return frame
        end,
        reset = function(frame)
            frame:Hide()
            frame:ClearAllPoints()
            frame.text:SetText("")
        end,
    })
end

local function releaseLabels()
    for plate, label in pairs(state.labels) do
        ns.FramePool.Release(state.pool, label)
        state.labels[plate] = nil
    end
    state.labelCount = 0
end

local function commandDraw()
    ensurePool()
    releaseLabels()

    local plates, reason = currentPlates()
    if not plates then
        ns.Log.Error(reason)
        return
    end

    local drawn, noContainer, noGuild = 0, 0, 0
    local rows = {}
    for _, plate in pairs(plates) do
        local row = describePlate(plate)
        local _unitFrame, container = resolveParts(plate)
        if not container then
            row.noContainer = true
            noContainer = noContainer + 1
        elseif row.guildKind ~= "Plain" then
            noGuild = noGuild + 1
        else
            local label = ns.FramePool.Acquire(state.pool)
            if label then
                -- GetWidth is secret-capable in the docs, so it goes through
                -- ClientRead and falls back to a plain default.
                local widthKind, width = ClientRead.Call(container.GetWidth, "number", container)
                label:SetWidth((widthKind == PLAIN and width and width > 0) and width or 120)
                label:ClearAllPoints()
                -- Under the bar, where nothing of Blizzard's sits.
                label:SetPoint("TOP", container, "BOTTOM", 0, -1)
                label:SetFrameStrata("HIGH")
                label.text:SetText(format("<%s>",
                    ns.EscapeGuard.Neutralize(tostring(row.guild))))
                label.text:SetAlpha(0.7)
                label:Show()
                state.labels[plate] = label
                state.labelCount = state.labelCount + 1
                drawn = drawn + 1
                row.drawn = true
            end
        end
        rows[#rows + 1] = row
    end

    local summary = format("drew %d label(s); %d plate(s) with no container, %d with no readable guild",
        drawn, noContainer, noGuild)
    ns.Log.Info("G4: " .. summary)
    recordRun("draw", rows, summary)
    ns.Log.Warn("NOW LOOK. Is the guild name under the right bar, the right way up, and does it stay put as you move?")
    ns.Log.Info("Then move so a plate leaves view and comes back, and run /pa probe guild draw again.")
end

local function commandClear()
    if not state.pool then
        ns.Log.Info("nothing drawn")
        return
    end
    local count = state.labelCount
    releaseLabels()
    ns.Log.Info(format("released %d label(s)", count))
end

local function commandReport()
    ns.Log.Info(format("guild-name probe: enabled=%s labels=%s",
        tostring(state.enabled), tostring(state.labelCount)))
    ns.Log.Info("  read | draw | clear")
end

-- Lifecycle ---------------------------------------------------------------------

local function enable()
    state.enabled = true
    return true
end

local function disable()
    if state.pool then
        releaseLabels()
    end
    state.enabled = false
end

ns.Registry.Register(FEATURE_ID, {
    enabledByDefault = false,
    internal = true,
    label = "Guild name probe (spike G)",
    settings = {},
    schema = {},
}, {
    enable = enable,
    disable = disable,
    onConfigChanged = function() return ns.CONFIG_RESULT.APPLIED end,
})

ns.GuildNameProbe = {
    Route = function(subcommand)
        if not state.enabled then
            ns.Registry.SetEnabled(FEATURE_ID, true)
            if not state.enabled then
                ns.Log.Error("the probe would not enable; /pa status says why")
                return
            end
            ns.Log.Info("guild-name probe on. /pa off guildNameProbe when you are done")
        end
        local word = string.lower(tostring(subcommand or ""))
        if word == "" or word == "report" then
            commandReport()
        elseif word == "read" then
            commandRead()
        elseif word == "draw" then
            commandDraw()
        elseif word == "clear" then
            commandClear()
        else
            ns.Log.Warn("/pa probe guild [read | draw | clear]")
        end
    end,
}
