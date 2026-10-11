-- Offline stand-ins for the macro, item and cooldown APIs consumable macros touch
-- (Architecture/20261011-Phase16.md section 12.1).
--
-- The macro list is a flat array, as the client's is: indices up to
-- MAX_ACCOUNT_MACROS are account macros and the rest are this character's. That
-- layout is what lets a check exercise audit finding 9 -- an account macro of the
-- configured name is never adopted.

HARNESS.macros = {}
HARNESS.macroWrites = {}
HARNESS.macrosReadable = true
HARNESS.macroInline = {}
HARNESS.consumables = {}
HARNESS.cooldowns = {}
HARNESS.tooltips = {}
HARNESS.playerLevel = 40
HARNESS.levelReadable = true
HARNESS.manaUser = true
HARNESS.manaReadable = true

Constants = Constants or {}
Constants.MacroConsts = { MAX_ACCOUNT_MACROS = 120, MAX_CHARACTER_MACROS = 30 }

Enum = Enum or {}
Enum.ItemClass = Enum.ItemClass or {}
Enum.ItemClass.Consumable = 0
Enum.ItemConsumableSubclass = {
    Generic = 0, Potion = 1, Elixir = 2, Flasksphials = 3, Scroll = 4,
    Fooddrink = 5, Itemenhancement = 6, Bandage = 7, Other = 8,
}

ITEM_CONJURED = "Conjured Item"

-- The words the classifier tells food from water by (D14). Blizzard labels its own
-- character pane with both (Camelot/PaperDollFrame.lua:617, :665).
HEALTH = "Health"
MANA = "Mana"

-- Reference spells. The classifier compares an item's use-spell name against
-- these, so every name here is the client's, not a string in the addon.
local SPELL_NAMES = {
    [433] = "Food",
    [430] = "Drink",
    [439] = "Healing Potion",
    [19705] = "Well Fed",
}
C_Spell = C_Spell or {}
local priorGetSpellTexture = C_Spell.GetSpellTexture
C_Spell.GetSpellTexture = priorGetSpellTexture
function C_Spell.GetSpellName(spellId)
    if HARNESS.referenceNamesAbsent then
        return nil
    end
    return SPELL_NAMES[spellId]
end

-- Items ------------------------------------------------------------------------------
--
-- HARNESS.consumables[itemId] = {
--   classID, subClassID, requiredLevel, itemLevel, spell, loaded, conjured, wellFed
-- }
-- `loaded = false` stands for an item whose data has not arrived: GetItemInfo
-- answers nothing, and the classifier must not cache that (audit finding 13).

function HARNESS.addConsumable(itemId, fields)
    local entry = {
        classID = 0,
        subClassID = 0,
        requiredLevel = 1,
        itemLevel = 1,
        loaded = true,
    }
    for key, value in pairs(fields or {}) do
        entry[key] = value
    end
    HARNESS.consumables[itemId] = entry
    return itemId
end

C_Item = C_Item or {}
local priorInstant = C_Item.GetItemInfoInstant
C_Item.GetItemInfoInstant = function(itemId)
    local entry = HARNESS.consumables[itemId]
    if entry then
        return itemId, "Consumable", "Sub", "", 1, entry.classID, entry.subClassID
    end
    if priorInstant then
        return priorInstant(itemId)
    end
    return nil
end

function C_Item.GetItemInfo(itemId)
    local entry = HARNESS.consumables[itemId]
    HARNESS.itemInfoCalls = (HARNESS.itemInfoCalls or 0) + 1
    if not entry or entry.loaded == false then
        return nil
    end
    return "Item " .. itemId, "link", 1, entry.itemLevel, entry.requiredLevel
end

function C_Item.GetItemSpell(itemId)
    local entry = HARNESS.consumables[itemId]
    if not entry then
        return nil
    end
    HARNESS.itemSpellCalls = (HARNESS.itemSpellCalls or 0) + 1
    HARNESS.spellCallsFor = HARNESS.spellCallsFor or {}
    HARNESS.spellCallsFor[itemId] = (HARNESS.spellCallsFor[itemId] or 0) + 1
    if entry.spell == nil then
        return nil
    end
    return entry.spell, 1
end

