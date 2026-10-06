-- Core/ClientRead.lua
-- The one seam every value the client may make secret passes through before any
-- other code touches it (Architecture/20261002-Phase09.md section 2, README rule 10).
--
-- On an addon-restricted map -- a dungeon or raid -- and in combat, the client
-- returns secret values from many functions. A secret value is not an error: the
-- call succeeds, and comparing, testing or doing arithmetic on the result raises
-- in our code. A pcall around the call catches nothing, because the call did not
-- fail. That is how the nameplate sweep died 7,843 times in the 2026-10-01 dungeon
-- (GAPBugs01 section 3).
--
-- So a read here answers three ways: Plain (a value we may use), Absent (the client
-- said nil), or Withheld (with the reason). Each function returns two values, the
-- kind and then the value or the reason, so no read allocates. The accessibility
-- check is the first thing applied to any value, the nil test included.
--
-- Stateless: callers count what comes back.

local ADDON_NAME, ns = ...

local ClientRead = {}
ns.ClientRead = ClientRead

local type, pcall, select = type, pcall, select

local PLAIN, ABSENT, WITHHELD = "Plain", "Absent", "Withheld"
local UNAVAILABLE, CALL_FAILED = "Unavailable", "CallFailed"
local SECRET_VALUE, UNEXPECTED_TYPE = "SecretValue", "UnexpectedType"

ClientRead.PLAIN = PLAIN
ClientRead.ABSENT = ABSENT
ClientRead.WITHHELD = WITHHELD
ClientRead.UNAVAILABLE = UNAVAILABLE
ClientRead.CALL_FAILED = CALL_FAILED
ClientRead.SECRET_VALUE = SECRET_VALUE
ClientRead.UNEXPECTED_TYPE = UNEXPECTED_TYPE

-- Resolved per call rather than cached at load: the predicates are client globals,
-- and a harness or a later client may define them after this file runs.
local function accessible(value)
    local canAccess = _G.canaccessvalue
    if type(canAccess) == "function" then
        return canAccess(value) == true
    end
    local isSecret = _G.issecretvalue
    if type(isSecret) == "function" then
        return isSecret(value) ~= true
    end
    return true
end

-- Whether this code may read a table's contents. A table can be readable as a
-- value and still be flagged so that indexing it would produce secrets.
local function tableAccessible(container)
    local canAccessTable = _G.canaccesstable
    if type(canAccessTable) == "function" then
        return canAccessTable(container) == true
    end
    local isSecretTable = _G.issecrettable
    if type(isSecretTable) == "function" then
        return isSecretTable(container) ~= true
    end
    return true
end

-- The reason a value fails to be a plain value of expectedType, or nil when it is
-- one. A nil value fails as UnexpectedType: callers that accept nil use Classify.
local function failureOf(value, expectedType)
    if not accessible(value) then
        return SECRET_VALUE
    end
    if type(value) ~= expectedType then
        return UNEXPECTED_TYPE
    end
    return nil
end

-- Classifies one value already in hand, such as an event payload field.
function ClientRead.Classify(value, expectedType)
    if not accessible(value) then
        return WITHHELD, SECRET_VALUE
    end
    if value == nil then
        return ABSENT, nil
    end
    if type(value) ~= expectedType then
        return WITHHELD, UNEXPECTED_TYPE
    end
    return PLAIN, value
end
local classify = ClientRead.Classify

-- Calls a client function and classifies its first return.
function ClientRead.Call(clientFunction, expectedType, ...)
    if type(clientFunction) ~= "function" then
        return WITHHELD, UNAVAILABLE
    end
    local ok, value = pcall(clientFunction, ...)
    if not ok then
        return WITHHELD, CALL_FAILED
    end
    return classify(value, expectedType)
end

