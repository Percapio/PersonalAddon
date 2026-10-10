-- Features/Toasts.lua
-- Pop-up notices for money and notable items you loot, and a display other
-- features post to (Phase 8 section 6).
--
-- The toast is this addon's own. Blizzard's BossBanner does not load on this
-- client, and its loot alerts are fed only by server toast events and roll wins, so
-- there is nothing native to restore; showing one from here would mean calling
-- AddAlert in our execution, which writes Blizzard's alert queue and pooled frames.
-- The geometry and art are copied from Blizzard's compact money toast
-- (MoneyWonAlertFrameTemplate) onto frames we create. The template itself is never
-- inherited: its mixin and scripts are Blizzard's code.
--
-- Loot is read from CHAT_MSG_LOOT and CHAT_MSG_MONEY. Both are formatted from server
-- packets, so no Blizzard Lua raises them inside its own call, and neither is among
-- the chat events the client makes secret in dungeons and raids (section 3). The
-- first deliveries of each session check that on the stack (section 6.5).

local ADDON_NAME, ns = ...

local FEATURE_ID = "toasts"

local format, pcall, type, tostring, tonumber = string.format, pcall, type, tostring, tonumber
local concat, remove, floor, min = table.concat, table.remove, math.floor, math.min

-- The container's strata, named because the preview has to put it back after
-- raising it over Blizzard's Options window, which is HIGH too (section 3.1).
local CONTAINER_STRATA = "HIGH"
local TOAST_WIDTH = 249
local TOAST_HEIGHT = 71
local TOAST_SPACING = 4
local FADE_SECONDS = 0.5

-- From MoneyWonAlertFrameTemplate (AlertFrameSystems.xml:842-895).
local LOOT_TOAST_TEXTURE = "Interface\\LootFrame\\LootToast"
local BACKGROUND_COORDS = { 0.56347656, 0.80664063, 0.28906250, 0.56640625 }
local ICON_BORDER_COORDS = { 0.73242188, 0.78906250, 0.57421875, 0.80078125 }
local MONEY_ICON = "Interface\\Icons\\INV_Misc_Coin_02"

local KIND = {
    LOOTED_ITEM = "LootedItem",
    LOOTED_MONEY = "LootedMoney",
    JUNK_SOLD = "JunkSold",
}

local OUTCOME = {
    SHOWN = "Shown",
    QUEUED = "Queued",
    COALESCED = "Coalesced",
    DROPPED = "Dropped",
    UNAVAILABLE = "Unavailable",
}

local UNAVAILABLE = {
    DISABLED = "ToastsDisabled",
    NOT_READY = "NotReady",
}

local MESSAGE = {
    ITEM = "ItemLooted",
    MONEY = "MoneyLooted",
    NOT_OURS = "NotOurs",
    UNPARSED = "Unparsed",
}

-- Every count Toasts keeps. Since Phase 10 (section 7.2) they live in this UI
-- load's PersonalAddonDiagnostics record, created on first use by Bump, so a
-- /reload no longer loses them; Inspect reports an absent one as 0.
local COUNT_NAMES = {
    "posted", "shown", "queued", "coalesced", "dropped", "unavailable",
    "secretTexts", "unparsed", "unresolved", "notShown", "notOurs", "inboxDropped",
    "stackChecked", "deliveredInsideCall",
    "lootMessagesOnRestrictedMap", "shownOnRestrictedMap",
}

local bump = ns.Diagnostics.Bump

local state = {
    enabled = false,
    container = nil,
    pool = nil,
    visible = {},
    queue = {},
    patterns = nil,
    patternFailure = nil,
    inbox = {},
    inboxScheduled = false,
    inboxGeneration = 0,
    tokens = {},
    -- A detached table until enable binds this UI load's diagnostics table.
    counts = {},
    settings = {
        showLootedItems = true,
        showQuestItems = true,
        showLootedMoney = true,
        durationSeconds = 4,
        anchorOffsetX = 0,
        anchorOffsetY = -180,
        minimumQuality = 2,
        maximumVisible = 3,
    },
}

-- Values ------------------------------------------------------------------------

local function isSecret(value)
    local check = _G.issecretvalue
    if type(check) ~= "function" then
        return false
    end
    local ok, secret = pcall(check, value)
    return not ok or secret == true
end

local function isPlain(value, expectedType)
    return not isSecret(value) and type(value) == expectedType
end

