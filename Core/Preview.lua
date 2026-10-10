-- Core/Preview.lua
-- This addon's windows on screen with sample contents, so their settings can be
-- adjusted and the result seen at once (Phase 13 section 2).
--
-- TWO TABLES WITH DIFFERENT LIFETIMES. `WINDOWS` is static: it names the four
-- windows, the place on screen each is drawn in, and the feature that owns it.
-- A REGISTRATION is transient -- a feature adds one at its enable and drops it
-- at its disable, because the frames a registration points at are built at
-- enable. So "known" and "registered" are different questions, and both are
-- answered: a window whose feature is off is reported with its registry state
-- rather than left out of the report, which is the difference between "it is
-- off" and "it is broken".
--
-- WHAT THIS MODULE NEVER DOES. It reads no client value, and it touches no
-- Blizzard frame: raising a window's strata is a write to one of ours. It never
-- observes Blizzard's Options window closing -- which is the whole reason the
-- preview survives that close instead of ending with it, and what keeps the
-- feature clear of rule 8.

local ADDON_NAME, ns = ...

local Preview = {}
ns.Preview = Preview

local type, pairs, pcall, tonumber, format = type, pairs, pcall, tonumber, string.format
local sort = table.sort

local PANEL = ns.PREVIEW_PANEL
local GROUP = ns.PREVIEW_GROUP

Preview.STATE = { OFF = "Off", ON = "On" }
Preview.OUTCOME = { SHOWN = "Shown", DEFERRED = "Deferred", SKIPPED = "Skipped" }
-- A standing distinct from every FEATURE_STATE: the feature is not in the
-- registry at all, which is a different fault from being disabled.
Preview.NOT_REGISTERED = "NotRegistered"

local STATE = Preview.STATE
local OUTCOME = Preview.OUTCOME

local COMBAT_EVENT = "PLAYER_REGEN_DISABLED"
-- Preview is substrate, not a registered feature, so it subscribes under its own
-- name. Dispatch asks only for a non-empty string.
local SUBSCRIBER_ID = "preview"

-- `order` breaks the tie in section 2.5's fallback for a group holding more than
-- one window. It is DECLARED rather than derived from registration order, so
-- which feature enabled first cannot change which window stands in.
local WINDOWS = {
    [PANEL.THREAT_PANEL] =
        { group = GROUP.PLAYER_FRAME, featureId = "threatPanel", order = 1 },
    [PANEL.DAMAGE_BREAKDOWN] =
        { group = GROUP.PLAYER_FRAME, featureId = "damageBreakdown", order = 2 },
    [PANEL.EQUIPPED_SKILLS] =
        { group = GROUP.BAGS, featureId = "equippedSkills", order = 1 },
    [PANEL.TOASTS] =
        { group = GROUP.SCREEN, featureId = "toasts", order = 1 },
}

-- The order SetEnabled and /pa preview report in.
local WINDOW_ORDER = {
    PANEL.THREAT_PANEL,
    PANEL.DAMAGE_BREAKDOWN,
    PANEL.EQUIPPED_SKILLS,
    PANEL.TOASTS,
}

