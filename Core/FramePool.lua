-- Core/FramePool.lua
-- Bounded, per-pool capacity and policy (§8). There is no unbounded mode.
-- No Phase 1 feature consumes this; Phase 2 acquires a frame per nameplate
-- unit, and retrofitting pooling into a module that already creates frames
-- inline is a rewrite of that module's lifetime handling.

local ADDON_NAME, ns = ...

local FramePool = {}
ns.FramePool = FramePool

local type, format, remove = type, string.format, table.remove
local POLICY = ns.DROP_POLICY

local function markLive(pool, frame)
    pool.live[#pool.live + 1] = frame
    pool.isLive[frame] = true
    return frame
end

function FramePool.Create(spec)
    assert(type(spec) == "table", "FramePool.Create requires a spec table")
    assert(type(spec.poolName) == "string" and spec.poolName ~= "",
        "FramePool.Create requires poolName")
    assert(type(spec.capacity) == "number" and spec.capacity > 0,
        "FramePool.Create requires capacity > 0")
    assert(spec.dropPolicy == POLICY.SURFACE_AND_FAIL
        or spec.dropPolicy == POLICY.RECYCLE_OLDEST,
        "FramePool.Create requires an explicit dropPolicy")
    assert(type(spec.factory) == "function", "FramePool.Create requires factory")
    assert(type(spec.reset) == "function", "FramePool.Create requires reset")

    return {
        poolName = spec.poolName,
        capacity = spec.capacity,
        dropPolicy = spec.dropPolicy,
        factory = spec.factory,
        reset = spec.reset,
        free = {},
        live = {},
        isLive = {},
        constructed = 0,
    }
end

-- Returns frame, or nil and "POOL_EXHAUSTED".
function FramePool.Acquire(pool)
    local frame = remove(pool.free)
    if frame then
        pool.reset(frame)
        return markLive(pool, frame)
    end

    if pool.constructed < pool.capacity then
        frame = pool.factory()
        pool.constructed = pool.constructed + 1
        pool.reset(frame)
        return markLive(pool, frame)
    end

    if pool.dropPolicy == POLICY.RECYCLE_OLDEST then
        -- Evict the least-recently-acquired live frame. Its previous holder's
        -- reference is invalid from here; that constraint is the price of this
        -- policy and is why it is a per-pool choice.
        local oldest = remove(pool.live, 1)
        if not oldest then
            return nil, "POOL_EXHAUSTED"
        end
        pool.isLive[oldest] = nil
        pool.reset(oldest)
        return markLive(pool, oldest)
    end

    ns.Log.Once("pool:" .. pool.poolName .. ":exhausted", format(
        "frame pool '%s' hit its cap of %d; the cap is wrong",
        pool.poolName, pool.capacity))
    return nil, "POOL_EXHAUSTED"
end

function FramePool.Release(pool, frame)
    if frame == nil then
        return false
    end

    if not pool.isLive[frame] then
        ns.Log.Once("pool:" .. pool.poolName .. ":doublerelease", format(
            "frame pool '%s' saw a release of a frame it does not hold; ignored",
            pool.poolName))
        return false
    end

    pool.isLive[frame] = nil
    -- Linear, but bounded by capacity and only on release.
    for index = 1, #pool.live do
        if pool.live[index] == frame then
            remove(pool.live, index)
            break
        end
    end

    pool.reset(frame)
    pool.free[#pool.free + 1] = frame
    return true
end

function FramePool.ReleaseAll(pool)
    local released = 0
    for index = #pool.live, 1, -1 do
        if FramePool.Release(pool, pool.live[index]) then
            released = released + 1
        end
    end
    return released
end

function FramePool.Stats(pool)
    return pool.constructed, #pool.live, #pool.free, pool.capacity
end
