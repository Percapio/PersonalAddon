-- Patch 03 additions to the offline stand-ins (Architecture/20261122-Patch03.md section
-- 14.1). Loaded in every session, after stubs22.lua. It wraps, never replaces (Phase
-- 19's lesson): every older session reads what it read before.
--
--   UnitFactionGroup(token)            "player" answers HARNESS.playerFaction. A unit
--                                      answers its faction field; one without it answers
--                                      the other faction, so every Phase 22 player reads as
--                                      the other faction and tests22 keeps its meaning.
--                                      HARNESS.playerFactionSecret, or a unit's faction set
--                                      to HARNESS.SECRET, answers the secret
--   UnitHasEffectivelyTankAura(unit)   answers HARNESS.effectivelyTank. effectivelyTankSecret
--                                      answers the secret, effectivelyTankSilent nothing;
--                                      removeTankTest and restoreTankTest take it away
--   PlayerUtil.IsPlayerEffectivelyTank counted, answering HARNESS.compositeTank. Auto must
--                                      never ask it (A13)
--   Button:Click()                     runs OnClick, as the engine's dispatch does;
--                                      RegisterForClicks is recorded
--   ShowUIPanel / HideUIPanel          counted: the role box must call neither (B12)
--   UnitAffectingCombat("player")      counted; HARNESS.combatSecret answers the secret
--   HARNESS.setStoredRole(value)       threatRole written straight into the store (K10, A11)

-- Factions ------------------------------------------------------------------------------------

HARNESS.playerFaction = "Alliance"
HARNESS.playerFactionSecret = false
HARNESS.factionCalls = {}

local function otherFaction(faction)
    if faction == "Horde" then
        return "Alliance"
    end
    return "Horde"
end

if UnitFactionGroup == nil then
    function UnitFactionGroup(token)
        HARNESS.factionCalls[token] = (HARNESS.factionCalls[token] or 0) + 1
        if token == "player" then
            if HARNESS.playerFactionSecret then
                return HARNESS.SECRET
            end
            return HARNESS.playerFaction, HARNESS.playerFaction
        end
        local unit = HARNESS.resolve(token)
        if unit and unit.faction ~= nil then
            return unit.faction, unit.faction
        end
        local other = otherFaction(HARNESS.playerFaction)
        return other, other
    end
end

function HARNESS.factionCallCount(token)
    return HARNESS.factionCalls[token] or 0
end

-- The game's tank test, and Blizzard's composite -----------------------------------------------

HARNESS.effectivelyTank = false
HARNESS.effectivelyTankSecret = false
HARNESS.effectivelyTankSilent = false
HARNESS.tankTestCalls = 0

local function tankTest(_unit)
    HARNESS.tankTestCalls = HARNESS.tankTestCalls + 1
    if HARNESS.effectivelyTankSecret then
        return HARNESS.SECRET
    end
    if HARNESS.effectivelyTankSilent then
        return nil
    end
    return HARNESS.effectivelyTank == true
end

if UnitHasEffectivelyTankAura == nil then
    UnitHasEffectivelyTankAura = tankTest
end

function HARNESS.removeTankTest()
    UnitHasEffectivelyTankAura = nil
end

function HARNESS.restoreTankTest()
    UnitHasEffectivelyTankAura = tankTest
end

PlayerUtil = PlayerUtil or {}
HARNESS.compositeTank = false
HARNESS.compositeCalls = 0
if PlayerUtil.IsPlayerEffectivelyTank == nil then
    function PlayerUtil.IsPlayerEffectivelyTank()
        HARNESS.compositeCalls = HARNESS.compositeCalls + 1
        return HARNESS.compositeTank == true
    end
end

-- Buttons: a click is the engine's dispatch to OnClick ------------------------------------------

HARNESS.clicks = 0
local priorCreateFrame = CreateFrame
function CreateFrame(frameType, name, parent, template)
    local frame = priorCreateFrame(frameType, name, parent, template)
    if frameType == "Button" then
        rawset(frame, "RegisterForClicks", function(self, ...)
            rawset(self, "clicksRegistered", { ... })
        end)
        rawset(frame, "Click", function(self, mouseButton)
            HARNESS.clicks = HARNESS.clicks + 1
            local onClick = self.scripts and self.scripts.OnClick
            if onClick then
                onClick(self, mouseButton or "LeftButton", false)
            end
        end)
    end
    return frame
end

function HARNESS.click(button)
    button:Click("LeftButton")
end

-- Panel management: counted, and never expected ------------------------------------------------

HARNESS.uiPanelCalls = 0
local priorShowUIPanel, priorHideUIPanel = ShowUIPanel, HideUIPanel
function ShowUIPanel(...)
    HARNESS.uiPanelCalls = HARNESS.uiPanelCalls + 1
    if priorShowUIPanel then
        return priorShowUIPanel(...)
    end
end
function HideUIPanel(...)
    HARNESS.uiPanelCalls = HARNESS.uiPanelCalls + 1
    if priorHideUIPanel then
        return priorHideUIPanel(...)
    end
end

-- Combat ----------------------------------------------------------------------------------------

HARNESS.combatSecret = false
HARNESS.combatCalls = 0
local priorAffectingCombat = UnitAffectingCombat
function UnitAffectingCombat(token)
    if token == "player" then
        HARNESS.combatCalls = HARNESS.combatCalls + 1
        if HARNESS.combatSecret then
            return HARNESS.SECRET
        end
    end
    return priorAffectingCombat(token)
end

-- The stored choice, written raw ----------------------------------------------------------------

function HARNESS.setStoredRole(value)
    local feature = HARNESS_NS.ConfigStore.Feature("nameplates")
    feature.settings.threatRole = value
end
