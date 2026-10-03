-- Core/Diagnostics.lua
-- Per-session counters and fault notes, kept in the PersonalAddonDiagnostics saved
-- variable so a run can be read from disk afterwards
-- (Architecture/20261002-Phase09.md section 3).
--
-- The 2026-10-01 dungeon left its evidence only in BugGrabber: Chatify's 250-line
-- window had already scrolled past it. A session here is one UI load, a login or a
-- /reload, as in BugGrabber.
--
-- The counter tables ARE the saved tables. A feature asks for its table once and
-- increments it directly, so whatever the client writes at unload is current, a
-- disconnect included, with no logout handler: PLAYER_LOGOUT is a SynchronousEvent,
-- and README rule 1 forbids subscribing to one without knowing what raises it.
--
-- The log binds in this addon's ADDON_LOADED, called from Registry right after the
-- config store hydrates. Saved variables are loaded by then; binding earlier would
-- capture an empty global that the client then replaces, losing the session. A
-- table handed out before the bind is adopted into the record when it binds, so the
-- reference a feature holds is always the saved one (Phase 9 audit finding 5).

local ADDON_NAME, ns = ...

local Diagnostics = {}
ns.Diagnostics = Diagnostics

local type, pairs, tostring, format, sub = type, pairs, tostring, string.format, string.sub
local remove = table.remove

local SAVED_VARIABLE = "PersonalAddonDiagnostics"

local diag = {
    log = nil,
    session = nil,
    -- Every counter table handed out this UI load, by feature, bound or not.
    counters = {},
    -- Fault notes made before the bind, adopted with the counters.
    pendingFaults = {},
}

local function newLog()
    return { formatVersion = ns.DIAGNOSTICS_FORMAT_VERSION, sessions = {} }
end

local function isSequence(value)
    if type(value) ~= "table" then
        return false
    end
    local entries = 0
    for _ in pairs(value) do
        entries = entries + 1
    end
    return entries == #value
end

local function isValidCounters(counters)
    if type(counters) ~= "table" then
        return false
    end
    for featureId, featureCounters in pairs(counters) do
        if type(featureId) ~= "string" or type(featureCounters) ~= "table" then
            return false
        end
        for name, value in pairs(featureCounters) do
            if type(name) ~= "string" then
                return false
            end
            if type(value) ~= "number" and type(value) ~= "boolean" then
                return false
            end
        end
    end
    return true
end

local function isValidFault(note)
    return type(note) == "table" and type(note.featureId) == "string"
        and type(note.at) == "number" and type(note.message) == "string"
end

local function isValidRecord(record)
    if type(record) ~= "table" then
        return false
    end
    if type(record.startedAt) ~= "number" or type(record.clientBuild) ~= "string"
        or type(record.addonVersion) ~= "string" then
        return false
    end
    if not isValidCounters(record.counters) or not isSequence(record.faults) then
        return false
    end
    for index = 1, #record.faults do
        if not isValidFault(record.faults[index]) then
            return false
        end
    end
    return true
end

-- Returns the saved log when it can be trusted, otherwise nil and the reason. The
-- file is user-editable, so nothing in it is taken on faith (section 3.5).
local function validated(persisted)
    if type(persisted) ~= "table" then
        return nil, "WrongShape"
    end
    if persisted.formatVersion ~= ns.DIAGNOSTICS_FORMAT_VERSION then
        return nil, "UnknownFormatVersion"
    end
    if not isSequence(persisted.sessions) then
        return nil, "WrongShape"
    end
    for index = 1, #persisted.sessions do
        if not isValidRecord(persisted.sessions[index]) then
            return nil, "WrongShape"
        end
    end
    return persisted, nil
end

-- A record that counted nothing and noted nothing: a load spent at the character
-- screen, or a quick /reload. Dropped so it does not take one of the five slots.
local function isEmpty(record)
    if #record.faults > 0 then
        return false
    end
    for _, counters in pairs(record.counters) do
        for _, value in pairs(counters) do
            if value ~= 0 and value ~= false then
                return false
            end
        end
    end
    return true
