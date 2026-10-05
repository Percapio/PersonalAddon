-- The fixture's stand-in for PersonalAddon's code (Phase 10 section 10.1): it uses one
-- documented function, two documented events, a hook target, an XML-defined frame and a
-- callback-registry event, so each kind of surface name appears.

local ADDON_NAME, ns = ...

local function onLoot(text)
    return text
end

local function readThreat(unit, mob)
    return ns.ClientRead.Call(UnitThreatSituation, "number", unit, mob)
end

local LOOT_EVENTS = { "CHAT_MSG_LOOT", "CHAT_MSG_MONEY" }

hooksecurefunc("CompactUnitFrame_UpdateAll", function() end)
hooksecurefunc("CompactUnitFrame_UpdateHealthColor", function() end)

local bags = _G.ContainerFrameCombinedBags
EventRegistry:RegisterCallback("ContainerFrame.OpenBag", onLoot)

ns.Fixture = { readThreat = readThreat, events = LOOT_EVENTS, bags = bags }
