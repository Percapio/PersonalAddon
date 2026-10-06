-- Features/ThreatPanel.lua
-- In combat, the mobs fighting you or your group: each with its health as a bar in
-- the nameplate colours, and your threat on it as a percentage, highest first. It
-- sits in the damage breakdown's place above the player frame
-- (Architecture/20261005-Phase11.md section 5).
--
-- A mob's health is always hidden from addon code on this client, and its name may
-- be. Neither is ever read here. ClientRead.Pass hands the client's value straight
-- to a status bar or a font string, whose documented setters accept hidden values,
-- so the client draws what our code may not look at (section 4).
--
-- The plates are read from the client on every sweep, so nothing is tracked between
-- sweeps and no token can go stale. The panel runs only in combat, on its own timer.
-- Its two event handlers record state and schedule; every client read happens a
-- frame later (README rules 1 and 5). Every frame is made at enable.

local ADDON_NAME, ns = ...

local FEATURE_ID = "threatPanel"
-- The bar colours are the nameplates feature's settings (section 2.2).
local NAMEPLATES_ID = "nameplates"

local format, pairs, type, tostring = string.format, pairs, type, tostring
local max, min, sort = math.max, math.min, table.sort

local ClientRead = ns.ClientRead
local PLAIN, ABSENT, WITHHELD = ClientRead.PLAIN, ClientRead.ABSENT, ClientRead.WITHHELD
local SHOWN, UNAVAILABLE = ClientRead.SHOWN, ClientRead.UNAVAILABLE
local Threat = ns.Threat
local VERDICT, ENGAGEMENT = Threat.VERDICT, Threat.ENGAGEMENT
local bump = ns.Diagnostics.Bump

-- Your threat on a mob, as the panel sorts and shows it (section 1.4).
local READING = { READABLE = "Readable", HIDDEN = "Hidden", NOT_ON_YOUR_LIST = "NotOnYourList" }
-- Readable first, then hidden, then not on your list (section 5.3).
local READING_RANK = { Readable = 1, Hidden = 2, NotOnYourList = 3 }

-- Layout (section 5.1).
local PANEL_WIDTH = 200
local PANEL_PADDING = 6
local ROW_HEIGHT = 16
local ROW_SPACING = 2
local MARKER_WIDTH = 3
local MARKER_HEIGHT = 14
local TAG_WIDTH = 30
local THREAT_WIDTH = 36
local CELL_GAP = 3
local BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"
local PERCENT_FORMAT = "%.0f%%"
-- An em dash: you are not on this mob's threat list.
local NOT_ON_LIST_TEXT = "\226\128\148"

-- Blizzard's own tag conventions: + elite, r rare, ?? a skull (Phase 11 assumptions).
local CLASSIFICATION_SUFFIX = { elite = "+", rare = "r", rareelite = "r+" }

-- Printed by /pa threat in this order, zero when absent (section 5.9).
local COUNTER_NAMES = {
    "sweeps", "rowsShownMax", "rowsTruncated",
    "threatReadsPlain", "threatReadsAbsent", "threatReadsWithheld", "standingReadsWithheld",
    "percentReadsPlain", "percentReadsAbsent", "percentReadsWithheld",
    "filterReadsWithheld", "platesWithoutToken", "valuesPassedHidden", "passFailures",
    "targetMarked", "enemyPlatesOff", "sweepFaults",
}