local function qualityColour(quality)
    local api = _G.C_Item and _G.C_Item.GetItemQualityColor
    if type(api) == "function" and isPlain(quality, "number") then
        local ok, red, green, blue = pcall(api, quality)
        if ok and isPlain(red, "number") and isPlain(green, "number") and isPlain(blue, "number") then
            return red, green, blue
        end
    end
    return 1, 1, 1
end

-- The client's own coin string, with coin icons; plain text where it has none.
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

-- Frames ------------------------------------------------------------------------

local function createToast()
    local toast = CreateFrame("Frame", nil, state.container)
    toast:SetWidth(TOAST_WIDTH)
    toast:SetHeight(TOAST_HEIGHT)
    toast:EnableMouse(false)

    toast.background = toast:CreateTexture(nil, "BACKGROUND")
    toast.background:SetTexture(LOOT_TOAST_TEXTURE)
    toast.background:SetTexCoord(BACKGROUND_COORDS[1], BACKGROUND_COORDS[2],
        BACKGROUND_COORDS[3], BACKGROUND_COORDS[4])
    toast.background:SetAllPoints(toast)

    toast.icon = toast:CreateTexture(nil, "ARTWORK")
    toast.icon:SetWidth(38)
    toast.icon:SetHeight(38)
    toast.icon:SetPoint("LEFT", toast, "LEFT", 16, 0)

    toast.iconBorder = toast:CreateTexture(nil, "OVERLAY")
    toast.iconBorder:SetTexture(LOOT_TOAST_TEXTURE)
    toast.iconBorder:SetTexCoord(ICON_BORDER_COORDS[1], ICON_BORDER_COORDS[2],
        ICON_BORDER_COORDS[3], ICON_BORDER_COORDS[4])
    toast.iconBorder:SetWidth(45)
    toast.iconBorder:SetHeight(45)
    toast.iconBorder:SetPoint("CENTER", toast.icon, "CENTER", 0, 0)

    toast.label = toast:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    toast.label:SetPoint("TOPLEFT", toast.iconBorder, "TOPRIGHT", 7, -1)
    toast.label:SetJustifyH("LEFT")

    toast.text = toast:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    toast.text:SetPoint("BOTTOMLEFT", toast.iconBorder, "BOTTOMRIGHT", 10, 7)
    toast.text:SetJustifyH("LEFT")
    toast.text:SetWidth(TOAST_WIDTH - 16 - 45 - 10 - 12)
    toast.text:SetWordWrap(false)

    toast.count = toast:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    toast.count:SetPoint("BOTTOMRIGHT", toast.icon, "BOTTOMRIGHT", -1, 2)
    toast.count:SetJustifyH("RIGHT")

    toast.generation = 0
    return toast
end

local function cancelToastTimer(toast)
    if toast.timer and toast.timer.Cancel then
        toast.timer:Cancel()
    end
    toast.timer = nil
end

local function resetToast(toast)
    cancelToastTimer(toast)
    toast:SetScript("OnUpdate", nil)
    toast.fading = false
    toast.isPreviewSample = false
    toast.generation = (toast.generation or 0) + 1
    toast.request = nil
    toast:Hide()
    toast:ClearAllPoints()
    toast:SetAlpha(1)
    toast.icon:SetTexture(nil)
    toast.iconBorder:SetVertexColor(1, 1, 1)
    toast.label:SetText("")
    toast.text:SetText("")
    toast.text:SetTextColor(1, 1, 1)
    toast.count:SetText("")
end

local function setIcon(texture, icon)
    if icon == nil or texture:SetTexture(icon) == false then
        texture:SetTexture(MONEY_ICON)
    end
end

local function paint(toast, request)
    toast.request = request
    if request.kind == KIND.LOOTED_ITEM then
        toast.label:SetText(request.isQuestItem and "Quest item" or "You looted")
        setIcon(toast.icon, request.icon)
        local red, green, blue = qualityColour(request.quality)
        toast.text:SetText(ns.EscapeGuard.Neutralize(request.name))
        toast.text:SetTextColor(red, green, blue)
        toast.iconBorder:SetVertexColor(red, green, blue)
        toast.count:SetText((request.quantity or 1) > 1 and tostring(request.quantity) or "")
    elseif request.kind == KIND.LOOTED_MONEY then
        toast.label:SetText("You looted")
        toast.icon:SetTexture(MONEY_ICON)
        toast.text:SetText(coinText(request.amount))
        toast.text:SetTextColor(1, 1, 1)
    elseif request.kind == KIND.JUNK_SOLD then
        toast.icon:SetTexture(MONEY_ICON)
        toast.text:SetTextColor(1, 1, 1)
        if request.confirmed then
            toast.label:SetText(request.itemsUnsold > 0 and "Some junk sold" or "Junk sold")
            local text = format("%d for %s", request.itemsSold, coinText(request.revenue))
            if request.itemsUnsold > 0 then
                text = text .. format(", %d left", request.itemsUnsold)
            end
            toast.text:SetText(text)
        else
            toast.label:SetText("Junk sale not confirmed")
            toast.text:SetText(format("%d still in your bags", request.itemsUnsold))
        end
    end
