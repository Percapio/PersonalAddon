-- Features/FiveSecondRule.lua
-- A vertical line that sweeps across the player's mana bar over the five-second
-- rule window: it sits at the left edge when a mana-costing cast opens the
-- window and reaches the right edge as spirit regen resumes.
--
-- This is the option-A re-scope recorded in Architecture section 11.1a. The
-- original design inferred a regen tick clock from observed mana deltas. This
-- client returns power as a protected value that addon code may not use in
-- arithmetic, so there is no delta, no tick edge and no phase. The window needs
-- no power value at all -- it is the cast event plus GetTime -- which is why it
-- survives the restriction and the tick line does not.
--
-- Nothing in this file reads a power amount. The only unit call is the power
-- TYPE, and only its string token is compared.
--
-- Phase 20 (Architecture/20261021-Phase20.md section 2): a cast that costs nothing
-- leaves the window alone. C_Spell.GetSpellPowerCost answers NOTHING for a spell with
-- no resource cost -- its documented answer, and the one every Blizzard caller treats
-- as "no cost" -- and this file used to read that as "the client will not say", which
-- restarted the window on every wand shot, Auto Shot, potion and Hearthstone.
--
-- Patch 03 (Architecture/20261122-Patch03.md section 4): after a window that ends in
-- combat, the same line keeps moving in the tick colour, crossing the bar every
-- FSR_TICK_PERIOD seconds, until the next mana-costing cast or the end of the fight.
-- The rhythm is WoW Classic's 2 seconds, by the user's decision: a cue, not a reading
-- of Forever's ticks, which stay unreadable for the reason above. It reads GetTime
-- and, once at the window's end and once per tick, UnitAffectingCombat("player").

local ADDON_NAME, ns = ...

local FEATURE_ID = "fiveSecondRule"

local format, max, floor = string.format, math.max, math.floor
local STATE = ns.TRACKER_STATE
local MANA = ns.POWER_TYPE_MANA
local FSR_WINDOW = ns.FSR_WINDOW
local TICK_PERIOD = ns.FSR_TICK_PERIOD
local TICK_COLOUR_DEFAULT = "ffd100"

-- Why a run of ticks ended (Patch 03 section 4.3). Disable resets them uncounted, as
-- it resets the window (audit finding 6).
local TICK_STOP = {
    CAST = "Cast",
    FIGHT_ENDED = "FightEnded",
    BACKSTOP = "Backstop",
    SWITCHED_OFF = "SwitchedOff",
    LOADING_SCREEN = "LoadingScreen",
}

-- What UnitAffectingCombat("player") answered. Unread is never "in combat", in either
-- direction: it starts no ticks and ends running ones (section 4.3).
local COMBAT = { IN = "In", OUT = "Out", UNREAD = "Unread" }

-- The spellcast payload and the mana bar's geometry are client values that can be
-- secret (Phase 9 section 5.2), so they are read through ClientRead.
local ClientRead = ns.ClientRead
local PLAIN, ABSENT, WITHHELD = ClientRead.PLAIN, ClientRead.ABSENT, ClientRead.WITHHELD
local bump = ns.Diagnostics.Bump

local tracker = {
    state = STATE.REGENERATING,
    windowStartedAt = 0,
    windowEndsAt = 0,
    -- Patch 03 section 4.3: the tick clock. tickAnchor is the window's end, and
    -- tickLastCycle the last tick boundary the backstop checked; both 0 outside Ticking.
    tickAnchor = 0,
    tickLastCycle = 0,
    showTicks = true,
    tickColour = { red = 1, green = 0.82, blue = 0 },
    -- Whether the line is on screen, kept here rather than asked of the texture.
    lineShown = false,
    tokens = {},
    marker = nil,
    markerBar = nil,
    driver = nil,
    updating = false,
    windowTimer = nil,
    timerGeneration = 0,
    manaUser = true,
    -- False exactly when this client has no spell cost lookup at all.
    costQueryable = nil,
    lastUnknownReason = nil,
    lineWidth = 2,
    lineAlpha = 0.9,
    -- This UI load's diagnostics table, bound at enable.
    counters = {},
}

-- Window ---------------------------------------------------------------------