local state = {
    enabled = false,
    inCombat = false,
    -- Bumped on every combat change and on disable, so a scheduled start or stop
    -- that is no longer wanted does nothing when its frame comes.
    generation = 0,
    panel = nil,
    chrome = nil,
    rowPool = nil,
    -- The drawn rows, top down.
    liveRows = {},
    tokens = {},
    ticker = nil,
    sweepCount = 0,
    platesCheckPending = false,
    anchorIsPlayerFrame = false,
    -- Kept here rather than asked of the frame: IsShown is a secret-capable method,
    -- and this is the only code that shows or hides the panel.
    panelShown = false,
    drawnCount = 0,
    truncatedCount = 0,
    palette = nil,
    -- The nameplates feature's colour strings the palette was built from.
    paletteSource = {},
    sweepFaultNoted = false,
    -- This UI load's diagnostics table, bound at enable.
    counters = {},
    settings = {
        maximumRows = 6,
        panelAlpha = 0.8,
        anchorOffsetX = 0,
        anchorOffsetY = 8,
        showLevel = true,
        markTarget = true,
        showWhenEmpty = false,
        updateInterval = 0.25,
    },
}

-- Reused on every sweep, so a warm sweep allocates nothing. Each is bounded by the
-- number of nameplates the client shows at once.
local plateFrames, plateTokens = {}, {}
local records = {}
local ordered = {}
-- Each listed token's position and first sweep, for this sweep and the last; the
-- two pairs swap after each order (section 5.3).
local positionNow, positionBefore = {}, {}
local firstSeenNow, firstSeenBefore = {}, {}

local function clear(map)
    for key in pairs(map) do
        map[key] = nil
    end
end

local function trim(list, count)
    for index = #list, count + 1, -1 do
        list[index] = nil
    end
end

-- Raises a counter to value when value is higher: the most in any one sweep.
local function raiseTo(counters, name, value)
    local current = counters[name] or 0
    if value > current then
        bump(counters, name, value - current)
    end
end

-- Which mobs (section 5.2) --------------------------------------------------------

-- The nameplates on screen now, with their unit tokens, into plateFrames and
-- plateTokens. Returns how many.
local function currentPlates(counters)
    local api = C_NamePlate
    local listKind, list = ClientRead.Call(type(api) == "table" and api.GetNamePlates or nil, "table")
    if listKind ~= PLAIN then
        if listKind == WITHHELD then
            ns.Log.Once("threat:noplatelist", format(
                "the client gave no nameplate list (%s), so the threat panel can list nothing",
                tostring(list)))
        end
        trim(plateFrames, 0)
        trim(plateTokens, 0)
        return 0
    end

    local count, index = 0, 1
    while true do
        local entryKind, frame = ClientRead.Field(list, index, "table")
        if entryKind ~= PLAIN then
            break
        end
        local tokenKind, token = ClientRead.Field(frame, "unitToken", "string")
        if tokenKind == PLAIN then
            count = count + 1
            plateFrames[count] = frame
            plateTokens[count] = token
        else
            bump(counters, "platesWithoutToken")
        end
        index = index + 1
    end
    trim(plateFrames, count)
    trim(plateTokens, count)
    return count
end

-- One filter read: true or false when it was read, nil when it was withheld, which
-- is counted.
local function filterRead(counters, kind, value)
    if kind == WITHHELD then
        bump(counters, "filterReadsWithheld")
        return nil
    end
    return value == true
end

-- Whether a plate's unit may be listed: it exists, can be attacked, is alive and is
-- in combat. A withheld read leaves it out: "could not tell" never lists a mob as
-- fighting you.
local function passesFilter(token, counters)
    if not filterRead(counters, ClientRead.Call(UnitExists, "boolean", token)) then
        return false
    end
    if not filterRead(counters, ClientRead.Call(UnitCanAttack, "boolean", "player", token)) then
        return false
    end
    if filterRead(counters, ClientRead.Call(UnitIsDead, "boolean", token)) ~= false then
        return false
    end
    return filterRead(counters, ClientRead.Call(UnitAffectingCombat, "boolean", token)) == true
end

local function threatReading(token, counters)
    local kind, percent = Threat.ReadScaledPercent(token, counters)
    if kind == PLAIN then
        return READING.READABLE, percent
    end
    if kind == ABSENT then
        return READING.NOT_ON_YOUR_LIST, nil
    end
    return READING.HIDDEN, nil
end

