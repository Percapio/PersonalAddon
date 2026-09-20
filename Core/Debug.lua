-- Core/Debug.lua
-- The Phase 1 stand-in for the Phase 6 options panel (§2), plus the two probe
-- features the exit criteria need in order to be testable at all.
--
-- Debug is substrate, not a feature: it is always on, because it is the only way
-- to toggle anything before the panel exists.

local ADDON_NAME, ns = ...

local Debug = {}
ns.Debug = Debug

local format, tostring, tonumber = string.format, tostring, tonumber
local RESULT = ns.CONFIG_RESULT

-- Probe features ------------------------------------------------------------

local FAULT_PROBE_ID = "faultProbe"
local ENABLE_FAIL_PROBE_ID = "enableFailProbe"

local faultProbe = { armed = false, tokens = {} }

-- Subscribes to the same event the FSR tracker uses, so faulting it
-- demonstrates the property exit criterion 3 asks about: one feature dies, the
-- other keeps running.
-- Kept rather than deleted with the spikes: forty lines, and the only way to
-- verify Phase 1 section 6.1's isolation contract against the live client, which
-- is exactly what a future client patch would quietly break.
ns.Registry.Register(FAULT_PROBE_ID, {
    enabledByDefault = false,
    internal = true,
    settings = {},
}, {
    enable = function()
        local tokens = faultProbe.tokens
        tokens[#tokens + 1] = ns.Dispatch.Subscribe(FAULT_PROBE_ID,
            "UNIT_SPELLCAST_SUCCEEDED", function(unit)
                if unit ~= "player" or not faultProbe.armed then
                    return
                end
                faultProbe.armed = false
                error("deliberate fault from " .. FAULT_PROBE_ID)
            end)
        return true
    end,
    disable = function()
        for index = #faultProbe.tokens, 1, -1 do
            ns.Dispatch.Unsubscribe(faultProbe.tokens[index])
            faultProbe.tokens[index] = nil
        end
        faultProbe.armed = false
    end,
    onConfigChanged = function()
        return RESULT.APPLIED
    end,
})

ns.Registry.Register(ENABLE_FAIL_PROBE_ID, {
    enabledByDefault = false,
    internal = true,
    settings = {},
}, {
    enable = function()
        return nil, "deliberate enable failure for exit criterion 4"
    end,
    disable = function()
    end,
    onConfigChanged = function()
        return RESULT.APPLIED
    end,
})

-- Commands ------------------------------------------------------------------

local function reportConfigResult(featureId, key, outcome, detail)
    if outcome == RESULT.RELOAD_REQUIRED then
        ns.Log.Warn(format("%s.%s stored; a reload is needed to apply it (%s)",
            featureId, tostring(key), tostring(detail)))
    else
        ns.Log.Info(format("%s.%s applied", featureId, tostring(key)))
    end
end

local function commandStatus(showAll)
    local failure = ns.Registry.StoreFailure()
    if failure then
        ns.Log.Error(format("config store unusable: %s at v%s",
            tostring(failure.reason), tostring(failure.version)))
    else
        ns.Log.Info(format("schema v%s, xpcall forwards args: %s",
            tostring(ns.ConfigStore.SchemaVersion()),
            tostring(ns.Isolation.ForwardsArguments())))
    end

    local ids = showAll and ns.Registry.Ids() or ns.Registry.PublicIds()
    local hidden = #ns.Registry.Ids() - #ids
    for index = 1, #ids do
        local id = ids[index]
        local state, reason = ns.Registry.State(id)
        ns.Log.Info(format("  %-18s %-10s stored=%s subs=%d%s",
            id,
            tostring(state),
            tostring(ns.ConfigStore.IsEnabled(id)),
            ns.Dispatch.SubscriptionCount(id),
            reason and (" reason=" .. tostring(reason)) or ""))
    end
    if hidden > 0 then
        ns.Log.Info(format("  %d internal feature(s) hidden; /pa status all shows them", hidden))
    end
end

