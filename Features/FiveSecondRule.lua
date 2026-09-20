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

local ADDON_NAME, ns = ...

local FEATURE_ID = "fiveSecondRule"

local format, max = string.format, math.max
local STATE = ns.TRACKER_STATE
local MANA = ns.POWER_TYPE_MANA
local FSR_WINDOW = ns.FSR_WINDOW

local tracker = {
    state = STATE.REGENERATING,
    windowStartedAt = 0,
    windowEndsAt = 0,
    tokens = {},
    marker = nil,
    markerBar = nil,
    driver = nil,
    updating = false,
    windowTimer = nil,
    timerGeneration = 0,
    manaUser = true,
    costQueryable = nil,
    lineWidth = 2,
    lineAlpha = 0.9,
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
    if tracker.markerBar then
        local height = tracker.markerBar:GetHeight()
        if height and height > 0 then
            marker:SetHeight(height)
        end
    end
    marker:SetAlpha(tracker.lineAlpha)
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
    return tracker.state == STATE.IN_FSR and tracker.manaUser == true
end

-- One SetPoint against the same anchor point, which replaces it rather than
-- stacking. No allocation in the update path.
local function positionMarker()
    local marker, bar = tracker.marker, tracker.markerBar
    if not marker or not bar then
        return
    end
    local width = bar:GetWidth()
    if not width or width <= 0 then
        return
    end
    marker:SetPoint("LEFT", bar, "LEFT", width * windowElapsedFraction(GetTime()), 0)
end

local function onUpdate()
    positionMarker()
end

local function refreshVisibility()
    local marker = tracker.marker
    if not marker then
        return
    end

    if shouldRender() then
        if not tracker.updating and tracker.driver then
            tracker.driver:SetScript("OnUpdate", onUpdate)
            tracker.updating = true
        end
        positionMarker()
        marker:Show()
        return
    end

    if tracker.updating and tracker.driver then
        tracker.driver:SetScript("OnUpdate", nil)
    end
    tracker.updating = false
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

    clearWindow()
    refreshVisibility()
end

-- Signals --------------------------------------------------------------------

-- Returns 1 when the cast cost mana, 0 when it did not, or nil when this client
-- will not say. The whole lookup is protected because the cost may itself be a
-- restricted value, and only the predicate is returned so a protected number
-- never escapes this function.
local function costsMana(spellId)
    local getCosts = (C_Spell and C_Spell.GetSpellPowerCost) or _G.GetSpellPowerCost
    if not getCosts then
        return nil
    end

    local ok, predicate = pcall(function()
        local costs = getCosts(spellId)
        if type(costs) ~= "table" then
            return nil
        end
        if costs.type ~= nil or costs.cost ~= nil then
            costs = { costs }
        end
        for index = 1, #costs do
            local entry = costs[index]
            if entry and entry.type == MANA then
                return ((entry.cost or 0) > 0) and 1 or 0
            end
        end
        return 0
    end)

    if not ok then
        return nil
    end
    return predicate
end

local function startWindow(now)
    tracker.state = STATE.IN_FSR
    tracker.windowStartedAt = now
    tracker.windowEndsAt = now + FSR_WINDOW
    scheduleWindowEnd(FSR_WINDOW + 0.02)
    refreshVisibility()
end

local function onSpellcastSucceeded(unit, _, spellId)
    if unit ~= "player" then
        return
    end

    local predicate = costsMana(spellId)
    if predicate == nil then
        tracker.costQueryable = false
        ns.Log.Once("fsr:nocostapi",
            "spell mana cost is not queryable on this client, so every successful cast opens the window; a free cast will show a window that is not really running")
        predicate = 1
    else
        tracker.costQueryable = true
    end

    if predicate > 0 then
        startWindow(GetTime())
    end
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
    clearWindow()
    refreshManaUser()
    refreshVisibility()
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
}

-- Lifecycle ------------------------------------------------------------------

local function readSettings(config)
    local settings = config and config.settings
    if not settings then
        return
    end
    tracker.lineWidth = settings.lineWidth or tracker.lineWidth
    tracker.lineAlpha = settings.lineAlpha or tracker.lineAlpha
end

local function enable(config)
    readSettings(config)

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

    for index = #tracker.tokens, 1, -1 do
        ns.Dispatch.Unsubscribe(tracker.tokens[index])
        tracker.tokens[index] = nil
    end

    tracker.state = STATE.REGENERATING
    tracker.windowStartedAt = 0
    tracker.windowEndsAt = 0
end

local function onConfigChanged(config, changedKey)
    readSettings(config)
    if changedKey == "lineWidth" or changedKey == "lineAlpha" then
        applyAppearance()
        refreshVisibility()
    end
    return ns.CONFIG_RESULT.APPLIED
end

ns.Registry.Register(FEATURE_ID, {
    enabledByDefault = true,
    label = "Five-second rule indicator",
    description = "A line that sweeps across your mana bar while the five-second rule is running.",
    settings = {
        lineWidth = 2,
        lineAlpha = 0.9,
    },
    schema = {
        lineWidth = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Line width",
            description = "Thickness of the sweeping line, in pixels.",
            minimum = 1, maximum = 6, step = 1,
        },
        lineAlpha = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Line opacity",
            description = "How solid the line is.",
            minimum = 0.1, maximum = 1.0, step = 0.05,
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
        }
    end,
}