-- The mobs fighting you or your group, into records. Returns how many. A mob is
-- listed when its engagement is Engaged or CouldNotTell: leaving one out because a
-- threat read was withheld would hide exactly the mob nobody can read.
local function collectRows(plateCount, allies, allyCount, counters)
    local count = 0
    for index = 1, plateCount do
        local token = plateTokens[index]
        if passesFilter(token, counters) then
            local aggro, _, engagement = Threat.ClassifyAggro(token, allies, allyCount, counters)
            if engagement ~= ENGAGEMENT.NOT_ENGAGED then
                count = count + 1
                local record = records[count]
                if not record then
                    record = {}
                    records[count] = record
                end
                record.token = token
                record.plate = plateFrames[index]
                record.aggro = aggro
                record.verdict = nil
                record.isTarget = false
                record.reading, record.percent = threatReading(token, counters)
                local before = positionBefore[token]
                record.known = (before ~= nil)
                record.tiebreak = before or index
                record.firstSeenSweep = firstSeenBefore[token] or state.sweepCount
            end
        end
    end
    for index = count + 1, #records do
        records[index].plate = nil
    end
    return count
end

-- Order (section 5.3) ---------------------------------------------------------------

-- Readable threat first, highest first; then hidden; then not on your list. Ties
-- keep last sweep's order, and a new row goes after the old ones of its group.
-- Every value compared was classified Plain or is our own.
local function drawOrder(left, right)
    local leftRank, rightRank = READING_RANK[left.reading], READING_RANK[right.reading]
    if leftRank ~= rightRank then
        return leftRank < rightRank
    end
    if left.reading == READING.READABLE and left.percent ~= right.percent then
        return left.percent > right.percent
    end
    if left.known ~= right.known then
        return left.known
    end
    return left.tiebreak < right.tiebreak
end

local function orderRows(count)
    for index = 1, count do
        ordered[index] = records[index]
    end
    trim(ordered, count)
    sort(ordered, drawOrder)

    clear(positionNow)
    clear(firstSeenNow)
    for index = 1, count do
        local record = ordered[index]
        positionNow[record.token] = index
        firstSeenNow[record.token] = record.firstSeenSweep
    end
    positionBefore, positionNow = positionNow, positionBefore
    firstSeenBefore, firstSeenNow = firstSeenNow, firstSeenBefore
end

-- Reads -------------------------------------------------------------------------------

-- The target's plate, compared with each row's plate by identity. The lookup is
-- never hidden, while UnitIsUnit goes hidden on restricted maps (section 5.4).
local function readTargetPlate()
    if not state.settings.markTarget then
        return nil
    end
    local api = C_NamePlate
    local kind, plate = ClientRead.Call(type(api) == "table" and api.GetNamePlateForUnit or nil, "table", "target")
    if kind == PLAIN then
        return plate
    end
    return nil
end

-- Rebuilt only when one of the nameplates feature's colour strings changed, so a
-- colour changed in Settings shows on the next sweep. Its stored settings exist
-- whether or not that feature is enabled.
local function refreshPalette()
    local stored = ns.ConfigStore.Feature(NAMEPLATES_ID)
    local settings = stored and stored.settings
    local keys = Threat.PALETTE_KEYS
    local changed = (state.palette == nil)
    for index = 1, #keys do
        local key = keys[index].key
        local value = settings and settings[key]
        if state.paletteSource[key] ~= value then
            state.paletteSource[key] = value
            changed = true
        end
    end
    if changed then
        state.palette = Threat.PaletteFrom(settings)
    end
end

-- A withheld read omits the tag rather than guessing it.
local function levelTag(token)
    local levelKind, level = ClientRead.Call(UnitLevel, "number", token)
    local classKind, classification = ClientRead.Call(UnitClassification, "string", token)
    if levelKind ~= PLAIN or classKind == WITHHELD then
        return ""
    end
    if level < 0 or classification == "worldboss" then
        return "??"
    end
    return format("%d%s", level, CLASSIFICATION_SUFFIX[classification] or "")
