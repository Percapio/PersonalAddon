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
    -- The stored flag changed whatever SetEnabled returned, so the settings panel's
    -- copy is brought in step either way (Patch01Implementation section 5.6).
    if ns.SettingsPanel and ns.SettingsPanel.ReflectEnabled then
        ns.SettingsPanel.ReflectEnabled(featureId)
    end
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

    if ns.SettingsPanel and ns.SettingsPanel.ReflectStoredValue then
        ns.SettingsPanel.ReflectStoredValue(featureId, key)
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
    if view.withheldSpellIds > 0 or view.withheldBarGeometry > 0 then
        ns.Log.Info(format("  withheld reads: spell ids=%d (each opened the window) bar geometry=%d",
            view.withheldSpellIds, view.withheldBarGeometry))
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
    -- Phase 7 exit criteria 5 and 7 read these two lines.
    local verdicts = view.verdicts or {}
    -- aboutToPull (Phase 11, R7) goes last, so the Phase 7 part of the line reads as before.
    ns.Log.Info(format("  verdicts: onPlayer=%d tapDenied=%d onGroupOrPet=%d neutral=%d elsewhere=%d ceded=%d aboutToPull=%d",
        verdicts.OnPlayer or 0, verdicts.TapDenied or 0, verdicts.OnGroupOrPet or 0,
        verdicts.Neutral or 0, verdicts.Elsewhere or 0, verdicts.Ceded or 0,
        verdicts.AboutToPull or 0))
    ns.Log.Info(format("  contested=%d driver=%s yieldSelectedTarget=%s",
        view.contested or 0, tostring(view.contestedRunning),
        tostring(view.yieldSelectedTarget)))
    ns.Log.Info(format("  ledger: widgets=%d restored=%d widgetGone=%d writeRefused=%d",
        view.ledgerWidgets, view.ledgerRestored, view.ledgerWidgetGone,
        view.ledgerWriteRefused))
    ns.Log.Info(format("  capability: barRecolourable=%s standing=%s hook=%s",
        tostring(view.barRecolourable), tostring(view.standingCapability),
        tostring(view.hookInstalled)))
    -- Phase 9 section 4.5: aggro comes from threat, so these replace the old
    -- "no nameplate target has ever resolved" warning.
    ns.Log.Info(format("  threat: plain=%d absent=%d withheld=%d  faults=%d  restricted map now=%s",
        view.threatReadsPlain, view.threatReadsAbsent, view.threatReadsWithheld,
        view.plateFaults, tostring(view.restrictedMapNow)))
    ns.Log.Info(format("  withheld reads: comparison=%d standing=%d barColour=%d",
        view.comparisonReadsWithheld, view.standingReadsWithheld, view.barColourReadsWithheld))
    if not view.colouringActive then
        ns.Log.Warn("  nameplate colouring is OFF")
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
    ns.Log.Info(format("  withheldReads=%d pool=%d live / %d free / %d cap",
        view.withheldReads, view.poolLive, view.poolFree, view.poolCapacity))
end