end

local function clientBuild()
    if type(_G.GetBuildInfo) ~= "function" then
        return "unknown"
    end
    local version, build = _G.GetBuildInfo()
    if version and build then
        return tostring(version) .. "." .. tostring(build)
    end
    return tostring(version or "unknown")
end

-- Binds the saved log and opens this UI load's record. Called once, from
-- Registry's ADDON_LOADED handler; later calls return the same record.
function Diagnostics.OpenSession()
    if diag.session then
        return diag.session
    end

    local persisted = _G[SAVED_VARIABLE]
    local log, reason = validated(persisted)
    if not log then
        log = newLog()
        if persisted ~= nil then
            ns.Log.OnceError("diag:reset", format(
                "the saved diagnostics log was unreadable (%s), so a new one was started",
                tostring(reason)))
        end
    end

    local kept = {}
    for index = 1, #log.sessions do
        if not isEmpty(log.sessions[index]) then
            kept[#kept + 1] = log.sessions[index]
        end
    end
    log.sessions = kept

    local session = {
        startedAt = time(),
        clientBuild = clientBuild(),
        addonVersion = tostring(ns.VERSION),
        counters = {},
        faults = {},
    }
    for featureId, counters in pairs(diag.counters) do
        session.counters[featureId] = counters
    end
    for index = 1, #diag.pendingFaults do
        session.faults[#session.faults + 1] = diag.pendingFaults[index]
    end
    diag.pendingFaults = {}

    log.sessions[#log.sessions + 1] = session
    while #log.sessions > ns.DIAGNOSTICS_SESSION_CAPACITY do
        remove(log.sessions, 1)
    end

    _G[SAVED_VARIABLE] = log
    diag.log = log
    diag.session = session
    return session
end

-- The live counter table a feature increments. The same table for the rest of the
-- UI load, saved from the bind on.
function Diagnostics.CountersFor(featureId)
    local counters = diag.counters[featureId]
    if counters then
        return counters
    end
    counters = {}
    diag.counters[featureId] = counters
    if diag.session then
        diag.session.counters[featureId] = counters
    end
    return counters
end

-- Adds one to a counter. A helper rather than a pattern repeated in every feature.
function Diagnostics.Bump(counters, name, amount)
    counters[name] = (counters[name] or 0) + (amount or 1)
end

-- Keeps a fault message for after-the-fact reading: neutralized, cut to length,
-- and bounded per UI load.
function Diagnostics.NoteFault(featureId, message)
    local faults = diag.session and diag.session.faults or diag.pendingFaults
    if #faults >= ns.DIAGNOSTICS_FAULT_NOTE_CAPACITY then
        Diagnostics.Bump(Diagnostics.CountersFor(featureId), "faultNotesDropped")
        return false
    end
    local kind, text = ns.ClientRead.Classify(message, "string")
    if kind ~= ns.ClientRead.PLAIN then
        text = "<a fault message the client withheld>"
    end
    faults[#faults + 1] = {
        featureId = tostring(featureId),
        at = time(),
        message = sub(ns.EscapeGuard.Neutralize(text), 1, ns.DIAGNOSTICS_FAULT_NOTE_LENGTH),
    }
    return true
end

-- Drops every record but this UI load's. Returns how many were dropped.
function Diagnostics.ClearPrevious()
    if not diag.log then
        return 0
    end
    local dropped = #diag.log.sessions - 1
    diag.log.sessions = { diag.session }
    return dropped > 0 and dropped or 0
end

-- The records, oldest first, for /pa diag. Before the bind, only what this UI load
-- has gathered so far.
function Diagnostics.Sessions()
    if diag.log then
        return diag.log.sessions, diag.session
    end
    local provisional = {
        startedAt = time(),
        clientBuild = clientBuild(),
        addonVersion = tostring(ns.VERSION),
        counters = diag.counters,
        faults = diag.pendingFaults,
    }
    return { provisional }, provisional
end

function Diagnostics.IsBound()
    return diag.session ~= nil
end