end

-- Read at the first sweep of each fight. The CVar is the user's, never changed here
-- (section 5.7).
local function checkEnemyPlates(counters)
    local api = C_CVar
    local kind, value = ClientRead.Call(type(api) == "table" and api.GetCVar or nil, "string", "nameplateShowEnemies")
    if kind == PLAIN and value == "0" then
        bump(counters, "enemyPlatesOff")
        ns.Log.Once("threat:enemyplatesoff",
            "enemy nameplates are off, so the threat panel can list nothing; turn them on to use it")
    end
end

-- Counts one hand-over. True when the value was shown.
local function shown(counters, outcome, detail)
    if outcome == SHOWN then
        if detail then
            bump(counters, "valuesPassedHidden")
        end
        return true
    end
    if outcome == UNAVAILABLE then
        bump(counters, "passFailures")
        ns.Log.Once("threat:passfailed", format(
            "the client would not show a value on the threat panel (%s); that cell stays blank",
            tostring(detail)))
    end
    return false
end

-- Panel -------------------------------------------------------------------------------

-- PlayerFrame may be missing under a replacement UI; a panel in a slightly wrong
-- place beats a feature that faulted over someone else's UI. The breakdown anchors
-- the same way, so by default the two take turns in one place (section 5.6).
local function resolvePanelAnchor()
    if _G.PlayerFrame then
        return _G.PlayerFrame, "BOTTOMLEFT", "TOPLEFT", true
    end
    ns.Log.Once("threat:noplayerframe",
        "PlayerFrame was not found; the threat panel is anchored to the screen instead")
    return _G.UIParent, "BOTTOMLEFT", "BOTTOMLEFT", false
end

local function anchorPanel()
    if not state.panel then
        return
    end
    local anchorFrame, panelPoint, anchorPoint, usedPlayerFrame = resolvePanelAnchor()
    if not anchorFrame then
        ns.Log.OnceError("threat:noanchor",
            "neither PlayerFrame nor UIParent exists; the threat panel cannot be anchored")
        state.anchorIsPlayerFrame = false
        return
    end
    state.anchorIsPlayerFrame = usedPlayerFrame
    state.panel:ClearAllPoints()
    state.panel:SetPoint(panelPoint, anchorFrame, anchorPoint,
        state.settings.anchorOffsetX, state.settings.anchorOffsetY)
end