-- Phase 11 section 5.9: the threat panel's state, its rows and its counters.
local function commandThreat()
    if not ns.ThreatPanel then
        ns.Log.Error("the threat panel did not load")
        return
    end
    local view = ns.ThreatPanel.Inspect()
    ns.Log.Info(format("enabled=%s inCombat=%s rows=%d/%d truncated=%d timer=%s (%ss) sweeps=%d panel=%s anchor=%s",
        tostring(view.enabled), tostring(view.inCombat), view.rowsDrawn, view.maximumRows,
        view.rowsTruncated, view.sweeping and "running" or "stopped", tostring(view.updateInterval),
        view.sweeps, view.panelShown and "shown" or "hidden",
        view.anchorIsPlayerFrame and "PlayerFrame" or "screen"))
    for index = 1, #view.rows do
        local row = view.rows[index]
        ns.Log.Info(format("  %d. %s %s %s%s", index, tostring(row.token), tostring(row.verdict),
            row.threat, row.isTarget and " (your target)" or ""))
    end
    local names, counters, parts = ns.ThreatPanel.COUNTER_NAMES, view.counters or {}, {}
    for index = 1, #names do
        parts[#parts + 1] = format("%s=%d", names[index], counters[names[index]] or 0)
    end
    ns.Log.Info("  counters: " .. table.concat(parts, " ", 1, 9))
    ns.Log.Info("  counters: " .. table.concat(parts, " ", 10))
end

-- Phase 8 section 5: what the skills window would show now, and how it resolved.
local function commandSkills()
    if not ns.EquippedSkills then
        ns.Log.Error("the skills window did not load")
        return
    end
    ns.EquippedSkills.Refresh()
    local view = ns.EquippedSkills.Inspect()
    ns.Log.Info(format("enabled=%s capability=%s bagShown=%s windowShown=%s poll=%s (%ss)",
        tostring(view.enabled), tostring(view.capability), tostring(view.bagShown),
        tostring(view.panelShown), tostring(view.pollRunning), tostring(view.pollSeconds)))
    if view.capabilityReason then
        ns.Log.Warn("  withheld: " .. tostring(view.capabilityReason))
    end
    for index = 1, #view.rows do
        local row = view.rows[index]
        ns.Log.Info(format("  %s%s%s: %d / %d%s",
            tostring(row.source),
            row.slot and (" [" .. row.slot .. "]") or "",
            row.label and (" " .. ns.EscapeGuard.Neutralize(row.label)) or "",
            row.rank, row.maximum,
            row.hasIcon and "" or " (no icon)"))
    end
    if #view.rows == 0 then
        ns.Log.Info("  no rows")
    end
    for index = 1, #view.unresolved do
        ns.Log.Warn("  unresolved weapon: " .. view.unresolved[index])
    end
    ns.Log.Info(format("  fist weapons and unarmed resolved to skill line %s",
        view.fistLine and tostring(view.fistLine) or "NotTested"))
    ns.Log.Info(format("  reads=%d withheld=%d iconFailures=%d border=%s pool=%d live / %d free / %d cap",
        view.reads, view.withheldReads, view.iconFailures, tostring(view.borderStyle),
        view.poolLive, view.poolFree, view.poolCapacity))
end

-- Phase 8 section 6: the toast service and loot capture, or one of each toast.
local function commandToasts(subcommand)
    if not ns.Toasts then
        ns.Log.Error("the toasts feature did not load")
        return
    end
    if string.lower(subcommand or "") == "test" then
        local outcomes = ns.Toasts.PostSamples()
        ns.Log.Info("posted one of each toast: " .. table.concat(outcomes, ", "))
        return
    end
    local view = ns.Toasts.Inspect()
    local counts = view.counts
    ns.Log.Info(format("enabled=%s visible=%d/%d queued=%d lootCapture=%s%s",
        tostring(view.enabled), view.visible, view.maximumVisible, view.queued,
        tostring(view.lootCapture),
        view.patternFailure and (" (missing " .. tostring(view.patternFailure) .. ")") or ""))
    ns.Log.Info(format("  posted=%d shown=%d queued=%d coalesced=%d dropped=%d unavailable=%d",
        counts.posted, counts.shown, counts.queued, counts.coalesced, counts.dropped,
        counts.unavailable))
    ns.Log.Info(format("  loot: notOurs=%d notShown=%d unresolved=%d unparsed=%d secret=%d inboxDropped=%d",
        counts.notOurs, counts.notShown, counts.unresolved, counts.unparsed,
        counts.secretTexts, counts.inboxDropped))
    ns.Log.Info(format("  deliveredInsideCall=%d of %d checked (section 6.5 expects 0)",
        counts.deliveredInsideCall, counts.stackChecked))
    ns.Log.Info(format("  restricted map: messages=%d shown=%d (Phase 10 section 7.2)",
        counts.lootMessagesOnRestrictedMap, counts.shownOnRestrictedMap))
end

-- Phase 8 section 7.1: why the last bag close did or did not sort.
local function commandBags()
    if not ns.AutoSortBags then
        ns.Log.Error("tidy bags did not load")
        return
    end
    local view = ns.AutoSortBags.Inspect()
    ns.Log.Info(format("enabled=%s sorts=%d cooldown=%ss last sort %s",
        tostring(view.enabled), view.sorts, tostring(view.cooldownSeconds),
        view.secondsSinceSort and format("%.0fs ago", view.secondsSinceSort) or "never"))
    ns.Log.Info("  skipped: " .. (#view.skips > 0 and table.concat(view.skips, ", ") or "none")
        .. (view.lastSkip and (" (last: " .. view.lastSkip .. ")") or ""))
    ns.Log.Info("  inside the last sort: " .. (view.lastInline or "nothing yet"))
    ns.Log.Info("  listening now: " .. ns.EscapeGuard.Neutralize(tostring(view.listenersNow)))
end

-- Phase 8 section 7.2: the last sale and why any visit was skipped.
local function commandVend()
    if not ns.AutoSellJunk then
        ns.Log.Error("sell junk did not load")
        return
    end
    local view = ns.AutoSellJunk.Inspect()
    ns.Log.Info(format("enabled=%s sales=%d pending=%s", tostring(view.enabled), view.sales,
        tostring(view.salePending)))
    ns.Log.Info("  skipped: " .. (#view.skips > 0 and table.concat(view.skips, ", ") or "none")
        .. (view.lastSkip and (" (last: " .. view.lastSkip .. ")") or ""))
    ns.Log.Info("  last sale: " .. (view.lastSummary or "none yet")
        .. (view.lastPosted and (" [" .. view.lastPosted .. "]") or ""))
end

local function commandPanel()
    if not ns.SettingsPanel then
        ns.Log.Error("the settings panel did not load")
        return
    end
    local view = ns.SettingsPanel.Inspect()
    ns.Log.Info(format("panel registered=%s controls=%d skipped=%d reverts=%d unreadableColours=%d",
        tostring(view.registered), view.controlCount, #view.skipped,
        view.reverts or 0, view.unreadable or 0))
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

    -- Level 1 since Phase 9 (README, "To trace how taint reached a refusal"): the
    -- line above each blocked entry already names where that execution became
    -- tainted, and level 4 helped one session flood until it disconnected.
    ns.Log.Info("for the propagation path, which names the line that spread it:")
    ns.Log.Info("  keep BugGrabber installed, then /console taintLog 1, /reload, reproduce once, and quit")
    ns.Log.Info("  in _classic_beta_/Logs/taint.log the line above each \"An action was blocked\"")
    ns.Log.Info("  is where that execution became tainted; copy the file before logging in again")
    ns.Log.Info("  /console taintLog 0   turns it back off; never use level 4")
end

-- The saved block log (Patch01Implementation section 4.6). Records survive a
-- reload, carry the path each refusal came through, and are bounded at 16.
local function commandBlocked(subcommand, argument)
    if not ns.BlockWatch then
        ns.Log.Error("the blocked-action watch did not load")
        return
    end

    local verb = string.lower(subcommand or "")

    if verb == "selftest" then
        local report = ns.BlockWatch.SelfTest()
        ns.Log.Info(format("selftest: %d/%d passed", report.passed, report.total))
        for index = 1, #report.failed do
            local failure = report.failed[index]
            ns.Log.Error(format("  %s: %s", failure.caseName,
                ns.EscapeGuard.Neutralize(tostring(failure.reason))))
        end
        return
    end

    if verb == "clear" then
        ns.Log.Info(format("cleared %d record(s)", ns.BlockWatch.Clear()))
        return
    end

    if verb == "stack" then
        local lines = ns.BlockWatch.StackLines(tonumber(argument))
        if not lines then
            ns.Log.Error(format("no record %s; /pa blocked lists them",
                ns.EscapeGuard.Neutralize(tostring(argument))))
            return
        end
        for index = 1, #lines do
            ns.Log.Info(lines[index])
        end
        return
    end

    if verb ~= "" then
        ns.Log.Error("usage: /pa blocked [stack <n> | clear | selftest]")
        return
    end

    -- "Saw nothing" and "was not watching" are different facts, and reporting the
    -- first when the second is true wasted a controlled test run.
    if not ns.BlockWatch.IsObserving() then
        ns.Log.Error("NOT OBSERVING: the blocked-action watch is disabled, so an empty tally means nothing")
        ns.Log.Info("  /pa on blockWatch to start watching, then /reload")
        return
    end

    local records = ns.BlockWatch.Records()
    ns.Log.Info(format("%d record(s); up to %d are kept", #records, ns.BlockWatch.Capacity()))
    for index = 1, #records do
        ns.Log.Info("  " .. ns.BlockWatch.Describe(index, records[index]))
    end

    -- Phase 9 section 6.2: during a storm only counts are kept, so they are listed.
    local storm = ns.BlockWatch.StormSummary()
    if storm.storming then
        ns.Log.Warn(format("STORM since %.0fs ago: %d refusals counted, no stacks read; /reload clears it",
            GetTime() - (storm.since or GetTime()), storm.refusals))
        for index = 1, #storm.byFunction do
            local entry = storm.byFunction[index]
            ns.Log.Info(format("  %dx %s", entry.count, ns.EscapeGuard.Neutralize(entry.name)))
        end
    else
        ns.Log.Info(format("no refusal storm this session (%d within %ds would start one)",
            storm.threshold, storm.windowSeconds))
    end
end

-- Phase 9 section 3.6: what earlier sessions counted, from the saved diagnostics.
local function describeCounters(counters)
    local names = {}
    for name, value in pairs(counters) do
        if value ~= 0 and value ~= false then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    local parts = {}
    for index = 1, #names do
        parts[#parts + 1] = format("%s=%s", names[index], tostring(counters[names[index]]))
    end
    return table.concat(parts, " ")
end

local function commandDiag(subcommand)
    local verb = string.lower(subcommand or "")
    if verb == "clear" then
        ns.Log.Info(format("dropped %d earlier session record(s); this session keeps counting",
            ns.Diagnostics.ClearPrevious()))
        return
    end
    if verb ~= "" then
        ns.Log.Error("usage: /pa diag [clear]")
        return
    end

    local sessions, current = ns.Diagnostics.Sessions()
    local dateOf = _G.date
    ns.Log.Info(format("%d session record(s), newest first:", #sessions))
    for index = #sessions, 1, -1 do
        local record = sessions[index]
        local when = (type(dateOf) == "function") and dateOf("%Y-%m-%d %H:%M", record.startedAt)
            or tostring(record.startedAt)
        ns.Log.Info(format("%s %s build %s, addon %s",
            record == current and "*" or " ", when,
            ns.EscapeGuard.Neutralize(record.clientBuild), ns.EscapeGuard.Neutralize(record.addonVersion)))
        local featureIds = {}
        for featureId in pairs(record.counters) do
            featureIds[#featureIds + 1] = featureId
        end
        table.sort(featureIds)
        for position = 1, #featureIds do
            local line = describeCounters(record.counters[featureIds[position]])
            if line ~= "" then
                ns.Log.Info(format("    %s: %s", featureIds[position], line))
            end
        end
        for position = 1, #record.faults do
            local note = record.faults[position]
            ns.Log.Warn(format("    fault in %s: %s", ns.EscapeGuard.Neutralize(note.featureId), note.message))
        end
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
    ns.Log.Info("/pa threat              the threat panel's rows, timer and counters")
    ns.Log.Info("/pa skills              what the skills window shows, and how each row resolved")
    ns.Log.Info("/pa toasts [test]       toast and loot counts; test posts one of each toast")
    ns.Log.Info("/pa bags                tidy bags: sorts, skips, and who listens")
    ns.Log.Info("/pa vend                sell junk: the last sale and any skips")
    ns.Log.Info("/pa panel               open the settings panel and report how it built")
    ns.Log.Info("/pa blocked             refusals the client blamed on this addon, with their paths")
    ns.Log.Info("/pa blocked stack <n>   one record's stored stack")
    ns.Log.Info("/pa blocked clear       empty the saved block log")
    ns.Log.Info("/pa blocked selftest    check the recorder against fixed samples")
    ns.Log.Info("/pa diag                counters and fault notes from the last five sessions")
    ns.Log.Info("/pa diag clear          drop all but the current session's record")
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
    elseif command == "threat" then
        commandThreat()
    elseif command == "skills" then
        commandSkills()
    elseif command == "toasts" then
        commandToasts(words[2])
    elseif command == "bags" then
        commandBags()
    elseif command == "vend" then
        commandVend()
    elseif command == "panel" then
        commandPanel()
    elseif command == "blocked" then
        commandBlocked(words[2], words[3])
    elseif command == "diag" then
        commandDiag(words[2])
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
