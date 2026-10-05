-- Phase 8 offline checks (Architecture/20260927-Phase08.md). HARNESS_SESSION picks
-- the variant: "phase8" (everything), "phase8-withheld" (skill ranks secret),
-- "phase8-positional" (a locale that reorders loot arguments), "phase8-noglobals"
-- (LOOT_ITEM_SELF missing).

local ns = HARNESS_NS
local passed, failures = 0, {}

local function check(name, condition, detail)
    if condition then
        passed = passed + 1
    else
        failures[#failures + 1] = name .. (detail ~= nil and (" -- " .. tostring(detail)) or "")
    end
end

local function slash(text)
    SlashCmdList.PERSONALADDON_DEBUG(text)
end

local function chatMark()
    return #HARNESS.chat
end

local function chatSince(mark)
    local lines = {}
    for index = mark + 1, #HARNESS.chat do
        lines[#lines + 1] = HARNESS.chat[index]
    end
    return table.concat(lines, "\n")
end

local function count(text, needle)
    local total, start = 0, 1
    while true do
        local found = text:find(needle, start, true)
        if not found then
            return total
        end
        total = total + 1
        start = found + #needle
    end
end

local function shownChildren(parent)
    local list = {}
    for _, frame in ipairs(HARNESS.createdFrames) do
        if frame.parent == parent and frame.shown then
            list[#list + 1] = frame
        end
    end
    return list
end

-- Rows in drawn order: the first is anchored to the panel, each next one to the row
-- above it. Pool order says nothing about screen order.
local function rowsText()
    local panel = _G.PersonalAddonEquippedSkills
    local rows = shownChildren(panel)
    local texts, anchor = {}, panel
    for _ = 1, #rows do
        local nextRow
        for _, row in ipairs(rows) do
            local point = row.points[1]
            if point and point[2] == anchor then
                nextRow = row
            end
        end
        if not nextRow then
            break
        end
        texts[#texts + 1] = nextRow.level:GetText()
        anchor = nextRow
    end
    return table.concat(texts, ", ")
end

local function inspectRows()
    local view = ns.EquippedSkills.Inspect()
    local parts = {}
    for index = 1, #view.rows do
        local row = view.rows[index]
        parts[#parts + 1] = string.format("%s%s %d/%d", row.source,
            row.slot and ("[" .. row.slot .. "]") or "", row.rank, row.maximum)
    end
    return table.concat(parts, "; "), view
end

local function toastFrames()
    return shownChildren(_G.PersonalAddonToasts)
end

local function lootLink(itemId, name, colour)
    return string.format("|c%s|Hitem:%d::::::::60:::::|h[%s]|h|r", colour or "ff1eff00", itemId, name)
end

-- Session variants, set before login ----------------------------------------------
if HARNESS_SESSION == "phase8-withheld" then
    HARNESS.secretSkills = true
elseif HARNESS_SESSION == "phase8-positional" then
    LOOT_ITEM_SELF_MULTIPLE = "Beute: %2$dx %1$s."
elseif HARNESS_SESSION == "phase8-noglobals" then
    LOOT_ITEM_SELF = nil
end

-- Boot -------------------------------------------------------------------------------
HARNESS.fire("ADDON_LOADED", "PersonalAddon")
HARNESS.fire("PLAYER_LOGIN")
HARNESS.frame()

check("skills window enabled", ns.Registry.State("equippedSkills") == "ENABLED", ns.Registry.State("equippedSkills"))
check("toasts enabled", ns.Registry.State("toasts") == "ENABLED", ns.Registry.State("toasts"))
check("probe gone", ns.Registry.Exists("bagWriteProbe") == false and ns.BagWriteProbe == nil)
check("tidy bags enabled", ns.Registry.State("autoSortBags") == "ENABLED", ns.Registry.State("autoSortBags"))
check("sell junk enabled", ns.Registry.State("autoSellJunk") == "ENABLED", ns.Registry.State("autoSellJunk"))
HARNESS.expectedFaults = {}

if HARNESS_SESSION == "phase8-withheld" then
    local view = ns.EquippedSkills.Inspect()
    check("withheld: capability Withheld", view.capability == "Withheld", view.capability)
    ContainerFrameCombinedBags:Show()
    HARNESS.frame()
    local rows = inspectRows()
    check("withheld: professions only", rows == "PrimaryProfession 38/75; PrimaryProfession 60/75", rows)
    check("withheld: surfaced once", count(table.concat(HARNESS.chat, "\n"), "withholds skill levels") == 1)
    check("withheld: panel still shows the professions", _G.PersonalAddonEquippedSkills.shown)
elseif HARNESS_SESSION == "phase8-positional" then
    local parsed = ns.Toasts.ParseLootMessage("Beute: 3x " .. lootLink(2001, "Grüne Stiefel") .. ".")
    check("positional: parsed as an item", parsed and parsed.kind == "ItemLooted", parsed and parsed.kind)
    check("positional: quantity from %2$d", parsed and parsed.quantity == 3, parsed and parsed.quantity)
    check("positional: item id from %1$s", parsed and parsed.itemId == 2001, parsed and parsed.itemId)
elseif HARNESS_SESSION == "phase8-noglobals" then
    local view = ns.Toasts.Inspect()
    check("no globals: toasts still enabled", view.enabled)
    check("no globals: loot capture off", view.lootCapture == false)
    check("no globals: names the missing global", view.patternFailure == "LOOT_ITEM_SELF", view.patternFailure)
    check("no globals: no chat subscriptions", ns.Dispatch.SubscriptionCount("toasts") == 0,
        ns.Dispatch.SubscriptionCount("toasts"))
    local outcomes = ns.Toasts.PostSamples()
    check("no globals: the display still works", outcomes[1] == "Shown" and outcomes[2] == "Shown"
        and outcomes[3] == "Shown", table.concat(outcomes, ","))
else
    -- Substrate: callbacks, chrome, prewarm ----------------------------------------
    check("skills: two callback subscriptions", ns.Dispatch.SubscriptionCount("equippedSkills") == 2
        and ns.Dispatch.CallbackCount("equippedSkills") == 2,
        ns.Dispatch.SubscriptionCount("equippedSkills"))
    -- The skills window follows both; tidy bags follows the close only.
    check("registry holds one owner per subscription",
        HARNESS.callbackCount("ContainerFrame.OpenBag") == 1
        and HARNESS.callbackCount("ContainerFrame.CloseBag") == 2,
        HARNESS.callbackCount("ContainerFrame.CloseBag"))

    local panel = _G.PersonalAddonEquippedSkills
    check("skills panel exists, hidden", panel ~= nil and panel.shown == false)
    check("skills panel parented to UIParent", panel and panel.parent == UIParent)
    check("skills panel mouse disabled", panel and panel.mouse == false)
    check("skills panel strata MEDIUM", panel and panel.strata == "MEDIUM", panel and panel.strata)
    check("skills panel clamped", panel and panel.clamped == true)
    local point, relativeTo, relativePoint, x, y = panel:GetPoint(1)
    check("skills panel anchored at the bag's left edge", point == "TOPRIGHT"
        and relativeTo == ContainerFrameCombinedBags and relativePoint == "TOPLEFT" and x == -4 and y == 0,
        string.format("%s %s %s %s", tostring(point), tostring(relativePoint), tostring(x), tostring(y)))
    local skillsView = ns.EquippedSkills.Inspect()
    check("skills rows prewarmed", skillsView.poolConstructed == 8 and skillsView.poolFree == 8,
        skillsView.poolConstructed)
    check("skills border matches the breakdown's", skillsView.borderStyle == "backdrop via BackdropTemplate",
        skillsView.borderStyle)
    local toastView = ns.Toasts.Inspect()
    check("toast pool prewarmed", toastView.poolConstructed == 5, toastView.poolConstructed)
    check("toasts container on HIGH, mouse off", _G.PersonalAddonToasts.strata == "HIGH"
        and _G.PersonalAddonToasts.mouse == false)

    for _, frame in ipairs(HARNESS.createdFrames) do
        if HARNESS.descendsFrom(frame, ContainerFrameCombinedBags) then
            check("no frame of ours under the bag", false, frame.name or "anonymous")
        end
    end

    -- Criterion 1: the breakdown panel through the shared chrome.
    check("damage breakdown enabled", ns.Registry.State("damageBreakdown") == "ENABLED",
        ns.Registry.State("damageBreakdown"))
    local mark = chatMark()
    slash("dps")
    local dps = chatSince(mark)
    check("breakdown border unchanged", dps:find("border=backdrop via BackdropTemplate", 1, true) ~= nil, dps)
    local breakdown = _G.PersonalAddonDamageBreakdown
    check("breakdown background alone carries the opacity", breakdown.background.alpha == 0.8
        and breakdown.alpha == 1, tostring(breakdown.background.alpha))
    check("breakdown still anchored to PlayerFrame", select(2, breakdown:GetPoint(1)) == PlayerFrame)

    -- Settings panel builds the new controls from the schema.
    local controls = table.concat(HARNESS.settingsControls, "\n")
    check("panel: skills opacity slider", controls:find("slider:Panel opacity", 1, true) ~= nil)
    check("panel: toast duration slider", controls:find("slider:Seconds on screen", 1, true) ~= nil)
    check("panel: looted money checkbox", controls:find("checkbox:Looted money", 1, true) ~= nil)
    check("panel: uncurated keys absent", controls:find("Refresh interval while open", 1, true) == nil
        and controls:find("Toasts on screen at once", 1, true) == nil)
    check("panel: probe not offered", controls:find("Bag write probe", 1, true) == nil)

    -- Skills window: open, rows, deferral ---------------------------------------------
    local framesBefore = #HARNESS.createdFrames
    ContainerFrameCombinedBags:Show()
    check("deferred: nothing drawn inside the bag's OnShow", panel.shown == false)
    HARNESS.frame()
    check("shown a frame later", panel.shown == true)
    check("no frame created on open", #HARNESS.createdFrames == framesBefore,
        #HARNESS.createdFrames - framesBefore)
    local rows = inspectRows()
    check("rows: professions, main hand, ranged, Defense",
        rows == "PrimaryProfession 38/75; PrimaryProfession 60/75; WeaponSkill[main hand] 38/40; WeaponSkill[ranged] 30/40; Defense 40/40",
        rows)
    check("rows drawn as rank / maximum", rowsText() == "38 / 75, 60 / 75, 38 / 40, 30 / 40, 40 / 40", rowsText())
    check("panel height fits five rows", panel.height == 6 * 2 + 5 * 16 + 4 * 2, panel.height)
    local _, view = inspectRows()
    check("poll running while shown", view.pollRunning == true)

    -- Another container frame's callbacks change nothing: level-triggered.
    ContainerFrame1:Show()
    ContainerFrame1:Hide()
    HARNESS.frame()
    check("other bag frames ignored", panel.shown == true)

    -- Equipment changes while open, picked up by the poll.
    HARNESS.equipped[16] = 1004
    HARNESS.advance(1.1)
    rows = inspectRows()
    check("poll: main hand now Daggers", rows:find("WeaponSkill[main hand] 1/40", 1, true) ~= nil, rows)
    HARNESS.equipped[17] = 1004
    HARNESS.advance(1.1)
    rows = inspectRows()
    check("two daggers make one row", count(rows, "1/40") == 1, rows)
    HARNESS.equipped[17] = 1003
    HARNESS.advance(1.1)
    rows = inspectRows()
    check("a shield makes no row", rows:find("off hand", 1, true) == nil, rows)

    HARNESS.equipped[16] = nil
    HARNESS.advance(1.1)
    rows, view = inspectRows()
    check("empty main hand shows Unarmed", rows:find("WeaponSkill[main hand] 10/40", 1, true) ~= nil, rows)
    check("fist line resolved to 162", view.fistLine == 162, view.fistLine)
    check("unarmed row has the empty-slot icon", view.rows[3] and view.rows[3].hasIcon == true)

    HARNESS.skillLines[162] = nil
    HARNESS.skillLines[473] = { name = "Fist Weapons", rank = 5, max = 40 }
    HARNESS.equipped[16] = 1006
    HARNESS.advance(1.1)
    rows, view = inspectRows()
    check("fist weapon falls back to 473", view.fistLine == 473 and rows:find("5/40", 1, true) ~= nil, rows)

    HARNESS.equipped[16] = 1005
    HARNESS.advance(1.1)
    rows = inspectRows()
    check("fishing pole shows Fishing", rows:find("Fishing 12/75", 1, true) ~= nil, rows)

    HARNESS.equipped[16] = 1007
    HARNESS.advance(1.1)
    rows, view = inspectRows()
    check("warglaive: no row, listed unresolved", #view.unresolved == 1
        and view.unresolved[1]:find("main hand (Warglaive)", 1, true) ~= nil,
        table.concat(view.unresolved, ","))

    -- An icon that fails to load is hidden, not drawn wrong.
    HARNESS.equipped[16] = 1001
    HARNESS.badTextures[ns.DEFENSE_ICON] = true
    HARNESS.advance(1.1)
    view = ns.EquippedSkills.Inspect()
    check("failed icon counted", view.iconFailures >= 1, view.iconFailures)
    HARNESS.badTextures[ns.DEFENSE_ICON] = nil

    -- Settings apply live.
    slash("set equippedSkills anchorOffsetX 10")
    point, relativeTo, relativePoint, x = panel:GetPoint(1)
    check("offset re-anchors", x == 10, x)
    slash("set equippedSkills panelAlpha 0.5")
    check("opacity on the background", panel.background.alpha == 0.5, panel.background.alpha)

    -- Close: hidden a frame later, poll stopped.
    ContainerFrameCombinedBags:Hide()
    check("close deferred", panel.shown == true)
    HARNESS.frame()
    check("hidden a frame later", panel.shown == false)
    check("poll stopped", ns.EquippedSkills.Inspect().pollRunning == false)

    -- Open and close in one frame: stays hidden.
    ContainerFrameCombinedBags:Show()
    ContainerFrameCombinedBags:Hide()
    HARNESS.frame()
    check("open and close in one frame: hidden", panel.shown == false)

    -- /pa skills with the bag closed still reads.
    mark = chatMark()
    slash("skills")
    local skills = chatSince(mark)
    check("/pa skills prints rows", skills:find("PrimaryProfession", 1, true) ~= nil, skills)
    check("/pa skills names the fist line", skills:find("resolved to skill line 473", 1, true) ~= nil, skills)

    -- Disable: zero subscriptions, callbacks released, hidden.
    ContainerFrameCombinedBags:Show()
    HARNESS.frame()
    slash("off equippedSkills")
    check("disable: no subscriptions", ns.Dispatch.SubscriptionCount("equippedSkills") == 0)
    check("disable: its callbacks released, tidy bags' kept",
        HARNESS.callbackCount("ContainerFrame.OpenBag") == 0
        and HARNESS.callbackCount("ContainerFrame.CloseBag") == 1)
    check("disable: hidden, no poll", panel.shown == false and ns.EquippedSkills.Inspect().pollRunning == false)
    -- Enabling while the bag is open shows at once, in our own execution.
    slash("on equippedSkills")
    check("enable with the bag open shows", panel.shown == true)
    ContainerFrameCombinedBags:Hide()
    HARNESS.frame()

    -- Toasts ----------------------------------------------------------------------------
    -- Section 6.5 first, while the stack check still has deliveries left.
    table.insert(HARNESS.callContext,
        '[string "@Interface/AddOns/Blizzard_UIPanels_Game/Mainline/LootFrame.lua"]:143: in function <LootFrame_OnEvent>')
    HARNESS.fire("CHAT_MSG_LOOT", "You receive loot: " .. lootLink(2002, "Linen Cloth", "ffffffff") .. ".")
    table.remove(HARNESS.callContext)
    check("inside-call delivery counted", ns.Toasts.Inspect().counts.deliveredInsideCall == 1,
        ns.Toasts.Inspect().counts.deliveredInsideCall)
    HARNESS.fire("CHAT_MSG_LOOT", "You receive loot: " .. lootLink(2002, "Linen Cloth", "ffffffff") .. ".")
    check("server delivery not counted", ns.Toasts.Inspect().counts.deliveredInsideCall == 1)
    HARNESS.frame()
    check("white items make no toast", #toastFrames() == 0 and ns.Toasts.Inspect().counts.notShown == 2,
        ns.Toasts.Inspect().counts.notShown)

    HARNESS.fire("CHAT_MSG_LOOT", "You receive loot: " .. lootLink(2001, "Green Boots") .. ".")
    check("toast waits for the next frame", #toastFrames() == 0)
    HARNESS.frame()
    local toasts = toastFrames()
    check("green item toasted", #toasts == 1 and toasts[1].text:GetText() == "Green Boots",
        toasts[1] and toasts[1].text:GetText())
    check("name coloured by quality", toasts[1] and math.abs(toasts[1].text.textColor[2] - 1) < 0.01
        and math.abs(toasts[1].text.textColor[1] - 0.12) < 0.01)
    check("label says looted", toasts[1] and toasts[1].label:GetText() == "You looted")
    check("toast icon is the item's", toasts[1] and toasts[1].icon.texture == 132539, toasts[1] and toasts[1].icon.texture)

    HARNESS.fire("CHAT_MSG_LOOT", "You receive loot: " .. lootLink(2001, "Green Boots") .. "x3.")
    HARNESS.fire("CHAT_MSG_LOOT", "You receive loot: " .. lootLink(2003, "Kobold Candle", "ffffffff") .. ".")
    HARNESS.frame()
    toasts = toastFrames()
    check("three visible", #toasts == 3, #toasts)
    local quantityShown, questShown = false, false
    for _, toast in ipairs(toasts) do
        if toast.count:GetText() == "3" then quantityShown = true end
        if toast.label:GetText() == "Quest item" then questShown = true end
    end
    check("quantity shown", quantityShown)
    check("quest item of any quality shown", questShown)

    HARNESS.fire("CHAT_MSG_LOOT", "Bob receives loot: " .. lootLink(2001, "Green Boots") .. ".")
    HARNESS.fire("CHAT_MSG_LOOT", "You receive item: " .. lootLink(2001, "Green Boots") .. ".")
    HARNESS.fire("CHAT_MSG_LOOT", "You receive loot: " .. lootLink(2004, "Uncached Boots") .. ".")
    HARNESS.fire("CHAT_MSG_LOOT", HARNESS.SECRET)
    HARNESS.frame()
    local counts = ns.Toasts.Inspect().counts
    check("other players and pushed items are not ours", counts.notOurs == 2, counts.notOurs)
    check("uncached quality unresolved", counts.unresolved == 1, counts.unresolved)
    check("secret text counted", counts.secretTexts == 1, counts.secretTexts)

    -- Money, into the queue while three are visible, then coalesced.
    HARNESS.fire("CHAT_MSG_MONEY", "You loot 1 Gold, 5 Silver, 3 Copper")
    HARNESS.fire("CHAT_MSG_MONEY", "Your share of the loot is 5 Silver.")
    HARNESS.fire("CHAT_MSG_MONEY", "You loot a shiny thing")
    HARNESS.frame()
    local view8 = ns.Toasts.Inspect()
    check("money queued behind three", view8.queued == 1, view8.queued)
    check("second money coalesced", view8.counts.coalesced == 1, view8.counts.coalesced)
    check("unreadable money message counted", view8.counts.unparsed == 1, view8.counts.unparsed)
    check("unparsed surfaced with its text",
        table.concat(HARNESS.chat, "\n"):find("could not be read, so it made no toast: You loot a shiny thing", 1, true) ~= nil)

    -- Expiry: after the duration and fade, the queued money takes a slot.
    HARNESS.advance(4.0 + 0.6)
    toasts = toastFrames()
    local moneyText
    for _, toast in ipairs(toasts) do
        if toast.label:GetText() == "You looted" and toast.icon.texture == "Interface\\Icons\\INV_Misc_Coin_02" then
            moneyText = toast.text:GetText()
        end
    end
    check("money toast shows the summed amount", moneyText == "coins:11003", moneyText)
    check("expired toasts released", ns.Toasts.Inspect().queued == 0)

    -- A visible money toast absorbs more money and restarts its timer.
    HARNESS.fire("CHAT_MSG_MONEY", "You loot 7 Copper")
    HARNESS.frame()
    moneyText = nil
    for _, toast in ipairs(toastFrames()) do
        if toast.icon.texture == "Interface\\Icons\\INV_Misc_Coin_02" then
            moneyText = toast.text:GetText()
        end
    end
    check("visible money coalesced", moneyText == "coins:11010", moneyText)

    HARNESS.advance(10)
    check("all toasts gone after their time", #toastFrames() == 0, #toastFrames())

    -- Queue bound: 3 shown, 10 queued, the rest dropped.
    local outcomes = {}
    for index = 1, 16 do
        outcomes[index] = ns.Toasts.Post({ kind = "LootedItem", itemId = 2001, name = "Boots " .. index,
            quantity = 1, quality = 2, isQuestItem = false })
    end
    check("three shown", outcomes[1] == "Shown" and outcomes[3] == "Shown")
    check("ten queued", outcomes[4] == "Queued" and outcomes[13] == "Queued")
    check("the rest dropped", outcomes[14] == "Dropped" and outcomes[16] == "Dropped", outcomes[14])
    check("drop surfaced once", count(table.concat(HARNESS.chat, "\n"), "later ones are dropped") == 1)
    HARNESS.advance(30)
    check("queue drains", #toastFrames() == 0 and ns.Toasts.Inspect().queued == 0)

    -- /pa toasts test and /pa toasts.
    mark = chatMark()
    slash("toasts test")
    check("/pa toasts test posts three", chatSince(mark):find("Shown, Shown, Shown", 1, true) ~= nil, chatSince(mark))
    mark = chatMark()
    slash("toasts")
    check("/pa toasts prints the stack check", chatSince(mark):find("deliveredInsideCall=1", 1, true) ~= nil, chatSince(mark))

    -- Disable: unavailable, nothing left.
    slash("off toasts")
    local outcome, reason = ns.Toasts.Post({ kind = "LootedMoney", amount = 5 })
    check("disabled: Unavailable(ToastsDisabled)", outcome == "Unavailable" and reason == "ToastsDisabled",
        tostring(outcome) .. " " .. tostring(reason))
    check("disabled: container hidden, nothing visible", _G.PersonalAddonToasts.shown == false
        and #toastFrames() == 0)
    check("disabled: no subscriptions", ns.Dispatch.SubscriptionCount("toasts") == 0)
    local liveTimers = 0
    for _, timer in ipairs(HARNESS.timers) do
        if not timer.cancelled then liveTimers = liveTimers + 1 end
    end
    slash("on toasts")
    HARNESS.frame()

    -- CallWindow ---------------------------------------------------------------------------
    local names, ok = ns.CallWindow.Capture(function() HARNESS.fire("ITEM_LOCKED", 0, 1) end)
    check("window records what arrives inside the call", ok and table.concat(names, ",") == "ITEM_LOCKED",
        table.concat(names, ","))
    names = ns.CallWindow.Capture(function() end)
    check("window records nothing for a quiet call", #names == 0)
    local anyAllEvents = false
    for _, frame in ipairs(HARNESS.createdFrames) do
        if frame.allEvents then anyAllEvents = true end
    end
    check("window frame holds nothing afterwards", not anyAllEvents)
    local own = ns.CallWindow.Listeners({ "CHAT_MSG_LOOT" })
    check("listener read leaves out our Dispatch frame", own and #own.CHAT_MSG_LOOT == 0,
        own and table.concat(own.CHAT_MSG_LOOT, ","))
    local merchantListeners = ns.CallWindow.Listeners({ "BAG_UPDATE" })
    check("listener read names another frame", merchantListeners
        and merchantListeners.BAG_UPDATE[1] == "MerchantFrame")

    -- Tidy bags (section 7.1) ------------------------------------------------------------
    local function closeBag()
        ContainerFrameCombinedBags:Show()
        HARNESS.frame()
        ContainerFrameCombinedBags:Hide()
    end
    check("tidy bags: one callback", ns.Dispatch.SubscriptionCount("autoSortBags") == 1
        and ns.Dispatch.CallbackCount("autoSortBags") == 1)
    HARNESS.sortCalls = 0
    HARNESS.advance(61)
    closeBag()
    check("sort waits for the flush", HARNESS.sortCalls == 0)
    HARNESS.frame()
    check("closing the bags sorts", HARNESS.sortCalls == 1, HARNESS.sortCalls)
    local sortView = ns.AutoSortBags.Inspect()
    check("the spike's two events arrived inside the sort",
        sortView.lastInline == "ITEM_LOCK_CHANGED, ITEM_LOCKED", sortView.lastInline)
    check("still enabled after an expected sort", ns.Registry.State("autoSortBags") == "ENABLED")
    HARNESS.flushEvents()

    closeBag()
    HARNESS.frame()
    check("cooldown: no second sort", HARNESS.sortCalls == 1)
    check("cooldown counted", ns.AutoSortBags.Inspect().lastSkip == "CoolingDown",
        ns.AutoSortBags.Inspect().lastSkip)
    HARNESS.advance(61)

    HARNESS.playerInCombat = true
    closeBag()
    HARNESS.frame()
    check("combat: no sort", HARNESS.sortCalls == 1 and ns.AutoSortBags.Inspect().lastSkip == "InCombat")
    HARNESS.playerInCombat = false

    HARNESS.cursorItem = true
    closeBag()
    HARNESS.frame()
    check("cursor: no sort", HARNESS.sortCalls == 1 and ns.AutoSortBags.Inspect().lastSkip == "CursorHoldsItem")
    HARNESS.cursorItem = false

    HARNESS.bags[0].locked[1] = true
    closeBag()
    HARNESS.frame()
    check("locked items: no sort", HARNESS.sortCalls == 1 and ns.AutoSortBags.Inspect().lastSkip == "ItemsLocked")
    HARNESS.bags[0].locked[1] = nil

    -- A tracked bag item in the Cooldown Manager listens to ITEM_LOCK_CHANGED.
    local cooldownItem = CreateFrame("Frame", "CooldownViewerBagItem1", UIParent)
    cooldownItem:RegisterEvent("ITEM_LOCK_CHANGED")
    local mark = chatMark()
    closeBag()
    HARNESS.frame()
    check("a listener holds the sort back", HARNESS.sortCalls == 1
        and ns.AutoSortBags.Inspect().lastSkip == "ListenersPresent", ns.AutoSortBags.Inspect().lastSkip)
    check("the listener is named", chatSince(mark):find("ITEM_LOCK_CHANGED: CooldownViewerBagItem1", 1, true) ~= nil,
        chatSince(mark))
    cooldownItem:UnregisterEvent("ITEM_LOCK_CHANGED")
    closeBag()
    HARNESS.frame()
    check("sorts once nothing listens", HARNESS.sortCalls == 2, HARNESS.sortCalls)
    HARNESS.flushEvents()

    mark = chatMark()
    slash("bags")
    check("/pa bags reports skips", chatSince(mark):find("ListenersPresent=1", 1, true) ~= nil, chatSince(mark))

    -- A third event inside the sort: one fault, surfaced, and nothing else stops.
    HARNESS.advance(61)
    HARNESS.sortInline = { { "ITEM_LOCK_CHANGED", 0, 1 }, { "BAG_UPDATE", 0 } }
    HARNESS.expectedFaults[#HARNESS.expectedFaults + 1] = "SortBags delivered BAG_UPDATE inside the call"
    closeBag()
    HARNESS.frame()
    check("unexpected event faults tidy bags", ns.Registry.State("autoSortBags") == "FAULTED",
        ns.Registry.State("autoSortBags"))
    check("the fault names the event",
        table.concat(HARNESS.chat, "\n"):find("SortBags delivered BAG_UPDATE inside the call", 1, true) ~= nil)
    check("the fault released the callback", ns.Dispatch.SubscriptionCount("autoSortBags") == 0)
    check("the skills window carries on", ns.Registry.State("equippedSkills") == "ENABLED")
    HARNESS.sortInline = { { "ITEM_LOCK_CHANGED", 0, 1 }, { "ITEM_LOCKED", 0, 1 } }
    HARNESS.flushEvents()
    slash("on autoSortBags")
    check("re-enabled by hand", ns.Registry.State("autoSortBags") == "ENABLED")

    -- Sell junk (section 7.2) -------------------------------------------------------------
    local function junkToast()
        for _, toast in ipairs(toastFrames()) do
            local label = toast.label:GetText()
            if label == "Junk sold" or label == "Some junk sold" or label == "Junk sale not confirmed" then
                return toast
            end
        end
    end
    HARNESS.advance(30)
    HARNESS.merchantOpen = true
    HARNESS.junk = 2
    HARNESS.sellCalls = 0
    HARNESS.fire("MERCHANT_SHOW")
    check("sale waits a frame", HARNESS.sellCalls == 0)
    HARNESS.frame()
    check("one sale per visit", HARNESS.sellCalls == 1, HARNESS.sellCalls)
    HARNESS.fire("MERCHANT_SHOW")
    HARNESS.frame()
    check("a pending sale blocks a second", HARNESS.sellCalls == 1
        and ns.AutoSellJunk.Inspect().lastSkip == "SaleInProgress", ns.AutoSellJunk.Inspect().lastSkip)
    HARNESS.completeSale()
    HARNESS.frame()
    local toast = junkToast()
    check("junk sold toast", toast and toast.label:GetText() == "Junk sold"
        and toast.text:GetText() == "2 for coins:500", toast and toast.text:GetText())
    check("summary kept", ns.AutoSellJunk.Inspect().lastSummary == "sold 2 junk item(s) for coins:500",
        ns.AutoSellJunk.Inspect().lastSummary)

    HARNESS.fire("MERCHANT_SHOW")
    HARNESS.frame()
    check("no junk: nothing sold", HARNESS.sellCalls == 1 and ns.AutoSellJunk.Inspect().lastSkip == "NoJunk")
    HARNESS.advance(10)

    -- Partial: two of three sold by the timeout.
    HARNESS.junk = 3
    HARNESS.fire("MERCHANT_SHOW")
    HARNESS.frame()
    HARNESS.money = HARNESS.money + 500
    HARNESS.junk = 1
    HARNESS.fire("BAG_UPDATE_DELAYED")
    check("still pending while junk remains", ns.AutoSellJunk.Inspect().salePending == true)
    HARNESS.advance(3.2)
    toast = junkToast()
    check("partial toast", toast and toast.label:GetText() == "Some junk sold"
        and toast.text:GetText() == "2 for coins:500, 1 left", toast and toast.text:GetText())
    HARNESS.advance(10)

    -- Unconfirmed: nothing moved by the timeout.
    HARNESS.junk = 2
    HARNESS.fire("MERCHANT_SHOW")
    HARNESS.frame()
    HARNESS.advance(3.2)
    toast = junkToast()
    check("unconfirmed toast", toast and toast.label:GetText() == "Junk sale not confirmed"
        and toast.text:GetText() == "2 still in your bags", toast and toast.text:GetText())
    HARNESS.advance(10)

    -- Toasts off: the summary goes to chat.
    slash("off toasts")
    HARNESS.junk = 1
    mark = chatMark()
    HARNESS.fire("MERCHANT_SHOW")
    HARNESS.frame()
    HARNESS.completeSale()
    check("toasts off: summary in chat", chatSince(mark):find("sold 1 junk item(s) for coins:250", 1, true) ~= nil,
        chatSince(mark))
    check("toasts off: posted Unavailable", ns.AutoSellJunk.Inspect().lastPosted == "Unavailable")
    slash("on toasts")

    -- Switched off, away from a merchant, in combat.
    HARNESS.junk = 1
    HARNESS.sellAllEnabled = false
    HARNESS.fire("MERCHANT_SHOW")
    HARNESS.frame()
    check("sell-all off: skipped", ns.AutoSellJunk.Inspect().lastSkip == "SellAllJunkDisabled")
    HARNESS.sellAllEnabled = true
    HARNESS.merchantOpen = false
    HARNESS.fire("MERCHANT_SHOW")
    HARNESS.frame()
    check("not at a merchant: skipped", ns.AutoSellJunk.Inspect().lastSkip == "NotAtMerchant")
    HARNESS.merchantOpen = true
    HARNESS.playerInCombat = true
    HARNESS.fire("MERCHANT_SHOW")
    HARNESS.frame()
    check("combat: skipped", ns.AutoSellJunk.Inspect().lastSkip == "InCombat")
    HARNESS.playerInCombat = false
    check("none of those sold", HARNESS.sellCalls == 4, HARNESS.sellCalls)

    -- Disabled while a sale settles: nothing reported afterwards.
    HARNESS.fire("MERCHANT_SHOW")
    HARNESS.frame()
    check("sale started", ns.AutoSellJunk.Inspect().salePending == true)
    slash("off autoSellJunk")
    check("disable clears the pending sale", ns.AutoSellJunk.Inspect().salePending == false)
    mark = chatMark()
    HARNESS.advance(3.5)
    check("no report after disable", chatSince(mark) == "", chatSince(mark))
    check("no subscriptions after disable", ns.Dispatch.SubscriptionCount("autoSellJunk") == 0)
    slash("on autoSellJunk")

    -- An event inside the sale: one fault.
    HARNESS.junk = 1
    HARNESS.sellInline = { { "BAG_UPDATE", 0 } }
    HARNESS.expectedFaults[#HARNESS.expectedFaults + 1] = "SellAllJunkItems delivered BAG_UPDATE inside the call"
    HARNESS.fire("MERCHANT_SHOW")
    HARNESS.frame()
    check("unexpected event faults sell junk", ns.Registry.State("autoSellJunk") == "FAULTED",
        ns.Registry.State("autoSellJunk"))
    HARNESS.sellInline = {}
    HARNESS.merchantOpen = false

    local panelControls = table.concat(HARNESS.settingsControls, "\n")
    check("panel: sort cooldown slider",
        panelControls:find("slider:Minimum seconds between sorts", 1, true) ~= nil)
end

-- Report -------------------------------------------------------------------------------
local errors = {}
local function expectedFault(index)
    -- A deliberate fault prints its announcement and, on the next line, its reason.
    for _, needle in ipairs(HARNESS.expectedFaults or {}) do
        local line, nextLine = HARNESS.chat[index], HARNESS.chat[index + 1] or ""
        if line:find(needle, 1, true) or nextLine:find(needle, 1, true) then
            return true
        end
    end
    return false
end
for index, line in ipairs(HARNESS.chat) do
    if (line:find("raised", 1, true) or line:find("faulted", 1, true)) and not expectedFault(index) then
        errors[#errors + 1] = line
    end
end
HARNESS_RESULT = { passed = passed, failures = failures, errors = errors, chat = HARNESS.chat }
