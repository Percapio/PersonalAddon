-- Core/UnitIdentity.lua
-- The NPC id behind a unit, from its GUID (Architecture/20261021-Phase20.md section 9).
--
-- One copy of a parse that existed twice -- the NPC tooltip's and the quest marker's --
-- and that the nameplate's role label would have made three. Each caller keeps its own
-- counters and maps the reading onto its own outcomes; this file counts nothing and
-- keeps nothing.
--
-- UnitGUID carries SecretWhenUnitIdentityRestricted, so the GUID is classified
-- through ClientRead before any string operation touches it: a match on a withheld
-- value raises in our code (README rule 10), and the secret-read lint exists for this
-- line.

local ADDON_NAME, ns = ...

local UnitIdentity = {}
ns.UnitIdentity = UnitIdentity

local ClientRead = ns.ClientRead
local tonumber = tonumber

local READING = {
    RESOLVED = "Resolved",
    NOT_AN_NPC = "NotAnNpc",
    WITHHELD = "Withheld",
    ABSENT = "Absent",
}
UnitIdentity.READING = READING

-- Creature-0-<server>-<instance>-<zone>-<npcId>-<spawn>. The first field says what
-- the unit is: a player's GUID carries no NPC id, and a pet's belongs to its owner.
--
-- Returns the reading, then: the NPC id for Resolved; for NotAnNpc, whether the unit
-- is a player. Withheld covers a hidden GUID and a call that failed or is missing;
-- Absent covers a unit with no GUID and an id field that does not parse.
function UnitIdentity.NpcIdFor(unitToken)
    local kind, guid = ClientRead.Call(_G.UnitGUID, "string", unitToken)
    if kind == ClientRead.ABSENT then
        return READING.ABSENT
    end
    if kind ~= ClientRead.PLAIN then
        return READING.WITHHELD
    end
    local guidType = guid:match("^(%a+)")
    if guidType ~= "Creature" and guidType ~= "Vehicle" then
        return READING.NOT_AN_NPC, guidType == "Player"
    end
    local npcId = tonumber(guid:match("-(%d+)-%x+$"))
    if npcId == nil then
        return READING.ABSENT
    end
    return READING.RESOLVED, npcId
end
