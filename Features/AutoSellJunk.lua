-- Features/AutoSellJunk.lua
-- Sells every grey item when you open a merchant, with the game's own Sell All Junk,
-- and reports what it earned (Phase 8 section 7.2). Built on the spike's go (8.4).
--
-- No popup appears, and none is answered. Blizzard's Sell All Junk button shows a
-- confirmation whose Accept calls C_MerchantFrame.SellAllJunkItems() and nothing
-- else (MerchantFrame.lua:1124-1126). This makes that call directly. Pressing the
-- button from here would run its OnClick in our execution, and answering the popup
-- would run StaticPopup's Lua there.
--
-- One call per visit, chosen by the server: no slot index is ours, so a concurrent
-- sort cannot make us sell the wrong item, and a merchant closing mid-sale cannot
-- turn a sale into an equip. The spike saw the call deliver nothing inside itself;
-- the window stays on so that a patch which changes that is caught once.
--
-- MERCHANT_CLOSED is never subscribed: MerchantFrame_OnHide raises it inside the
-- panel-hide path (section 4.4). Whether a merchant is open is a read.

local ADDON_NAME, ns = ...

local FEATURE_ID = "autoSellJunk"

local format, pcall, type, tostring, floor = string.format, pcall, type, tostring, math.floor
local concat = table.concat

local REASON = {
    IN_COMBAT = "InCombat",
    SALE_IN_PROGRESS = "SaleInProgress",
    NOT_AT_MERCHANT = "NotAtMerchant",
    DISABLED = "SellAllJunkDisabled",
    NO_JUNK = "NoJunk",
}

local state = {
    enabled = false,
    tokens = {},
    manifest = nil,
    deferGeneration = 0,
    sales = 0,
    skips = {},
    lastSkip = nil,
    lastSummary = nil,
    lastPosted = nil,
}

-- Reads --------------------------------------------------------------------------

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

local function merchantApi()
    local api = _G.C_MerchantFrame
    if type(api) ~= "table" or type(api.SellAllJunkItems) ~= "function"
        or type(api.IsSellAllJunkEnabled) ~= "function"
        or type(api.GetNumJunkItems) ~= "function" then
        return nil
    end
    return api
end

local function inCombat()
    return type(_G.InCombatLockdown) == "function" and _G.InCombatLockdown() == true
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
    local api = merchantApi()
    if not api then
        return nil
    end
    local ok, count = pcall(api.GetNumJunkItems)
    if ok and isPlain(count, "number") then
        return count
    end
    return nil
end

local function money()
    if type(_G.GetMoney) ~= "function" then
        return nil
    end
    local ok, amount = pcall(_G.GetMoney)
    if ok and isPlain(amount, "number") then
        return amount
    end
    return nil
end