-- Elapsed portion of the current window, clamped to [0, 1]. Derived entirely
-- from our own timestamps, so no client-protected value is involved.
local function windowElapsedFraction(now)
    if tracker.windowEndsAt <= tracker.windowStartedAt then
        return 0
    end
    local elapsed = (now - tracker.windowStartedAt) / FSR_WINDOW
    if elapsed < 0 then
        return 0
    end
    if elapsed > 1 then
        return 1
    end
    return elapsed
end

-- Where the line sits during ticks, from our own clock only (Patch 03 section 4.3):
-- the share of the current 2-second cycle since the window's end. 0 whenever the
-- state is not Ticking, so Inspect never reports a phase that is not running
-- (audit finding 8).
local function tickFraction(now)
    if tracker.state ~= STATE.TICKING or tracker.tickAnchor <= 0 then
        return 0
    end
    local elapsed = now - tracker.tickAnchor
    if elapsed < 0 then
        return 0
    end
    return (elapsed % TICK_PERIOD) / TICK_PERIOD
end

local function lineFraction(now)
    if tracker.state == STATE.TICKING then
        return tickFraction(now)
    end
    return windowElapsedFraction(now)
end

-- Render ---------------------------------------------------------------------

local function resolveManaBar()
    return (PlayerFrame and PlayerFrame.manabar) or _G.PlayerFrameManaBar
end

local function applyAppearance()
    local marker = tracker.marker
    if not marker then
        return
    end
    marker:SetWidth(tracker.lineWidth)
    local bar = tracker.markerBar
    if bar then
        local kind, height = ClientRead.Call(bar.GetHeight, "number", bar)
        if kind == PLAIN and height > 0 then
            marker:SetHeight(height)
        elseif kind == WITHHELD then
            bump(tracker.counters, "withheldBarGeometry")
        end
    end
    marker:SetAlpha(tracker.lineAlpha)
end

local function setLineColour(marker, red, green, blue)
    if marker.SetColorTexture then
        marker:SetColorTexture(red, green, blue, 1)
    else
        marker:SetTexture(red, green, blue, 1)
    end
end

-- White for the window, the tick colour for ticks (Patch 03 section 4.4). Written on
-- each state change, never per frame.
local function applyLineColour()
    local marker = tracker.marker
    if not marker then
        return
    end
    if tracker.state == STATE.TICKING then
        local colour = tracker.tickColour
        setLineColour(marker, colour.red, colour.green, colour.blue)
    else
        setLineColour(marker, 1, 1, 1)
    end
end

local function ensureMarker()
    if tracker.marker then
        return tracker.marker
    end

    local bar = resolveManaBar()
    if not bar then
        return nil
    end

    local marker = bar:CreateTexture(nil, "OVERLAY")
    if marker.SetColorTexture then
        marker:SetColorTexture(1, 1, 1, 1)
    else
        marker:SetTexture(1, 1, 1, 1)
    end
    marker:Hide()

    tracker.marker = marker
    tracker.markerBar = bar
    applyAppearance()
    return marker
end

-- The power type's string token, never its numeric index, so a client that
-- protects power values cannot make this raise. If it is unreadable we show the
-- indicator rather than hide it -- a visible indicator on a rage user is a
-- cosmetic complaint, an invisible one on a mana user is a dead feature.
local function refreshManaUser()
    local ok, _, token = pcall(UnitPowerType, "player")
    if ok and type(token) == "string" then
        tracker.manaUser = (token == "MANA")
        return
    end
    ns.Log.Once("fsr:nopowertype",
        "the player's power type is not readable on this client; the window indicator will show for every class")
    tracker.manaUser = true
end

local function shouldRender()
    return (tracker.state == STATE.IN_FSR or tracker.state == STATE.TICKING)
        and tracker.manaUser == true
end

-- One SetPoint against the same anchor point, which replaces it rather than
-- stacking. No allocation in the update path. A withheld width skips that frame's
-- positioning: the line stays where it was for one frame.
local function positionMarker()
    local marker, bar = tracker.marker, tracker.markerBar
    if not marker or not bar then
        return
    end
    local kind, width = ClientRead.Call(bar.GetWidth, "number", bar)
    if kind ~= PLAIN then
        if kind == WITHHELD then
            bump(tracker.counters, "withheldBarGeometry")
        end
        return
    end
    if width <= 0 then
        return
    end
    marker:SetPoint("LEFT", bar, "LEFT", width * lineFraction(GetTime()), 0)
