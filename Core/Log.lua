-- Core/Log.lua
-- Surfacing, with once-per-key suppression. §7 property 2: the first error is
-- printed, the rest are counted. Nothing in this addon degrades silently, and
-- nothing in it spams either.

local ADDON_NAME, ns = ...

local Log = {}
ns.Log = Log

local emitted = {}
local counts = {}

-- Output goes to a chat frame we resolve ourselves, never through print().
--
-- Blizzard's taint log named this addon as the tainter of two globals:
--
--   Execution tainted by PersonalAddon while reading global SELECTED_CHAT_FRAME
--   Execution tainted by PersonalAddon while reading global LAST_ACTIVE_CHAT_EDIT_BOX
--
-- both holding the same chat frame table. print() resolves its destination
-- through SELECTED_CHAT_FRAME, a shared mutable global that Blizzard's chat code
-- and other addons also read -- so our output put this addon's taint on the path
-- every one of them walks. The propagation in the log runs out through Chatify
-- and back into Blizzard's chat internals.
--
-- Resolving our own frame keeps our writes off the shared globals.
--
-- Deliberately not cached. Log.lua loads before the chat frames exist, so any
-- cache must be lazy, and a lazy cache holding a frame that has since been
-- replaced keeps writing to the dead one. Two table lookups per message is not a
-- cost worth that.
local function resolveChatTarget()
    -- DEFAULT_CHAT_FRAME is a fixed reference to frame 1. SELECTED_CHAT_FRAME is
    -- deliberately NOT consulted: it is the global the taint log named, and it
    -- changes under us whenever the user picks a different tab.
    local candidate = _G.DEFAULT_CHAT_FRAME or _G.ChatFrame1
    if candidate and candidate.AddMessage then
        return candidate
    end
    return nil
end

local function emit(text)
    local line = ns.CHAT_PREFIX .. tostring(text)
    local target = resolveChatTarget()
    if target then
        target:AddMessage(line)
        return
    end
    -- No chat frame at all: better to print than to lose the message. This is the
    -- path that taints, and it is reached only when the alternative is silence.
    print(line)
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
