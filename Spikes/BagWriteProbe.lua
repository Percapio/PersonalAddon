-- Spikes/BagWriteProbe.lua
-- The Phase 8 spike (Architecture/20260927-Phase08.md section 8). Temporary:
-- deleted with its /pa probe bags route once section 8.4 is filled in.
--
-- It answers one question for each of the two writes auto-sort and auto-sell would
-- make: is any event delivered while our call is running? If one is, Blizzard's
-- listeners for it run in our execution, and whatever they write carries our taint
-- (README rule 9).
--
-- Only our own calls are wrapped. Phase 7's passive stage listened to Blizzard's
-- calls, and Patch 01 section 0.5 could not rule that listener out: a synchronous
-- event runs its handler inside the caller. So this probe registers nothing outside
-- its one-call windows, except BAG_UPDATE_DELAYED -- a unique event, which cannot
-- arrive inside a call -- while a sale settles.
--
-- It makes no call at all until a /pa probe bags command is typed.

local ADDON_NAME, ns = ...

local FEATURE_ID = "bagWriteProbe"

local format, pcall, type, tostring = string.format, pcall, type, tostring
local concat = table.concat

local NOT_TESTED = "NotTested"

-- Where RegisterAllEvents is missing, the window listens for the events section 8.1
-- names, plus the other bag events a sort or sale could raise.
local FALLBACK_EVENTS = {
    "BAG_UPDATE", "BAG_UPDATE_DELAYED", "BAG_CONTAINER_UPDATE", "BAG_NEW_ITEMS_UPDATED",
    "ITEM_LOCK_CHANGED", "ITEM_LOCKED", "ITEM_UNLOCKED", "INVENTORY_SEARCH_UPDATE",
    "MERCHANT_UPDATE", "PLAYER_MONEY", "UNIT_INVENTORY_CHANGED",
}

local function newReport()
    return {
        b1 = NOT_TESTED, b1Names = {},
        b2 = NOT_TESTED, b2Listeners = nil,
        v0 = NOT_TESTED,
        v1 = NOT_TESTED, v1Names = {},
        v2 = NOT_TESTED, v2Listeners = nil,
        v3 = NOT_TESTED, v3Detail = nil,
        v4 = NOT_TESTED,
    }
end

local state = {
    enabled = false,
    frame = nil,
    report = newReport(),
    settle = nil,
    settleToken = nil,
}

local function isPlain(value, expectedType)
    local check = _G.issecretvalue
    if type(check) == "function" then
        local ok, secret = pcall(check, value)
        if not ok or secret then
            return false
        end
    end
    return type(value) == expectedType
end

local function neutralize(text)
    return ns.EscapeGuard.Neutralize(tostring(text))
end

-- The window (section 8.2) -------------------------------------------------------