local GROUP_MEMBERS = {}
for index = 1, #WINDOW_ORDER do
    local panelId = WINDOW_ORDER[index]
    local group = WINDOWS[panelId].group
    GROUP_MEMBERS[group] = GROUP_MEMBERS[group] or {}
    local members = GROUP_MEMBERS[group]
    members[#members + 1] = panelId
end
for _, members in pairs(GROUP_MEMBERS) do
    sort(members, function(left, right)
        return WINDOWS[left].order < WINDOWS[right].order
    end)
end

local state = {
    enabled = false,
    registrations = {},
    raised = {},
    focus = {},
    outcomes = {},
    observer = nil,
    token = nil,
    refusal = nil,
}

state.focus[GROUP.PLAYER_FRAME] = ns.PREVIEW_INITIAL_FOCUS
state.focus[GROUP.BAGS] = PANEL.EQUIPPED_SKILLS
state.focus[GROUP.SCREEN] = PANEL.TOASTS

-- Reporting -------------------------------------------------------------------

local function record(panelId, kind, detail, rowsDrawn)
    state.outcomes[panelId] = {
        panelId = panelId,
        kind = kind,
        detail = detail,
        rowsDrawn = rowsDrawn,
    }
end

-- Why a known window holds no registration. A feature absent from the registry
-- is NOT_REGISTERED; one that is there reports its own state, which tells a
-- disabled feature from a faulted one.
local function standingOf(featureId)
    if not ns.Registry.Exists(featureId) then
        return Preview.NOT_REGISTERED
    end
    return (ns.Registry.State(featureId)) or Preview.NOT_REGISTERED
end

-- Subject ---------------------------------------------------------------------

-- The window a group shows, which is not always the focused one (section 2.5).
-- The focus is the user's last stated intent; a feature being off is not a
-- statement about intent, so a sibling stands in and the focus does not move.
local function groupSubject(group)
    local focused = state.focus[group]
    if focused and state.registrations[focused] then
        return focused
    end
    local members = GROUP_MEMBERS[group] or {}
    for index = 1, #members do
        if state.registrations[members[index]] then
            return members[index]
        end
    end
    return nil
end

-- Showing and clearing --------------------------------------------------------

local function showWindow(panelId)
    local registration = state.registrations[panelId]
    if not registration then
        return nil
    end

    if not state.raised[panelId] then
        if not ns.PanelChrome.Raise(registration.raiseTarget) then
            record(panelId, OUTCOME.SKIPPED, "the client refused to raise it")
            return nil
        end
        state.raised[panelId] = true
    end

    local ok, rowsDrawn = pcall(registration.show)
    if not ok then
        record(panelId, OUTCOME.SKIPPED, "its sample contents raised")
        return nil
    end
    record(panelId, OUTCOME.SHOWN, nil, tonumber(rowsDrawn) or 0)
    return rowsDrawn
end

-- clear() runs whether or not the window was raised, so a feature that drew
-- something outside the preview's knowledge still gets told to stop.
local function clearWindow(panelId)
    local registration = state.registrations[panelId]
    if not registration then
        state.raised[panelId] = nil
        return
    end
    pcall(registration.clear)
    if state.raised[panelId] then
        ns.PanelChrome.Restore(registration.raiseTarget, registration.baseStrata)
        state.raised[panelId] = nil
    end
end

-- Brings one group to its subject: the subject shown, every other member of the
-- group cleared and reported. Called whenever the subject could have changed --
-- a focus change, a registration, an unregistration.
local function applyGroup(group)
    local subject = groupSubject(group)
    local members = GROUP_MEMBERS[group] or {}
    for index = 1, #members do
        local panelId = members[index]
        if not state.registrations[panelId] then
            -- No detail: a standing captured here can be stale by the time it is
            -- read. Registry.SetEnabled runs the feature's disable -- which
            -- unregisters -- BEFORE it writes the new state, so a standing taken
            -- now would still say ENABLED. It is resolved when reported instead.
            record(panelId, OUTCOME.SKIPPED, nil)
        elseif panelId ~= subject then
            if state.raised[panelId] then
                clearWindow(panelId)
            end
            record(panelId, OUTCOME.DEFERRED, subject)
        else
            showWindow(panelId)
        end
    end
end

-- Combat ----------------------------------------------------------------------

local function onCombatStart()
    if not state.enabled then
        return
    end
    Preview.SetEnabled(false)
    ns.Log.Info("the preview ended because a fight started")
end

-- Subscribed on the first SetEnabled(true) and kept for the UI load. A preview
-- that could not hear a fight start would cover the real threat panel with
-- sample rows, so the subscription failing refuses the preview rather than
-- running without it.
local function ensureCombatSubscription()
    if state.token then
        return true
    end
    local token = ns.Dispatch.Subscribe(SUBSCRIBER_ID, COMBAT_EVENT, onCombatStart)
    if not token then
        state.refusal = format(
            "this client does not deliver %s, so the preview cannot end when a fight starts and will not run",
            COMBAT_EVENT)
        ns.Log.OnceError("preview:nocombat", state.refusal)
        return false
    end
    state.token = token
    state.refusal = nil
    return true
end

-- Observer --------------------------------------------------------------------

local function notifyObserver()
    local observer = state.observer
    if type(observer) ~= "function" then
        return
    end
    pcall(observer, state.enabled and STATE.ON or STATE.OFF)
end

-- Public ----------------------------------------------------------------------

function Preview.IsEnabled()
    return state.enabled
end

function Preview.SetEnabled(wanted)
    wanted = (wanted == true)

    if wanted == state.enabled then
        return Preview.Outcomes()
    end

    if wanted then
        if not ensureCombatSubscription() then
            return {}
        end
        state.enabled = true
        state.outcomes = {}
        for group in pairs(GROUP_MEMBERS) do
            applyGroup(group)
        end
    else
        state.enabled = false
        for index = 1, #WINDOW_ORDER do
            clearWindow(WINDOW_ORDER[index])
        end
        state.outcomes = {}
    end

    notifyObserver()
    return Preview.Outcomes()
end

function Preview.Focus(panelId)
    local window = WINDOWS[panelId]
    if not window then
        return
    end
    if state.focus[window.group] == panelId then
        return
    end
    state.focus[window.group] = panelId
    if state.enabled then
        applyGroup(window.group)
    end
end

function Preview.Register(registration)
    if type(registration) ~= "table" then
        return
    end
    local panelId = registration.panelId
    local window = WINDOWS[panelId]
    if not window then
        ns.Log.OnceError("preview:unknown:" .. tostring(panelId), format(
            "the preview was offered a window it does not know (%s); it is ignored",
            tostring(panelId)))
        return
    end
    if type(registration.show) ~= "function" or type(registration.clear) ~= "function" then
        ns.Log.OnceError("preview:incomplete:" .. tostring(panelId), format(
            "%s offered the preview no sample contents; it is ignored", tostring(panelId)))
        return
    end

    state.registrations[panelId] = {
        panelId = panelId,
        raiseTarget = registration.raiseTarget,
        baseStrata = registration.baseStrata,
        show = registration.show,
        clear = registration.clear,
    }

    if state.enabled then
        applyGroup(window.group)
    end
end

function Preview.Unregister(panelId)
    local window = WINDOWS[panelId]
    if not window then
        return
    end
    if state.registrations[panelId] then
        clearWindow(panelId)
        state.registrations[panelId] = nil
    end
    state.outcomes[panelId] = nil
    if state.enabled then
        applyGroup(window.group)
    end
end

function Preview.SetStateObserver(observer)
    if observer ~= nil and type(observer) ~= "function" then
        return
    end
    state.observer = observer
end

-- One record per KNOWN window, in static-table order, so a window that is off or
-- standing aside is listed with its reason rather than missing.
-- A Skipped window's standing is read HERE, not when the outcome was recorded,
-- because it can change in between (see applyGroup).
local function resolved(outcome)
    if outcome.kind == OUTCOME.SKIPPED and outcome.detail == nil then
        return {
            panelId = outcome.panelId,
            kind = outcome.kind,
            detail = standingOf(WINDOWS[outcome.panelId].featureId),
            rowsDrawn = outcome.rowsDrawn,
        }
    end
    return outcome
end

function Preview.Outcomes()
    local outcomes = {}
    for index = 1, #WINDOW_ORDER do
        local panelId = WINDOW_ORDER[index]
        local outcome = state.outcomes[panelId]
        if outcome then
            outcomes[#outcomes + 1] = resolved(outcome)
        end
    end
    return outcomes
end

function Preview.Inspect()
    local focus, subject = {}, {}
    for group in pairs(GROUP_MEMBERS) do
        focus[group] = state.focus[group]
        subject[group] = groupSubject(group)
    end

    local windows = {}
    for index = 1, #WINDOW_ORDER do
        local panelId = WINDOW_ORDER[index]
        local outcome = state.outcomes[panelId]
        if outcome then
            outcome = resolved(outcome)
        end
        windows[index] = {
            panelId = panelId,
            group = WINDOWS[panelId].group,
            registered = state.registrations[panelId] ~= nil,
            raised = state.raised[panelId] == true,
            kind = outcome and outcome.kind or nil,
            detail = outcome and outcome.detail or nil,
            rowsDrawn = outcome and outcome.rowsDrawn or nil,
            standing = standingOf(WINDOWS[panelId].featureId),
        }
    end

    return {
        state = state.enabled and STATE.ON or STATE.OFF,
        focus = focus,
        subject = subject,
        windows = windows,
        refusal = state.refusal,
        observing = state.observer ~= nil,
    }
end

-- The group a window belongs to, for callers that need to name one.
function Preview.GroupOf(panelId)
    local window = WINDOWS[panelId]
    return window and window.group or nil
end

-- The window a feature owns, or nil for a feature that owns none.
function Preview.PanelForFeature(featureId)
    for panelId, window in pairs(WINDOWS) do
        if window.featureId == featureId then
            return panelId
        end
    end
    return nil
end

-- Focus by featureId, which is what the settings panel has to hand. A feature
-- that owns no window is ignored, so every other key costs one lookup.
function Preview.FocusFeature(featureId)
    local panelId = Preview.PanelForFeature(featureId)
    if panelId then
        Preview.Focus(panelId)
    end
end
