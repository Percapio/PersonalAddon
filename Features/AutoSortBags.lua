-- Features/AutoSortBags.lua
-- Runs the game's own Clean Up Bags when the bags close, at most once per cooldown,
-- never in combat (Phase 8 section 7.1). Built on the spike's go (section 8.4).
--
-- The spike found that C_Container.SortBags delivers ITEM_LOCK_CHANGED and
-- ITEM_LOCKED inside the call, so every listener of those two would run in our
-- execution. It went ahead because nothing listened with the bag hidden. That is a
-- condition of the moment -- Blizzard's Cooldown Manager listens while it tracks a
-- bag item, the bag tutorial while it points -- so it is checked before every sort,
-- and the sort runs inside the spike's window so that a third event is caught once
-- rather than tainting quietly.
--
-- The trigger is the bag's own close callback, delivered a frame late by Dispatch
-- (section 4.1). Everything else is a read until the one call to SortBags.

local ADDON_NAME, ns = ...

local FEATURE_ID = "autoSortBags"

local format, pcall, type, tostring = string.format, pcall, type, tostring
local concat = table.concat

local SORT_INLINE_LIST = { "ITEM_LOCK_CHANGED", "ITEM_LOCKED" }
local SORT_INLINE_EVENTS = { ITEM_LOCK_CHANGED = true, ITEM_LOCKED = true }

local REASON = {
    IN_COMBAT = "InCombat",
    BAG_SHOWN = "BagShown",
    COOLING_DOWN = "CoolingDown",
    CURSOR = "CursorHoldsItem",
    LOCKED = "ItemsLocked",
    LISTENERS = "ListenersPresent",
    LISTENERS_UNKNOWN = "ListenersUnknown",
}

local state = {
    enabled = false,
    tokens = {},
    lastSortAt = nil,
    sorts = 0,
    skips = {},
    lastSkip = nil,
    lastListeners = nil,
    lastInline = nil,
    settings = { cooldownSeconds = 60 },
}

-- Reads --------------------------------------------------------------------------

local function now()
    return _G.GetTime and _G.GetTime() or 0
end

local function inCombat()
    return type(_G.InCombatLockdown) == "function" and _G.InCombatLockdown() == true
end

local function combinedBagShown()
    local bag = _G.ContainerFrameCombinedBags
    if not bag then
        return false
    end
    local ok, shown = pcall(bag.IsShown, bag)
    return ok and shown == true
end

local function cursorHasItem()
    return type(_G.CursorHasItem) == "function" and _G.CursorHasItem() == true
end

-- Items in flight -- a sale, a trade, mail, a move -- are locked. Sorting then would
-- move items the server is still acting on. The held bags are at most five, so the
-- scan is bounded.
local function lockedItemCount()
    local container = _G.C_Container
    if type(container) ~= "table" or type(container.GetContainerNumSlots) ~= "function"
        or type(container.GetContainerItemInfo) ~= "function" then
        return 0
    end
    local inventory = _G.Constants and _G.Constants.InventoryConstants
    local lastBag = (inventory and inventory.NumBagSlots or _G.NUM_BAG_SLOTS or 4)
        + (inventory and inventory.NumReagentBagSlots or 0)
    local locked = 0
    for bag = 0, lastBag do
        local ok, slots = pcall(container.GetContainerNumSlots, bag)
        if ok and type(slots) == "number" then
            for slot = 1, slots do
                local infoOk, info = pcall(container.GetContainerItemInfo, bag, slot)
                if infoOk and type(info) == "table" and info.isLocked == true then
                    locked = locked + 1
                end
            end
        end
    end
    return locked
end

-- The sort (section 7.1) ---------------------------------------------------------

local function skip(reason)
    state.skips[reason] = (state.skips[reason] or 0) + 1
    state.lastSkip = reason
    return reason
end

