-- Spikes/QuestWatchProbe.lua
-- The Phase 7 quest-watch spike (Architecture/20260926-Phase07.md section 6.3).
-- Answers whether this addon may reorder the client's quest watch list at all,
-- before any code for section 6.5 exists.
--
-- The question is not how often we reorder: one call is enough. If the client
-- delivers QUEST_WATCH_LIST_CHANGED while our add or remove call is still
-- running, the tracker's handler writes its dirty flag inside our execution, and
-- its next redraw carries our taint into the Gamepad UI's navigation state -- the
-- chain Patch 01 traced.
--
-- Stage P writes nothing: it watches the client's own add and remove calls.
-- Stage A makes one rewrite of its own, and only after Stage P has shown the
-- tracker's event arrives after the call returns. A question never reached reads
-- NotTested, never a pass (Phase 2 section 4).
--
-- Delete this file, its TOC line and its /pa probe route once section 6.4 is
-- filled in (Phase 7 exit criterion 19).

local ADDON_NAME, ns = ...

local FEATURE_ID = "questWatchProbe"

local format, tostring, type, pairs, ipairs, pcall =
    string.format, tostring, type, pairs, ipairs, pcall

-- How long a call that changed the list waits for its own delivery before S1
-- records NotObserved for it.
local PROBE_EVENT_WAIT = 2.0

local STACK_TOP_FRAMES, STACK_BOTTOM_FRAMES = 30, 10

-- The tracker's own events (Blizzard_QuestObjectiveTracker.lua:3), registered for
-- Stage A's window when the client offers no all-events registration.
local TRACKER_EVENTS = {
    "QUEST_LOG_UPDATE", "QUEST_WATCH_LIST_CHANGED", "QUEST_AUTOCOMPLETE",
    "SUPER_TRACKING_CHANGED", "QUEST_TURNED_IN", "QUEST_POI_UPDATE",
    "SUPER_TRACKING_PATH_UPDATED",
}

local NOT_TESTED = "NotTested"

local TIMING = {
    INSIDE = "InsideCall",
    AFTER = "AfterCall",
    NOT_OBSERVED = "NotObserved",
}

-- S1 is the worst verdict over every judged call: one call that delivers inside
-- itself is enough for a no-go.
local TIMING_RANK = {
    [NOT_TESTED] = 0,
    [TIMING.NOT_OBSERVED] = 1,
    [TIMING.AFTER] = 2,
    [TIMING.INSIDE] = 3,
}

local EVIDENCE = {
    IN_STACK = "CallInStack",
    NOT_IN_CALL = "NotInCall",
    WITHHELD = "StackWithheld",
}

-- Gateway (section 6.3) -----------------------------------------------------------
--
-- Every client call the spike makes, in one place. Accessors are resolved rather
-- than assumed: this client has already proved a namespace can exist while a
-- function in it does not.

local function clientCall(namespace, functionName, ...)
    local api = _G[namespace]
    local fn = type(api) == "table" and api[functionName] or nil
    if type(fn) ~= "function" then
        return false
    end
    return pcall(fn, ...)
end

local WATCH_TYPE_NAMES = { [0] = "Automatic", [1] = "Manual" }

local gateway = {}

function gateway.count()
    local ok, count = clientCall("C_QuestLog", "GetNumQuestWatches")
    if ok and type(count) == "number" then
        return count
    end
    return 0
end

function gateway.questAt(index)
    local ok, questId = clientCall("C_QuestLog", "GetQuestIDForQuestWatchIndex", index)
    if ok and type(questId) == "number" then
        return questId
    end
    return nil
end

function gateway.watchTypeOf(questId)
    local ok, watchType = clientCall("C_QuestLog", "GetQuestWatchType", questId)
    if not ok or watchType == nil then
        return nil
    end
    local enum = _G.Enum and _G.Enum.QuestWatchType
    if type(enum) == "table" then
        for name, value in pairs(enum) do
            if value == watchType then
                return name
            end
        end
    end
    return WATCH_TYPE_NAMES[watchType] or tostring(watchType)
end

