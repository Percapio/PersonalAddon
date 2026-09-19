-- Core/Log.lua
-- Surfacing, with once-per-key suppression. §7 property 2: the first error is
-- printed, the rest are counted. Nothing in this addon degrades silently, and
-- nothing in it spams either.

local ADDON_NAME, ns = ...

local Log = {}
ns.Log = Log

local emitted = {}
local counts = {}

local function emit(text)
    print(ns.CHAT_PREFIX .. tostring(text))
end

function Log.Info(text)
    emit(text)
end

function Log.Warn(text)
    emit("|cffffcc00" .. tostring(text) .. "|r")
end

function Log.Error(text)
    emit("|cffff5555" .. tostring(text) .. "|r")
end

-- Emits once per key per session. Returns true on the emitting call only.
function Log.Once(key, text)
    counts[key] = (counts[key] or 0) + 1
    if emitted[key] then
        return false
    end
    emitted[key] = true
    Log.Warn(text)
    return true
end

function Log.OnceError(key, text)
    counts[key] = (counts[key] or 0) + 1
    if emitted[key] then
        return false
    end
    emitted[key] = true
    Log.Error(text)
    return true
end

function Log.SuppressedCount(key)
    local total = counts[key] or 0
    if total <= 1 then
        return 0
    end
    return total - 1
end

function Log.Keys()
    local keys = {}
    for key in pairs(counts) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    return keys
end

function Log.Notices(notices)
    if type(notices) ~= "table" then
        return 0
    end
    for i = 1, #notices do
        Log.Warn(notices[i])
    end
    return #notices
end
