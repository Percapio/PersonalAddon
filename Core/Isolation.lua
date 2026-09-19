-- Core/Isolation.lua
-- The protected-call boundary every lifecycle hook, migration step, combat log
-- filter and event handler crosses (§7). One feature's error must not silence
-- the others.

local ADDON_NAME, ns = ...

local Isolation = {}
ns.Isolation = Isolation

local select, xpcall, tostring, unpack = select, xpcall, tostring, unpack

-- WoW's xpcall forwards trailing arguments; stock Lua 5.1's does not. Probe it
-- once at load rather than guessing, and take the allocating path only if the
-- client turns out to be strict.
local PASSES_ARGS
do
    local ok, value = xpcall(function(probe) return probe end, function() end, 42)
    PASSES_ARGS = (ok == true and value == 42)
end

local function annotate(err)
    if debugstack then
        return tostring(err) .. "\n" .. debugstack(2, 6, 6)
    end
    return tostring(err)
end

-- Calls fn(...) under protection. Returns ok followed by fn's return values,
-- or false and an annotated error string.
function Isolation.Call(fn, ...)
    if PASSES_ARGS then
        return xpcall(fn, annotate, ...)
    end

    local count = select("#", ...)
    if count == 0 then
        return xpcall(fn, annotate)
    end

    -- Lua 5.1 cannot capture "..." in a nested closure, so the strict path has
    -- to pack. It only runs on a client whose xpcall rejected the probe.
    local packed = { ... }
    return xpcall(function()
        return fn(unpack(packed, 1, count))
    end, annotate)
end

function Isolation.ForwardsArguments()
    return PASSES_ARGS
end