-- Runs one write inside an all-events window. Returns the events delivered between
-- register and unregister -- exactly those that arrived while the call ran --
-- deduplicated in arrival order, and whether the write raised.
local function captureInlineEvents(write)
    local frame = state.frame
    local names, seen = {}, {}
    frame:SetScript("OnEvent", function(_, eventName)
        if not seen[eventName] then
            seen[eventName] = true
            names[#names + 1] = eventName
        end
    end)
    if type(frame.RegisterAllEvents) == "function" then
        frame:RegisterAllEvents()
    else
        for index = 1, #FALLBACK_EVENTS do
            pcall(frame.RegisterEvent, frame, FALLBACK_EVENTS[index])
        end
    end

    local ok, err = pcall(write)

    frame:UnregisterAllEvents()
    frame:SetScript("OnEvent", nil)
    return names, ok, err
end

local function frameLabel(frame)
    if type(frame) ~= "table" then
        return tostring(frame)
    end
    if type(frame.GetName) == "function" then
        local ok, name = pcall(frame.GetName, frame)
        if ok and isPlain(name, "string") and name ~= "" then
            return name
        end
    end
    if type(frame.GetDebugName) == "function" then
        local ok, name = pcall(frame.GetDebugName, frame)
        if ok and isPlain(name, "string") and name ~= "" then
            return name
        end
    end
    return "<unnamed>"
end

-- Who was registered for each delivered event, read after the window closed and
-- still in the same execution. Other addons' frames can appear here too; the probe
-- cannot tell them from Blizzard's, so a list with anything in it is for the person
-- to judge (section 8.5).
local function listenersFor(names)
    local reader = _G.GetFramesRegisteredForEvent
    if type(reader) ~= "function" then
        return nil
    end
    local byEvent = {}
    for index = 1, #names do
        local results = { pcall(reader, names[index]) }
        local labels = {}
        if results[1] then
            for position = 2, #results do
                local frame = results[position]
                if frame ~= state.frame then
                    labels[#labels + 1] = frameLabel(frame)
                end
            end
        end
        byEvent[names[index]] = labels
    end
    return byEvent
end

local function anyListener(byEvent)
    if not byEvent then
        return nil
    end
    for _, labels in pairs(byEvent) do
        if #labels > 0 then
            return true
        end
    end
    return false
end

-- Reads -----------------------------------------------------------------------------

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

local function lockedItemCount()
    local container = _G.C_Container
    if type(container) ~= "table" or type(container.GetContainerNumSlots) ~= "function" then
        return 0
    end
    local lastBag = (_G.Constants and _G.Constants.InventoryConstants
        and _G.Constants.InventoryConstants.NumBagSlots) or _G.NUM_BAG_SLOTS or 4
    local locked = 0
    for bag = 0, lastBag do
        local ok, slots = pcall(container.GetContainerNumSlots, bag)
        if ok and isPlain(slots, "number") then
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

local function atMerchant()
    local manager = _G.C_PlayerInteractionManager
    local interaction = _G.Enum and _G.Enum.PlayerInteractionType
    if type(manager) ~= "table" or type(manager.IsInteractingWithNpcOfType) ~= "function"
        or type(interaction) ~= "table" or interaction.Merchant == nil then
        return false
    end
    local ok, interacting = pcall(manager.IsInteractingWithNpcOfType, interaction.Merchant)
    return ok and interacting == true
end

local function junkCount()
    local merchant = _G.C_MerchantFrame
    if type(merchant) ~= "table" or type(merchant.GetNumJunkItems) ~= "function" then
        return nil
    end
    local ok, count = pcall(merchant.GetNumJunkItems)
    if ok and isPlain(count, "number") then
        return count
    end
    return nil
end

local function money()
    local ok, amount = pcall(_G.GetMoney)
    if ok and isPlain(amount, "number") then
        return amount
    end
    return nil
end

-- Report ----------------------------------------------------------------------------

local function describeListeners(byEvent)
    if not byEvent then
        return "listener list unavailable on this client; judge with section 8.1's table"
    end
    local parts = {}
    for eventName, labels in pairs(byEvent) do
        parts[#parts + 1] = format("%s: %s", eventName,
            #labels > 0 and neutralize(concat(labels, ", ")) or "none")
    end
    table.sort(parts)
    return #parts > 0 and concat(parts, "; ") or "none"
end

local function sortDecision(report)
    if report.b1 == NOT_TESTED then
        return "Undecided: run /pa probe bags sort"
    end
    if report.b1 == "NoneDelivered" then
        return "Auto-sort: go"
    end
    if anyListener(report.b2Listeners) == false then
        return "Auto-sort: go (events were delivered, but nothing was registered for them)"
    end
    return "Auto-sort: review the listeners against section 8.1; go only if none is Blizzard's"
end

local function sellDecision(report)
    if report.v0 == "SellAllDisabled" then
        return "Auto-sell: no-go on this client (IsSellAllJunkEnabled is false)"
    end
    if report.v0 == NOT_TESTED or report.v1 == NOT_TESTED then
        return "Undecided: run /pa probe bags sell at a merchant"
    end
    if report.v1 == "Delivered" then
        return "Auto-sell: no-go (the merchant frame always listens to BAG_UPDATE and MERCHANT_UPDATE)"
    end
    local notes = {}
    if report.v3 == "DidNotSettle" then
        notes[#notes + 1] = "settle on the timeout alone"
    elseif report.v3 == NOT_TESTED then
        notes[#notes + 1] = "V3 still pending"
    end
    if report.v4 == "PopupSeen" then
        notes[#notes + 1] = "the README notes the extra press"
    elseif report.v4 == NOT_TESTED then
        notes[#notes + 1] = "V4 not yet answered"
    end
    if #notes > 0 then
        return "Auto-sell: go, with: " .. concat(notes, "; ")
    end
    return "Auto-sell: go"
end

local function printReport()
    local report = state.report
    ns.Log.Info("bag write spike (Phase 8 section 8):")
    ns.Log.Info(format("  B1 events inside SortBags: %s%s", report.b1,
        #report.b1Names > 0 and (" -- " .. concat(report.b1Names, ", ")) or ""))
    ns.Log.Info("  B2 listeners: " .. (report.b1 == "Delivered"
        and describeListeners(report.b2Listeners) or report.b2))
    ns.Log.Info("  V0 IsSellAllJunkEnabled: " .. report.v0)
    ns.Log.Info(format("  V1 events inside SellAllJunkItems: %s%s", report.v1,
        #report.v1Names > 0 and (" -- " .. concat(report.v1Names, ", ")) or ""))
    ns.Log.Info("  V2 listeners: " .. (report.v1 == "Delivered"
        and describeListeners(report.v2Listeners) or report.v2))
    ns.Log.Info("  V3 settle: " .. report.v3 .. (report.v3Detail and (" -- " .. report.v3Detail) or ""))
    ns.Log.Info("  V4 confirmation popup: " .. report.v4)
    ns.Log.Info("  decision: " .. sortDecision(report))
    ns.Log.Info("  decision: " .. sellDecision(report))
end

-- Settle (V3) ---------------------------------------------------------------------

local function stopSettle()
    local settle = state.settle
    state.settle = nil
    if settle and settle.timer and settle.timer.Cancel then
        settle.timer:Cancel()
    end
    if state.settleToken then
        ns.Dispatch.Unsubscribe(state.settleToken)
        state.settleToken = nil
    end
end

local function finishSettle(settled)
    local settle = state.settle
    if not settle then
        return
    end
    local junkAfter = junkCount()
    local moneyAfter = money()
    local revenue = (moneyAfter and settle.moneyBefore) and (moneyAfter - settle.moneyBefore) or nil
    local seconds = (_G.GetTime and _G.GetTime() or settle.startedAt) - settle.startedAt
    state.report.v3 = settled and "SettledWithin" or "DidNotSettle"
    state.report.v3Detail = format("%.2fs, junk %s -> %s, revenue %s copper",
        seconds, tostring(settle.junkBefore), tostring(junkAfter), tostring(revenue))
    stopSettle()
    ns.Log.Info("V3 settle: " .. state.report.v3 .. " -- " .. state.report.v3Detail)
    ns.Log.Info("now answer V4: /pa probe bags popup seen, or /pa probe bags popup none")
end

local function onBagsSettled()
    if not state.settle then
        return
    end
    local count = junkCount()
    if count == 0 then
        finishSettle(true)
    end
end

-- Commands --------------------------------------------------------------------------

local function ensureEnabled()
    if state.enabled then
        return true
    end
    local ok, reason = ns.Registry.SetEnabled(FEATURE_ID, true)
    if not ok or not state.enabled then
        ns.Log.Error("the bag write probe could not start: " .. tostring(reason))
        return false
    end
    return true
end

local function commandSort()
    if not ensureEnabled() then
        return
    end
    if inCombat() then
        ns.Log.Error("leave combat first")
        return
    end
    if combinedBagShown() then
        ns.Log.Error("close the bags first: the sort is measured with the bag hidden")
        return
    end
    if cursorHasItem() then
        ns.Log.Error("put down the item on the cursor first")
        return
    end
    local locked = lockedItemCount()
    if locked > 0 then
        ns.Log.Error(format("%d item(s) in your bags are locked; wait for them to settle", locked))
        return
    end
    local container = _G.C_Container
    if type(container) ~= "table" or type(container.SortBags) ~= "function" then
        ns.Log.Error("this client has no C_Container.SortBags")
        return
    end

    local names, ok, err = captureInlineEvents(container.SortBags)
    if not ok then
        ns.Log.Error("SortBags raised: " .. neutralize(err))
    end
    state.report.b1 = (#names == 0) and "NoneDelivered" or "Delivered"
    state.report.b1Names = names
    if #names > 0 then
        state.report.b2Listeners = listenersFor(names)
        state.report.b2 = state.report.b2Listeners and "Listed" or "ListenersUnavailable"
    else
        state.report.b2 = "NothingToList"
    end
    printReport()
    ns.Log.Warn("now /reload, before anything else (section 8.3)")
end

local function commandSell()
    if not ensureEnabled() then
        return
    end
    if state.settle then
        ns.Log.Error("a sale is still settling; wait for V3")
        return
    end
    if inCombat() then
        ns.Log.Error("leave combat first")
        return
    end
    if not atMerchant() then
        ns.Log.Error("open a merchant first")
        return
    end
    local merchant = _G.C_MerchantFrame
    if type(merchant) ~= "table" or type(merchant.SellAllJunkItems) ~= "function"
        or type(merchant.IsSellAllJunkEnabled) ~= "function" then
        ns.Log.Error("this client has no C_MerchantFrame.SellAllJunkItems")
        return
    end
    local enabledOk, enabled = pcall(merchant.IsSellAllJunkEnabled)
    state.report.v0 = (enabledOk and enabled == true) and "SellAllEnabled" or "SellAllDisabled"
    if state.report.v0 == "SellAllDisabled" then
        printReport()
        return
    end
    local junkBefore = junkCount()
    if not junkBefore or junkBefore == 0 then
        ns.Log.Error("carry at least one grey item the merchant will buy")
        return
    end
    local moneyBefore = money()

    local names, ok, err = captureInlineEvents(merchant.SellAllJunkItems)
    if not ok then
        ns.Log.Error("SellAllJunkItems raised: " .. neutralize(err))
    end
    state.report.v1 = (#names == 0) and "NoneDelivered" or "Delivered"
    state.report.v1Names = names
    if #names > 0 then
        state.report.v2Listeners = listenersFor(names)
        state.report.v2 = state.report.v2Listeners and "Listed" or "ListenersUnavailable"
    else
        state.report.v2 = "NothingToList"
    end
    printReport()

    state.settle = {
        junkBefore = junkBefore,
        moneyBefore = moneyBefore,
        startedAt = _G.GetTime and _G.GetTime() or 0,
    }
    state.settleToken = ns.Dispatch.Subscribe(FEATURE_ID, "BAG_UPDATE_DELAYED", onBagsSettled)
    if C_Timer and C_Timer.NewTimer then
        state.settle.timer = C_Timer.NewTimer(ns.VEND_SETTLE_SECONDS, function()
            finishSettle(false)
        end)
    end
    ns.Log.Info(format("waiting up to %ds for the sale to settle (V3)", ns.VEND_SETTLE_SECONDS))
end

local function commandPopup(answer)
    if answer ~= "seen" and answer ~= "none" then
        ns.Log.Error("usage: /pa probe bags popup seen | none")
        return
    end
    if state.settle then
        ns.Log.Error("the sale is still settling; wait for V3 first")
        return
    end
    state.report.v4 = (answer == "seen") and "PopupSeen" or "NoPopup"
    printReport()
    ns.Registry.SetEnabled(FEATURE_ID, false)
    ns.Log.Info("the probe is off; /reload, then copy this report into section 8.4")
end

-- Lifecycle -------------------------------------------------------------------------

local function enable()
    if not state.frame then
        -- Never shown, and registered for nothing outside a one-call window.
        state.frame = CreateFrame("Frame")
    end
    state.enabled = true
    return true
end

local function disable()
    state.enabled = false
    stopSettle()
    if state.frame then
        state.frame:UnregisterAllEvents()
        state.frame:SetScript("OnEvent", nil)
    end
end

ns.Registry.Register(FEATURE_ID, {
    enabledByDefault = false,
    internal = true,
    label = "Bag write probe",
    description = "Temporary: the Phase 8 spike for auto-sort and auto-sell.",
    settings = {},
}, {
    enable = enable,
    disable = disable,
    onConfigChanged = function()
        return ns.CONFIG_RESULT.APPLIED
    end,
})

ns.BagWriteProbe = {
    Command = function(verb, argument)
        verb = string.lower(verb or "")
        if verb == "sort" then
            commandSort()
        elseif verb == "sell" then
            commandSell()
        elseif verb == "popup" then
            commandPopup(string.lower(argument or ""))
        elseif verb == "" or verb == "report" then
            printReport()
        else
            ns.Log.Error("usage: /pa probe bags [sort | sell | popup seen | popup none]")
        end
    end,
    Report = function()
        return state.report
    end,
    SortDecision = function()
        return sortDecision(state.report)
    end,
    SellDecision = function()
        return sellDecision(state.report)
    end,
}