local function coinText(amount)
    local api = _G.C_CurrencyInfo and _G.C_CurrencyInfo.GetCoinTextureString
    if type(api) == "function" then
        local ok, text = pcall(api, amount)
        if ok and isPlain(text, "string") then
            return text
        end
    end
    local gold = floor(amount / 10000)
    local silver = floor((amount % 10000) / 100)
    local copper = amount % 100
    local parts = {}
    if gold > 0 then parts[#parts + 1] = gold .. "g" end
    if silver > 0 then parts[#parts + 1] = silver .. "s" end
    if copper > 0 or #parts == 0 then parts[#parts + 1] = copper .. "c" end
    return concat(parts, " ")
end

-- The summary (section 7.2) ------------------------------------------------------

local function summaryText(sold)
    if not sold.confirmed then
        return format("junk sale not confirmed: %d still in your bags", sold.itemsUnsold)
    end
    local text = format("sold %d junk item(s) for %s", sold.itemsSold, coinText(sold.revenue))
    if sold.itemsUnsold > 0 then
        text = text .. format("; %d left", sold.itemsUnsold)
    end
    return text
end

-- Posted as a toast; to chat when the toast is Unavailable or Dropped, so the
-- summary is never lost (audit finding 7).
local function report(sold)
    state.lastSummary = summaryText(sold)
    local posted = "Unavailable"
    if ns.Toasts and ns.Toasts.Post then
        posted = ns.Toasts.Post({
            kind = "JunkSold",
            itemsSold = sold.itemsSold,
            revenue = sold.revenue,
            itemsUnsold = sold.itemsUnsold,
            confirmed = sold.confirmed,
        })
    end
    state.lastPosted = posted
    if posted == "Unavailable" or posted == "Dropped" then
        ns.Log.Info(state.lastSummary)
    end
end

-- Decides whether a started sale has finished, and what it earned. Returns true once
-- it has reported.
local function settle(trigger)
    local manifest = state.manifest
    if not manifest then
        return false
    end
    local junk = junkCount() or manifest.junkBefore
    local after = money()
    local revenue = (after and manifest.moneyBefore) and (after - manifest.moneyBefore) or 0
    -- A purchase inside the settle window could make this negative; shown as 0.
    if revenue < 0 then
        revenue = 0
    end

    local sold
    if trigger == "BagsSettled" then
        if junk ~= 0 then
            return false
        end
        sold = { itemsSold = manifest.junkBefore, revenue = revenue, itemsUnsold = 0, confirmed = true }
    elseif junk < manifest.junkBefore then
        sold = {
            itemsSold = manifest.junkBefore - junk, revenue = revenue,
            itemsUnsold = junk, confirmed = true,
        }
    else
        sold = { itemsSold = 0, revenue = revenue, itemsUnsold = manifest.junkBefore, confirmed = false }
    end

    if manifest.timer and manifest.timer.Cancel then
        manifest.timer:Cancel()
    end
    state.manifest = nil
    report(sold)
    return true
end

local function skip(reason)
    state.skips[reason] = (state.skips[reason] or 0) + 1
    state.lastSkip = reason
    return reason
end

-- Sells every junk item at the open merchant with one client call.
local function startVend()
    if inCombat() then
        return skip(REASON.IN_COMBAT)
    end
    -- A sale still settling blocks a new one; it settles on its own timeout
    -- (audit finding 6).
    if state.manifest then
        return skip(REASON.SALE_IN_PROGRESS)
    end
    if not atMerchant() then
        return skip(REASON.NOT_AT_MERCHANT)
    end
    local api = merchantApi()
    if not api then
        return skip(REASON.DISABLED)
    end
    local enabledOk, sellAllEnabled = pcall(api.IsSellAllJunkEnabled)
    if not (enabledOk and sellAllEnabled == true) then
        ns.Log.Once("autosell:disabled",
            "this client has Sell All Junk switched off, so junk is not sold automatically")
        return skip(REASON.DISABLED)
    end
    local junkBefore = junkCount()
    if not junkBefore or junkBefore == 0 then
        return skip(REASON.NO_JUNK)
    end
    local moneyBefore = money()

    local names, ok, err = ns.CallWindow.Capture(api.SellAllJunkItems)
    state.sales = state.sales + 1
    if not ok then
        ns.Log.OnceError("autosell:raised", "SellAllJunkItems raised: "
            .. ns.EscapeGuard.Neutralize(tostring(err)))
    end
    if #names > 0 then
        ns.Registry.Fault(FEATURE_ID, format(
            "SellAllJunkItems delivered %s inside the call, which the Phase 8 spike did not see; /reload to clear anything those handlers wrote",
            concat(names, ", ")))
        return "Stopped"
    end

    local manifest = {
        junkBefore = junkBefore,
        moneyBefore = moneyBefore,
        calledAt = _G.GetTime and _G.GetTime() or 0,
    }
    state.manifest = manifest
    if C_Timer and C_Timer.NewTimer then
        manifest.timer = C_Timer.NewTimer(ns.VEND_SETTLE_SECONDS, function()
            if state.manifest ~= manifest then
                return
            end
            local timerOk, timerErr = ns.Isolation.Call(settle, "TimedOut")
            if not timerOk then
                ns.Registry.Fault(FEATURE_ID, "raised settling a sale", timerErr)
            end
        end)
    end
    return "Started"
end

-- Signals ----------------------------------------------------------------------------

-- MERCHANT_SHOW comes from the server (section 4.4). The sale still runs one frame
-- later, from a deferral disable can cancel.
local function onMerchantShow()
    if not state.enabled or not (C_Timer and C_Timer.After) then
        return
    end
    local generation = state.deferGeneration
    C_Timer.After(0, function()
        if generation ~= state.deferGeneration or not state.enabled then
            return
        end
        local ok, err = ns.Isolation.Call(startVend)
        if not ok then
            ns.Registry.Fault(FEATURE_ID, "raised starting a sale", err)
        end
    end)
end

-- A unique event: coalesced, never delivered inside a call.
local function onBagsSettled()
    if state.manifest then
        settle("BagsSettled")
    end
end

-- Lifecycle -------------------------------------------------------------------------

local SIGNALS = {
    { event = "MERCHANT_SHOW", handler = onMerchantShow },
    { event = "BAG_UPDATE_DELAYED", handler = onBagsSettled },
}

local function enable()
    if not merchantApi() then
        return nil, "this client has no C_MerchantFrame.SellAllJunkItems"
    end
    if not (_G.C_PlayerInteractionManager and _G.Enum and _G.Enum.PlayerInteractionType
        and _G.Enum.PlayerInteractionType.Merchant ~= nil) then
        return nil, "this client cannot say whether a merchant is open"
    end
    for index = 1, #SIGNALS do
        local token, reason = ns.Dispatch.Subscribe(FEATURE_ID, SIGNALS[index].event,
            SIGNALS[index].handler)
        if not token then
            return nil, format("cannot follow %s (%s)", SIGNALS[index].event, tostring(reason))
        end
        state.tokens[#state.tokens + 1] = token
    end
    state.enabled = true
    return true
end

-- Cancels the pending deferral and the settle timeout, and clears the manifest. A
-- sale already sent completes at the server, unreported (audit finding 5).
local function disable()
    state.enabled = false
    state.deferGeneration = state.deferGeneration + 1
    local manifest = state.manifest
    state.manifest = nil
    if manifest and manifest.timer and manifest.timer.Cancel then
        manifest.timer:Cancel()
    end
    for index = #state.tokens, 1, -1 do
        ns.Dispatch.Unsubscribe(state.tokens[index])
        state.tokens[index] = nil
    end
end

ns.Registry.Register(FEATURE_ID, {
    enabledByDefault = true,
    label = "Sell junk automatically",
    description = "Sells every grey item when you open a merchant, with the game's own Sell All Junk, without the confirmation.",
    settings = {},
    schema = {},
}, {
    enable = enable,
    disable = disable,
    onConfigChanged = function()
        return ns.CONFIG_RESULT.APPLIED
    end,
})

-- /pa vend ------------------------------------------------------------------------------

ns.AutoSellJunk = {
    Inspect = function()
        local skips = {}
        for reason, count in pairs(state.skips) do
            skips[#skips + 1] = format("%s=%d", reason, count)
        end
        table.sort(skips)
        return {
            enabled = state.enabled,
            sales = state.sales,
            salePending = state.manifest ~= nil,
            skips = skips,
            lastSkip = state.lastSkip,
            lastSummary = state.lastSummary,
            lastPosted = state.lastPosted,
        }
    end,
}