function gateway.difficultyLevel(questId)
    local ok, level = clientCall("C_QuestLog", "GetQuestDifficultyLevel", questId)
    if ok and type(level) == "number" then
        return level
    end
    return nil
end

function gateway.logLevel(questId)
    local ok, logIndex = clientCall("C_QuestLog", "GetLogIndexForQuestID", questId)
    if not ok or type(logIndex) ~= "number" then
        return nil
    end
    local infoOk, info = clientCall("C_QuestLog", "GetInfo", logIndex)
    if infoOk and type(info) == "table" and type(info.level) == "number" then
        return info.level
    end
    return nil
end

function gateway.distanceTo(questId)
    local ok, distanceSq, onContinent = clientCall("C_QuestLog", "GetDistanceSqToQuest", questId)
    if ok and type(distanceSq) == "number" and onContinent then
        return distanceSq
    end
    return nil
end

function gateway.titleOf(questId)
    local ok, title = clientCall("C_QuestLog", "GetTitleForQuestID", questId)
    if ok and type(title) == "string" and title ~= "" then
        return title
    end
    return nil
end

function gateway.remove(questId)
    local ok, removed = clientCall("C_QuestLog", "RemoveQuestWatch", questId)
    return ok and removed ~= false
end

function gateway.add(questId)
    local ok, watched = clientCall("C_QuestLog", "AddQuestWatch", questId)
    return ok and watched ~= false
end

function gateway.superTracked()
    local ok, questId = clientCall("C_SuperTrack", "GetSuperTrackedQuestID")
    if ok and type(questId) == "number" and questId > 0 then
        return questId
    end
    return nil
end

function gateway.setSuperTracked(questId)
    clientCall("C_SuperTrack", "SetSuperTrackedQuestID", questId)
end

-- Called directly rather than through QuestUtil.CanRemoveQuestWatch, so no
-- Blizzard Lua runs in our execution to answer it.
function gateway.npeRestricted()
    local ok, restricted = clientCall("C_PlayerInfo", "IsPlayerNPERestricted")
    return ok and restricted == true
end

function gateway.inCombat()
    if type(InCombatLockdown) == "function" and InCombatLockdown() then
        return true
    end
    local ok, combat = pcall(UnitAffectingCombat, "player")
    return ok and combat == true
end

function gateway.now()
    return GetTime()
end

-- State ----------------------------------------------------------------------------

local probe = {
    enabled = false,
    hooksInstalled = false,
    tokens = {},
    -- Every live timer handle, so disable can cancel them all.
    timers = {},
    snapshot = { order = {}, set = {} },
    snapshotTimer = nil,
    zoneTimer = nil,
    -- The last delivery seen per quest, and the calls still waiting for theirs.
    deliveries = {},
    awaiting = {},
    lastReturnSequence = {},
    sequence = 0,
    unattributed = 0,
    timingCounts = {},
    stageARunning = false,
    window = nil,
    frame = nil,
    report = nil,
}

local function newReport()
    return {
        s1 = NOT_TESTED,
        s1Evidence = nil,
        s2FreshAddTypes = {},
        s2AutomaticWatches = 0,
        s2ReAdd = NOT_TESTED,
        s2ReAddChanged = nil,
        s3 = NOT_TESTED,
        s3Index = nil,
        s4 = NOT_TESTED,
        s5 = NOT_TESTED,
        s5Order = nil,
        s6 = NOT_TESTED,
        s6Disagree = nil,
        s6NonPositive = nil,
        s7 = NOT_TESTED,
        s8 = NOT_TESTED,
        s8Names = nil,
        orderRestored = nil,
    }
end

local function nextSequence()
    probe.sequence = probe.sequence + 1
    return probe.sequence
end

local function cancelTimer(handle)
    if handle then
        probe.timers[handle] = nil
        pcall(handle.Cancel, handle)
    end
end