end

-- Patch 03 section 4.3. Plain false and Absent are out of combat; Withheld and a
-- failed call are Unread.
local function readCombat()
    local kind, inCombat = ClientRead.Call(UnitAffectingCombat, "boolean", "player")
    if kind == PLAIN then
        return inCombat == true and COMBAT.IN or COMBAT.OUT
    end
    if kind == ABSENT then
        return COMBAT.OUT
    end
    return COMBAT.UNREAD
end

local refreshVisibility

-- Ends a run of ticks (Patch 03 section 4.3): Regenerating, the line white again and
-- hidden, the clock cleared, the driver stopped by the visibility refresh, counted by
-- reason. A no-op outside Ticking. A cast's stop is the window's own start, not this.
local function stopTicks(reason)
    if tracker.state ~= STATE.TICKING then
        return
    end
    tracker.state = STATE.REGENERATING
    tracker.tickAnchor = 0
    tracker.tickLastCycle = 0
    bump(tracker.counters, "tickStops" .. reason)
    applyLineColour()
    refreshVisibility()
end

-- The backstop: once per tick, the fight is checked (section 4.3). Between boundaries
-- nothing is read, so the read is one per tick, never one per frame.
local function checkFightAtTick(now)
    local cycle = floor((now - tracker.tickAnchor) / TICK_PERIOD)
    if cycle <= tracker.tickLastCycle then
        return
    end
    tracker.tickLastCycle = cycle
    if readCombat() ~= COMBAT.IN then
        stopTicks(TICK_STOP.BACKSTOP)
    end
end

-- Runs while the window line is shown, and for as long as ticks run, shown or not
-- (audit finding 7): a non-mana form hides the line but never stops the backstop.
local function onUpdate()
    if tracker.state == STATE.TICKING then
        checkFightAtTick(GetTime())
        if tracker.state ~= STATE.TICKING then
            return
        end
    end
    if tracker.lineShown then
        positionMarker()
    end
end

function refreshVisibility()
    local marker = tracker.marker
    if not marker then
        return
    end

    -- About to show the line while ticking (a shift back into a mana form): the fight
    -- is checked first, so one that ended unannounced never flashes the gold line
    -- (audit finding 7). stopTicks refreshes again with the state no longer Ticking.
    if tracker.state == STATE.TICKING and shouldRender() and not tracker.lineShown
        and readCombat() ~= COMBAT.IN then
        stopTicks(TICK_STOP.BACKSTOP)
        return
    end

    local driverWanted = (tracker.state == STATE.TICKING) or shouldRender()
    if driverWanted then
        if not tracker.updating and tracker.driver then
            tracker.driver:SetScript("OnUpdate", onUpdate)
            tracker.updating = true
        end
    else
        if tracker.updating and tracker.driver then
            tracker.driver:SetScript("OnUpdate", nil)
        end
        tracker.updating = false
    end

    if shouldRender() then
        tracker.lineShown = true
        positionMarker()
        marker:Show()
        return
    end
    tracker.lineShown = false
    marker:Hide()
end

-- Window timer ---------------------------------------------------------------
-- A cancellable handle where the client offers one, and a generation guard as
-- the fallback, so the section 6.1 "zero running timers" post-condition holds
-- either way.

local onWindowTimer

local function cancelWindowTimer()
    if tracker.windowTimer and tracker.windowTimer.Cancel then
        tracker.windowTimer:Cancel()
    end
    tracker.windowTimer = nil
    tracker.timerGeneration = tracker.timerGeneration + 1
end

local function scheduleWindowEnd(delay)
    cancelWindowTimer()
    local generation = tracker.timerGeneration

    local function fire()
        if generation ~= tracker.timerGeneration then
            return
        end
        tracker.windowTimer = nil
        onWindowTimer()
    end

    if C_Timer and C_Timer.NewTimer then
        tracker.windowTimer = C_Timer.NewTimer(delay, fire)
    elseif C_Timer and C_Timer.After then
        C_Timer.After(delay, fire)
    end