local function sortIfSettled()
    if inCombat() then
        return skip(REASON.IN_COMBAT)
    end
    if combinedBagShown() then
        return skip(REASON.BAG_SHOWN)
    end
    local startedAt = now()
    if state.lastSortAt and startedAt - state.lastSortAt < state.settings.cooldownSeconds then
        return skip(REASON.COOLING_DOWN)
    end
    if cursorHasItem() then
        return skip(REASON.CURSOR)
    end
    if lockedItemCount() > 0 then
        return skip(REASON.LOCKED)
    end

    local listeners = ns.CallWindow.Listeners(SORT_INLINE_LIST)
    if not listeners then
        ns.Log.Once("autosort:listenersunknown",
            "tidy bags cannot tell whether anything listens to what a sort delivers inside the call (no GetFramesRegisteredForEvent), so it does not sort")
        return skip(REASON.LISTENERS_UNKNOWN)
    end
    if ns.CallWindow.AnyListener(listeners) then
        local described = ns.CallWindow.Describe(listeners)
        state.lastListeners = described
        ns.Log.Once("autosort:listeners:" .. described, format(
            "tidy bags is holding back while something listens to what a sort delivers inside the call -- %s",
            ns.EscapeGuard.Neutralize(described)))
        return skip(REASON.LISTENERS)
    end

    local names, ok, err = ns.CallWindow.Capture(_G.C_Container.SortBags)
    state.lastSortAt = startedAt
    state.sorts = state.sorts + 1
    state.lastInline = names
    if not ok then
        ns.Log.OnceError("autosort:raised", "SortBags raised: "
            .. ns.EscapeGuard.Neutralize(tostring(err)))
    end

    local unexpected = ns.CallWindow.Unexpected(names, SORT_INLINE_EVENTS)
    if #unexpected > 0 then
        ns.Registry.Fault(FEATURE_ID, format(
            "SortBags delivered %s inside the call, which the Phase 8 spike did not see; /reload to clear anything those handlers wrote",
            concat(unexpected, ", ")))
        return "Stopped"
    end
    return "Sorted"
end

-- Dispatch delivers the close a frame late (section 4.1). Level-triggered: what
-- matters is that the bag is hidden now, not which frame announced it.
local function onBagSignal()
    if not state.enabled or combinedBagShown() then
        return
    end
    sortIfSettled()
end

-- Lifecycle -------------------------------------------------------------------------

local function readSettings(config)
    local settings = config and config.settings
    if settings and settings.cooldownSeconds then
        state.settings.cooldownSeconds = settings.cooldownSeconds
    end
end

local function enable(config)
    readSettings(config)
    if not (_G.C_Container and type(_G.C_Container.SortBags) == "function") then
        return nil, "this client has no C_Container.SortBags"
    end
    if not _G.ContainerFrameCombinedBags then
        return nil, "this client has no combined bag frame (ContainerFrameCombinedBags)"
    end
    local token, reason = ns.Dispatch.SubscribeCallback(FEATURE_ID,
        "ContainerFrame.CloseBag", onBagSignal)
    if not token then
        return nil, format("cannot follow the bag closing (%s)", tostring(reason))
    end
    state.tokens[#state.tokens + 1] = token
    state.enabled = true
    return true
end

-- Tolerates a partial enable (Phase 1 section 6.1).
local function disable()
    state.enabled = false
    state.lastSortAt = nil
    for index = #state.tokens, 1, -1 do
        ns.Dispatch.Unsubscribe(state.tokens[index])
        state.tokens[index] = nil
    end
end

local function onConfigChanged(config)
    readSettings(config)
    return ns.CONFIG_RESULT.APPLIED
end

ns.Registry.Register(FEATURE_ID, {
    enabledByDefault = true,
    label = "Tidy bags when closed",
    description = "Runs the game's Clean Up Bags when the bags close, at most once a minute, never in combat.",
    settings = {
        cooldownSeconds = 60,
    },
    schema = {
        cooldownSeconds = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Minimum seconds between sorts",
            minimum = 10, maximum = 600, step = 10,
        },
    },
}, {
    enable = enable,
    disable = disable,
    onConfigChanged = onConfigChanged,
})

-- /pa bags ----------------------------------------------------------------------------

ns.AutoSortBags = {
    Inspect = function()
        local skips = {}
        for reason, count in pairs(state.skips) do
            skips[#skips + 1] = format("%s=%d", reason, count)
        end
        table.sort(skips)
        return {
            enabled = state.enabled,
            sorts = state.sorts,
            secondsSinceSort = state.lastSortAt and (now() - state.lastSortAt) or nil,
            cooldownSeconds = state.settings.cooldownSeconds,
            skips = skips,
            lastSkip = state.lastSkip,
            lastListeners = state.lastListeners,
            lastInline = state.lastInline and concat(state.lastInline, ", ") or nil,
            listenersNow = (function()
                local listeners = ns.CallWindow.Listeners(SORT_INLINE_LIST)
                return listeners and ns.CallWindow.Describe(listeners) or "unreadable"
            end)(),
        }
    end,
}
