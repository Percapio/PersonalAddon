-- Spikes/MeterProbe.lua
-- Phase 4 feasibility. The client ships an accurate first-party damage meter,
-- which means the data exists somewhere addressable. This finds out whether it is
-- addressable by US -- a sanctioned API we can read -- or only by Blizzard, in
-- which case the only options left involve restyling its window.
--
-- Read-only. Nothing here writes to a Blizzard frame.
--
-- Delete once Phase 4's mechanism is decided.

local ADDON_NAME, ns = ...

local FEATURE_ID = "meterProbe"
local format, type, pairs, pcall, tostring = string.format, type, pairs, pcall, tostring

ns.MeterProbe = ns.MeterProbe or {}

-- Output is bounded: iterating the global table can produce a great deal, and a
-- report nobody reads to the end is a report that hides its own answer.
local MAX_ROWS_PER_SECTION = 60

local INTERESTING = { "damage", "meter", "session", "combatlog", "threat" }

local function nameLooksRelevant(name)
    local lowered = string.lower(name)
    for index = 1, #INTERESTING do
        if string.find(lowered, INTERESTING[index], 1, true) then
            return true
        end
    end
    return false
end

local function sortedKeys(container, predicate)
    local keys = {}
    for key in pairs(container) do
        if type(key) == "string" and (not predicate or predicate(key)) then
            keys[#keys + 1] = key
        end
    end
    table.sort(keys)
    return keys
end

local function emitBounded(label, lines)
    if #lines == 0 then
        ns.Log.Warn(format("  %s: nothing found", label))
        return
    end
    ns.Log.Info(format("  %s: %d found", label, #lines))
    local shown = math.min(#lines, MAX_ROWS_PER_SECTION)
    for index = 1, shown do
        ns.Log.Info("    " .. lines[index])
    end
    if #lines > shown then
        ns.Log.Warn(format("    ... and %d more, not shown", #lines - shown))
    end
end

-- Is this value one we could actually put on screen? A number we can hold but
-- neither compute with nor print is worthless for a meter (Phase 1 section 11.1a).
local function describeValue(value)
    local kind = type(value)
    if kind ~= "number" and kind ~= "string" and kind ~= "boolean" then
        return kind
    end
    if kind ~= "number" then
        return format("%s = %s", kind, tostring(value))
    end
    local computable = pcall(function() return value + 0 end)
    local printable = pcall(function() return format("%d", value) end)
    if computable and printable then
        return format("number = %s (usable)", tostring(value))
    end
    return format("number PROTECTED (computable=%s printable=%s)",
        tostring(computable), tostring(printable))
end

-- 1. Sanctioned namespaces ----------------------------------------------------

local function probeNamespaces()
    local lines = {}
    for name, value in pairs(_G) do
        if type(name) == "string" and type(value) == "table"
            and string.sub(name, 1, 2) == "C_" and nameLooksRelevant(name) then
            local functions = sortedKeys(value, function(key)
                return type(value[key]) == "function"
            end)
            lines[#lines + 1] = format("%s  (%d functions)", name, #functions)
            for index = 1, #functions do
                lines[#lines + 1] = "    ." .. functions[index]
            end
        end
    end
    emitBounded("C_* namespaces", lines)
    return #lines > 0
end

-- 2. Global functions and frames ---------------------------------------------

local function probeGlobals()
    local functions, frames = {}, {}
    for name, value in pairs(_G) do
        if type(name) == "string" and nameLooksRelevant(name) then
            local kind = type(value)
            if kind == "function" then
                functions[#functions + 1] = name .. "()"
            elseif kind == "table" and value.GetObjectType then
                local okType, objectType = pcall(value.GetObjectType, value)
                frames[#frames + 1] = format("%s  <%s>", name,
                    okType and tostring(objectType) or "?")
            end
        end
    end
    table.sort(functions)
    table.sort(frames)
    emitBounded("global functions", functions)
    emitBounded("global frames", frames)
end

-- 3. The meter window's own structure ----------------------------------------

local function describeFrame(path, frame)
    if type(frame) ~= "table" then
        ns.Log.Warn(format("  %s: absent", path))
        return nil
    end

    local okType, objectType = pcall(frame.GetObjectType, frame)
    ns.Log.Info(format("  %s: <%s>", path, okType and tostring(objectType) or "not a widget"))

    -- Whether we may MEASURE it is the section 4.7 question, and it decides
    -- whether re-anchoring is possible at all.
    if frame.GetNumPoints then
        local countOk, count = pcall(frame.GetNumPoints, frame)
        if not countOk or count == nil then
            ns.Log.Error(format("    anchors: NOT MEASURABLE (restricted region)"))
        else
            local pointOk, point = pcall(frame.GetPoint, frame, 1)
            if not pointOk or (count > 0 and point == nil) then
                ns.Log.Error("    anchors: NOT MEASURABLE (restricted region)")
            else
                ns.Log.Info(format("    anchors: %d point(s), first is %s",
                    count, tostring(point)))
            end
        end
    end

    if frame.IsForbidden then
        local ok, forbidden = pcall(frame.IsForbidden, frame)
        if ok and forbidden then
            ns.Log.Error("    FORBIDDEN frame: addons may not touch it at all")
        end
    end

    local children, values = {}, {}
    for key, value in pairs(frame) do
        if type(key) == "string" then
            if type(value) == "table" and value.GetObjectType then
                children[#children + 1] = key
            elseif type(value) ~= "function" and type(value) ~= "table" then
                values[#values + 1] = format("%s: %s", key, describeValue(value))
            end
        end
    end
    table.sort(children)
    table.sort(values)

    if #children > 0 then
        ns.Log.Info(format("    child widgets (%d): %s", #children,
            table.concat(children, ", ")))
    end
    emitBounded(path .. " scalar fields", values)
    return frame
end

local function probeMeterWindow()
    local window = _G.DamageMeterSessionWindow1
    if not describeFrame("DamageMeterSessionWindow1", window) then
        ns.Log.Warn("  the session window global was not found; try /pa probe meter globals")
        return
    end

    local container = window.MinimizeContainer
    if describeFrame("  .MinimizeContainer", container) then
        describeFrame("    .SourceWindow", container.SourceWindow)
    end
end

-- 4. The sanctioned API, in depth -------------------------------------------

-- Only these prefixes are ever called. C_CombatLog carries ClearEntries and
-- SetMessageLimit, and a probe that blindly invoked everything it found would
-- wipe the user's combat log to answer a question about damage.
local READ_ONLY_PREFIXES = { "Get", "Is", "Are", "Can", "Has", "Does" }

local function isReadOnlyName(name)
    for index = 1, #READ_ONLY_PREFIXES do
        local prefix = READ_ONLY_PREFIXES[index]
        if string.sub(name, 1, #prefix) == prefix then
            return true
        end
    end
    return false
end

local MAX_DUMP_LINES = 80
local MAX_ARRAY_SAMPLE = 3

local function dumpValue(label, value, depth, indent, lines)
    if #lines >= MAX_DUMP_LINES then
        return
    end

    local kind = type(value)
    if kind ~= "table" then
        lines[#lines + 1] = format("%s%s: %s", indent, label, describeValue(value))
        return
    end

    if value.GetObjectType then
        lines[#lines + 1] = format("%s%s: <widget>", indent, label)
        return
    end

    local arrayCount = #value
    local keys = sortedKeys(value)
    lines[#lines + 1] = format("%s%s: table (%d array entries, %d named keys)",
        indent, label, arrayCount, #keys)

    if depth <= 0 then
        return
    end

    for index = 1, math.min(arrayCount, MAX_ARRAY_SAMPLE) do
        dumpValue("[" .. index .. "]", value[index], depth - 1, indent .. "  ", lines)
    end
    if arrayCount > MAX_ARRAY_SAMPLE then
        lines[#lines + 1] = format("%s  ... %d more entries",
            indent, arrayCount - MAX_ARRAY_SAMPLE)
    end

    for index = 1, #keys do
        dumpValue(keys[index], value[keys[index]], depth - 1, indent .. "  ", lines)
    end
end

local function callAndDump(namespaceName, namespace, functionName, ...)
    local fn = namespace[functionName]
    if type(fn) ~= "function" then
        return nil
    end

    local ok, result = pcall(fn, ...)
    local argCount = select("#", ...)
    local label = format("%s.%s(%s)", namespaceName, functionName,
        argCount > 0 and tostring((...)) or "")

    if not ok then
        ns.Log.Warn(format("  %s -> refused: %s", label, tostring(result)))
        return nil
    end
    if result == nil then
        ns.Log.Warn(format("  %s -> nil", label))
        return nil
    end

    ns.Log.Info(format("  %s ->", label))
    local lines = {}
    dumpValue("result", result, 3, "    ", lines)
    for index = 1, #lines do
        ns.Log.Info(lines[index])
    end
    return result
end

local function probeApi()
    local meter = _G.C_DamageMeter
    if type(meter) ~= "table" then
        ns.Log.Error("  C_DamageMeter is absent")
        return false
    end

    local names = sortedKeys(meter, function(key)
        return type(meter[key]) == "function"
    end)
    ns.Log.Info(format("  C_DamageMeter: %d functions", #names))
    for index = 1, #names do
        ns.Log.Info(format("    .%s%s", names[index],
            isReadOnlyName(names[index]) and "" or "   (not called: not a read-only name)"))
    end

    ns.Log.Info("  --- calling the read-only ones ---")

    local sessions = callAndDump("C_DamageMeter", meter, "GetAvailableCombatSessions")

    -- Session type 0 is what the meter window reports for sessionType, so it is
    -- the value the client itself considers current.
    callAndDump("C_DamageMeter", meter, "GetCombatSessionFromType", 0)

    -- Try an id taken from the available list rather than a guessed number.
    if type(sessions) == "table" then
        local firstId = sessions[1]
        if type(firstId) == "table" then
            firstId = firstId.id or firstId.sessionID or firstId.combatSessionID
        end
        if firstId ~= nil then
            callAndDump("C_DamageMeter", meter, "GetCombatSessionFromID", firstId)
        end
    end

    -- Anything else read-only that takes no argument.
    for index = 1, #names do
        local name = names[index]
        if isReadOnlyName(name)
            and name ~= "GetAvailableCombatSessions"
            and name ~= "GetCombatSessionFromType"
            and name ~= "GetCombatSessionFromID" then
            callAndDump("C_DamageMeter", meter, name)
        end
    end

    -- Closure on the Phase 1 section 11.2 finding: the restriction is queryable,
    -- which makes it deliberate rather than inferred.
    local combatLog = _G.C_CombatLog
    if type(combatLog) == "table" then
        ns.Log.Info("  --- C_CombatLog, read-only calls ---")
        callAndDump("C_CombatLog", combatLog, "IsCombatLogRestricted")
        callAndDump("C_CombatLog", combatLog, "AreFilteredEventsEnabled")
        callAndDump("C_CombatLog", combatLog, "GetMessageLimit")
        callAndDump("C_CombatLog", combatLog, "GetEntryRetentionTime")
    end

    return true
end

-- 5. The data model -----------------------------------------------------------
-- The signatures came free, from the client's own argument errors:
--   GetCombatSessionFromType(sessionType, type)
--   GetCombatSessionFromID(sessionID, type)
--   GetCombatSessionSourceFromID(sessionID, type [, sourceGUID, sourceCreatureID])
--   GetSessionDurationSeconds(sessionType)
-- What remains is which values the two enums take, and what a session and a
-- session source actually contain.

local PROBE_RANGE = 4

-- Prefer the client's own enum names over brute force: a named value we can cite
-- beats an integer we guessed and have to re-guess after a patch.
local function probeEnums()
    if type(Enum) ~= "table" then
        ns.Log.Warn("  Enum is absent")
        return
    end

    local found = 0
    for name, value in pairs(Enum) do
        if type(name) == "string" and type(value) == "table" and nameLooksRelevant(name) then
            found = found + 1
            local pairsList = {}
            for key, enumValue in pairs(value) do
                pairsList[#pairsList + 1] = format("%s = %s", tostring(key), tostring(enumValue))
            end
            table.sort(pairsList)
            ns.Log.Info(format("  Enum.%s: %d values", name, #pairsList))
            for index = 1, math.min(#pairsList, 20) do
                ns.Log.Info("    " .. pairsList[index])
            end
            if #pairsList > 20 then
                ns.Log.Warn(format("    ... %d more", #pairsList - 20))
            end
        end
    end
    if found == 0 then
        ns.Log.Warn("  no relevant Enum tables; the two parameters are plain integers")
    end
end

local function dumpResult(label, result, depth)
    ns.Log.Info("  " .. label .. " ->")
    local lines = {}
    dumpValue("result", result, depth, "    ", lines)
    for index = 1, #lines do
        ns.Log.Info(lines[index])
    end
end

local function probeModel()
    local meter = _G.C_DamageMeter
    if type(meter) ~= "table" then
        ns.Log.Error("  C_DamageMeter is absent")
        return
    end

    probeEnums()

    -- Which (sessionType, type) pairs are accepted at all.
    ns.Log.Info("  --- probing sessionType x type ---")
    local accepted = {}
    for sessionType = 0, PROBE_RANGE do
        for metricType = 0, PROBE_RANGE do
            local ok, session = pcall(meter.GetCombatSessionFromType, sessionType, metricType)
            if ok and session ~= nil then
                accepted[#accepted + 1] = { sessionType = sessionType, metricType = metricType }
            end
        end
    end

    if #accepted == 0 then
        ns.Log.Warn("  no (sessionType, type) pair returned a session; fight something first")
    else
        local names = {}
        for index = 1, #accepted do
            names[#names + 1] = format("(%d,%d)", accepted[index].sessionType,
                accepted[index].metricType)
        end
        ns.Log.Info(format("  accepted pairs: %s", table.concat(names, " ")))

        local first = accepted[1]
        local ok, session = pcall(meter.GetCombatSessionFromType, first.sessionType, first.metricType)
        if ok then
            dumpResult(format("GetCombatSessionFromType(%d, %d)",
                first.sessionType, first.metricType), session, 4)
        end
    end

    for sessionType = 0, PROBE_RANGE do
        local ok, duration = pcall(meter.GetSessionDurationSeconds, sessionType)
        if ok and duration ~= nil then
            ns.Log.Info(format("  GetSessionDurationSeconds(%d) -> %s",
                sessionType, describeValue(duration)))
        end
    end

    -- The call that matters: our own breakdown, filtered by GUID.
    ns.Log.Info("  --- our own source, by GUID ---")
    local playerGuid = UnitGUID("player")
    ns.Log.Info("  player GUID: " .. tostring(playerGuid))

    local sessions = nil
    local listOk, list = pcall(meter.GetAvailableCombatSessions)
    if listOk and type(list) == "table" then
        sessions = list
    end
    local sessionId = sessions and sessions[1] and sessions[1].sessionID or 1

    local reported = false
    for metricType = 0, PROBE_RANGE do
        local ok, source = pcall(meter.GetCombatSessionSourceFromID,
            sessionId, metricType, playerGuid)
        if ok and source ~= nil then
            dumpResult(format("GetCombatSessionSourceFromID(%d, %d, <player>)",
                sessionId, metricType), source, 4)
            reported = true
            break
        end
    end

    if not reported then
        -- Without the GUID filter, in case the argument is positional-sensitive.
        for metricType = 0, PROBE_RANGE do
            local ok, source = pcall(meter.GetCombatSessionSourceFromID, sessionId, metricType)
            if ok and source ~= nil then
                dumpResult(format("GetCombatSessionSourceFromID(%d, %d)",
                    sessionId, metricType), source, 4)
                reported = true
                break
            end
        end
    end

    if not reported then
        ns.Log.Warn("  no session source returned; this is where the spell breakdown lives, so it needs answering")
    end
end

-- 6. Capture to disk ----------------------------------------------------------
-- Chat is a poor transport for a data model: it wraps, truncates, and cannot be
-- copied out in bulk. Saved variables are an ordinary file on disk, so the probe
-- writes the raw structures there and they can be read directly.
--
-- A SEPARATE saved variable, deliberately. PersonalAddonDB is the config store,
-- and its hydration prunes any key no feature declares (Phase 1 section 5.2 step
-- 4) -- probe output written there would be silently deleted on the next login.

local MAX_CAPTURE_ENTRIES = 60

-- Saved variables can only hold plain values. Anything else is reduced to a
-- description rather than dropped, so an unexpected type shows up in the file
-- instead of vanishing from it.
local function sanitize(value, depth)
    local kind = type(value)
    if kind == "number" or kind == "string" or kind == "boolean" then
        return value
    end
    if kind ~= "table" then
        return "<" .. kind .. ">"
    end
    if value.GetObjectType then
        return "<widget>"
    end
    if depth <= 0 then
        return "<table, depth limit>"
    end

    local copy, count = {}, 0
    for key, inner in pairs(value) do
        if type(key) == "string" or type(key) == "number" then
            count = count + 1
            if count > MAX_CAPTURE_ENTRIES then
                copy.__truncated = true
                break
            end
            copy[key] = sanitize(inner, depth - 1)
        end
    end
    return copy
end

local function captureEnums()
    local captured = {}
    if type(Enum) ~= "table" then
        return captured
    end
    for name, value in pairs(Enum) do
        if type(name) == "string" and type(value) == "table" and nameLooksRelevant(name) then
            captured[name] = sanitize(value, 2)
        end
    end
    return captured
end

local function probeCapture()
    local meter = _G.C_DamageMeter
    if type(meter) ~= "table" then
        ns.Log.Error("  C_DamageMeter is absent; nothing to capture")
        return false
    end

    local captured = {
        capturedAt = date and date("%Y-%m-%d %H:%M:%S") or "unknown",
        addonVersion = ns.VERSION,
        playerGuid = UnitGUID("player"),
        enums = captureEnums(),
        isDamageMeterAvailable = select(2, pcall(meter.IsDamageMeterAvailable)),
        isCombatLogRestricted = C_CombatLog
            and select(2, pcall(C_CombatLog.IsCombatLogRestricted)) or nil,
        acceptedPairs = {},
        durations = {},
        sessions = nil,
        sessionSamples = {},
        sourceSamples = {},
    }

    local listOk, list = pcall(meter.GetAvailableCombatSessions)
    if listOk then
        captured.sessions = sanitize(list, 3)
    end

    for sessionType = 0, PROBE_RANGE do
        local ok, duration = pcall(meter.GetSessionDurationSeconds, sessionType)
        if ok and duration ~= nil then
            captured.durations[sessionType] = sanitize(duration, 1)
        end

        for metricType = 0, PROBE_RANGE do
            local sessionOk, session = pcall(meter.GetCombatSessionFromType,
                sessionType, metricType)
            if sessionOk and session ~= nil then
                captured.acceptedPairs[#captured.acceptedPairs + 1] =
                    { sessionType = sessionType, metricType = metricType }
                -- One full sample per metric type is enough to learn the shape;
                -- thirteen sessions of it is noise.
                if captured.sessionSamples[metricType] == nil then
                    captured.sessionSamples[metricType] = sanitize(session, 6)
                end
            end
        end
    end

    local sessionId = nil
    if listOk and type(list) == "table" and list[1] then
        sessionId = list[1].sessionID
    end

    local playerGuid = UnitGUID("player")
    for metricType = 0, PROBE_RANGE do
        if sessionId then
            local ok, source = pcall(meter.GetCombatSessionSourceFromID,
                sessionId, metricType, playerGuid)
            if ok and source ~= nil then
                captured.sourceSamples["byId_" .. metricType] = sanitize(source, 6)
            end
        end
        local typeOk, sourceByType = pcall(meter.GetCombatSessionSourceFromType,
            0, metricType, playerGuid)
        if typeOk and sourceByType ~= nil then
            captured.sourceSamples["byType_" .. metricType] = sanitize(sourceByType, 6)
        end
    end

    _G.PersonalAddonProbeLog = captured

    ns.Log.Info(format("captured %d accepted pair(s), %d session sample(s), %d source sample(s)",
        #captured.acceptedPairs,
        (function() local n = 0 for _ in pairs(captured.sessionSamples) do n = n + 1 end return n end)(),
        (function() local n = 0 for _ in pairs(captured.sourceSamples) do n = n + 1 end return n end)()))
    ns.Log.Warn("now type /reload -- saved variables are only written on reload or logout (Phase 1 section 5.4)")
    return true
end

-- Report ----------------------------------------------------------------------

function ns.MeterProbe.Command(argument)
    if ns.Registry.State(FEATURE_ID) ~= ns.FEATURE_STATE.ENABLED then
        return false, "enable it first: /pa on " .. FEATURE_ID
    end

    argument = string.lower(argument or "run")

    ns.Log.Info("damage meter probe:")

    if argument == "globals" then
        probeGlobals()
        return true
    end

    if argument == "window" then
        probeMeterWindow()
        return true
    end

    if argument == "api" then
        probeApi()
        return true
    end

    if argument == "model" then
        probeModel()
        return true
    end

    if argument == "capture" then
        return probeCapture()
    end

    -- Tier order matters: a sanctioned API makes everything else unnecessary, so
    -- it is reported first.
    local haveNamespace = probeNamespaces()
    probeGlobals()
    probeMeterWindow()

    ns.Log.Info("---")
    if haveNamespace then
        ns.Log.Info("a candidate namespace exists: run /pa probe meter api for its shape")
    else
        ns.Log.Warn("no candidate namespace found: tier 1 is unlikely, and Phase 4 falls to restyling Blizzard's window")
    end
    ns.Log.Info("record the findings in Architecture/20260919-Phase04.md when it is drafted")
    return true
end

local function enable()
    ns.Log.Info("meter probe armed; run /pa probe meter after a fight, with the built-in meter open")
    return true
end

local function disable()
end

ns.Registry.Register(FEATURE_ID, {
    enabledByDefault = false,
    settings = {},
}, {
    enable = enable,
    disable = disable,
    onConfigChanged = function()
        return ns.CONFIG_RESULT.APPLIED
    end,
})