end

local function clearWindow()
    cancelWindowTimer()
    tracker.state = STATE.REGENERATING
    tracker.windowStartedAt = 0
    tracker.windowEndsAt = 0
    tracker.tickAnchor = 0
    tracker.tickLastCycle = 0
end

-- What follows the window (Patch 03 section 4.3): Ticking, anchored at the window's
-- end, when ticks are on, the player uses mana and the fight is on; otherwise the
-- state stays Regenerating and the outcome is counted. One combat read at most.
local function onWindowEnd(anchor)
    if not tracker.showTicks then
        bump(tracker.counters, "ticksSkippedOff")
        return
    end
    if tracker.manaUser ~= true then
        bump(tracker.counters, "ticksSkippedNotManaUser")
        return
    end
    local combat = readCombat()
    if combat == COMBAT.UNREAD then
        bump(tracker.counters, "ticksSkippedCombatUnread")
        return
    end
    if combat ~= COMBAT.IN then
        bump(tracker.counters, "ticksSkippedOutOfCombat")
        return
    end
    tracker.state = STATE.TICKING
    tracker.tickAnchor = anchor
    tracker.tickLastCycle = 0
    bump(tracker.counters, "ticksStarted")
    applyLineColour()
end

function onWindowTimer()
    if tracker.state ~= STATE.IN_FSR then
        return
    end

    local remaining = tracker.windowEndsAt - GetTime()
    if remaining > 0 then
        scheduleWindowEnd(remaining + 0.02)
        return
    end

    local endedAt = tracker.windowEndsAt
    clearWindow()
    onWindowEnd(endedAt)
    refreshVisibility()
end

-- Signals --------------------------------------------------------------------

-- What a cast cost (section 2.3). Unknown carries its reason.
local CAST_COST = { COSTS_MANA = "CostsMana", FREE = "Free", UNKNOWN = "Unknown" }
local UNKNOWN_REASON = {
    API_MISSING = "ApiMissing",
    CALL_FAILED = "CallFailed",
    WITHHELD = "Withheld",
    ENTRY_UNREADABLE = "EntryUnreadable",
}
local MANA_ENTRY = { NOT_MANA = "NotMana", MANA = "Mana", UNREADABLE = "Unreadable" }

-- No real cost answer has more than a handful of entries; this only bounds the walk
-- if a client table answers every index.
local COST_ENTRY_LIMIT = 16

local function costLookup()
    return (C_Spell and C_Spell.GetSpellPowerCost) or _G.GetSpellPowerCost
end

-- One cost entry, field by field through ClientRead. Returns the kind and, for MANA,
-- whether any of its cost is above zero and whether it applies. Applicability is part
-- of the MANA test, so a hidden aura field is "could not tell", never "free" (audit
-- finding 3): a non-zero requiredAuraID needs hasRequiredAura to read Plain.
local function readManaEntry(entry)
    local typeKind, powerType = ClientRead.Field(entry, "type", "number")
    if typeKind == WITHHELD then
        return MANA_ENTRY.UNREADABLE
    end
    if typeKind ~= PLAIN or powerType ~= MANA then
        return MANA_ENTRY.NOT_MANA
    end
    local costKind, cost = ClientRead.Field(entry, "cost", "number")
    local perSecondKind, perSecond = ClientRead.Field(entry, "costPerSec", "number")
    local auraKind, auraId = ClientRead.Field(entry, "requiredAuraID", "number")
    if costKind == WITHHELD or perSecondKind == WITHHELD or auraKind == WITHHELD then
        return MANA_ENTRY.UNREADABLE
    end
    local applies = true
    if auraKind == PLAIN and auraId ~= 0 then
        local hasKind, has = ClientRead.Field(entry, "hasRequiredAura", "boolean")
        if hasKind ~= PLAIN then
            return MANA_ENTRY.UNREADABLE
        end
        applies = (has == true)
    end
    local positive = ((costKind == PLAIN) and cost > 0)
        or ((perSecondKind == PLAIN) and perSecond > 0)
    return MANA_ENTRY.MANA, positive, applies
end

