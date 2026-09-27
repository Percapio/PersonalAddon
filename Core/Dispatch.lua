-- Core/Dispatch.lua
-- Features never register client events directly (§7). The dispatcher owns the
-- frame, wraps every handler, and drops the underlying registration when the
-- last subscriber for an event goes away.

local ADDON_NAME, ns = ...

local Dispatch = {}
ns.Dispatch = Dispatch

local type, format, remove = type, string.format, table.remove
local pcall, select, tostring, unpack = pcall, select, tostring, unpack

local COMBAT_LOG_EVENT = "COMBAT_LOG_EVENT_UNFILTERED"
-- A subscription to an event Blizzard delivers through EventRegistry, rather than
-- a client event (Phase 8 section 4.1).
local CALLBACK = "callback"

local host = CreateFrame("Frame")
local subsByEvent = {}
local subsByFeature = {}
local liveTokens = {}
local nextToken = 0

-- Callback deliveries wait here for the next frame, keyed by token, latest payload
-- wins. Consumers are level-triggered -- they read the state, not the event -- so
-- coalescing an open and a close in one frame loses nothing.
local callbackPending = {}
local callbackPendingOrder = {}
local callbackFlushScheduled = false
local deliverCallbacks

local function eventRegistry()
    local registry = _G.EventRegistry
    if type(registry) ~= "table"
        or type(registry.RegisterCallback) ~= "function"
        or type(registry.UnregisterCallback) ~= "function" then
        return nil
    end
    return registry
end

-- One scratch array per dispatch depth. Handlers can fault a feature, which
-- unsubscribes mid-iteration, so we always walk a snapshot -- and reusing the
-- arrays keeps the hot path allocation-free after warmup.
local scratchByDepth = {}
local depth = 0