-- A timer whose callback is dropped once the probe is off, and which faults the
-- probe rather than raising into the client if it errors.
local function after(delay, fn)
    if not (C_Timer and C_Timer.NewTimer) then
        return nil
    end
    local handle
    handle = C_Timer.NewTimer(delay, function()
        probe.timers[handle] = nil
        if not probe.enabled then
            return
        end
        local ok, err = ns.Isolation.Call(fn)
        if not ok then
            ns.Registry.Fault(FEATURE_ID, "raised in a probe timer", err)
        end
    end)
    probe.timers[handle] = true
    return handle
end

local function titled(questId)
    return ns.EscapeGuard.Neutralize(gateway.titleOf(questId) or ("quest " .. tostring(questId)))
end

local function indexOf(order, questId)
    for index = 1, #order do
        if order[index] == questId then
            return index
        end
    end
    return nil
end

local function firstDivergence(current, desired)
    local longest = math.max(#current, #desired)
    for index = 1, longest do
        if current[index] ~= desired[index] then
            return index
        end
    end
    return nil
end

local function readOrder()
    local order = {}
    for index = 1, gateway.count() do
        local questId = gateway.questAt(index)
        if not questId then
            break
        end
        order[#order + 1] = questId
    end
    return order
end

local function readTypes(order)
    local types = {}
    for index = 1, #order do
        types[order[index]] = gateway.watchTypeOf(order[index]) or "unknown"
    end
    return types
end

-- Snapshot: which quests were watched a frame ago -----------------------------------
--
-- A call changed the list when its quest was absent (add) or present (remove) in
-- the snapshot. It is refreshed one frame after each delivery, never inside the
-- listener, so a post-hook always compares against the list as it stood before
-- the call.

local function takeSnapshot()
    local order = readOrder()
    local set = {}
    local automatic = 0
    for index = 1, #order do
        set[order[index]] = true
        if gateway.watchTypeOf(order[index]) == "Automatic" then
            automatic = automatic + 1
        end
    end
    probe.snapshot = { order = order, set = set }
    if automatic > probe.report.s2AutomaticWatches then
        probe.report.s2AutomaticWatches = automatic
    end
end

local function scheduleSnapshot()
    if probe.snapshotTimer then
        return
    end
    probe.snapshotTimer = after(0, function()
        probe.snapshotTimer = nil
        takeSnapshot()
    end)
end

-- S1: the stack, with timing as the fallback ----------------------------------------

local function readStack()
    local reader = _G.debugstack
    if type(reader) ~= "function" then
        return nil
    end
    local ok, text = pcall(reader, 2, STACK_TOP_FRAMES, STACK_BOTTOM_FRAMES)
    if not ok then
        return nil
    end
    local isSecret = _G.issecretvalue
    if type(isSecret) == "function" then
        local checked, secret = pcall(isSecret, text)
        if not checked or secret then
            return nil
        end
    end
    if type(text) ~= "string" then
        return nil
    end
    return text
end

-- The listener runs inside the call only if the delivery is synchronous, and
-- then the call's frame is on the stack. Matching the closing quote keeps this
-- file's own name, which contains "QuestWatch", from ever matching.
local function judgeDelivery(stackText)
    if not stackText then
        return EVIDENCE.WITHHELD
    end
    if string.find(stackText, "AddQuestWatch'", 1, true)
        or string.find(stackText, "RemoveQuestWatch'", 1, true) then
        return EVIDENCE.IN_STACK
    end
    return EVIDENCE.NOT_IN_CALL
end

local function noteTiming(verdict, evidence, kind)
    local key = (kind or "any") .. ":" .. verdict
    probe.timingCounts[key] = (probe.timingCounts[key] or 0) + 1

    local report = probe.report
    if TIMING_RANK[verdict] > TIMING_RANK[report.s1] then
        report.s1 = verdict
        report.s1Evidence = evidence
        local line = format("S1 watch event timing: %s%s", verdict,
            evidence and (" (" .. evidence .. ")") or "")
        if verdict == TIMING.INSIDE then
            ns.Log.Error(line .. " -- a no-go; see /pa probe quests")
        else
            ns.Log.Info(line)
        end
    end
end

local function awaitDelivery(kind, questId)
    local previous = probe.awaiting[questId]
    if previous then
        cancelTimer(previous.timer)
    end
    local entry = { kind = kind }
    entry.timer = after(PROBE_EVENT_WAIT, function()
        if probe.awaiting[questId] == entry then
            probe.awaiting[questId] = nil
            noteTiming(TIMING.NOT_OBSERVED, "no delivery within 2 s", kind)
        end
    end)
    probe.awaiting[questId] = entry
end

local function onWatchListChanged(questId)
    if not probe.enabled or probe.stageARunning then
        return
    end
    scheduleSnapshot()

    if type(questId) ~= "number" then
        probe.unattributed = probe.unattributed + 1
        return
    end

    local evidence = judgeDelivery(readStack())
    probe.deliveries[questId] = {
        frame = gateway.now(),
        sequence = nextSequence(),
        evidence = evidence,
    }

    if evidence == EVIDENCE.IN_STACK then
        noteTiming(TIMING.INSIDE, "the stack shows the watch call", nil)
        return
    end

    local waiting = probe.awaiting[questId]
    if waiting then
        -- Its call had already returned: the delivery came after it.
        probe.awaiting[questId] = nil
        cancelTimer(waiting.timer)
        noteTiming(TIMING.AFTER, nil, waiting.kind)
    end
    -- Otherwise NotInCall with nothing waiting is the client's own change and does
    -- not count; StackWithheld is left for the post-hook, if one follows this frame.
end

-- S2 and S3 come only from adds that changed the list: a removal assigns no type
-- and takes no position.
local function measureFreshAdd(questId)
    local report = probe.report
    local watchType = gateway.watchTypeOf(questId) or "unknown"
    if not report.s2FreshAddTypes[watchType] then
        report.s2FreshAddTypes[watchType] = true
        ns.Log.Info(format("S2 a fresh one-argument add assigned: %s", watchType))
    end

    local order = readOrder()
    local index = indexOf(order, questId)
    if not index then
        return
    end
    if index == #order then
        if report.s3 == NOT_TESTED then
            report.s3 = "Appended"
            ns.Log.Info("S3 add position: Appended")
        end
    elseif report.s3 ~= "InsertedAt" then
        report.s3 = "InsertedAt"
        report.s3Index = index
        ns.Log.Error(format("S3 add position: InsertedAt %d of %d -- a no-go", index, #order))
    end
end

local function onWatchCallReturned(kind, questId)
    if not probe.enabled or probe.stageARunning or type(questId) ~= "number" then
        return
    end

    local wasWatched = probe.snapshot.set[questId] == true
    local changed = (kind == "add" and not wasWatched) or (kind == "remove" and wasWatched)
    if not changed then
        return
    end

    local now = gateway.now()
    local delivery = probe.deliveries[questId]
    local previousReturn = probe.lastReturnSequence[questId] or 0
    probe.lastReturnSequence[questId] = nextSequence()

    if delivery
        and delivery.frame == now
        and delivery.sequence > previousReturn
        and delivery.evidence ~= EVIDENCE.NOT_IN_CALL then
        noteTiming(TIMING.INSIDE, delivery.evidence == EVIDENCE.IN_STACK
            and "the stack shows the watch call"
            or "delivered in the same frame before the call returned; the client withheld the stack",
            kind)
    else
        awaitDelivery(kind, questId)
    end

    if kind == "add" then
        measureFreshAdd(questId)
    end
end

-- Two post-hooks, installed at most once per session and inert while the probe is
-- off (Phase 2 section 7.2). hooksecurefunc replaces the table entry with a secure
-- wrapper, as the nameplate hooks do for globals, so Blizzard's callers stay secure.
local function installHooks()
    if probe.hooksInstalled then
        return
    end
    probe.hooksInstalled = true

    if type(hooksecurefunc) ~= "function" or type(C_QuestLog) ~= "table" then
        ns.Log.Once("questprobe:nohooks",
            "this client offers no way to observe watch calls; S1, S2 and S3 cannot be answered")
        return
    end

    local installed = 0
    local targets = { add = "AddQuestWatch", remove = "RemoveQuestWatch" }
    for kind, functionName in pairs(targets) do
        if type(C_QuestLog[functionName]) == "function" then
            local ok = pcall(hooksecurefunc, C_QuestLog, functionName, function(questId)
                if not probe.enabled then
                    return
                end
                local called, err = ns.Isolation.Call(onWatchCallReturned, kind, questId)
                if not called then
                    ns.Registry.Fault(FEATURE_ID, "raised in a watch post-hook", err)
                end
            end)
            if ok then
                installed = installed + 1
            end
        end
    end

    if installed < 2 then
        ns.Log.Once("questprobe:partialhooks", format(
            "only %d of the two watch calls could be hooked; S1 may stay NotTested", installed))
    end
end

-- S5 and S6 ---------------------------------------------------------------------------

local function judgeZoneSort()
    local order = readOrder()
    local withDistance, lastDistance = 0, nil
    local seenAbsent, ordered = false, true
    for index = 1, #order do
        local distance = gateway.distanceTo(order[index])
        if distance == nil then
            seenAbsent = true
        else
            withDistance = withDistance + 1
            if seenAbsent or (lastDistance and distance < lastDistance) then
                ordered = false
            end
            lastDistance = distance
        end
    end

    local report = probe.report
    if withDistance < 2 then
        ns.Log.Info("S5 not decidable in this zone: fewer than two watched quests have a distance; it waits for the next zone change")
        return
    end
    if ordered then
        if report.s5 == NOT_TESTED then
            report.s5 = "Proximity"
            ns.Log.Info("S5 zone sort: Proximity")
        end
        return
    end
    -- Once seen out of order, it is not consistently proximity.
    if report.s5 ~= "OtherOrder" then
        report.s5 = "OtherOrder"
        local titles = {}
        for index = 1, #order do
            titles[index] = titled(order[index])
        end
        report.s5Order = table.concat(titles, ", ")
        ns.Log.Info("S5 zone sort: OtherOrder -- " .. report.s5Order)
    end
end

local function onNewArea()
    if not probe.enabled or probe.zoneTimer then
        return
    end
    -- One frame later, so Blizzard's own sort on this event has already run.
    probe.zoneTimer = after(0, function()
        probe.zoneTimer = nil
        judgeZoneSort()
    end)
end

local function judgeLevelSources()
    local order = readOrder()
    if #order == 0 then
        ns.Log.Info("S6 NotTested: nothing is watched yet")
        return
    end
    local disagree, nonPositive = {}, {}
    for index = 1, #order do
        local questId = order[index]
        local difficulty = gateway.difficultyLevel(questId)
        local logged = gateway.logLevel(questId)
        if difficulty ~= logged then
            disagree[#disagree + 1] = format("%s (%s vs %s)", titled(questId),
                tostring(difficulty), tostring(logged))
        end
        if not difficulty or difficulty <= 0 then
            nonPositive[#nonPositive + 1] = titled(questId)
        end
    end

    local report = probe.report
    report.s6 = (#disagree == 0) and "Agree" or "Disagree"
    report.s6Disagree = (#disagree > 0) and table.concat(disagree, "; ") or nil
    report.s6NonPositive = (#nonPositive > 0) and table.concat(nonPositive, ", ") or nil
    ns.Log.Info("S6 level sources: " .. report.s6
        .. (report.s6Disagree and (" -- " .. report.s6Disagree) or ""))
end

-- Stage A: one rewrite by the addon -----------------------------------------------------
--
-- The window is the probe's own frame, not a Dispatch subscription: Dispatch has
-- no all-events form. It is registered only for the length of one call, in the
-- same execution, so what it records was delivered while our call was running. A
-- deferred event is dispatched after it has unregistered, and is not recorded.

local function windowFrame()
    if not probe.frame then
        probe.frame = CreateFrame("Frame")
        probe.frame:SetScript("OnEvent", function(_, eventName)
            if probe.window then
                probe.window[#probe.window + 1] = eventName
            end
        end)
    end
    return probe.frame
end

local function openWindow(delivered)
    local frame = windowFrame()
    probe.window = delivered
    if type(frame.RegisterAllEvents) == "function" then
        frame:RegisterAllEvents()
        return
    end
    for _, eventName in ipairs(TRACKER_EVENTS) do
        pcall(frame.RegisterEvent, frame, eventName)
    end
end

local function closeWindow()
    probe.window = nil
    if probe.frame then
        probe.frame:UnregisterAllEvents()
    end
end

local function rewriteBackTo(original, current, delivered)
    local from = firstDivergence(current, original)
    if not from then
        return true
    end
    openWindow(delivered)
    for index = #current, from, -1 do
        gateway.remove(current[index])
    end
    for index = from, #original do
        gateway.add(original[index])
    end
    closeWindow()
    return firstDivergence(readOrder(), original) == nil
end

local function stageA()
    local report = probe.report
    if report.s1 ~= TIMING.AFTER then
        return false, format("Stage A needs S1 = AfterCall from Stage P; S1 is %s", report.s1)
    end
    if report.s3 ~= "Appended" then
        return false, format("Stage A needs S3 = Appended from Stage P; S3 is %s", report.s3)
    end
    if gateway.inCombat() then
        return false, "leave combat first: watch calls are never made in combat"
    end
    if gateway.npeRestricted() then
        return false, "this character cannot remove quest watches (new player experience)"
    end

    local original = readOrder()
    if #original < 2 then
        return false, "watch at least two quests first"
    end
    local superTracked = gateway.superTracked()
    if not (superTracked and indexOf(original, superTracked)) then
        return false, "super-track one of your watched quests first (select it on the map or in the tracker), then run this again"
    end
    local typesBefore = readTypes(original)

    local delivered = {}
    probe.stageARunning = true
    local ok, err = ns.Isolation.Call(function()
        openWindow(delivered)
        gateway.remove(superTracked)
        gateway.add(superTracked)
        closeWindow()

        local moved = readOrder()
        report.s7 = (gateway.superTracked() == superTracked) and "Kept" or "Cleared"

        report.orderRestored = rewriteBackTo(original, moved, delivered)

        if report.s7 == "Cleared" then
            openWindow(delivered)
            gateway.setSuperTracked(superTracked)
            closeWindow()
        end
    end)
    closeWindow()
    probe.stageARunning = false
    takeSnapshot()

    if not ok then
        ns.Registry.Fault(FEATURE_ID, "raised during Stage A", err)
        return false, "Stage A raised; the report so far is kept"
    end

    local typesAfter = readTypes(original)
    local changedTypes = {}
    for index = 1, #original do
        local questId = original[index]
        if typesBefore[questId] ~= typesAfter[questId] then
            changedTypes[#changedTypes + 1] = format("%s (%s to %s)", titled(questId),
                tostring(typesBefore[questId]), tostring(typesAfter[questId]))
        end
    end
    report.s2ReAdd = (#changedTypes == 0) and "Preserved" or "Changed"
    report.s2ReAddChanged = (#changedTypes > 0) and table.concat(changedTypes, "; ") or nil

    local names, seen = {}, {}
    for index = 1, #delivered do
        local eventName = delivered[index]
        if not seen[eventName] then
            seen[eventName] = true
            names[#names + 1] = eventName
        end
    end
    report.s8 = (#names == 0) and "NoneDelivered" or "Delivered"
    report.s8Names = (#names > 0) and table.concat(names, ", ") or nil

    ns.Log.Info(format("S2 re-add type: %s%s", report.s2ReAdd,
        report.s2ReAddChanged and (" -- " .. report.s2ReAddChanged) or ""))
    ns.Log.Info("S7 super-track: " .. report.s7
        .. (report.s7 == "Cleared" and " (restored)" or ""))
    if report.s8 == "Delivered" then
        ns.Log.Error("S8 events inside our call: Delivered -- " .. report.s8Names .. " -- a no-go")
    else
        ns.Log.Info("S8 events inside our call: NoneDelivered")
    end
    if not report.orderRestored then
        local titles = {}
        for index = 1, #original do
            titles[index] = titled(original[index])
        end
        ns.Log.Error("the watch order could not be restored; re-watch in this order: "
            .. table.concat(titles, ", "))
    end
    ns.Log.Info("Did the tracker play the new-quest animation just now? Answer with /pa probe quests animation played, or /pa probe quests animation none")
    return true
end

-- Report and decision (section 6.3, "Decision rule") --------------------------------------

local function decide(report)
    local noGo = {}
    if report.s1 == TIMING.INSIDE then
        noGo[#noGo + 1] = "S1 InsideCall"
    end
    if report.s3 == "InsertedAt" then
        noGo[#noGo + 1] = "S3 InsertedAt"
    end
    if report.s8 == "Delivered" then
        noGo[#noGo + 1] = "S8 Delivered (" .. tostring(report.s8Names) .. ")"
    end
    if #noGo > 0 then
        return "No-go: " .. table.concat(noGo, "; ")
    end
    if report.s4 == "Played" then
        return "No-go, unless you accept the new-quest animation on every reorder (S4 Played)"
    end

    local missing = {}
    if report.s1 ~= TIMING.AFTER then
        missing[#missing + 1] = "S1 (" .. report.s1 .. ")"
    end
    for _, field in ipairs({ "s3", "s4", "s7", "s8" }) do
        if report[field] == NOT_TESTED then
            missing[#missing + 1] = string.upper(field)
        end
    end
    if #missing > 0 then
        return "Undecided: " .. table.concat(missing, ", ") .. " not yet answered"
    end

    local adjustments = {}
    if report.s2ReAdd == "Changed" then
        adjustments[#adjustments + 1] = "the watch-type guard (S2)"
    end
    if report.s6 == "Disagree" then
        adjustments[#adjustments + 1] = "LevelSource = QuestLogLevel (S6)"
    end
    if report.s7 == "Cleared" then
        adjustments[#adjustments + 1] = "the super-tracking restore (S7)"
    end
    if report.s5 == "OtherOrder" then
        adjustments[#adjustments + 1] = "README wording: the game's own order (S5)"
    end
    if #adjustments == 0 then
        return "Go"
    end
    return "Go, with " .. table.concat(adjustments, "; ")
end

local function describeTimingCounts()
    local parts = {}
    for key, count in pairs(probe.timingCounts) do
        parts[#parts + 1] = format("%s x%d", key, count)
    end
    table.sort(parts)
    if probe.unattributed > 0 then
        parts[#parts + 1] = format("unattributed deliveries x%d", probe.unattributed)
    end
    return (#parts > 0) and table.concat(parts, "; ") or "no calls judged yet"
end

local function printReport()
    local report = probe.report
    local freshTypes = {}
    for watchType in pairs(report.s2FreshAddTypes) do
        freshTypes[#freshTypes + 1] = watchType
    end
    table.sort(freshTypes)

    ns.Log.Info("quest watch probe -- copy into Architecture/20260926-Phase07.md section 6.4:")
    ns.Log.Info(format("  S1 watch event timing: %s%s [%s]", report.s1,
        report.s1Evidence and (" (" .. report.s1Evidence .. ")") or "", describeTimingCounts()))
    ns.Log.Info(format("  S2 fresh-add type: %s; automatic watches seen: %d; re-add: %s%s",
        (#freshTypes > 0) and table.concat(freshTypes, "/") or NOT_TESTED,
        report.s2AutomaticWatches, report.s2ReAdd,
        report.s2ReAddChanged and (" -- " .. report.s2ReAddChanged) or ""))
    ns.Log.Info(format("  S3 add position: %s%s", report.s3,
        report.s3Index and (" at " .. report.s3Index) or ""))
    ns.Log.Info("  S4 animation: " .. report.s4)
    ns.Log.Info("  S5 zone sort: " .. report.s5
        .. (report.s5Order and (" -- " .. report.s5Order) or ""))
    ns.Log.Info("  S6 level sources: " .. report.s6
        .. (report.s6Disagree and (" -- " .. report.s6Disagree) or "")
        .. (report.s6NonPositive and (" -- no positive level: " .. report.s6NonPositive) or ""))
    ns.Log.Info("  S7 super-track: " .. report.s7)
    ns.Log.Info("  S8 events inside our call: " .. report.s8
        .. (report.s8Names and (" -- " .. report.s8Names) or ""))
    if report.orderRestored == false then
        ns.Log.Error("  the watch order was NOT restored after Stage A")
    end
    ns.Log.Info("  decision: " .. decide(report))
end

-- Lifecycle ---------------------------------------------------------------------------------

local function enable()
    if not (C_QuestLog and C_QuestLog.GetNumQuestWatches and C_QuestLog.GetQuestIDForQuestWatchIndex) then
        return nil, "this client exposes no quest watch list API"
    end

    probe.enabled = true
    probe.report = newReport()
    probe.deliveries = {}
    probe.awaiting = {}
    probe.lastReturnSequence = {}
    probe.timingCounts = {}
    probe.unattributed = 0
    probe.snapshotTimer = nil
    probe.zoneTimer = nil

    installHooks()

    local watchToken = ns.Dispatch.Subscribe(FEATURE_ID, "QUEST_WATCH_LIST_CHANGED", onWatchListChanged)
    if not watchToken then
        return nil, "this client does not deliver QUEST_WATCH_LIST_CHANGED, so S1 cannot be observed"
    end
    probe.tokens[#probe.tokens + 1] = watchToken

    local zoneToken = ns.Dispatch.Subscribe(FEATURE_ID, "ZONE_CHANGED_NEW_AREA", onNewArea)
    if zoneToken then
        probe.tokens[#probe.tokens + 1] = zoneToken
    else
        ns.Log.Once("questprobe:nozone", "ZONE_CHANGED_NEW_AREA is unavailable; S5 stays NotTested")
    end

    takeSnapshot()
    ns.Log.Info("quest watch probe: Stage P started; the addon writes nothing until Stage A")
    judgeLevelSources()
    ns.Log.Info("next: watch a quest through the game's own interface (accepting one with auto-watch on counts), and change zone once")
    return true
end

-- Tolerates a partial enable: it may run after enable failed half-way.
local function disable()
    probe.enabled = false
    probe.stageARunning = false
    closeWindow()
    for handle in pairs(probe.timers) do
        pcall(handle.Cancel, handle)
    end
    probe.timers = {}
    probe.snapshotTimer = nil
    probe.zoneTimer = nil
    probe.awaiting = {}
    for index = #probe.tokens, 1, -1 do
        ns.Dispatch.Unsubscribe(probe.tokens[index])
        probe.tokens[index] = nil
    end
end

ns.Registry.Register(FEATURE_ID, {
    enabledByDefault = false,
    internal = true,
    label = "Quest watch probe",
    settings = {},
}, {
    enable = enable,
    disable = disable,
    onConfigChanged = function()
        return ns.CONFIG_RESULT.APPLIED
    end,
})

ns.QuestWatchProbe = {}

function ns.QuestWatchProbe.Command(verb, answer)
    verb = string.lower(verb or "")

    if not probe.enabled then
        if verb ~= "" and verb ~= "status" then
            return false, "start the probe first: /pa probe quests"
        end
        local ok, reason = ns.Registry.SetEnabled(FEATURE_ID, true)
        if not ok then
            return false, reason
        end
        return true
    end

    if verb == "" or verb == "status" then
        printReport()
        return true
    end

    if verb == "rewrite" then
        return stageA()
    end

    if verb == "animation" then
        answer = string.lower(answer or "")
        if answer ~= "played" and answer ~= "none" then
            return false, "usage: /pa probe quests animation played|none"
        end
        if probe.report.s7 == NOT_TESTED then
            return false, "run /pa probe quests rewrite first; S4 is observed during it"
        end
        probe.report.s4 = (answer == "played") and "Played" or "NotPlayed"
        printReport()
        ns.Registry.SetEnabled(FEATURE_ID, false)
        ns.Log.Info("probe turned off. Now /reload, then copy the report above into section 6.4")
        return true
    end

    return false, "usage: /pa probe quests [status | rewrite | animation played|none]"
end

-- For the offline harness only.
ns.QuestWatchProbe.Report = function()
    return probe.report
end
ns.QuestWatchProbe.Decide = decide