-- Whether one successful player cast spent mana (section 2.3). Returns the cost and,
-- for Unknown, the reason. No cost value leaves this function.
local function classifyCastCost(spellId)
    local kind, costs = ClientRead.Call(costLookup(), "table", spellId)
    if kind == ABSENT then
        -- The documented answer for a spell with no resource cost.
        return CAST_COST.FREE
    end
    if kind ~= PLAIN then
        if costs == ClientRead.UNAVAILABLE then
            return CAST_COST.UNKNOWN, UNKNOWN_REASON.API_MISSING
        end
        if costs == ClientRead.CALL_FAILED then
            return CAST_COST.UNKNOWN, UNKNOWN_REASON.CALL_FAILED
        end
        return CAST_COST.UNKNOWN, UNKNOWN_REASON.WITHHELD
    end

    -- A table carrying type or cost at its top level is one entry, the shape the
    -- pre-Phase-20 code already tolerated; otherwise its array part.
    local topType = ClientRead.Field(costs, "type", "number")
    local topCost = ClientRead.Field(costs, "cost", "number")
    if topType ~= ABSENT or topCost ~= ABSENT then
        local entryKind, positive, applies = readManaEntry(costs)
        if entryKind == MANA_ENTRY.UNREADABLE then
            return CAST_COST.UNKNOWN, UNKNOWN_REASON.ENTRY_UNREADABLE
        end
        if entryKind == MANA_ENTRY.MANA and positive and applies then
            return CAST_COST.COSTS_MANA
        end
        return CAST_COST.FREE
    end

    for index = 1, COST_ENTRY_LIMIT do
        local slotKind, entry = ClientRead.Field(costs, index, "table")
        if slotKind == ABSENT then
            break
        end
        if slotKind ~= PLAIN then
            return CAST_COST.UNKNOWN, UNKNOWN_REASON.ENTRY_UNREADABLE
        end
        local entryKind, positive, applies = readManaEntry(entry)
        if entryKind == MANA_ENTRY.UNREADABLE then
            return CAST_COST.UNKNOWN, UNKNOWN_REASON.ENTRY_UNREADABLE
        end
        if entryKind == MANA_ENTRY.MANA and positive and applies then
            return CAST_COST.COSTS_MANA
        end
    end
    return CAST_COST.FREE
end

local function startWindow(now)
    -- Patch 03 section 4.2: a cast during ticks restarts the window, and the line turns
    -- white again. The tick clock goes with it; the window's end re-anchors it.
    if tracker.state == STATE.TICKING then
        bump(tracker.counters, "tickStops" .. TICK_STOP.CAST)
        tracker.tickAnchor = 0
        tracker.tickLastCycle = 0
    end
    tracker.state = STATE.IN_FSR
    tracker.windowStartedAt = now
    tracker.windowEndsAt = now + FSR_WINDOW
    scheduleWindowEnd(FSR_WINDOW + 0.02)
    applyLineColour()
    refreshVisibility()
end

-- UNIT_SPELLCAST_SUCCEEDED is SecretWhenUnitSpellCastRestricted: individual spells
-- can be flagged always secret, even for the player. A withheld unit is not the
-- player's. A spell id that is not Plain -- withheld or missing -- restarts the
-- window, as a cost the client will not report does, and is counted (section 2.4).
--
-- Unknown restarts the window too: a line on a cast that was free is a cosmetic
-- error, and no line on a mana user is a dead feature. What changed in Phase 20 is
-- that Free now means free.
local function onSpellcastSucceeded(unit, _, spellId)
    local unitKind, unitToken = ClientRead.Classify(unit, "string")
    if unitKind ~= PLAIN or unitToken ~= "player" then
        return
    end

    local spellKind, spell = ClientRead.Classify(spellId, "number")
    if spellKind ~= PLAIN then
        bump(tracker.counters, "withheldSpellIds")
        startWindow(GetTime())
        return
    end

    local cost, reason = classifyCastCost(spell)
    if cost == CAST_COST.FREE then
        bump(tracker.counters, "castsFree")
        tracker.costQueryable = true
        return
    end
    if cost == CAST_COST.UNKNOWN then
        bump(tracker.counters, "castsCostUnknown")
        tracker.lastUnknownReason = reason
        -- A missing lookup is a standing client fact; a per-cast failure is not.
        tracker.costQueryable = (reason ~= UNKNOWN_REASON.API_MISSING)
        startWindow(GetTime())
        return
    end
    bump(tracker.counters, "castsCostingMana")
    tracker.costQueryable = true
    startWindow(GetTime())
