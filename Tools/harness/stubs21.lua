-- Offline stand-ins for Phase 21 (Architecture/20261112-Phase21.md section 16.1).
-- Loaded after every earlier stub file, for every session. Everything here WRAPS;
-- nothing replaces. Phase 19's lesson: an earlier session asserts on the old stub,
-- and replacing it silently retires that check. Every default is "nothing to show":
-- no auras, no enchants, no ammo, so the thirty older sessions draw no Upkeep cell
-- and post no alert they did not post before.
--
-- Knobs, by subject:
--
--   HARNESS.playerAuras            the player's helpful auras, a list of AuraData tables
--   HARNESS.aurasSecret            "list": the whole list is hidden; "expiration": the
--                                  first entry's expirationTime is; "icon": the first
--                                  entry's icon is; "raise": the call raises
--
--   HARNESS.weaponEnchants[slot]   WeaponEnchantInfo tables for Enum.WeaponSlot slot
--   HARNESS.enchantsSecret         "list", "timeLeft", "charges" (first entry), "raise"
--   HARNESS.enchantRaiseSlot       only that slot's call raises (audit finding 3)
--   HARNESS.equippedIdSecret[slot]   GetInventoryItemID answers a hidden value
--   HARNESS.equippedIconSecret[slot] GetInventoryItemTexture answers a hidden value
--
--   HARNESS.usesAmmo, usesAmmoSecret   UnitUsesAmmo("player")
--   HARNESS.itemCounts[itemId]     C_Item.GetItemCount; itemCountSecret hides every count
--   HARNESS.itemIcons[itemId]      C_Item.GetItemIconByID, else stubs8's item icon
--
--   HARNESS.missingAtlases[atlas]  C_Texture.GetAtlasInfo answers nothing for it
--   HARNESS.atlasRaise             SetAtlas raises
--   HARNESS.sounds                 every C_Sound.PlaySound kit id; soundRaise raises
--
-- Call counts, so a check can show a path read nothing: auraCalls, enchantCalls,
-- itemCountCalls, usesAmmoCalls.

HARNESS.playerAuras = {}
HARNESS.aurasSecret = nil
HARNESS.auraCalls = 0
HARNESS.weaponEnchants = {}
HARNESS.enchantsSecret = nil
HARNESS.enchantRaiseSlot = nil
HARNESS.enchantCalls = 0
HARNESS.equippedIdSecret = {}
HARNESS.equippedIconSecret = {}
HARNESS.usesAmmo = false
HARNESS.usesAmmoSecret = false
HARNESS.usesAmmoCalls = 0
HARNESS.itemCounts = {}
HARNESS.itemCountSecret = false
HARNESS.itemCountCalls = 0
HARNESS.itemIcons = {}
HARNESS.missingAtlases = {}
HARNESS.atlasRaise = false
HARNESS.sounds = {}
HARNESS.soundRaise = false

local function shallowCopy(source)
    local copy = {}
    for key, value in pairs(source) do
        copy[key] = value
    end
    return copy
end

-- Enums, with the documented values (ItemConstantsDocumentation.lua:382-393, 819-829).
Enum.WeaponSlot = Enum.WeaponSlot or { MainHand = 0, OffHand = 1, Ranged = 2 }
Enum.ItemEnchantType = Enum.ItemEnchantType or { None = 0, Permanent = 1, Temporary = 2, Imbue = 3 }

-- Auras ------------------------------------------------------------------------------------
C_UnitAuras = C_UnitAuras or {}
C_UnitAuras.GetUnitAuras = function(unit, filter, maxCount)
    HARNESS.auraCalls = HARNESS.auraCalls + 1
    if HARNESS.aurasSecret == "raise" then
        error("GetUnitAuras raised")
    end
    if HARNESS.aurasSecret == "list" then
        return HARNESS.SECRET
    end
    local list = {}
    if unit ~= "player" or filter ~= "HELPFUL" then
        return list
    end
    for index, aura in ipairs(HARNESS.playerAuras) do
        if maxCount and index > maxCount then
            break
        end
        local copy = shallowCopy(aura)
        if index == 1 and HARNESS.aurasSecret == "expiration" then
            copy.expirationTime = HARNESS.SECRET
        elseif index == 1 and HARNESS.aurasSecret == "icon" then
            copy.icon = HARNESS.SECRET
        end
        list[index] = copy
    end
    return list
end

