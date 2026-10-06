-- Phase 11 additions to the offline stand-ins (Architecture/20261005-Phase11.md
-- section 10.1). Loaded after stubs.lua, stubs8.lua and stubs9.lua for every
-- session; everything here derives from the existing unit model.
--
-- Unit fields read here: threatPercent[unitId] (your scaled threat; nil when that
-- unit is not on the mob's threat list), percentSecret, name, level,
-- classification, dead, healthAbsent, percentText.

-- Nameplate frames carry their unit token in unitToken, as
-- NamePlateBaseMixin:SetUnit writes it, and are listed in the order they were added.
HARNESS.plateOrder = {}
local addPlate = HARNESS.addPlate
function HARNESS.addPlate(token, unit, blizzardColour)
    local bar = addPlate(token, unit, blizzardColour)
    HARNESS.plates[token].unitToken = token
    HARNESS.plateOrder[#HARNESS.plateOrder + 1] = token
    return bar
end

function HARNESS.removePlate(token)
    HARNESS.fire("NAME_PLATE_UNIT_REMOVED", token)
    HARNESS.plates[token] = nil
    HARNESS.units[token] = nil
end

C_NamePlate.GetNamePlates = function()
    local list = {}
    for _, token in ipairs(HARNESS.plateOrder) do
        local frame = HARNESS.plates[token]
        if frame then
            list[#list + 1] = frame
        end
    end
    return list
end

local plateForUnit = C_NamePlate.GetNamePlateForUnit
C_NamePlate.GetNamePlateForUnit = function(token)
    if token == "target" then
        return HARNESS.selectedTarget and HARNESS.plates[HARNESS.selectedTarget] or nil
    end
    return plateForUnit(token)
end

-- Counted, so a test can show the panel never asks it.
HARNESS.unitIsUnitCalls = 0
local unitIsUnit = UnitIsUnit
function UnitIsUnit(...)
    HARNESS.unitIsUnitCalls = HARNESS.unitIsUnitCalls + 1
    return unitIsUnit(...)
end

-- Your scaled threat: nothing when the unit is not on the mob's list; the hidden
-- sentinel when the mob is flagged percentSecret; percentText stands in for a value
-- of the wrong type.
function UnitDetailedThreatSituation(unit, mobToken)
    local mob = HARNESS.units[mobToken]
    local resolved = HARNESS.resolve(unit)
    if not mob or not resolved then
        return
    end
    if mob.percentText then
        return false, 0, mob.percentText, mob.percentText, 0
    end
    local percent = mob.threatPercent and mob.threatPercent[resolved.id]
    if percent == nil then
        return
    end
    if mob.percentSecret then
        return HARNESS.SECRET, HARNESS.SECRET, HARNESS.SECRET, HARNESS.SECRET, HARNESS.SECRET
    end
    local tanking = (mob.targetId == resolved.id)
    return tanking, tanking and 3 or 0, percent, percent, percent * 100
end

-- A mob's health is always hidden, as the client returns it; healthAbsent makes it
-- nothing at all.
function UnitHealth(token)
    local unit = HARNESS.resolve(token)
    if not unit or unit.healthAbsent then
        return nil
    end
    return HARNESS.SECRET
end
function UnitHealthMax(token)
    local unit = HARNESS.resolve(token)
    if not unit or unit.healthAbsent then
        return nil
    end
    return HARNESS.SECRET
end

HARNESS.hiddenNames = false
function UnitName(token)
    local unit = HARNESS.resolve(token)
    if not unit or unit.name == nil then
        return nil
    end
    if HARNESS.hiddenNames then
        return HARNESS.SECRET
    end
    return unit.name
end
function UnitLevel(token)
    local unit = HARNESS.resolve(token)
    return unit and unit.level or 60
end
function UnitClassification(token)
    local unit = HARNESS.resolve(token)
    return unit and unit.classification or "normal"
end
function UnitIsDead(token)
    local unit = HARNESS.resolve(token)
    return unit and unit.dead == true or false
end

-- CVars, installed by a test before login: not every session has had a C_CVar.
HARNESS.cvarWrites = 0
function HARNESS.installCVars(values)
    HARNESS.cvars = values
    C_CVar = {
        GetCVar = function(name) return HARNESS.cvars[name] end,
        SetCVar = function(name, value)
            HARNESS.cvarWrites = HARNESS.cvarWrites + 1
            HARNESS.cvars[name] = value
            return true
        end,
    }
end

-- Status bars and font strings that keep what they were handed, hidden values
-- included. The sentinel raises on arithmetic, ordering and concatenation, so code
-- that touched a hidden value on its way to a widget fails here.
HARNESS.framesCreatedInCombat = 0
local createFrame = CreateFrame
function CreateFrame(frameType, name, parent, template)
    if HARNESS.playerInCombat then
        HARNESS.framesCreatedInCombat = HARNESS.framesCreatedInCombat + 1
    end
    local frame = createFrame(frameType, name, parent, template)
    if frameType == "StatusBar" then
        frame.minValue, frame.maxValue, frame.value = 0, 1, 0
        rawset(frame, "SetMinMaxValues", function(self, low, high)
            self.minValue, self.maxValue = low, high
        end)
        rawset(frame, "SetValue", function(self, value) self.value = value end)
        rawset(frame, "SetStatusBarColor", function(self, red, green, blue)
            self.r, self.g, self.b = red, green, blue
        end)
    end
    local createFontString = frame.CreateFontString
    rawset(frame, "CreateFontString", function(self, ...)
        local region = createFontString(self, ...)
        rawset(region, "SetFormattedText", function(fontString, pattern, value)
            if value == HARNESS.SECRET then
                fontString.text = HARNESS.SECRET
                return
            end
            fontString.text = string.format(pattern, value)
        end)
        return region
    end)
    return frame
end