end

local function onDisplayPower(unit)
    if unit ~= nil and unit ~= "player" then
        return
    end
    refreshManaUser()
    refreshVisibility()
end

local function onEnteringWorld()
    -- Conservative: do not carry a window across a loading screen. A stale
    -- window shows the line after regen has already resumed, which is a
    -- confidently wrong reading; dropping it merely under-reports once.
    if tracker.state == STATE.TICKING then
        bump(tracker.counters, "tickStops" .. TICK_STOP.LOADING_SCREEN)
    end
    clearWindow()
    applyLineColour()
    refreshManaUser()
    refreshVisibility()
end

-- Patch 03 section 4.5: the fight ended. SynchronousEvent, so this changes only our
-- own state and hides only our own texture, as onEnteringWorld does.
local function onRegenEnabled()
    stopTicks(TICK_STOP.FIGHT_ENDED)
end

-- What each signal costs us if this client will not deliver it. The one
-- required signal is the feature; the rest degrade it, loudly and specifically.
local SIGNALS = {
    { event = "UNIT_SPELLCAST_SUCCEEDED", handler = onSpellcastSucceeded, required = true,
      lost = "the five-second window cannot be detected at all" },
    { event = "UNIT_DISPLAYPOWER", handler = onDisplayPower, required = false,
      lost = "the indicator will not follow a form or power-type change" },
    { event = "PLAYER_ENTERING_WORLD", handler = onEnteringWorld, required = false,
      lost = "a running window will not be cleared after a loading screen" },
    { event = "PLAYER_REGEN_ENABLED", handler = onRegenEnabled, required = false,
      lost = "regen ticks will end at the next tick's check rather than when the fight ends" },
}

-- Lifecycle ------------------------------------------------------------------

-- A malformed or missing colour takes the default rather than ConfigSchema.HexToRgb's
-- white, which would look like the window line.
local function tickColourFrom(hex)
    if type(hex) ~= "string" or #hex ~= 6 or not tonumber(hex, 16) then
        hex = TICK_COLOUR_DEFAULT
    end
    local red, green, blue = ns.ConfigSchema.HexToRgb(hex)
    return { red = red, green = green, blue = blue }
end

local function readSettings(config)
    local settings = config and config.settings
    if not settings then
        return
    end
    tracker.lineWidth = settings.lineWidth or tracker.lineWidth
    tracker.lineAlpha = settings.lineAlpha or tracker.lineAlpha
    tracker.showTicks = (settings.showTicks ~= false)
    tracker.tickColour = tickColourFrom(settings.tickColour)
end