-- Weapons, enchants and items ----------------------------------------------------------------
C_Item.GetWeaponEnchantInfo = function(slot)
    HARNESS.enchantCalls = HARNESS.enchantCalls + 1
    if HARNESS.enchantsSecret == "raise" or HARNESS.enchantRaiseSlot == slot then
        error("GetWeaponEnchantInfo raised")
    end
    if HARNESS.enchantsSecret == "list" then
        return HARNESS.SECRET
    end
    local list = {}
    for index, enchant in ipairs(HARNESS.weaponEnchants[slot] or {}) do
        local copy = shallowCopy(enchant)
        if index == 1 and HARNESS.enchantsSecret == "timeLeft" then
            copy.timeLeft = HARNESS.SECRET
        elseif index == 1 and HARNESS.enchantsSecret == "charges" then
            copy.charges = HARNESS.SECRET
        end
        list[index] = copy
    end
    return list
end

C_Item.GetItemCount = function(itemId)
    HARNESS.itemCountCalls = HARNESS.itemCountCalls + 1
    if HARNESS.itemCountSecret then
        return HARNESS.SECRET
    end
    return HARNESS.itemCounts[itemId] or 0
end

C_Item.GetItemIconByID = function(itemId)
    if HARNESS.itemIcons[itemId] ~= nil then
        return HARNESS.itemIcons[itemId]
    end
    local item = HARNESS.items[itemId]
    return item and item.icon or nil
end

local priorItemId = GetInventoryItemID
function GetInventoryItemID(unit, slot)
    if HARNESS.equippedIdSecret[slot] then
        return HARNESS.SECRET
    end
    return priorItemId(unit, slot)
end

local priorItemTexture = GetInventoryItemTexture
function GetInventoryItemTexture(unit, slot)
    if HARNESS.equippedIconSecret[slot] then
        return HARNESS.SECRET
    end
    return priorItemTexture(unit, slot)
end

function UnitUsesAmmo(unit)
    HARNESS.usesAmmoCalls = HARNESS.usesAmmoCalls + 1
    if HARNESS.usesAmmoSecret then
        return HARNESS.SECRET
    end
    return unit == "player" and HARNESS.usesAmmo == true
end

-- Atlases, textures and sound ------------------------------------------------------------------

C_Texture = C_Texture or {}
if C_Texture.GetAtlasInfo == nil then
    C_Texture.GetAtlasInfo = function(atlas)
        if HARNESS.missingAtlases[atlas] then
            return nil
        end
        return { file = atlas, width = 32, height = 32 }
    end
end

-- stubs19 records SetAtlas; this marks the coordinates as the atlas's, as the client's
-- SetAtlas sets them, and records SetDesaturated, which stubs8's metatable would
-- otherwise answer with a silent no-op (the Phase 12, 18, 19 and 20 note).
local priorCreateFrame = CreateFrame
function CreateFrame(...)
    local frame = priorCreateFrame(...)
    local priorCreateTexture = frame.CreateTexture
    rawset(frame, "CreateTexture", function(self, ...)
        local region = priorCreateTexture(self, ...)
        local priorSetAtlas = region.SetAtlas
        rawset(region, "SetAtlas", function(texture, atlas, ...)
            if HARNESS.atlasRaise then
                error("SetAtlas raised")
            end
            priorSetAtlas(texture, atlas, ...)
            texture.texCoord = { "atlas", atlas }
        end)
        rawset(region, "SetDesaturated", function(texture, value)
            texture.desaturated = value and true or false
        end)
        rawset(region, "IsDesaturated", function(texture)
            return texture.desaturated == true
        end)
        return region
    end)
    return frame
end

C_Sound = C_Sound or {}
C_Sound.PlaySound = function(soundKitId)
    if HARNESS.soundRaise then
        error("PlaySound raised")
    end
    HARNESS.sounds[#HARNESS.sounds + 1] = soundKitId
    return true, #HARNESS.sounds
end
SOUNDKIT = SOUNDKIT or {}
if SOUNDKIT.RAID_WARNING == nil then
    SOUNDKIT.RAID_WARNING = 8959
end

-- Rare plates ------------------------------------------------------------------------------------

-- A complete plate (Phase 20's addPlate20), then the fields a rare check reads. The
-- event fires inside addPlate20, and the rare alert only queues the token there, so
-- fields set before the next frame are what the flush reads.
function HARNESS.addRarePlate(token, fields)
    fields = fields or {}
    HARNESS.addPlate20(token, {
        npcId = fields.npcId, guid = fields.guid, canAttack = fields.canAttack ~= false,
    })
    local unit = HARNESS.units[token]
    unit.name = fields.name or "Sample Rare"
    unit.level = fields.level or 34
    unit.classification = fields.classification or "rare"
    unit.dead = fields.dead == true
    unit.tapDenied = fields.tapDenied == true
    return unit
end
