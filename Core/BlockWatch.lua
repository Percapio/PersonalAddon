-- Core/BlockWatch.lua
-- Records every protected call the client blocks while naming this addon.
--
-- This lived in Spikes/GossipProbe.lua, which is internal and off by default.
-- That placement produced a false negative on the first occasion it mattered:
-- roughly 200 blocked calls were reported in one session, and a later controlled
-- run came back "nothing has been blocked" -- not because nothing was blocked, but
-- because the probe that owned the subscription was disabled. An empty result and
-- an absent observer are different facts and the readout could not tell them
-- apart.
--
-- So it is core, always on, and reports whether or not anything else is enabled.
-- It also outlives the Spikes folder, which Phase 6 deletes.
--
-- What it CANNOT tell you: whether the blocked call was ours. The client names the
-- addon it holds responsible, and taint spreads -- our code touches something,
-- Blizzard's code runs with our taint on it, and Blizzard's own protected call is
-- refused with our name attached. `attemptLabel` carries whatever deliberate
-- action of ours was in flight, and "unknown" means none was, which is evidence of
-- spread rather than of a call we made.

local ADDON_NAME, ns = ...

local FEATURE_ID = "blockWatch"

local BlockWatch = {}
ns.BlockWatch = BlockWatch

local format, pairs, tostring = string.format, pairs, tostring

local watch = {
    tokens = {},
    byFunction = {},
    order = {},
    totalBlocks = 0,
    attemptLabel = nil,
}

-- Set by a probe around a deliberate attempt, so a block that follows can be
-- attributed to it. Cleared by passing nil; a probe that forgets to clear leaves
-- every later block mislabelled as its own, so the label is the probe's to own.
function BlockWatch.NoteAttempt(label)
    watch.attemptLabel = label
end

function BlockWatch.CurrentAttempt()
    return watch.attemptLabel
end

local function recordBlocked(addonName, functionName)
    if addonName ~= ADDON_NAME then
        return
    end

    local blockedName = tostring(functionName or "unnamed")
    local attempt = watch.attemptLabel or "unknown"

    local entry = watch.byFunction[blockedName]
    if not entry then
        entry = { count = 0, firstAttempt = attempt }
        watch.byFunction[blockedName] = entry
        watch.order[#watch.order + 1] = blockedName
    end
    entry.count = entry.count + 1
    watch.totalBlocks = watch.totalBlocks + 1

    -- Deduped per function. The un-deduped version printed the same line about
    -- two hundred times in one session and buried the only other line printed,
    -- which is an unbounded log and a defect in its own right.
    ns.Log.OnceError("blockwatch:" .. blockedName, format(
        "BLOCKED: a protected function was called with this addon named (%s), attempt in flight: '%s'. /pa blocked for the tally",
        blockedName, attempt))
end

-- Distinct blocked functions in the order first seen, with counts.
function BlockWatch.Tally()
    local rows = {}
    for index = 1, #watch.order do
        local blockedName = watch.order[index]
        local entry = watch.byFunction[blockedName]
        rows[#rows + 1] = {
            functionName = blockedName,
            count = entry.count,
            firstAttempt = entry.firstAttempt,
        }
    end
    return rows
end

function BlockWatch.TotalBlocks()
    return watch.totalBlocks
end

-- Distinguishes "observing and saw nothing" from "not observing", which is the
-- confusion that made the first controlled run worthless.
function BlockWatch.IsObserving()
    return #watch.tokens > 0
end

local function enable()
    local subscribed = 0
    for _, eventName in ipairs({ "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN" }) do
        local token = ns.Dispatch.Subscribe(FEATURE_ID, eventName, recordBlocked)
        if token then
            watch.tokens[#watch.tokens + 1] = token
            subscribed = subscribed + 1
        end
    end

    if subscribed == 0 then
        return false, "this client refused both blocked-action events, so protected-call blame cannot be observed"
    end
    return true
end

local function disable()
    for index = #watch.tokens, 1, -1 do
        ns.Dispatch.Unsubscribe(watch.tokens[index])
        watch.tokens[index] = nil
    end
    watch.attemptLabel = nil
end

local function onConfigChanged()
    return ns.CONFIG_RESULT.APPLIED
end

ns.Registry.Register(FEATURE_ID, {
    enabledByDefault = true,
    internal = true,
    label = "Blocked-action watch",
    description = "Records protected calls the client blocks with this addon named.",
    settings = {},
    schema = {},
}, {
    enable = enable,
    disable = disable,
    onConfigChanged = onConfigChanged,
})