end

local function layout()
    for index = 1, #state.visible do
        local toast = state.visible[index]
        toast:ClearAllPoints()
        toast:SetPoint("TOP", state.container, "TOP", 0,
            -(index - 1) * (TOAST_HEIGHT + TOAST_SPACING))
    end
end

local showNext
local beginFade
-- Put a sample back once a real toast that took its slot has gone.
local refillPreviewSamples

local function startToastTimer(toast)
    cancelToastTimer(toast)
    local generation = toast.generation
    if C_Timer and C_Timer.NewTimer then
        toast.timer = C_Timer.NewTimer(state.settings.durationSeconds, function()
            if toast.generation == generation and toast.request then
                beginFade(toast)
            end
        end)
    end
end

local function release(toast)
    for index = #state.visible, 1, -1 do
        if state.visible[index] == toast then
            remove(state.visible, index)
            break
        end
    end
    ns.FramePool.Release(state.pool, toast)
    layout()
    showNext()
    if refillPreviewSamples then
        refillPreviewSamples()
    end
end

-- The fade is our own OnUpdate on our own frame, set only while it runs.
beginFade = function(toast)
    toast.timer = nil
    toast.fading = true
    local elapsedTotal = 0
    toast:SetScript("OnUpdate", function(self, elapsed)
        elapsedTotal = elapsedTotal + (elapsed or 0)
        local remaining = 1 - elapsedTotal / FADE_SECONDS
        if remaining <= 0 then
            self:SetScript("OnUpdate", nil)
            release(self)
            return
        end
        self:SetAlpha(remaining)
    end)
end