-- Calls a client function that returns several values of one type, and returns
-- the kind followed by the first count of them. Supports up to four, which covers
-- every caller (GetStatusBarColor's r, g, b, a) without building a table.
function ClientRead.CallMany(clientFunction, count, expectedType, ...)
    if type(clientFunction) ~= "function" then
        return WITHHELD, UNAVAILABLE
    end
    local ok, first, second, third, fourth = pcall(clientFunction, ...)
    if not ok then
        return WITHHELD, CALL_FAILED
    end
    local reason = failureOf(first, expectedType)
    if not reason and count >= 2 then
        reason = failureOf(second, expectedType)
    end
    if not reason and count >= 3 then
        reason = failureOf(third, expectedType)
    end
    if not reason and count >= 4 then
        reason = failureOf(fourth, expectedType)
    end
    if reason then
        return WITHHELD, reason
    end
    return PLAIN, first, second, third, fourth
end

-- Takes pcall's returns and keeps the status and the index-th value after it, so
-- one return of a multi-value call is picked without building a table. A value
-- past the last return is nil. Nothing here looks at the value.
local function statusAndNth(index, ok, ...)
    if not ok then
        return false, nil
    end
    return true, (select(index, ...))
end

-- Calls a client function and classifies only its index-th return, for calls
-- whose returns differ in type (UnitDetailedThreatSituation: boolean, number,
-- number, number, number). Phase 11 section 4.2.
function ClientRead.CallNth(clientFunction, index, expectedType, ...)
    if type(clientFunction) ~= "function" then
        return WITHHELD, UNAVAILABLE
    end
    local ok, value = statusAndNth(index, pcall(clientFunction, ...))
    if not ok then
        return WITHHELD, CALL_FAILED
    end
    return classify(value, expectedType)
end

-- Pass's outcomes: Shown, then whether the value handed over was hidden; Absent;
-- or Unavailable, then the reason.
local SHOWN, SETTER_FAILED = "Shown", "SetterFailed"
ClientRead.SHOWN = SHOWN
ClientRead.SETTER_FAILED = SETTER_FAILED

-- Calls a client function and hands its index-th return, untouched, to a widget
-- method: setter(receiver, value), or setter(receiver, leading, value) when leading
-- is given. The value is never compared, tested or computed on; only its
-- accessibility is asked, so that a readable nil can be told from a hidden value.
-- For widget methods whose docs accept hidden arguments (SecretArguments =
-- "AllowedWhenTainted"), which the patch check guards. Phase 11 section 4.2.
--
-- A readable nil is Absent and the setter is not called: the caller clears the
-- field. The function missing (Unavailable), the call raising (CallFailed) and the
-- setter raising (SetterFailed) are Unavailable, with the reason.
function ClientRead.Pass(setter, receiver, leading, index, clientFunction, ...)
    if type(clientFunction) ~= "function" then
        return UNAVAILABLE, UNAVAILABLE
    end
    local ok, value = statusAndNth(index, pcall(clientFunction, ...))
    if not ok then
        return UNAVAILABLE, CALL_FAILED
    end
    local hidden = not accessible(value)
    if not hidden and value == nil then
        return ABSENT, nil
    end
    local setterOk
    if leading == nil then
        setterOk = pcall(setter, receiver, value)
    else
        setterOk = pcall(setter, receiver, leading, value)
    end
    if not setterOk then
        return UNAVAILABLE, SETTER_FAILED
    end
    return SHOWN, hidden
end

local function indexOf(container, key)
    return container[key]
end

-- Reads one field of a table the client returned. Nothing is indexed until the
-- container is known to be an accessible table, and the index itself runs under
-- pcall, because a client table's metatable can raise.
function ClientRead.Field(container, key, expectedType)
    if not accessible(container) then
        return WITHHELD, SECRET_VALUE
    end
    if type(container) ~= "table" then
        return WITHHELD, UNEXPECTED_TYPE
    end
    if not tableAccessible(container) then
        return WITHHELD, SECRET_VALUE
    end
    local ok, value = pcall(indexOf, container, key)
    if not ok then
        return WITHHELD, CALL_FAILED
    end
    return classify(value, expectedType)
end

-- Whether a client function exists, without reading anything from it. Capability
-- checks go through here too, so the secret-read lint sees every reference.
function ClientRead.Available(candidate)
    return type(candidate) == "function"
end