local function commandSetEnabled(featureId, enabled)
    if not featureId or not ns.Registry.Exists(featureId) then
        ns.Log.Error("unknown feature: " .. tostring(featureId))
        return
    end
    local ok, detail = ns.Registry.SetEnabled(featureId, enabled)
    local state = ns.Registry.State(featureId)
    if ok then
        ns.Log.Info(format("%s -> %s%s", featureId, tostring(state),
            detail and (" (" .. tostring(detail) .. ")") or ""))
    else
        ns.Log.Error(format("%s -> %s: %s", featureId, tostring(state), tostring(detail)))
    end
end

local function commandGet(featureId)
    if not featureId or not ns.Registry.Exists(featureId) then
        ns.Log.Error("unknown feature: " .. tostring(featureId))
        return
    end
    local keys = ns.ConfigStore.DeclaredKeys(featureId)
    if #keys == 0 then
        ns.Log.Info(featureId .. " declares no settings")
        return
    end
    for index = 1, #keys do
        local key = keys[index]
        ns.Log.Info(format("  %s.%s = %s", featureId, key,
            tostring(ns.ConfigStore.Get(featureId, key))))
    end
end

local function commandSet(featureId, key, rawValue)
    if not featureId or not key or rawValue == nil then
        ns.Log.Error("usage: /pa set <feature> <key> <value>")
        return
    end

    local current = ns.ConfigStore.Get(featureId, key)
    if current == nil then
        ns.Log.Error(format("'%s' declares no key '%s'", featureId, key))
        return
    end

    local value
    if type(current) == "number" then
        value = tonumber(rawValue)
        if value == nil then
            ns.Log.Error(key .. " expects a number")
            return
        end
    elseif type(current) == "boolean" then
        if rawValue == "true" then
            value = true
        elseif rawValue == "false" then
            value = false
        else
            ns.Log.Error(key .. " expects true or false")
            return
        end
    else
        value = rawValue
    end

    local ok, reason = ns.ConfigStore.Set(featureId, key, value)
    if not ok then
        ns.Log.Error(tostring(reason))
        return
    end

    local outcome, detail = ns.Registry.NotifyConfigChanged(featureId, key)
    reportConfigResult(featureId, key, outcome, detail)
end

local function commandFsr()
    if not ns.FiveSecondRule then
        ns.Log.Error("the FSR tracker did not load")
        return
    end
    local view = ns.FiveSecondRule.Inspect()
    ns.Log.Info(format("state=%s visible=%s remaining=%.2fs elapsed=%d%% manaUser=%s",
        tostring(view.state), tostring(view.visible), view.windowRemaining,
        view.elapsedFraction * 100, tostring(view.manaUser)))
    if view.costQueryable == false then
        ns.Log.Warn("  spell mana cost is not queryable on this client, so EVERY successful")
        ns.Log.Warn("  cast opens the window; a free cast shows a window that is not running")
    end
end

local function commandPlates()
    if not ns.Nameplates then
        ns.Log.Error("the nameplate feature did not load")
        return
    end
    local view = ns.Nameplates.Inspect()
    ns.Log.Info(format("tracked=%d inScope=%d outOfScope=%d unreachable=%d coloured=%d sweeps=%d",
        view.tracked, view.inScope, view.outOfScope, view.unreachable,
        view.coloured, view.sweeps))
    ns.Log.Info(format("  ledger: widgets=%d restored=%d widgetGone=%d writeRefused=%d",
        view.ledgerWidgets, view.ledgerRestored, view.ledgerWidgetGone,
        view.ledgerWriteRefused))
    ns.Log.Info(format("  capability: barRecolourable=%s hook=%s",
        tostring(view.barRecolourable), tostring(view.hookInstalled)))
    if not view.colouringActive then
        ns.Log.Warn("  aggro colouring is OFF")
    elseif not view.aggroResolvedEver then
        ns.Log.Warn("  colouring is on but no nameplate target has ever resolved")
    end
end

