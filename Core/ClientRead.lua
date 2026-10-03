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

local type, pcall = type, pcall

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