-- Returns a token, or nil and a reason when the client will not deliver the
-- event. RegisterEvent returns false for an event this client does not
-- implement -- it does not raise -- so an unchecked call leaves the feature
-- holding a handler that can never fire and reporting success. That is the
-- silent degradation the design forbids, so a refusal surfaces and the
-- subscription is never recorded.
local function addSubscription(subscription)
    local list = subsByEvent[subscription.eventName]
    if not list then
        -- Only an explicit false is a refusal; clients that return nothing at
        -- all have registered the event.
        if host:RegisterEvent(subscription.eventName) == false then
            ns.Log.OnceError("dispatch:unsupported:" .. subscription.eventName, format(
                "this client refused to register '%s'; '%s' cannot subscribe to it",
                subscription.eventName, subscription.featureId))
            return nil, "EVENT_UNSUPPORTED"
        end
        list = {}
        subsByEvent[subscription.eventName] = list
    end
    list[#list + 1] = subscription

    local owned = subsByFeature[subscription.featureId]
    if not owned then
        owned = {}
        subsByFeature[subscription.featureId] = owned
    end
    owned[#owned + 1] = subscription

    nextToken = nextToken + 1
    subscription.token = nextToken
    liveTokens[nextToken] = subscription
    return nextToken
end

function Dispatch.Subscribe(featureId, eventName, handler)
    assert(type(featureId) == "string" and featureId ~= "",
        "Dispatch.Subscribe requires a featureId")
    assert(type(eventName) == "string" and eventName ~= "",
        "Dispatch.Subscribe requires an eventName")
    assert(eventName ~= COMBAT_LOG_EVENT,
        "combat log subscriptions must go through Dispatch.SubscribeCombatLog")
    assert(type(handler) == "function", "Dispatch.Subscribe requires a handler")

    return addSubscription({
        featureId = featureId,
        eventName = eventName,
        handler = handler,
    })
end

-- The filter is not optional. It is evaluated before any payload is built, so a
-- rejected occurrence costs three argument reads and a comparison.
function Dispatch.SubscribeCombatLog(featureId, sourceFilter, handler)
    assert(type(featureId) == "string" and featureId ~= "",
        "Dispatch.SubscribeCombatLog requires a featureId")
    assert(type(sourceFilter) == "function",
        "Dispatch.SubscribeCombatLog requires a sourceFilter; it is mandatory")
    assert(type(handler) == "function",
        "Dispatch.SubscribeCombatLog requires a handler")

    -- Feature-detect before registering. A client with no combat log reader has
    -- no combat log, and attempting the registration anyway is what trips
    -- ADDON_ACTION_FORBIDDEN and fills the user's error log on every login.
    if not CombatLogGetCurrentEventInfo then
        ns.Log.OnceError("dispatch:nocombatlog", format(
            "this client has no combat log reader, so '%s' cannot subscribe to combat events",
            featureId))
        return nil, "COMBAT_LOG_UNAVAILABLE"
    end

    return addSubscription({
        featureId = featureId,
        eventName = COMBAT_LOG_EVENT,
        sourceFilter = sourceFilter,
        handler = handler,
    })
end

local function removeFrom(list, subscription)
    if not list then
        return
    end
    for index = #list, 1, -1 do
        if list[index] == subscription then
            remove(list, index)
        end
    end
end

-- Subscribes a feature to an event Blizzard delivers through EventRegistry (Phase 8
-- section 4.1). README rule 1 allows this path: the registry calls each callback
-- through securecallfunction, so our taint does not return to Blizzard's caller.
--
-- The registry calls us INSIDE Blizzard's call -- for the bag, inside its OnShow and
-- OnHide. So the function it holds only records the payload and schedules a flush
-- one frame later; the feature's handler runs in the flush, in our own execution.
-- That makes rule 5 structural on this path rather than a discipline each feature
-- has to remember.
--
-- Only EventRegistry is accepted, so no other Blizzard table receives a function of
-- ours. The owner is a table created per subscription: the registry reserves number
-- owners, and a nil owner would draw on its internal counter.
function Dispatch.SubscribeCallback(featureId, eventName, handler)
    assert(type(featureId) == "string" and featureId ~= "",
        "Dispatch.SubscribeCallback requires a featureId")
    assert(type(eventName) == "string" and eventName ~= "",
        "Dispatch.SubscribeCallback requires an eventName")
    assert(type(handler) == "function", "Dispatch.SubscribeCallback requires a handler")

    local registry = eventRegistry()
    if not registry then
        ns.Log.OnceError("dispatch:noeventregistry", format(
            "this client has no EventRegistry, so '%s' cannot follow %s",
            featureId, eventName))
        return nil, "CALLBACK_REGISTRY_UNAVAILABLE"
    end
    -- No synchronous fallback: delivering inline would run the feature's work inside
    -- Blizzard's call, which is the one thing this path exists to prevent.
    if not (C_Timer and type(C_Timer.After) == "function") then
        ns.Log.OnceError("dispatch:nocallbackdefer", format(
            "this client has no C_Timer.After, so '%s' cannot follow %s without running inside Blizzard's call",
            featureId, eventName))
        return nil, "CALLBACK_REGISTRY_UNAVAILABLE"
    end

    nextToken = nextToken + 1
    local token = nextToken
    local subscription = {
        featureId = featureId,
        eventName = eventName,
        handler = handler,
        kind = CALLBACK,
        owner = {},
        token = token,
    }

    -- What the registry holds. Writes only this file's tables, and calls nothing but
    -- C_Timer.After.
    local function onDelivery(_, ...)
        if not liveTokens[token] then
            return
        end
        if callbackPending[token] == nil then
            callbackPendingOrder[#callbackPendingOrder + 1] = token
        end
        callbackPending[token] = { n = select("#", ...), ... }
        if not callbackFlushScheduled then
            callbackFlushScheduled = true
            C_Timer.After(0, deliverCallbacks)
        end
    end

    local ok, err = pcall(registry.RegisterCallback, registry, eventName,
        onDelivery, subscription.owner)
    if not ok then
        ns.Log.OnceError("dispatch:callbackrefused:" .. eventName, format(
            "EventRegistry refused '%s' a callback for %s: %s",
            featureId, eventName, tostring(err)))
        return nil, "CALLBACK_REGISTRY_UNAVAILABLE"
    end

    local owned = subsByFeature[featureId]
    if not owned then
        owned = {}
        subsByFeature[featureId] = owned
    end
    owned[#owned + 1] = subscription
    liveTokens[token] = subscription
    return token
end

function Dispatch.Unsubscribe(token)
    local subscription = liveTokens[token]
    if not subscription then
        return false
    end
    liveTokens[token] = nil

    if subscription.kind == CALLBACK then
        -- A delivery still waiting for the flush is dropped with its token. The
        -- registry's own unregister only clears a key that exists, so it cannot
        -- disturb a dispatch in progress; and this never runs inside a delivery.
        callbackPending[token] = nil
        local registry = eventRegistry()
        if registry then
            local ok, err = pcall(registry.UnregisterCallback, registry,
                subscription.eventName, subscription.owner)
            if not ok then
                ns.Log.OnceError("dispatch:callbackunregister:" .. subscription.eventName,
                    format("EventRegistry refused to release %s for '%s': %s",
                        subscription.eventName, subscription.featureId, tostring(err)))
            end
        end
    else
        local list = subsByEvent[subscription.eventName]
        removeFrom(list, subscription)
        if list and #list == 0 then
            subsByEvent[subscription.eventName] = nil
            host:UnregisterEvent(subscription.eventName)
        end
    end

    removeFrom(subsByFeature[subscription.featureId], subscription)
    return true
end

function Dispatch.UnsubscribeAll(featureId)
    local owned = subsByFeature[featureId]
    if not owned then
        return 0
    end

    local released = 0
    for index = #owned, 1, -1 do
        if Dispatch.Unsubscribe(owned[index].token) then
            released = released + 1
        end
    end
    subsByFeature[featureId] = nil
    return released
end

function Dispatch.SubscriptionCount(featureId)
    local owned = subsByFeature[featureId]
    return owned and #owned or 0
end

function Dispatch.RegisteredEventCount()
    local count = 0
    for _ in pairs(subsByEvent) do
        count = count + 1
    end
    return count
end

function Dispatch.CallbackCount(featureId)
    local count = 0
    for _, subscription in pairs(liveTokens) do
        if subscription.kind == CALLBACK
            and (featureId == nil or subscription.featureId == featureId) then
            count = count + 1
        end
    end
    return count
end

local function invoke(subscription, ...)
    local ok, err = ns.Isolation.Call(subscription.handler, ...)
    if not ok then
        ns.Registry.Fault(subscription.featureId,
            format("raised handling %s", subscription.eventName), err)
    end
end

-- The callback flush, in this addon's own execution. A handler that raises faults
-- its feature, as for client events, and the fault releases the feature's other
-- subscriptions -- still here, never inside a delivery.
deliverCallbacks = function()
    callbackFlushScheduled = false
    local pending, order = callbackPending, callbackPendingOrder
    callbackPending, callbackPendingOrder = {}, {}
    for index = 1, #order do
        local token = order[index]
        local payload = pending[token]
        local subscription = liveTokens[token]
        if payload and subscription then
            invoke(subscription, unpack(payload, 1, payload.n))
        end
    end
end

local function dispatchCombatLog(scratch, count)
    local getEventInfo = CombatLogGetCurrentEventInfo
    if not getEventInfo then
        ns.Log.OnceError("dispatch:nocleuapi",
            "CombatLogGetCurrentEventInfo is absent on this client; combat log subscribers will not fire")
        return
    end

    -- Read into locals, never a table. Filters see only what they need.
    local timestamp, subEvent, hideCaster,
          sourceGuid, sourceName, sourceFlags, sourceRaidFlags,
          destGuid, destName, destFlags, destRaidFlags,
          extra1, extra2, extra3, extra4, extra5, extra6,
          extra7, extra8, extra9, extra10 = getEventInfo()

    for index = 1, count do
        local subscription = scratch[index]
        if subscription and liveTokens[subscription.token] then
            local filterOk, passed = ns.Isolation.Call(
                subscription.sourceFilter, subEvent, sourceGuid, destGuid)

            if not filterOk then
                ns.Registry.Fault(subscription.featureId,
                    "combat log filter raised", passed)
            elseif passed == true then
                invoke(subscription,
                    timestamp, subEvent, hideCaster,
                    sourceGuid, sourceName, sourceFlags, sourceRaidFlags,
                    destGuid, destName, destFlags, destRaidFlags,
                    extra1, extra2, extra3, extra4, extra5, extra6,
                    extra7, extra8, extra9, extra10)
            end
        end
    end
end

host:SetScript("OnEvent", function(_, eventName, ...)
    local list = subsByEvent[eventName]
    if not list then
        return
    end

    local count = #list
    if count == 0 then
        return
    end

    depth = depth + 1
    local scratch = scratchByDepth[depth]
    if not scratch then
        scratch = {}
        scratchByDepth[depth] = scratch
    end
    for index = 1, count do
        scratch[index] = list[index]
    end

    if eventName == COMBAT_LOG_EVENT then
        dispatchCombatLog(scratch, count)
    else
        for index = 1, count do
            local subscription = scratch[index]
            if subscription and liveTokens[subscription.token] then
                invoke(subscription, ...)
            end
        end
    end

    for index = 1, count do
        scratch[index] = nil
    end
    depth = depth - 1
end)