local function commandDps()
    if not ns.DamageBreakdown then
        ns.Log.Error("the damage breakdown feature did not load")
        return
    end
    ns.DamageBreakdown.Refresh()
    local view = ns.DamageBreakdown.Inspect()
    ns.Log.Info(format("session=%s rows=%d/%d truncated=%d panel=%s inCombat=%s",
        view.sessionType, view.rowsShown, view.maximumRows, view.truncatedRows,
        tostring(view.panelShown), tostring(view.inCombat)))
    ns.Log.Info(format("  total=%d over %ds  (compare this against the built-in meter)",
        view.totalAmount, view.durationSeconds))
    ns.Log.Info(format("  icons=%s border=%s anchor=%s settlePending=%d",
        tostring(view.iconsAvailable), tostring(view.borderStyle),
        view.anchorIsPlayerFrame and "PlayerFrame" or "screen",
        view.settlePending))
    ns.Log.Info(format("  ticker=%s pool=%d live / %d free / %d cap",
        tostring(view.refreshTickerRunning),
        view.poolLive, view.poolFree, view.poolCapacity))
end

local function commandPanel()
    if not ns.SettingsPanel then
        ns.Log.Error("the settings panel did not load")
        return
    end
    local view = ns.SettingsPanel.Inspect()
    ns.Log.Info(format("panel registered=%s controls=%d skipped=%d",
        tostring(view.registered), view.controlCount, #view.skipped))
    for index = 1, #view.skipped do
        ns.Log.Warn("  skipped " .. view.skipped[index])
    end
    if view.registered then
        ns.SettingsPanel.Open()
    end
end

local function commandFault()
    faultProbe.armed = true
    commandSetEnabled(FAULT_PROBE_ID, true)
    ns.Log.Info("fault probe armed; cast any spell and the probe should fault while the FSR tracker keeps running")
end

-- Exercises both drop policies now rather than waiting for Phase 2 to be the
-- first thing that ever calls the pool (§8).
-- What the client blocked while naming this addon. An attempt of "unknown" means
-- no probe of ours was in flight, so the block is taint spreading out of our code
-- rather than a protected call we made -- which is a different bug with a
-- different fix, and the readout must not blur them.
-- Taint, asked directly rather than inferred ----------------------------------
--
-- BlockWatch reports that the client blamed us for a blocked call. It cannot say
-- WHAT we tainted, so every conclusion drawn from it so far has been a hypothesis.
-- The client answers the question directly through two facilities, and neither was
-- being used:
--
--   issecurevariable(name)        -> isSecure, taintingAddon
--   issecurevariable(table, key)  -> same, for a field
--
-- and Blizzard's own taint log, which records the propagation path to a file.
--
-- The suspects are the functions and frames named in the blocks this addon has
-- been credited with, plus the frames it genuinely touches. A name that comes back
-- insecure WITH our addon named is proof; insecure with someone else named, or
-- with no name, is proof it is not ours.
local TAINT_SUSPECTS = {
    -- The chat globals come first because they are the ones the taint log
    -- actually named, and the first version of this list did not include them:
    -- it enumerated the functions that were BLOCKED rather than the variables
    -- that carried the taint, and so reported "11 secure, 0 tainted" while the
    -- client's own log was naming this addon.
    "SELECTED_CHAT_FRAME",
    "LAST_ACTIVE_CHAT_EDIT_BOX",
    "DEFAULT_CHAT_FRAME",
    "ChatFrame1",
    "ChatFrame1EditBox",
    "SetPreferredGamepadInteractTarget",
    "UseAction",
    "PlayerFrame",
    "GamepadMainActionBarFramePageUnitHostileTargetingActionBar",
    "GamepadMainActionBarFramePageUnitFriendlyTargetingActionBar",
    "GamepadMainActionBarFramePageUnitTopCenteredAnchorTopBar",
    "SpellFlyout",
    "CompactUnitFrame_UpdateAll",
    "CompactUnitFrame_SetUnit",
    "SettingsPanel",
    "InterfaceOptionsFrame",
}

local function reportOneSuspect(name)
    local reader = _G.issecurevariable
    local ok, isSecure, tainter = pcall(reader, name)
    if not ok then
        ns.Log.Warn(format("  %s: could not be checked", name))
        return nil
    end
    if isSecure then
        return true
    end

    local blamed = tostring(tainter or "unnamed")
    if blamed == ns.ADDON_NAME then
        ns.Log.Error(format("  %s: TAINTED BY US", name))
    else
        ns.Log.Warn(format("  %s: tainted by %s", name, blamed))
    end
    return false
end

local function commandTaint(subject)
    local reader = _G.issecurevariable
    if type(reader) ~= "function" then
        ns.Log.Error("this client does not expose issecurevariable, so taint cannot be inspected from Lua")
        ns.Log.Info("the taint log below still works; it is written by the client, not by us")
    else
        if subject and subject ~= "" then
            ns.Log.Info(format("checking '%s':", subject))
            if reportOneSuspect(subject) then
                ns.Log.Info(format("  %s: secure", subject))
            end
            return
        end

        local secure, tainted, ours = 0, 0, 0
        ns.Log.Info("taint check, suspects named in the blocks credited to this addon:")
        for index = 1, #TAINT_SUSPECTS do
            local name = TAINT_SUSPECTS[index]
            -- Always asked, even when the global holds nothing right now: taint
            -- attaches to the VARIABLE, so an absent value still has a real
            -- answer. Skipping them meant the suspects most worth checking --
            -- the protected functions themselves -- were never checked.
            local verdict = reportOneSuspect(name)
            local present = (_G[name] ~= nil) and "" or " (no value on this client)"
            if verdict == true then
                secure = secure + 1
                if present ~= "" then
                    ns.Log.Info(format("  %s: secure%s", name, present))
                end
            elseif verdict == false then
                tainted = tainted + 1
                local _, who = pcall(reader, name)
                if tostring(who) == ns.ADDON_NAME then ours = ours + 1 end
            end
        end
        ns.Log.Info(format("%d secure, %d tainted, %d of those ours", secure, tainted, ours))
    end

    ns.Log.Info("for the propagation path, which names the line that spread it:")
    ns.Log.Info("  /console taintLog 2   then /reload, reproduce, and quit")
    ns.Log.Info("  the client writes _classic_beta_/Logs/taint.log")
    ns.Log.Info("  /console taintLog 0   turns it back off; it is verbose and slows the client")
end

local function commandBlocked()
    if not ns.BlockWatch then
        ns.Log.Error("the blocked-action watch did not load")
        return
    end

    -- "Saw nothing" and "was not watching" are different facts, and reporting the
    -- first when the second is true wasted a controlled test run.
    if not ns.BlockWatch.IsObserving() then
        ns.Log.Error("NOT OBSERVING: the blocked-action watch is disabled, so an empty tally means nothing")
        ns.Log.Info("  /pa on blockWatch to start watching, then /reload")
        return
    end

    local rows = ns.BlockWatch.Tally()
    if #rows == 0 then
        ns.Log.Info("watching, and nothing has been blocked with this addon named")
        return
    end

    local total, ours, cascaded = 0, 0, 0
    for index = 1, #rows do
        total = total + rows[index].count
        if rows[index].firstAttempt == "unknown" then
            cascaded = cascaded + 1
        else
            ours = ours + 1
        end
    end

    ns.Log.Info(format("%d block(s) across %d distinct function(s)", total, #rows))
    ns.Log.Info(format("  %d attributable to one of our attempts, %d not (taint spread)",
        ours, cascaded))

    for index = 1, #rows do
        local row = rows[index]
        local traced = ns.BlockWatch.IsKnown(row.functionName)
            and " [traced, benign]" or ""
        ns.Log.Info(format("  %dx %s (attempt: %s)%s", row.count, row.functionName,
            row.firstAttempt, traced))
    end
end

local function commandPool()
    local created = 0
    local function factory()
        created = created + 1
        return { id = created }
    end
    local function reset(frame)
        frame.inUse = false
    end

    local strict = ns.FramePool.Create({
        poolName = "debug-strict",
        capacity = 2,
        dropPolicy = ns.DROP_POLICY.SURFACE_AND_FAIL,
        factory = factory,
        reset = reset,
    })
    local first = ns.FramePool.Acquire(strict)
    local second = ns.FramePool.Acquire(strict)
    local third, failure = ns.FramePool.Acquire(strict)
    ns.Log.Info(format("SURFACE_AND_FAIL: acquired %s, %s; third=%s (%s)",
        tostring(first and first.id), tostring(second and second.id),
        tostring(third), tostring(failure)))
    ns.FramePool.Release(strict, first)
    ns.FramePool.Release(strict, first)

    created = 0
    local recycling = ns.FramePool.Create({
        poolName = "debug-recycle",
        capacity = 2,
        dropPolicy = ns.DROP_POLICY.RECYCLE_OLDEST,
        factory = factory,
        reset = reset,
    })
    local oldest = ns.FramePool.Acquire(recycling)
    ns.FramePool.Acquire(recycling)
    local recycled = ns.FramePool.Acquire(recycling)
    ns.Log.Info(format("RECYCLE_OLDEST: oldest=%s reclaimed=%s same=%s",
        tostring(oldest and oldest.id), tostring(recycled and recycled.id),
        tostring(oldest == recycled)))
end

local function commandHelp()
    ns.Log.Info("/pa status [all]        feature states; all includes internal ones")
    ns.Log.Info("/pa on / off <feature>  toggle a feature at runtime")
    ns.Log.Info("/pa get <feature>       show stored settings")
    ns.Log.Info("/pa set <f> <k> <v>     change a setting and apply it live")
    ns.Log.Info("/pa fsr                 FSR tracker state, phase and window")
    ns.Log.Info("/pa fault               arm the fault probe, then cast anything")
    ns.Log.Info("/pa failenable          enable the probe whose enable always fails")
    ns.Log.Info("/pa pool                exercise both frame pool drop policies")
    ns.Log.Info("/pa plates              nameplate tracking, ledger and capability state")
    ns.Log.Info("/pa dps                 refresh the damage breakdown panel and report it")
    ns.Log.Info("/pa panel               open the settings panel and report how it built")
    ns.Log.Info("/pa blocked             protected calls the client blamed on this addon")
    ns.Log.Info("/pa taint [name]        ask the client what is tainted, and by whom")
end

local function handler(input)
    local words = {}
    for word in string.gmatch(input or "", "%S+") do
        words[#words + 1] = word
    end

    local command = string.lower(words[1] or "")

    if command == "" or command == "help" then
        commandHelp()
    elseif command == "status" then
        commandStatus(words[2] == "all")
    elseif command == "on" then
        commandSetEnabled(words[2], true)
    elseif command == "off" then
        commandSetEnabled(words[2], false)
    elseif command == "get" then
        commandGet(words[2])
    elseif command == "set" then
        commandSet(words[2], words[3], words[4])
    elseif command == "fsr" then
        commandFsr()
    elseif command == "fault" then
        commandFault()
    elseif command == "failenable" then
        commandSetEnabled(ENABLE_FAIL_PROBE_ID, true)
    elseif command == "pool" then
        commandPool()
    elseif command == "plates" then
        commandPlates()
    elseif command == "dps" then
        commandDps()
    elseif command == "panel" then
        commandPanel()
    elseif command == "blocked" then
        commandBlocked()
    elseif command == "taint" then
        commandTaint(words[2])
    else
        ns.Log.Error("unknown command: " .. command)
        commandHelp()
    end
end

SLASH_PERSONALADDON_DEBUG1 = "/pa"
SLASH_PERSONALADDON_DEBUG2 = "/personaladdon"
SlashCmdList["PERSONALADDON_DEBUG"] = handler

Debug.FAULT_PROBE_ID = FAULT_PROBE_ID
Debug.ENABLE_FAIL_PROBE_ID = ENABLE_FAIL_PROBE_ID