local function enable(config)
    readSettings(config)
    tracker.counters = ns.Diagnostics.CountersFor(FEATURE_ID)

    if not ensureMarker() then
        return nil, "the player mana bar was not found; cannot anchor the window indicator"
    end
    applyAppearance()

    tracker.driver = tracker.driver or CreateFrame("Frame")
    clearWindow()
    refreshManaUser()

    local tokens = tracker.tokens
    for index = 1, #SIGNALS do
        local signal = SIGNALS[index]
        local token = ns.Dispatch.Subscribe(FEATURE_ID, signal.event, signal.handler)
        if token then
            tokens[#tokens + 1] = token
        elseif signal.required then
            return nil, format("this client does not deliver %s, so %s",
                signal.event, signal.lost)
        else
            ns.Log.Once("fsr:missing:" .. signal.event, format(
                "%s is unavailable on this client; %s", signal.event, signal.lost))
        end
    end

    refreshVisibility()
    return true
end

-- Every step is guarded: disable is invoked to clean up after a failed enable,
-- which may not have got as far as creating the driver (section 6.1).
local function disable()
    cancelWindowTimer()

    if tracker.driver then
        tracker.driver:SetScript("OnUpdate", nil)
    end
    tracker.updating = false

    if tracker.marker then
        tracker.marker:Hide()
    end
    tracker.lineShown = false

    for index = #tracker.tokens, 1, -1 do
        ns.Dispatch.Unsubscribe(tracker.tokens[index])
        tracker.tokens[index] = nil
    end

    -- Patch 03 section 4.3: the ticks are reset with the window, uncounted (audit
    -- finding 6).
    tracker.state = STATE.REGENERATING
    tracker.windowStartedAt = 0
    tracker.windowEndsAt = 0
    tracker.tickAnchor = 0
    tracker.tickLastCycle = 0
end

local function onConfigChanged(config, changedKey)
    readSettings(config)
    if changedKey == "lineWidth" or changedKey == "lineAlpha" then
        applyAppearance()
        refreshVisibility()
    elseif changedKey == "showTicks" then
        -- Patch 03 section 4.6: off ends a running set at once; on waits for a window.
        if not tracker.showTicks then
            stopTicks(TICK_STOP.SWITCHED_OFF)
        end
    elseif changedKey == "tickColour" then
        applyLineColour()
    end
    return ns.CONFIG_RESULT.APPLIED
end

ns.Registry.Register(FEATURE_ID, {
    enabledByDefault = true,
    label = "Five-second rule indicator",
    description = "A line that sweeps across your mana bar while the five-second rule is running, then keeps a two-second regen rhythm while you fight.",
    settingsPage = ns.SETTINGS_PAGE.COMBAT,
    settingsOrder = 10,
    settings = {
        lineWidth = 2,
        lineAlpha = 0.9,
        -- Patch 03 section 8.2 (D6).
        showTicks = true,
        tickColour = TICK_COLOUR_DEFAULT,
    },
    schema = {
        lineWidth = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Line width", order = 1,
            unit = ns.ConfigSchema.UNIT.PIXELS,
            description = "Thickness of the sweeping line, in pixels.",
            minimum = 1, maximum = 6, step = 1,
        },
        lineAlpha = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Line opacity", order = 2,
            unit = ns.ConfigSchema.UNIT.FRACTION,
            description = "How solid the line is.",
            minimum = 0.1, maximum = 1.0, step = 0.05,
        },
        -- Patch 03 section 8.2: no group, so both follow "Line opacity" under the
        -- feature's own switch.
        showTicks = {
            kind = ns.ConfigSchema.KIND.TOGGLE, label = "Show regen ticks", order = 3,
            description = "After the five-second window, a gold line keeps WoW Classic's two-second regen rhythm until your next mana-costing cast or the end of the fight. A rhythm for the Classic habit, not the game's own ticks.",
        },
        tickColour = {
            kind = ns.ConfigSchema.KIND.COLOUR, label = "Tick line colour", order = 4,
        },
    },
}, {
    enable = enable,
    disable = disable,
    onConfigChanged = onConfigChanged,
})

-- Read-only view for /pa fsr.
ns.FiveSecondRule = {
    Inspect = function()
        local now = GetTime()
        return {
            state = tracker.state,
            visible = (tracker.marker ~= nil and tracker.marker:IsShown()) or false,
            elapsedFraction = windowElapsedFraction(now),
            windowRemaining = max(0, tracker.windowEndsAt - now),
            manaUser = tracker.manaUser,
            costQueryable = tracker.costQueryable,
            lastUnknownReason = tracker.lastUnknownReason,
            withheldSpellIds = tracker.counters.withheldSpellIds or 0,
            withheldBarGeometry = tracker.counters.withheldBarGeometry or 0,
            castsCostingMana = tracker.counters.castsCostingMana or 0,
            castsFree = tracker.counters.castsFree or 0,
            castsCostUnknown = tracker.counters.castsCostUnknown or 0,
            windowStartedAt = tracker.windowStartedAt,
            -- Patch 03 section 9. tickFraction is 0 unless the state is Ticking.
            tickFraction = tickFraction(now),
            tickAnchor = tracker.tickAnchor,
            showTicks = tracker.showTicks,
            lineShown = tracker.lineShown,
            driverRunning = (tracker.driver ~= nil and tracker.driver:GetScript("OnUpdate") ~= nil),
            counters = tracker.counters,
        }
    end,
}