local function createRow()
    local row = CreateFrame("Frame", nil, state.panel)
    row:SetHeight(ROW_HEIGHT)
    row:SetWidth(PANEL_WIDTH - PANEL_PADDING * 2)

    row.marker = row:CreateTexture(nil, "OVERLAY")
    row.marker:SetWidth(MARKER_WIDTH)
    row.marker:SetHeight(MARKER_HEIGHT)
    row.marker:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.marker:SetColorTexture(1, 1, 1, 1)

    row.tag = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.tag:SetPoint("LEFT", row, "LEFT", MARKER_WIDTH + CELL_GAP, 0)
    row.tag:SetWidth(TAG_WIDTH)
    row.tag:SetJustifyH("LEFT")

    row.threat = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.threat:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.threat:SetWidth(THREAT_WIDTH)
    row.threat:SetJustifyH("RIGHT")

    local bar = CreateFrame("StatusBar", nil, row)
    bar:SetHeight(ROW_HEIGHT - 2)
    bar:SetStatusBarTexture(BAR_TEXTURE)
    bar:SetPoint("RIGHT", row, "RIGHT", -(THREAT_WIDTH + CELL_GAP), 0)
    local background = bar:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints(bar)
    background:SetColorTexture(0, 0, 0, 0.5)
    row.bar = bar

    -- Over the bar, truncated by the font string rather than wrapped.
    row.name = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", bar, "LEFT", 2, 0)
    row.name:SetPoint("RIGHT", bar, "RIGHT", -2, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    return row
end

-- Every field a row shows, emptied: a reused row never shows the last mob's values.
local function clearRow(row)
    row.marker:Hide()
    row.tag:SetText("")
    row.name:SetText("")
    row.threat:SetText("")
    row.bar:SetMinMaxValues(0, 1)
    row.bar:SetValue(0)
end

local function resetRow(row)
    row:Hide()
    row:ClearAllPoints()
    clearRow(row)
end

-- The bar starts after the tag, or after the marker when the tag is off.
local function placeBar(row)
    local left = MARKER_WIDTH + CELL_GAP
    if state.settings.showLevel then
        left = left + TAG_WIDTH + CELL_GAP
    end
    if row.barLeft ~= left then
        row.bar:SetPoint("LEFT", row, "LEFT", left, 0)
        row.barLeft = left
    end
end

-- The panel and every row, built here at enable, so nothing is created during a
-- fight (section 5.5).
local function ensurePanel()
    if state.panel then
        return state.panel
    end
    local chrome = ns.PanelChrome.Build({
        frameName = "PersonalAddonThreatPanel",
        width = PANEL_WIDTH,
        height = ROW_HEIGHT + PANEL_PADDING * 2,
        alpha = state.settings.panelAlpha,
        ownerKey = "threat",
        ownerLabel = "the threat panel",
    })
    state.chrome = chrome
    state.panel = chrome.frame
    state.rowPool = ns.FramePool.Create({
        poolName = "threatPanelRows",
        capacity = ns.THREAT_ROW_CAPACITY,
        dropPolicy = ns.DROP_POLICY.SURFACE_AND_FAIL,
        factory = createRow,
        reset = resetRow,
    })
    ns.FramePool.Prewarm(state.rowPool)
    return state.panel
end

local function releaseRows()
    local liveRows = state.liveRows
    for index = #liveRows, 1, -1 do
        ns.FramePool.Release(state.rowPool, liveRows[index])
        liveRows[index] = nil
    end
end

-- Draw (section 5.4) ------------------------------------------------------------------

-- Sets every field of one row. Only drawn rows are read beyond the filter and the
-- threat reads.
local function drawRow(row, record, targetPlate, counters)
    local token = record.token

    local verdict = Threat.ResolveVerdict(record.aggro, Threat.Disposition(token, counters))
    record.verdict = verdict
    -- Ceded has no colour of its own: there is no Blizzard bar here to cede to.
    local colour = state.palette[verdict] or state.palette[VERDICT.ELSEWHERE]
    local bar = row.bar
    bar:SetStatusBarColor(colour.red, colour.green, colour.blue)

    record.isTarget = (targetPlate ~= nil and record.plate == targetPlate)
    if record.isTarget then
        row.marker:Show()
    else
        row.marker:Hide()
    end

    placeBar(row)
    if state.settings.showLevel then
        row.tag:SetText(levelTag(token))
    else
        row.tag:SetText("")
    end

    if shown(counters, ClientRead.Pass(bar.SetMinMaxValues, bar, 0, 1, UnitHealthMax, token)) then
        if not shown(counters, ClientRead.Pass(bar.SetValue, bar, nil, 1, UnitHealth, token)) then
            bar:SetValue(0)
        end
    else
        bar:SetMinMaxValues(0, 1)
        bar:SetValue(0)
    end

    local name = row.name
    if not shown(counters, ClientRead.Pass(name.SetText, name, nil, 1, UnitName, token)) then
        name:SetText("")
    end

    local threat = row.threat
    if record.reading == READING.READABLE then
        threat:SetText(format(PERCENT_FORMAT, record.percent))
    elseif record.reading == READING.NOT_ON_YOUR_LIST then
        threat:SetText(NOT_ON_LIST_TEXT)
    elseif not shown(counters, ClientRead.Pass(threat.SetFormattedText, threat, PERCENT_FORMAT, 3, UnitDetailedThreatSituation, "player", token)) then
        threat:SetText("")
    end
end

local function anchorRow(row, index)
    row:ClearAllPoints()
    if index == 1 then
        row:SetPoint("TOPLEFT", state.panel, "TOPLEFT", PANEL_PADDING, -PANEL_PADDING)
    else
        row:SetPoint("TOPLEFT", state.liveRows[index - 1], "BOTTOMLEFT", 0, -ROW_SPACING)
    end
end

-- Draws the top rows, at most maximumRows, and sizes the panel. Returns how many.
local function renderRows(count, targetPlate, counters)
    local settings = state.settings
    local drawCount = min(count, max(1, min(settings.maximumRows, ns.THREAT_ROW_CAPACITY)))
    local liveRows = state.liveRows

    while #liveRows > drawCount do
        ns.FramePool.Release(state.rowPool, liveRows[#liveRows])
        liveRows[#liveRows] = nil
    end
    while #liveRows < drawCount do
        local row, poolError = ns.FramePool.Acquire(state.rowPool)
        if not row then
            ns.Log.OnceError("threat:poolexhausted", format(
                "the threat panel's row pool was exhausted (%s)", tostring(poolError)))
            drawCount = #liveRows
            break
        end
        liveRows[#liveRows + 1] = row
        anchorRow(row, #liveRows)
        row:Show()
    end

    local marked = false
    for index = 1, drawCount do
        drawRow(liveRows[index], ordered[index], targetPlate, counters)
        marked = marked or ordered[index].isTarget
    end
    if marked then
        bump(counters, "targetMarked")
    end

    state.drawnCount = drawCount
    state.truncatedCount = count - drawCount
    raiseTo(counters, "rowsShownMax", drawCount)
    raiseTo(counters, "rowsTruncated", count - drawCount)

    local panel = state.panel
    if drawCount == 0 and not settings.showWhenEmpty then
        panel:Hide()
        state.panelShown = false
        return drawCount
    end
    panel:SetHeight(PANEL_PADDING * 2 + max(1, drawCount) * ROW_HEIGHT
        + max(0, drawCount - 1) * ROW_SPACING)
    ns.PanelChrome.SetAlpha(state.chrome, settings.panelAlpha)
    panel:Show()
    state.panelShown = true
    return drawCount
end

-- Sweep (section 5.5) -----------------------------------------------------------------

local function sweep()
    if not state.enabled or not state.inCombat then
        return
    end
    state.sweepCount = state.sweepCount + 1
    local counters = state.counters
    bump(counters, "sweeps")

    if state.platesCheckPending then
        state.platesCheckPending = false
        checkEnemyPlates(counters)
    end
    refreshPalette()

    local plateCount = currentPlates(counters)
    local allies, allyCount = Threat.Allies()
    local rowCount = collectRows(plateCount, allies, allyCount, counters)
    orderRows(rowCount)
    renderRows(rowCount, readTargetPlate(), counters)
end

-- A sweep that raises is dropped and the next one runs. The message is noted once
-- per UI load: the fault notes are shared by every feature, and a sweep runs four
-- times a second.
local function guardedSweep()
    local ok, fault = ns.Isolation.Call(sweep)
    if ok then
        return
    end
    bump(state.counters, "sweepFaults")
    if not state.sweepFaultNoted then
        state.sweepFaultNoted = true
        ns.Diagnostics.NoteFault(FEATURE_ID, fault)
    end
    ns.Log.OnceError("threat:fault",
        "a threat panel update raised and was skipped; /pa diag shows the message")
end

local function startTicker()
    if state.ticker or not (C_Timer and C_Timer.NewTicker) then
        return
    end
    state.ticker = C_Timer.NewTicker(state.settings.updateInterval, guardedSweep)
end

local function stopTicker()
    if state.ticker and state.ticker.Cancel then
        state.ticker:Cancel()
    end
    state.ticker = nil
end

-- The first sweep runs at once, then one every updateInterval. The anchor is
-- re-resolved here, in case PlayerFrame was built after enable.
local function startSweeping()
    if state.ticker then
        return
    end
    anchorPanel()
    state.platesCheckPending = true
    guardedSweep()
    startTicker()
end

-- Hidden, rows released, no ticker, and nothing kept from the fight.
local function goIdle()
    stopTicker()
    if state.rowPool then
        releaseRows()
    end
    if state.panel then
        state.panel:Hide()
    end
    state.panelShown = false
    state.drawnCount = 0
    state.truncatedCount = 0
    trim(ordered, 0)
    for index = 1, #records do
        records[index].plate = nil
    end
    trim(plateFrames, 0)
    trim(plateTokens, 0)
    clear(positionBefore)
    clear(firstSeenBefore)
end

-- Signals -----------------------------------------------------------------------------

-- Runs action a frame later, unless a later combat change or a disable came first.
local function schedule(action)
    state.generation = state.generation + 1
    local generation = state.generation
    if not (C_Timer and C_Timer.After) then
        return
    end
    C_Timer.After(0, function()
        if generation == state.generation and state.enabled then
            action()
        end
    end)
end

local function onCombatStart()
    state.inCombat = true
    schedule(startSweeping)
end

local function onCombatEnd()
    state.inCombat = false
    schedule(goIdle)
end

-- Both flagged SynchronousEvent; Dispatch already registers them for the breakdown.
local SIGNALS = {
    { event = "PLAYER_REGEN_DISABLED", handler = onCombatStart,
      lost = "the panel cannot tell when a fight starts" },
    { event = "PLAYER_REGEN_ENABLED", handler = onCombatEnd,
      lost = "the panel cannot tell when a fight ends" },
}

-- Lifecycle ---------------------------------------------------------------------------

local function readSettings(config)
    local settings = config and config.settings
    if not settings then
        return
    end
    local own = state.settings
    own.maximumRows = settings.maximumRows or own.maximumRows
    own.panelAlpha = settings.panelAlpha or own.panelAlpha
    own.anchorOffsetX = settings.anchorOffsetX or own.anchorOffsetX
    own.anchorOffsetY = settings.anchorOffsetY or own.anchorOffsetY
    own.showLevel = (settings.showLevel ~= false)
    own.markTarget = (settings.markTarget ~= false)
    own.showWhenEmpty = (settings.showWhenEmpty == true)
    own.updateInterval = settings.updateInterval or own.updateInterval
end

local function enable(config)
    readSettings(config)

    if not ClientRead.Available(UnitThreatSituation) then
        return nil, "UnitThreatSituation is missing from this client, so the panel cannot tell which mobs are fighting you"
    end

    state.counters = ns.Diagnostics.CountersFor(FEATURE_ID)
    ensurePanel()
    anchorPanel()

    local tokens = state.tokens
    for index = 1, #SIGNALS do
        local signal = SIGNALS[index]
        local token = ns.Dispatch.Subscribe(FEATURE_ID, signal.event, signal.handler)
        if not token then
            return nil, format("this client does not deliver %s, so %s", signal.event, signal.lost)
        end
        tokens[#tokens + 1] = token
    end

    state.enabled = true
    state.generation = state.generation + 1

    -- Enabled during a fight, the panel starts at once: the plates are read from the
    -- client, so the mobs already on screen are listed (section 5.5).
    local combatKind, inCombat = ClientRead.Call(UnitAffectingCombat, "boolean", "player")
    state.inCombat = (combatKind == PLAIN and inCombat == true)
    if state.inCombat then
        startSweeping()
    end
    return true
end

-- Every step guarded: disable also cleans up after a failed enable.
local function disable()
    state.enabled = false
    state.inCombat = false
    state.generation = state.generation + 1
    goIdle()
    for index = #state.tokens, 1, -1 do
        ns.Dispatch.Unsubscribe(state.tokens[index])
        state.tokens[index] = nil
    end
end

-- The rest lands on the next sweep, under a quarter of a second away in a fight.
local function onConfigChanged(config, changedKey)
    readSettings(config)
    if changedKey == "anchorOffsetX" or changedKey == "anchorOffsetY" then
        anchorPanel()
    elseif changedKey == "panelAlpha" then
        ns.PanelChrome.SetAlpha(state.chrome, state.settings.panelAlpha)
    elseif changedKey == "updateInterval" and state.ticker then
        stopTicker()
        startTicker()
    end
    return ns.CONFIG_RESULT.APPLIED
end

ns.Registry.Register(FEATURE_ID, {
    enabledByDefault = true,
    label = "Threat panel",
    description = "In combat, the mobs fighting you or your group, with their health and your threat on each, in the damage breakdown's place. The bars use the nameplate colours, set under Nameplates. Needs enemy nameplates on.",
    settings = {
        maximumRows = 6,
        panelAlpha = 0.8,
        anchorOffsetX = 0,
        anchorOffsetY = 8,
        showLevel = true,
        markTarget = true,
        showWhenEmpty = false,
        updateInterval = 0.25,
    },
    schema = {
        maximumRows = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Rows shown",
            description = "How many mobs to list, highest threat first.",
            minimum = 1, maximum = 10, step = 1,
        },
        panelAlpha = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Panel opacity",
            minimum = 0.1, maximum = 1.0, step = 0.05,
        },
        anchorOffsetX = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Horizontal offset",
            minimum = -300, maximum = 300, step = 1,
        },
        anchorOffsetY = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Vertical offset",
            minimum = -300, maximum = 300, step = 1,
        },
        showLevel = {
            kind = ns.ConfigSchema.KIND.TOGGLE, label = "Show level and elite tag",
        },
        markTarget = {
            kind = ns.ConfigSchema.KIND.TOGGLE, label = "Mark your target",
        },
        showWhenEmpty = {
            kind = ns.ConfigSchema.KIND.TOGGLE, label = "Show when empty", curated = false,
        },
        -- Not curated: a frame-rate decision dressed as a preference.
        updateInterval = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Update interval",
            minimum = 0.1, maximum = 1.0, curated = false,
        },
    },
}, {
    enable = enable,
    disable = disable,
    onConfigChanged = onConfigChanged,
})

local function threatText(record)
    if record.reading == READING.READABLE then
        return format(PERCENT_FORMAT, record.percent)
    end
    if record.reading == READING.NOT_ON_YOUR_LIST then
        return "not on your list"
    end
    return "hidden"
end

ns.ThreatPanel = {
    COUNTER_NAMES = COUNTER_NAMES,
    Inspect = function()
        local rows = {}
        for index = 1, state.drawnCount do
            local record = ordered[index]
            rows[index] = {
                token = record.token,
                verdict = record.verdict,
                threat = threatText(record),
                isTarget = record.isTarget,
                firstSeenSweep = record.firstSeenSweep,
                frame = state.liveRows[index],
            }
        end
        local constructed, live, free, capacity = 0, 0, 0, 0
        if state.rowPool then
            constructed, live, free, capacity = ns.FramePool.Stats(state.rowPool)
        end
        return {
            enabled = state.enabled,
            inCombat = state.inCombat,
            sweeping = state.ticker ~= nil,
            updateInterval = state.settings.updateInterval,
            sweeps = state.sweepCount,
            rowsDrawn = state.drawnCount,
            maximumRows = state.settings.maximumRows,
            rowsTruncated = state.truncatedCount,
            panelShown = state.panelShown,
            anchorIsPlayerFrame = state.anchorIsPlayerFrame == true,
            rows = rows,
            counters = state.counters,
            poolConstructed = constructed,
            poolLive = live,
            poolFree = free,
            poolCapacity = capacity,
        }
    end,
}
