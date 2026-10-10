-- Phase 8 additions to the offline stand-ins: frames with regions, EventRegistry,
-- the combined bag, skills, items, loot strings, merchant and container APIs.
-- Loaded after stubs.lua for every session.

HARNESS.badTextures = {}
HARNESS.createdFrames = {}

-- Regions ------------------------------------------------------------------------
local regionMethods = {}
function regionMethods:SetTexture(texture)
    self.texture = texture
    if texture ~= nil and HARNESS.badTextures[texture] then
        return false
    end
    return true
end
function regionMethods:GetTexture() return self.texture end
function regionMethods:SetColorTexture(...) self.colorTexture = { ... } end
function regionMethods:SetTexCoord(...) self.texCoord = { ... } end
function regionMethods:SetAllPoints(target) self.allPoints = target end
function regionMethods:SetPoint(...) self.points[#self.points + 1] = { ... } end
function regionMethods:ClearAllPoints() self.points = {} end
function regionMethods:SetWidth(value) self.width = value end
function regionMethods:SetHeight(value) self.height = value end
function regionMethods:SetAlpha(value) self.alpha = value end
function regionMethods:GetAlpha() return self.alpha end
function regionMethods:Show() self.shown = true end
function regionMethods:Hide() self.shown = false end
function regionMethods:IsShown() return self.shown end
function regionMethods:SetText(text) self.text = text end
function regionMethods:GetText() return self.text end
function regionMethods:SetTextColor(r, g, b) self.textColor = { r, g, b } end
function regionMethods:GetTextColor() return self.textColor[1], self.textColor[2], self.textColor[3] end
function regionMethods:SetVertexColor(r, g, b) self.vertexColor = { r, g, b } end
function regionMethods:GetVertexColor() return self.vertexColor[1], self.vertexColor[2], self.vertexColor[3] end

local function newRegion(kind, owner)
    local region = {
        kind = kind, owner = owner, shown = true, alpha = 1, points = {},
        text = "", textColor = { 1, 1, 1 }, vertexColor = { 1, 1, 1 },
    }
    return setmetatable(region, {
        __index = function(_, key)
            if regionMethods[key] then
                return regionMethods[key]
            end
            -- Widget methods are PascalCase and tolerated as no-ops; any other key is a
            -- field, and a missing field is nil, as on a real frame.
            if type(key) == "string" and key:match("^%u") then
                return function() end
            end
            return nil
        end,
    })
end

-- Frames: a superset of stubs.lua's, keeping its event and script handling -------
local frameMethods = {}
function frameMethods:RegisterEvent(eventName) self.events[eventName] = true return true end
function frameMethods:UnregisterEvent(eventName) self.events[eventName] = nil end
function frameMethods:RegisterAllEvents() self.allEvents = true end
function frameMethods:UnregisterAllEvents() self.events = {} self.allEvents = false end
function frameMethods:SetScript(name, fn) self.scripts[name] = fn end
function frameMethods:GetScript(name) return self.scripts[name] end
function frameMethods:IsShown() return self.shown end
function frameMethods:Show() self.shown = true end
function frameMethods:Hide() self.shown = false end
function frameMethods:SetWidth(value) self.width = value end
function frameMethods:SetHeight(value) self.height = value end
function frameMethods:GetWidth() return self.width or 0 end
function frameMethods:GetHeight() return self.height or 0 end
function frameMethods:SetPoint(...) self.points[#self.points + 1] = { ... } end
function frameMethods:ClearAllPoints() self.points = {} end
function frameMethods:GetPoint(index)
    local point = self.points[index or 1]
    if point then
        return point[1], point[2], point[3], point[4], point[5]
    end
end
function frameMethods:SetAllPoints(target) self.allPoints = target end
function frameMethods:SetAlpha(value) self.alpha = value end
function frameMethods:GetAlpha() return self.alpha end
function frameMethods:SetFrameStrata(value) self.strata = value end
function frameMethods:GetFrameStrata() return self.strata end
function frameMethods:EnableMouse(value) self.mouse = value and true or false end
function frameMethods:IsMouseEnabled() return self.mouse end
function frameMethods:SetClampedToScreen(value) self.clamped = value end
function frameMethods:GetName() return self.name end
function frameMethods:GetDebugName() return self.name or "<anonymous frame>" end
function frameMethods:GetParent() return self.parent end
function frameMethods:SetBackdrop(backdrop) self.backdrop = backdrop end
function frameMethods:CreateTexture()
    local region = newRegion("Texture", self)
    self.regions[#self.regions + 1] = region
    return region
end
function frameMethods:CreateFontString()
    local region = newRegion("FontString", self)
    self.regions[#self.regions + 1] = region
    return region
end

function CreateFrame(frameType, name, parent, template)
    local frame = {
        frameType = frameType, name = name, parent = parent, template = template,
        scripts = {}, events = {}, allEvents = false, shown = false, alpha = 1,
        points = {}, regions = {}, mouse = false,
        -- A new frame inherits its parent's strata, as the client's does, so a
        -- caller that records one at creation reads a string rather than nil
        -- (Phase 13 section 3.3).
        strata = (parent and parent.strata) or "MEDIUM",
    }
    setmetatable(frame, {
        __index = function(_, key)
            if frameMethods[key] then
                return frameMethods[key]
            end
            if type(key) == "string" and key:match("^%u") then
                return function() end
            end
            return nil
        end,
    })
    HARNESS.frames[#HARNESS.frames + 1] = frame
    HARNESS.createdFrames[#HARNESS.createdFrames + 1] = frame
    if name then
        _G[name] = frame
    end
    return frame
end

-- True when a frame's parent chain reaches the given frame (the Patch 01 section 0.2
-- hazard: a frame created under a panel SmartNavigation tracks).
function HARNESS.descendsFrom(frame, ancestor)
    local current = rawget(frame, "parent")
    while type(current) == "table" do
        if current == ancestor then
            return true
        end
        current = rawget(current, "parent")
    end
    return false
end

UIParent = CreateFrame("Frame", "UIParent")
UIParent.shown = true
PlayerFrame = CreateFrame("Frame", "PlayerFrame", UIParent)
PlayerFrame.shown = true

-- EventRegistry, as CallbackRegistryMixin behaves for these purposes ---------------
EventRegistry = { callbacks = {} }
function EventRegistry:RegisterCallback(event, func, owner)
    if type(event) ~= "string" then error("RegisterCallback 'event' requires string type.") end
    if type(func) ~= "function" then error("RegisterCallback 'func' requires function type.") end
    if type(owner) == "number" then error("RegisterCallback 'owner' as number is reserved internally.") end
    if owner == nil then owner = {} end
    self.callbacks[event] = self.callbacks[event] or {}
    self.callbacks[event][owner] = func
    return owner
end
function EventRegistry:UnregisterCallback(event, owner)
    if owner == nil then error("UnregisterCallback 'owner' is required.") end
    local list = self.callbacks[event]
    if list and list[owner] then
        list[owner] = nil
    end
end
function EventRegistry:TriggerEvent(event, ...)
    local list = self.callbacks[event]
    if not list then
        return
    end
    local pairsList = {}
    for owner, func in pairs(list) do
        pairsList[#pairsList + 1] = { owner, func }
    end
    for _, pair in ipairs(pairsList) do
        pair[2](pair[1], ...)
    end
end
function HARNESS.callbackCount(event)
    local count = 0
    for _ in pairs(EventRegistry.callbacks[event] or {}) do
        count = count + 1
    end
    return count
end

-- The combined bag: its OnShow and OnHide fire the callbacks inside Blizzard's call.
local BAG_SHOW_FRAME = '[string "@Interface/AddOns/Blizzard_UIPanels_Game/Mainline/ContainerFrame.lua"]:810: in function <ContainerFrame_OnShow>'
local BAG_HIDE_FRAME = '[string "@Interface/AddOns/Blizzard_UIPanels_Game/Mainline/ContainerFrame.lua"]:782: in function <ContainerFrame_OnHide>'
local function makeContainer(name)
    local frame = CreateFrame("Frame", name, UIParent)
    function frame:Show()
        if self.shown then return end
        self.shown = true
        table.insert(HARNESS.callContext, BAG_SHOW_FRAME)
        HARNESS.handlerRanInsideBagShow = false
        EventRegistry:TriggerEvent("ContainerFrame.OpenBag", self)
        table.remove(HARNESS.callContext)
    end
    function frame:Hide()
        if not self.shown then return end
        self.shown = false
        table.insert(HARNESS.callContext, BAG_HIDE_FRAME)
        EventRegistry:TriggerEvent("ContainerFrame.CloseBag", self)
        table.remove(HARNESS.callContext)
    end
    return frame
end
ContainerFrameCombinedBags = makeContainer("ContainerFrameCombinedBags")
ContainerFrame1 = makeContainer("ContainerFrame1")

-- Enums and slots ------------------------------------------------------------------
Enum.ItemClass = { Weapon = 2, Armor = 4, Questitem = 12 }
Enum.ItemWeaponSubclass = {
    Axe1H = 0, Axe2H = 1, Bows = 2, Guns = 3, Mace1H = 4, Mace2H = 5, Polearm = 6,
    Sword1H = 7, Sword2H = 8, Warglaive = 9, Staff = 10, Bearclaw = 11, Catclaw = 12,
    Unarmed = 13, Generic = 14, Dagger = 15, Thrown = 16, Obsolete3 = 17, Crossbow = 18,
    Wand = 19, Fishingpole = 20,
}
Enum.PlayerInteractionType = { Merchant = 5 }
Enum.DamageMeterSessionType = { Current = 0, Overall = 1 }
Enum.DamageMeterType = { DamageDone = 0 }
INVSLOT_MAINHAND, INVSLOT_OFFHAND, INVSLOT_RANGED = 16, 17, 18
Constants = { InventoryConstants = { NumBagSlots = 4 } }

-- Skills ---------------------------------------------------------------------------
HARNESS.professionSlots = { 1, 2, nil, 4, nil }
HARNESS.professions = {
    [1] = { name = "Mining", icon = 136248, rank = 38, max = 75 },
    [2] = { name = "Blacksmithing", icon = 136241, rank = 60, max = 75 },
    [4] = { name = "Fishing", icon = 136245, rank = 12, max = 75 },
}
function GetProfessions()
    local slots = HARNESS.professionSlots
    return slots[1], slots[2], slots[3], slots[4], slots[5]
end
function GetProfessionInfo(index)
    local profession = HARNESS.professions[index]
    if not profession then
        return nil
    end
    return profession.name, profession.icon, profession.rank, profession.max
end

HARNESS.skillLines = {
    [55] = { name = "Two-Handed Swords", rank = 38, max = 40 },
    [45] = { name = "Bows", rank = 30, max = 40 },
    [173] = { name = "Daggers", rank = 1, max = 40 },
    [162] = { name = "Unarmed", rank = 10, max = 40 },
    [95] = { name = "Defense", rank = 40, max = 40 },
}
C_SkillInfo = {
    GetSkillLineInfoByID = function(id)
        local line = HARNESS.skillLines[id]
        if not line then
            return nil
        end
        if HARNESS.secretSkills then
            return { skillID = id, name = line.name, rank = HARNESS.SECRET, maxRank = HARNESS.SECRET }
        end
        return { skillID = id, name = line.name, rank = line.rank, maxRank = line.max, modifier = 0 }
    end,
}

-- Items ----------------------------------------------------------------------------
HARNESS.items = {
    [1001] = { classID = 2, subClassID = 8, icon = 135327, quality = 3 },   -- two-handed sword
    [1002] = { classID = 2, subClassID = 2, icon = 135490, quality = 2 },   -- bow
    [1003] = { classID = 4, subClassID = 6, icon = 134955, quality = 2 },   -- shield
    [1004] = { classID = 2, subClassID = 15, icon = 135641, quality = 2 },  -- dagger
    [1005] = { classID = 2, subClassID = 20, icon = 132932, quality = 1 },  -- fishing pole
    [1006] = { classID = 2, subClassID = 13, icon = 132938, quality = 2 },  -- fist weapon
    [1007] = { classID = 2, subClassID = 9, icon = 132939, quality = 2 },   -- warglaive
    [2001] = { classID = 4, subClassID = 2, icon = 132539, quality = 2 },   -- green boots
    [2002] = { classID = 7, subClassID = 5, icon = 132889, quality = 1 },   -- white cloth
    [2003] = { classID = 12, subClassID = 0, icon = 134400, quality = 1 },  -- quest item
    [2004] = { classID = 4, subClassID = 2, icon = 132540 },                -- not cached
}
HARNESS.equipped = { [16] = 1001, [18] = 1002 }
function GetInventoryItemID(_, slot) return HARNESS.equipped[slot] end
function GetInventoryItemTexture(_, slot)
    local itemId = HARNESS.equipped[slot]
    return itemId and HARNESS.items[itemId] and HARNESS.items[itemId].icon or nil
end
C_Item = {
    GetItemInfoInstant = function(itemId)
        local item = HARNESS.items[itemId]
        if not item then
            return nil
        end
        return itemId, "Type", "SubType", "", item.icon, item.classID, item.subClassID
    end,
    GetItemQualityByID = function(itemId)
        local item = HARNESS.items[itemId]
        return item and item.quality or nil
    end,
    GetItemQualityColor = function(quality)
        local colours = { [1] = { 1, 1, 1 }, [2] = { 0.12, 1, 0 }, [3] = { 0, 0.44, 0.87 } }
        local colour = colours[quality] or { 1, 1, 1 }
        return colour[1], colour[2], colour[3], "ffffffff"
    end,
}
C_PaperDollInfo = {
    GetInventorySlotInfoForInvSlot = function(slot) return slot, 136518, false, "MainHandSlot" end,
}

-- Loot strings and coins -------------------------------------------------------------
LOOT_ITEM_SELF = "You receive loot: %s."
LOOT_ITEM_SELF_MULTIPLE = "You receive loot: %sx%d."
LOOT_ITEM_PUSHED_SELF = "You receive item: %s."
YOU_LOOT_MONEY = "You loot %s"
LOOT_MONEY_SPLIT = "Your share of the loot is %s."
GOLD_AMOUNT = "%d Gold"
SILVER_AMOUNT = "%d Silver"
COPPER_AMOUNT = "%d Copper"
C_CurrencyInfo = {
    GetCoinTextureString = function(amount) return "coins:" .. tostring(amount) end,
}

-- Damage meter, so the breakdown panel enables and builds its chrome ---------------
C_DamageMeter = {
    IsDamageMeterAvailable = function() return true end,
    GetCombatSessionSourceFromType = function()
        return {
            totalAmount = 1000,
            combatSpells = {
                { spellID = 1, totalAmount = 600, amountPerSecond = 60 },
                { spellID = 2, totalAmount = 400, amountPerSecond = 40 },
            },
        }
    end,
    GetSessionDurationSeconds = function() return 10 end,
}
C_Spell = { GetSpellTexture = function(spellId) return 1000 + spellId end }
function UnitGUID() return "Player-1-00000001" end

-- Bags and the merchant -------------------------------------------------------------
HARNESS.bagEventMode = "deferred"
HARNESS.sortInline = { { "ITEM_LOCK_CHANGED", 0, 1 }, { "ITEM_LOCKED", 0, 1 } }
HARNESS.sellInline = {}
HARNESS.bags = {
    [0] = { size = 16, locked = {} },
    [1] = { size = 10, locked = {} },
    [2] = { size = 0, locked = {} },
    [3] = { size = 0, locked = {} },
    [4] = { size = 0, locked = {} },
}
HARNESS.merchantOpen = false
HARNESS.junk = 2
HARNESS.money = 10000
HARNESS.sellAllEnabled = true
HARNESS.cursorItem = false

local function raise(eventName, ...)
    if HARNESS.bagEventMode == "sync" then
        HARNESS.fire(eventName, ...)
    else
        local event = { n = select("#", ...) + 1, eventName, ... }
        HARNESS.pendingEvents[#HARNESS.pendingEvents + 1] = event
    end
end

C_Container = {
    -- As the spike measured on this client (Phase 8 section 8.4): the first locks
    -- arrive inside the call; the bag updates come later with the server's replies.
    SortBags = function()
        table.insert(HARNESS.callContext, "[C]: in function 'SortBags'")
        HARNESS.sortCalls = (HARNESS.sortCalls or 0) + 1
        for _, event in ipairs(HARNESS.sortInline) do
            HARNESS.fire(unpack(event))
        end
        HARNESS.pendingEvents[#HARNESS.pendingEvents + 1] = { n = 2, "BAG_UPDATE", 0 }
        HARNESS.pendingEvents[#HARNESS.pendingEvents + 1] = { n = 1, "BAG_UPDATE_DELAYED" }
        table.remove(HARNESS.callContext)
    end,
    GetContainerNumSlots = function(bag)
        local entry = HARNESS.bags[bag]
        return entry and entry.size or 0
    end,
    GetContainerItemInfo = function(bag, slot)
        local entry = HARNESS.bags[bag]
        if not entry then
            return nil
        end
        return { isLocked = entry.locked[slot] == true, stackCount = 1 }
    end,
}
C_MerchantFrame = {
    IsSellAllJunkEnabled = function() return HARNESS.sellAllEnabled end,
    GetNumJunkItems = function() return HARNESS.junk end,
    -- The spike saw nothing delivered inside the sale; tests can add events.
    SellAllJunkItems = function()
        table.insert(HARNESS.callContext, "[C]: in function 'SellAllJunkItems'")
        HARNESS.sellCalls = (HARNESS.sellCalls or 0) + 1
        for _, event in ipairs(HARNESS.sellInline) do
            HARNESS.fire(unpack(event))
        end
        table.remove(HARNESS.callContext)
    end,
}
-- The server completing a sale: items leave, money arrives, then the unique event.
function HARNESS.completeSale()
    HARNESS.money = HARNESS.money + 250 * HARNESS.junk
    HARNESS.junk = 0
    HARNESS.fire("BAG_UPDATE", 0)
    HARNESS.fire("BAG_UPDATE_DELAYED")
end
C_PlayerInteractionManager = {
    IsInteractingWithNpcOfType = function(kind)
        return HARNESS.merchantOpen and kind == Enum.PlayerInteractionType.Merchant
    end,
}
function GetMoney() return HARNESS.money end
function CursorHasItem() return HARNESS.cursorItem end
function GetFramesRegisteredForEvent(eventName)
    local list = {}
    for _, frame in ipairs(HARNESS.frames) do
        if frame.events[eventName] or frame.allEvents then
            list[#list + 1] = frame
        end
    end
    return unpack(list)
end

-- A Blizzard-like listener, registered for BAG_UPDATE the way the merchant frame is.
HARNESS.blizzardMerchant = CreateFrame("Frame", "MerchantFrame", UIParent)
HARNESS.blizzardMerchant:RegisterEvent("BAG_UPDATE")
