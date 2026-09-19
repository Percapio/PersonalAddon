-- Core/Dispatch.lua
-- Features never register client events directly (§7). The dispatcher owns the
-- frame, wraps every handler, and drops the underlying registration when the
-- last subscriber for an event goes away.

local ADDON_NAME, ns = ...

local Dispatch = {}
ns.Dispatch = Dispatch

local type, format, remove = type, string.format, table.remove

local COMBAT_LOG_EVENT = "COMBAT_LOG_EVENT_UNFILTERED"

local host = CreateFrame("Frame")
local subsByEvent = {}
local subsByFeature = {}
local liveTokens = {}
local nextToken = 0

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

function Dispatch.Unsubscribe(token)
    local subscription = liveTokens[token]
    if not subscription then
        return false
    end
    liveTokens[token] = nil

    local list = subsByEvent[subscription.eventName]
    removeFrom(list, subscription)
    if list and #list == 0 then
        subsByEvent[subscription.eventName] = nil
        host:UnregisterEvent(subscription.eventName)
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

local function invoke(subscription, ...)
    local ok, err = ns.Isolation.Call(subscription.handler, ...)
    if not ok then
        ns.Registry.Fault(subscription.featureId,
            format("raised handling %s", subscription.eventName), err)
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