-- isSample: a preview sample, which gets no duration timer so it never fades,
-- and is marked so a real toast can take its slot (Phase 13 section 5.5). The
-- mark is a field on one of OUR frames, so rule 2 is untouched.
local function display(request, isSample)
    local toast = ns.FramePool.Acquire(state.pool)
    if not toast then
        return false
    end
    paint(toast, request)
    toast.isPreviewSample = (isSample == true)
    state.visible[#state.visible + 1] = toast
    layout()
    toast:Show()
    if not isSample then
        startToastTimer(toast)
    end
    return true
end

showNext = function()
    while state.enabled and #state.queue > 0
        and #state.visible < state.settings.maximumVisible do
        local request = remove(state.queue, 1)
        if not display(request) then
            state.queue[#state.queue + 1] = request
            return
        end
    end
end

-- Preview samples (section 5.5) ---------------------------------------------------

-- Frees a slot for a real toast by giving up the NEWEST sample, so no real loot
-- notification is ever lost to the preview. The sample comes back on the next
-- ShowPreviewSamples, which the real toast's release triggers while the preview
-- is on.
local function evictSampleForRealToast()
    for index = #state.visible, 1, -1 do
        local toast = state.visible[index]
        if toast.isPreviewSample then
            remove(state.visible, index)
            ns.FramePool.Release(state.pool, toast)
            layout()
            return true
        end
    end
    return false
end

-- Money merges into a visible money toast, whose timer restarts, or into a queued one.
local function coalesceMoney(amount)
    for index = 1, #state.visible do
        local toast = state.visible[index]
        -- Never into a preview sample. Merging would add real loot to a made-up
        -- figure, and the sample carries no duration timer, so the merged total
        -- would sit on screen until the preview ended (Phase 13 section 5.5).
        if toast.request and toast.request.kind == KIND.LOOTED_MONEY
            and not toast.isPreviewSample then
            toast.request.amount = toast.request.amount + amount
            toast:SetScript("OnUpdate", nil)
            toast.fading = false
            toast:SetAlpha(1)
            paint(toast, toast.request)
            startToastTimer(toast)
            return true
        end
    end
    for index = 1, #state.queue do
        local request = state.queue[index]
        if request.kind == KIND.LOOTED_MONEY then
            request.amount = request.amount + amount
            return true
        end
    end
    return false
end

-- The service (section 6.2) -------------------------------------------------------

-- Queues a notice. The one entry point other features use.
-- Returns an outcome, plus a reason when the outcome is Unavailable.
local function post(request)
    if not state.enabled or not state.pool then
        bump(state.counts, "unavailable")
        return OUTCOME.UNAVAILABLE, UNAVAILABLE.DISABLED
    end
    if type(request) ~= "table" or not (request.kind == KIND.LOOTED_ITEM
        or request.kind == KIND.LOOTED_MONEY or request.kind == KIND.JUNK_SOLD) then
        bump(state.counts, "unavailable")
        return OUTCOME.UNAVAILABLE, UNAVAILABLE.NOT_READY
    end
    bump(state.counts, "posted")

    if request.kind == KIND.LOOTED_MONEY and coalesceMoney(request.amount) then
        bump(state.counts, "coalesced")
        return OUTCOME.COALESCED
    end

    -- A sample gives up its slot BEFORE the pool is asked, not after it fails:
    -- FramePool is SURFACE_AND_FAIL at TOAST_POOL_CAPACITY and logs "the cap is
    -- wrong" when exhausted, and two held samples with maximumVisible at its own
    -- maximum would trip that notice about a cap that is correct
    -- (Phase 13 section 5.5, decision D6).
    if #state.visible >= state.settings.maximumVisible then
        evictSampleForRealToast()
    end

    if #state.visible < state.settings.maximumVisible and display(request) then
        bump(state.counts, "shown")
        return OUTCOME.SHOWN
    end

    if #state.queue >= ns.TOAST_QUEUE_CAPACITY then
        bump(state.counts, "dropped")
        ns.Log.Once("toasts:dropped", format(
            "more than %d toasts were waiting, so later ones are dropped; /pa toasts counts them",
            ns.TOAST_QUEUE_CAPACITY))
        return OUTCOME.DROPPED
    end
    state.queue[#state.queue + 1] = request
    bump(state.counts, "queued")
    return OUTCOME.QUEUED
end

-- The samples the preview holds (decision D5): one item and one money toast.
-- Two, so the default maximumVisible of 3 leaves a slot free and the first real
-- toast evicts nothing. They go through display(), which bumps no counter --
-- post() is what counts, and these are not posts.
local SAMPLE_REQUESTS = {
    {
        kind = KIND.LOOTED_ITEM, itemId = 0, name = "Sample item",
        icon = "Interface\\Icons\\INV_Misc_QuestionMark", quantity = 1, quality = 2,
        isQuestItem = false,
    },
    { kind = KIND.LOOTED_MONEY, amount = 12345 },
}

local function visibleSampleCount()
    local count = 0
    for index = 1, #state.visible do
        if state.visible[index].isPreviewSample then
            count = count + 1
        end
    end
    return count
end

local function showPreviewSamples()
    if not state.enabled then
        return 0
    end
    local wanted = min(ns.PREVIEW_TOAST_SAMPLES, #SAMPLE_REQUESTS)
    local shownAlready = visibleSampleCount()
    for index = shownAlready + 1, wanted do
        if #state.visible >= state.settings.maximumVisible then
            break
        end
        if not display(SAMPLE_REQUESTS[index], true) then
            break
        end
    end
    return visibleSampleCount()
end

local function clearPreviewSamples()
    local released = 0
    for index = #state.visible, 1, -1 do
        local toast = state.visible[index]
        if toast.isPreviewSample then
            remove(state.visible, index)
            ns.FramePool.Release(state.pool, toast)
            released = released + 1
        end
    end
    if released > 0 then
        layout()
        showNext()
    end
    return released
end

refillPreviewSamples = function()
    if ns.Preview.IsEnabled() and state.enabled then
        showPreviewSamples()
    end
end

local function registerPreview()
    ns.Preview.Register({
        panelId = ns.PREVIEW_PANEL.TOASTS,
        raiseTarget = state.container,
        -- The container sets its own strata in code rather than through
        -- PanelChrome, so the literal is handed over here (section 3.1).
        baseStrata = CONTAINER_STRATA,
        show = showPreviewSamples,
        clear = clearPreviewSamples,
    })
end

-- Loot patterns (section 6.3) -----------------------------------------------------

local MAGIC = "^$()%.[]*+-?"

local function escapeChar(char)
    if MAGIC:find(char, 1, true) then
        return "%" .. char
    end
    return char
end

-- Converts one client format string into a Lua pattern. Returns the pattern and the
-- argument index of each capture, in capture order, so a locale that reorders its
-- arguments with %1$s still maps each capture to its meaning. Returns nil for a
-- placeholder this does not handle.
local function formatToPattern(formatString, anchored)
    local parts, order = {}, {}
    if anchored then
        parts[1] = "^"
    end
    local position, length, nextArgument = 1, #formatString, 1
    while position <= length do
        local char = formatString:sub(position, position)
        if char ~= "%" then
            parts[#parts + 1] = escapeChar(char)
            position = position + 1
        else
            local rest = formatString:sub(position + 1)
            local index, specifier = rest:match("^(%d+)%$([sd])")
            local consumed
            if index then
                consumed = #index + 2
                index = tonumber(index)
            else
                specifier = rest:match("^([sd])")
                if specifier then
                    consumed = 1
                    index = nextArgument
                    nextArgument = nextArgument + 1
                elseif rest:sub(1, 1) == "%" then
                    specifier = "%"
                    consumed = 1
                else
                    return nil
                end
            end
            if specifier == "s" then
                parts[#parts + 1] = "(.+)"
                order[#order + 1] = index
            elseif specifier == "d" then
                parts[#parts + 1] = "(%d+)"
                order[#order + 1] = index
            else
                parts[#parts + 1] = "%%"
            end
            position = position + 1 + consumed
        end
    end
    if anchored then
        parts[#parts + 1] = "$"
    end
    return { pattern = concat(parts), order = order }
end

local PATTERN_SOURCES = {
    { key = "itemSelfMultiple", global = "LOOT_ITEM_SELF_MULTIPLE", anchored = true },
    { key = "itemSelf", global = "LOOT_ITEM_SELF", anchored = true },
    { key = "moneySelf", global = "YOU_LOOT_MONEY", anchored = true },
    { key = "moneyShare", global = "LOOT_MONEY_SPLIT", anchored = true },
    { key = "gold", global = "GOLD_AMOUNT", anchored = false },
    { key = "silver", global = "SILVER_AMOUNT", anchored = false },
    { key = "copper", global = "COPPER_AMOUNT", anchored = false },
}

-- Returns the patterns, or nil and the name of the first global that is missing.
local function buildLootPatterns()
    local patterns = {}
    for index = 1, #PATTERN_SOURCES do
        local source = PATTERN_SOURCES[index]
        local formatString = _G[source.global]
        if not isPlain(formatString, "string") then
            return nil, source.global
        end
        local entry = formatToPattern(formatString, source.anchored)
        if not entry then
            return nil, source.global
        end
        patterns[source.key] = entry
    end
    return patterns
end

local function extract(text, entry)
    local captures = { text:match(entry.pattern) }
    if #captures == 0 then
        return nil
    end
    local arguments = {}
    for index = 1, #entry.order do
        arguments[entry.order[index]] = captures[index]
    end
    return arguments
end

local function coinAmount(coins, patterns)
    local amount, matched = 0, false
    local denominations = {
        { entry = patterns.gold, value = 10000 },
        { entry = patterns.silver, value = 100 },
        { entry = patterns.copper, value = 1 },
    }
    for index = 1, #denominations do
        local denomination = denominations[index]
        local arguments = extract(coins, denomination.entry)
        local count = arguments and tonumber(arguments[1])
        if count then
            amount = amount + count * denomination.value
            matched = true
        end
    end
    return matched and amount or nil
end

-- Classifies one loot or money chat message. Only the player's own loot matches.
local function parseLootMessage(text, patterns)
    local arguments = extract(text, patterns.itemSelfMultiple)
    local quantity = arguments and tonumber(arguments[2])
    if not arguments then
        arguments = extract(text, patterns.itemSelf)
        quantity = 1
    end
    if arguments then
        local link = arguments[1]
        local itemId = link and tonumber(link:match("|Hitem:(%d+)"))
        if not itemId then
            return { kind = MESSAGE.UNPARSED }
        end
        return { kind = MESSAGE.ITEM, link = link, itemId = itemId, quantity = quantity or 1 }
    end

    arguments = extract(text, patterns.moneySelf) or extract(text, patterns.moneyShare)
    if arguments then
        local amount = coinAmount(arguments[1] or "", patterns)
        if not amount then
            return { kind = MESSAGE.UNPARSED }
        end
        return { kind = MESSAGE.MONEY, amount = amount }
    end
    return { kind = MESSAGE.NOT_OURS }
end

-- Decides whether a looted item earns a toast, from the client's item cache alone.
-- Nothing is requested: RequestLoadItemDataByID may deliver its result, inside the
-- call, to Blizzard's item listener (section 4.4).
local function judgeLootedItem(itemId, quantity, link, settings)
    local instant = (_G.C_Item and _G.C_Item.GetItemInfoInstant) or _G.GetItemInfoInstant
    local icon, classId
    if type(instant) == "function" then
        local ok, _, _, _, _, instantIcon, instantClass = pcall(instant, itemId)
        if ok then
            icon = (isPlain(instantIcon, "number") or isPlain(instantIcon, "string")) and instantIcon or nil
            classId = isPlain(instantClass, "number") and instantClass or nil
        end
    end
    local questClass = _G.Enum and _G.Enum.ItemClass and _G.Enum.ItemClass.Questitem
    local isQuestItem = questClass ~= nil and classId == questClass

    local quality
    local qualityApi = _G.C_Item and _G.C_Item.GetItemQualityByID
    if type(qualityApi) == "function" then
        local ok, value = pcall(qualityApi, itemId)
        if ok and isPlain(value, "number") then
            quality = value
        end
    end

    local name = link:match("|h%[(.-)%]|h") or link:match("%[(.-)%]") or ("item " .. itemId)
    local request = {
        kind = KIND.LOOTED_ITEM,
        itemId = itemId,
        name = name,
        icon = icon,
        quantity = quantity,
        quality = quality or 1,
        isQuestItem = isQuestItem,
    }

    if isQuestItem and settings.showQuestItems then
        return "Toast", request
    end
    if quality == nil then
        return "Unresolved"
    end
    if settings.showLootedItems and quality >= settings.minimumQuality then
        return "Toast", request
    end
    return "NotShown"
end

local function judgeLootedMoney(amount, settings)
    if settings.showLootedMoney and amount > 0 then
        return "Toast", { kind = KIND.LOOTED_MONEY, amount = amount }
    end
    return "NotShown"
end

-- Capture ---------------------------------------------------------------------------

local TOAST_MADE = { [OUTCOME.SHOWN] = true, [OUTCOME.QUEUED] = true, [OUTCOME.COALESCED] = true }

-- Returns whether the message made a toast: shown now, queued, or merged into one
-- on screen.
local function handleMessage(text)
    local message = parseLootMessage(text, state.patterns)
    local verdict, request
    if message.kind == MESSAGE.ITEM then
        verdict, request = judgeLootedItem(message.itemId, message.quantity,
            message.link, state.settings)
    elseif message.kind == MESSAGE.MONEY then
        verdict, request = judgeLootedMoney(message.amount, state.settings)
    elseif message.kind == MESSAGE.UNPARSED then
        bump(state.counts, "unparsed")
        ns.Log.Once("toasts:unparsed", format(
            "a loot message could not be read, so it made no toast: %s",
            ns.EscapeGuard.Neutralize(text)))
        return false
    else
        bump(state.counts, "notOurs")
        return false
    end

    if verdict == "Toast" then
        return TOAST_MADE[post(request)] == true
    elseif verdict == "Unresolved" then
        bump(state.counts, "unresolved")
    else
        bump(state.counts, "notShown")
    end
    return false
end

-- Phase 10 section 7.2: the evidence criterion 12 lacked. Whether a processed loot or
-- money message came on a restricted map, and whether it made a toast. Read here, a
-- frame after the event (rule 5), once per message; "could not tell" counts in
-- neither counter (rule 10).
local function noteRestrictedMapOutcome(shown)
    if ns.MapRestriction.Read() ~= ns.MapRestriction.RESTRICTED then
        return
    end
    bump(state.counts, "lootMessagesOnRestrictedMap")
    if shown then
        bump(state.counts, "shownOnRestrictedMap")
    end
end

local function processMessage(text)
    noteRestrictedMapOutcome(handleMessage(text))
end

local function flushInbox(generation)
    if generation ~= state.inboxGeneration then
        return
    end
    state.inboxScheduled = false
    local inbox = state.inbox
    state.inbox = {}
    if not state.enabled or not state.patterns then
        return
    end
    for index = 1, #inbox do
        local ok, err = ns.Isolation.Call(processMessage, inbox[index])
        if not ok then
            ns.Registry.Fault(FEATURE_ID, "raised reading a loot message", err)
            return
        end
    end
end

-- Section 6.5: the classification of these two events rests on how the client
-- produces them. The first deliveries of each session read the stack; a Lua frame
-- from outside this addon means the event arrived inside someone's call.
local function checkDeliveryStack()
    if (state.counts.stackChecked or 0) >= ns.STACK_CHECK_DELIVERIES then
        return
    end
    bump(state.counts, "stackChecked")
    local reader = _G.debugstack
    if type(reader) ~= "function" then
        return
    end
    local ok, text = pcall(reader, 1, 30, 10)
    if not ok or not isPlain(text, "string") then
        return
    end
    for line in text:gmatch("[^\n]+") do
        local addon = line:match("Interface[/\\]AddOns[/\\]([^/\\%]\"]+)")
        if addon and addon ~= ADDON_NAME then
            bump(state.counts, "deliveredInsideCall")
            ns.Log.OnceError("toasts:insidecall", format(
                "a loot message arrived inside another call (%s); Phase 8 section 4.4 has these events wrong, please report it",
                ns.EscapeGuard.Neutralize(line)))
            return
        end
    end
end

local function onLootMessage(text)
    if not state.enabled then
        return
    end
    checkDeliveryStack()
    if text == nil then
        return
    end
    if isSecret(text) then
        bump(state.counts, "secretTexts")
        ns.Log.Once("toasts:secret",
            "the client withheld the text of a loot message, so it made no toast")
        return
    end
    if type(text) ~= "string" then
        return
    end
    if #state.inbox >= ns.LOOT_INBOX_CAPACITY then
        bump(state.counts, "inboxDropped")
        ns.Log.Once("toasts:inboxfull", format(
            "more than %d loot messages arrived in one frame; the rest made no toast",
            ns.LOOT_INBOX_CAPACITY))
        return
    end
    state.inbox[#state.inbox + 1] = text
    if not state.inboxScheduled and C_Timer and C_Timer.After then
        state.inboxScheduled = true
        local generation = state.inboxGeneration
        C_Timer.After(0, function()
            flushInbox(generation)
        end)
    end
end

-- Lifecycle -----------------------------------------------------------------------

local function anchorContainer()
    if not state.container then
        return
    end
    state.container:ClearAllPoints()
    state.container:SetPoint("TOP", _G.UIParent, "TOP",
        state.settings.anchorOffsetX, state.settings.anchorOffsetY)
end

-- Every frame the toasts will ever use is made here, at enable (section 3).
local function ensureContainer()
    if state.container then
        return
    end
    local container = CreateFrame("Frame", "PersonalAddonToasts", _G.UIParent)
    container:SetWidth(TOAST_WIDTH)
    container:SetHeight(TOAST_HEIGHT)
    container:SetFrameStrata(CONTAINER_STRATA)
    container:EnableMouse(false)
    container:Hide()
    state.container = container

    state.pool = ns.FramePool.Create({
        poolName = "toasts",
        capacity = ns.TOAST_POOL_CAPACITY,
        dropPolicy = ns.DROP_POLICY.SURFACE_AND_FAIL,
        factory = createToast,
        reset = resetToast,
    })
    ns.FramePool.Prewarm(state.pool)
end

local function readSettings(config)
    local settings = config and config.settings
    if not settings then
        return
    end
    local current = state.settings
    for key in pairs(current) do
        if settings[key] ~= nil then
            current[key] = settings[key]
        end
    end
end

local LOOT_EVENTS = { "CHAT_MSG_LOOT", "CHAT_MSG_MONEY" }

local function enable(config)
    readSettings(config)
    state.counts = ns.Diagnostics.CountersFor(FEATURE_ID)
    ensureContainer()
    anchorContainer()
    state.container:Show()
    state.enabled = true
    registerPreview()

    local patterns, missing = buildLootPatterns()
    state.patterns = patterns
    state.patternFailure = missing
    if not patterns then
        ns.Log.Once("toasts:nopatterns", format(
            "this client has no usable %s, so loot toasts are off; other notices still show",
            tostring(missing)))
        return true
    end

    for index = 1, #LOOT_EVENTS do
        local token = ns.Dispatch.Subscribe(FEATURE_ID, LOOT_EVENTS[index], onLootMessage)
        if token then
            state.tokens[#state.tokens + 1] = token
        end
    end
    return true
end

-- Tolerates a partial enable (Phase 1 section 6.1).
local function disable()
    ns.Preview.Unregister(ns.PREVIEW_PANEL.TOASTS)
    state.enabled = false
    state.inboxGeneration = state.inboxGeneration + 1
    state.inboxScheduled = false
    state.inbox = {}
    state.queue = {}
    if state.pool then
        for index = #state.visible, 1, -1 do
            ns.FramePool.Release(state.pool, state.visible[index])
            state.visible[index] = nil
        end
    end
    state.visible = {}
    if state.container then
        state.container:Hide()
    end
    for index = #state.tokens, 1, -1 do
        ns.Dispatch.Unsubscribe(state.tokens[index])
        state.tokens[index] = nil
    end
end

local function onConfigChanged(config, changedKey)
    readSettings(config)
    if changedKey == "anchorOffsetX" or changedKey == "anchorOffsetY" then
        anchorContainer()
    elseif changedKey == "maximumVisible" then
        showNext()
    end
    return ns.CONFIG_RESULT.APPLIED
end

ns.Registry.Register(FEATURE_ID, {
    enabledByDefault = true,
    label = "Toasts",
    description = "Pop-up notices for money and notable items you loot, and for junk sold automatically.",
    settingsPage = ns.SETTINGS_PAGE.BAGS_AND_LOOT,
    settingsOrder = 20,
    settings = {
        showLootedItems = true,
        showQuestItems = true,
        showLootedMoney = true,
        durationSeconds = 4,
        anchorOffsetX = 0,
        anchorOffsetY = -180,
        minimumQuality = 2,
        maximumVisible = 3,
    },
    schema = {
        showLootedItems = {
            kind = ns.ConfigSchema.KIND.TOGGLE, label = "Looted items of green quality or better", order = 1,
        },
        showQuestItems = {
            kind = ns.ConfigSchema.KIND.TOGGLE, label = "Looted quest items, whatever their quality", order = 2,
        },
        showLootedMoney = {
            kind = ns.ConfigSchema.KIND.TOGGLE, label = "Looted money", order = 3,
        },
        durationSeconds = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Seconds on screen", order = 4,
            unit = ns.ConfigSchema.UNIT.SECONDS,
            minimum = 2, maximum = 10, step = 0.5,
        },
        anchorOffsetX = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Horizontal position", order = 5,
            unit = ns.ConfigSchema.UNIT.PIXELS,
            minimum = -800, maximum = 800, step = 1,
        },
        anchorOffsetY = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Vertical position, from the top", order = 6,
            unit = ns.ConfigSchema.UNIT.PIXELS,
            minimum = -800, maximum = 0, step = 1,
        },
        minimumQuality = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Lowest item quality shown (2 is green)",
            minimum = 1, maximum = 5, step = 1, curated = false,
        },
        maximumVisible = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Toasts on screen at once",
            minimum = 1, maximum = ns.TOAST_POOL_CAPACITY, step = 1, curated = false,
        },
    },
}, {
    enable = enable,
    disable = disable,
    onConfigChanged = onConfigChanged,
})

-- The service other features use, and /pa toasts ---------------------------------

ns.Toasts = {
    KIND = KIND,
    OUTCOME = OUTCOME,
    Post = post,

    -- One of each kind, for placing the toasts and checking the art.
    PostSamples = function()
        local outcomes = {}
        outcomes[#outcomes + 1] = post({
            kind = KIND.LOOTED_ITEM, itemId = 0, name = "A green item",
            icon = "Interface\\Icons\\INV_Misc_QuestionMark", quantity = 1, quality = 2,
            isQuestItem = false,
        })
        outcomes[#outcomes + 1] = post({ kind = KIND.LOOTED_MONEY, amount = 12345 })
        outcomes[#outcomes + 1] = post({
            kind = KIND.JUNK_SOLD, itemsSold = 3, revenue = 250, itemsUnsold = 0, confirmed = true,
        })
        return outcomes
    end,

    Inspect = function()
        local counts = {}
        for index = 1, #COUNT_NAMES do
            counts[COUNT_NAMES[index]] = 0
        end
        for key, value in pairs(state.counts) do
            counts[key] = value
        end
        local constructed, live, free, capacity = 0, 0, 0, 0
        if state.pool then
            constructed, live, free, capacity = ns.FramePool.Stats(state.pool)
        end
        return {
            -- First: the defence against reading sample toasts as real loot
            -- (section 5.1).
            preview = ns.Preview.IsEnabled(),
            previewSamples = visibleSampleCount(),
            enabled = state.enabled,
            visible = #state.visible,
            queued = #state.queue,
            maximumVisible = state.settings.maximumVisible,
            lootCapture = state.patterns ~= nil,
            patternFailure = state.patternFailure,
            counts = counts,
            poolConstructed = constructed,
            poolLive = live,
            poolFree = free,
            poolCapacity = capacity,
        }
    end,

    -- Exposed for the offline harness: the parser is the part most likely to meet a
    -- string this client formats differently.
    ParseLootMessage = function(text)
        if not state.patterns then
            return nil
        end
        return parseLootMessage(text, state.patterns)
    end,
}
