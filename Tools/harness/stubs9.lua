-- Phase 9 additions to the offline stand-ins (Architecture/20261002-Phase09.md
-- section 9.1). Loaded after stubs.lua and stubs8.lua for every session.

-- Secret predicates. HARNESS.SECRET is the one secret value; HARNESS.SECRET_TABLE
-- is a table whose contents this code may not read.
HARNESS.SECRET_TABLE = setmetatable({}, { __tostring = function() return "<secret table>" end })
function canaccessvalue(value) return value ~= HARNESS.SECRET end
function canaccesstable(value) return value ~= HARNESS.SECRET_TABLE end
function issecrettable(value) return value == HARNESS.SECRET_TABLE end

-- Group roster. "Party" by default: the Phase 7 unit model has a party1.
HARNESS.group = "Party"
HARNESS.groupSize = 2
function IsInRaid() return HARNESS.group == "Raid" end
function IsInGroup() return HARNESS.group ~= "Solo" end
function GetNumGroupMembers() return HARNESS.groupSize end

-- Threat, derived from the unit model so the Phase 7 acceptance rows read the same:
-- the unit a mob targets is tanking (3); a mob whose target is hidden, or that is
-- flagged threatSecret, answers with a secret, as a dungeon might; otherwise the
-- mob's explicit threat table, or nil (not on the threat list).
HARNESS.threatCalls = 0
function UnitThreatSituation(unit, mobToken)
    HARNESS.threatCalls = HARNESS.threatCalls + 1
    local mob = HARNESS.units[mobToken]
    if not mob then
        return nil
    end
    if mob.threatSecret or mob.hiddenTarget then
        return HARNESS.SECRET
    end
    local resolved = HARNESS.resolve(unit)
    if not resolved then
        return nil
    end
    if mob.secretFor and mob.secretFor[resolved.id] then
        return HARNESS.SECRET
    end
    if mob.targetId and mob.targetId == resolved.id then
        return 3
    end
    if mob.threat then
        return mob.threat[resolved.id]
    end
    return nil
end

-- Addon restrictions: a dungeon is a restricted map.
HARNESS.restrictedMap = false
HARNESS.restrictionCalls = 0
Enum.AddOnRestrictionType = { Combat = 0, Encounter = 1, ChallengeMode = 2, PvPMatch = 3, Map = 4, Chat = 5 }
C_RestrictedActions = {
    IsAddOnRestrictionActive = function(restrictionType)
        HARNESS.restrictionCalls = HARNESS.restrictionCalls + 1
        if restrictionType == Enum.AddOnRestrictionType.Map then
            return HARNESS.restrictedMap == true
        end
        return false
    end,
}