-- Tooltip lines, which is where Conjured and Well Fed are read from.
C_TooltipInfo = C_TooltipInfo or {}
function C_TooltipInfo.GetItemByID(itemId)
    local entry = HARNESS.consumables[itemId]
    if not entry or HARNESS.tooltipsUnreadable then
        return nil
    end
    local lines = { { leftText = "Item " .. itemId } }
    if entry.restores == "health" then
        lines[#lines + 1] = { leftText = "Use: Restores 58 health over 18 sec." }
    elseif entry.restores == "mana" then
        lines[#lines + 1] = { leftText = "Use: Restores 302 mana over 21 sec." }
    end
    if entry.conjured then
        lines[#lines + 1] = { leftText = ITEM_CONJURED }
    end
    if entry.wellFed then
        lines[#lines + 1] = { leftText = "Well Fed (20 min)" }
    end
    return { lines = lines }
end

C_Container = C_Container or {}
function C_Container.GetContainerItemID(bag, slot)
    local entry = HARNESS.bags[bag]
    return entry and entry.items and entry.items[slot] or nil
end

-- startTime, duration, enable. 0, 0 is "ready".
function C_Container.GetItemCooldown(itemId)
    local remaining = HARNESS.cooldowns[itemId]
    if not remaining or remaining <= 0 then
        return 0, 0, 1
    end
    return HARNESS.now, remaining, 1
end

-- Puts a list of item IDs in the backpack, one per slot.
function HARNESS.carry(...)
    local items = { ... }
    HARNESS.bags[0] = { size = math.max(#items, 1), locked = {}, items = items }
    for bag = 1, 4 do
        HARNESS.bags[bag] = { size = 0, locked = {}, items = {} }
    end
end

-- Units ------------------------------------------------------------------------------

local priorUnitLevel = UnitLevel
function UnitLevel(token)
    if token == "player" then
        if not HARNESS.levelReadable then
            return HARNESS.SECRET
        end
        return HARNESS.playerLevel
    end
    return priorUnitLevel and priorUnitLevel(token) or 1
end

function UnitPowerType()
    if not HARNESS.manaReadable then
        return HARNESS.SECRET
    end
    return HARNESS.manaUser and 0 or 1
end

-- The macro API ------------------------------------------------------------------------
--
-- Undocumented globals on the real client, which is why spike S exists: no flag
-- certifies what they deliver inside the call.

local function fireMacroInline()
    for _, event in ipairs(HARNESS.macroInline) do
        HARNESS.fire(unpack(event))
    end
end

function GetNumMacros()
    if not HARNESS.macrosReadable then
        return HARNESS.SECRET, HARNESS.SECRET
    end
    local account, character = 0, 0
    for index, macro in pairs(HARNESS.macros) do
        if macro then
            if index <= Constants.MacroConsts.MAX_ACCOUNT_MACROS then
                account = account + 1
            else
                character = character + 1
            end
        end
    end
    return account, character
end

function GetMacroIndexByName(name)
    if type(name) ~= "string" then
        return 0
    end
    local folded = name:lower()
    local best
    for index, macro in pairs(HARNESS.macros) do
        if macro and macro.name:lower() == folded then
            if not best or index < best then
                best = index
            end
        end
    end
    return best or 0
end

function GetMacroInfo(index)
    local macro = HARNESS.macros[index]
    if not macro then
        return nil
    end
    return macro.name, macro.icon, macro.body
end

-- The first free character slot, as the client's own allocation does.
local function freeCharacterIndex()
    local first = Constants.MacroConsts.MAX_ACCOUNT_MACROS + 1
    for index = first, first + Constants.MacroConsts.MAX_CHARACTER_MACROS - 1 do
        if not HARNESS.macros[index] then
            return index
        end
    end
    return nil
end

function CreateMacro(name, icon, body, isCharacter)
    table.insert(HARNESS.callContext, "[C]: in function 'CreateMacro'")
    HARNESS.macroWrites[#HARNESS.macroWrites + 1] =
        { call = "CreateMacro", name = name, body = body, character = isCharacter }
    local index = freeCharacterIndex()
    if index then
        HARNESS.macros[index] = { name = name, icon = icon, body = body }
    end
    fireMacroInline()
    table.remove(HARNESS.callContext)
    return index
end

-- EditMacro(index, name, icon, body): a nil name or body leaves that field alone,
-- which is how the Macros window saves a body (Blizzard_MacroUI.lua:364).
function EditMacro(index, name, icon, body)
    table.insert(HARNESS.callContext, "[C]: in function 'EditMacro'")
    HARNESS.macroWrites[#HARNESS.macroWrites + 1] =
        { call = "EditMacro", index = index, name = name, body = body }
    local macro = HARNESS.macros[index]
    if macro then
        if name ~= nil then macro.name = name end
        if icon ~= nil then macro.icon = icon end
        if body ~= nil then macro.body = body end
    end
    fireMacroInline()
    table.remove(HARNESS.callContext)
    return index
end

-- The Macros window ---------------------------------------------------------------------
--
-- A named global in a LoadOnDemand addon (Blizzard_MacroUI.xml:25), so on a real
-- client it is nil until the player first opens it. Present here so the gate can be
-- exercised; a check sets MacroFrame = nil for the not-loaded case.

HARNESS.macroWindowShown = false
HARNESS.macroWindowReadable = true

MacroFrame = {
    IsShown = function()
        if not HARNESS.macroWindowReadable then
            return HARNESS.SECRET
        end
        return HARNESS.macroWindowShown
    end,
}

function DeleteMacro(index)
    table.insert(HARNESS.callContext, "[C]: in function 'DeleteMacro'")
    HARNESS.macroWrites[#HARNESS.macroWrites + 1] = { call = 'DeleteMacro', index = index }
    HARNESS.macros[index] = nil
    fireMacroInline()
    table.remove(HARNESS.callContext)
end

-- The Gamepad action bar's activeBar, and who the client blames for it (D16).
-- This is the harm the write guard asks about after every macro write.

HARNESS.activeBarTaintedBy = nil   -- nil = secure
HARNESS.pageUnitPresent = true
HARNESS.secureVariableReadable = true

GamepadMainActionBarFramePageUnit = { activeBar = nil }

function issecurevariable(container, key)
    if not HARNESS.secureVariableReadable then
        error("issecurevariable refused")
    end
    if container == GamepadMainActionBarFramePageUnit and key == "activeBar" then
        if HARNESS.activeBarTaintedBy == nil then
            return true
        end
        return false, HARNESS.activeBarTaintedBy
    end
    return true
end

-- Action slots, for the question "is this macro on a bar?" (section 2.9).
-- HARNESS.actionSlots[slot] = macroIndex puts a macro on a slot.

HARNESS.actionSlots = {}

function GetActionInfo(slot)
    local macroIndex = HARNESS.actionSlots[slot]
    if macroIndex == nil then
        return nil
    end
    return "macro", macroIndex
end

-- Puts the macro of this name on an action slot, as the action bar editor would.
function HARNESS.placeOnBar(name, slot)
    local index = GetMacroIndexByName(name)
    HARNESS.actionSlots[slot or 1] = index ~= 0 and index or nil
    return index
end

function HARNESS.clearBars()
    HARNESS.actionSlots = {}
end

-- Helpers the checks use ---------------------------------------------------------------

function HARNESS.putAccountMacro(name, body)
    HARNESS.macros[1] = { name = name, icon = 1, body = body or "#showtooltip" }
    return 1
end

function HARNESS.putCharacterMacro(name, body)
    local index = freeCharacterIndex()
    HARNESS.macros[index] = { name = name, icon = 1, body = body or "#showtooltip" }
    return index
end

function HARNESS.macroNamed(name)
    local index = GetMacroIndexByName(name)
    return index ~= 0 and HARNESS.macros[index] or nil
end

function HARNESS.countMacrosNamed(name)
    local folded = name:lower()
    local count = 0
    for _, macro in pairs(HARNESS.macros) do
        if macro and macro.name:lower() == folded then
            count = count + 1
        end
    end
    return count
end

function HARNESS.writesSince(mark)
    local list = {}
    for index = mark + 1, #HARNESS.macroWrites do
        list[#list + 1] = HARNESS.macroWrites[index]
    end
    return list
end
