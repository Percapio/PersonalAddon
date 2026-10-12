-- Offline stand-ins for QuestieDB, the tooltip data processor and the quest log
-- (Architecture/20261011-Phase17.md section 10.1).
--
-- The QuestieDB stand-in reproduces the one behaviour the bridge exists to manage:
-- a table getter hands back a FRESH DEEP COPY every call (src/read/shared.lua).
-- HARNESS.questieReads counts them, so a check can prove the bridge caches rather
-- than taking it on trust.

HARNESS.questieReads = 0
HARNESS.questiePresent = true
HARNESS.questieContractOk = true
HARNESS.questieContract = 3
HARNESS.questieFlavor = "Forever"
HARNESS.questieRaises = false
HARNESS.npcStarts = {}
HARNESS.quests = {}
HARNESS.questObjectives = {}
HARNESS.questExtras = {}
HARNESS.itemDrops = {}
HARNESS.completedQuests = {}
HARNESS.questLog = {}
HARNESS.questLogReadable = true
HARNESS.questLogShownLimit = nil
HARNESS.playerRaceId = 1
HARNESS.playerClassFile = "WARLOCK"
HARNESS.raceReadable = true
HARNESS.classReadable = true

local function freshCopy(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for key, inner in pairs(value) do
        out[key] = freshCopy(inner)
    end
    return out
end

-- QuestieDB ------------------------------------------------------------------------------

local function buildQuestie()
    if not HARNESS.questiePresent then
        LibQuestieDB, QuestDB, NpcDB, ItemDB = nil, nil, nil, nil
        return
    end

    LibQuestieDB = {
        contractVersion = HARNESS.questieContract,
        minSupportedContract = 1,
        readMode = "baked",
        flavor = { name = HARNESS.questieFlavor, expansion = "Forever" },
        RequireContract = function(required)
            if HARNESS.questieRaises then
                error("RequireContract raised")
            end
            if HARNESS.questieContractOk then
                return true
            end
            return false, ("QuestieDB contract mismatch: this consumer needs version %s, the installed QuestieDB provides %s")
                :format(tostring(required), tostring(HARNESS.questieContract))
        end,
        Enum = {
            -- Keyed by Blizzard's race ID, as QuestieDB's is. 95/96 carry bits 32/33,
            -- which is what makes bit.band the wrong tool.
            raceMaskById = {
                [1] = 1, [2] = 2, [3] = 4, [4] = 8, [5] = 16, [6] = 32,
                [7] = 64, [8] = 128, [9] = 256,
                [95] = 4294967296, [96] = 8589934592,
            },
            byExpansion = {
                Forever = {
                    classKeys = {
                        NONE = 0, WARRIOR = 1, PALADIN = 2, HUNTER = 4, ROGUE = 8,
                        PRIEST = 16, SHAMAN = 64, MAGE = 128, WARLOCK = 256,
                        DRUID = 1024, ALL_CLASSES = 1503,
                    },
                },
            },
            factionRaceMasks = { Alliance = 1 + 4 + 8 + 64, Horde = 2 + 16 + 32 + 128 },
        },
    }

    local function getter(store, field)
        return function(id)
            HARNESS.questieReads = HARNESS.questieReads + 1
            if HARNESS.questieRaises then
                error("QuestieDB getter raised")
            end
            local entry = store[id]
            if entry == nil then
                return nil
            end
            -- A fresh deep copy per call, as the real one does.
            return freshCopy(field and entry[field] or entry)
        end
    end

    QuestDB = {
        name = getter(HARNESS.quests, "name"),
        questLevel = getter(HARNESS.quests, "questLevel"),
        requiredLevel = getter(HARNESS.quests, "requiredLevel"),
        requiredMaxLevel = getter(HARNESS.quests, "requiredMaxLevel"),
        requiredRaces = getter(HARNESS.quests, "requiredRaces"),
        requiredClasses = getter(HARNESS.quests, "requiredClasses"),
        preQuestSingle = getter(HARNESS.quests, "preQuestSingle"),
        preQuestGroup = getter(HARNESS.quests, "preQuestGroup"),
        exclusiveTo = getter(HARNESS.quests, "exclusiveTo"),
        objectives = getter(HARNESS.questObjectives, nil),
        extraObjectives = getter(HARNESS.questExtras, nil),
        IdsByName = function() error("IdsByName must never be called") end,
        BuildNameIndex = function() error("BuildNameIndex must never be called") end,
    }
    -- ItemDB.npcDrops is the link from a quest's item objective to the creatures
    -- that drop it -- the half section 4.2 first left out.
    ItemDB = {
        npcDrops = getter(HARNESS.itemDrops, nil),
        name = function(id) return "Item " .. tostring(id) end,
        IdsByName = function() error("IdsByName must never be called") end,
        BuildNameIndex = function() error("BuildNameIndex must never be called") end,
    }
    NpcDB = {
        name = getter(HARNESS.npcNames or {}, "name"),
        questStarts = getter(HARNESS.npcStarts, nil),
        IdsByName = function() error("IdsByName must never be called") end,
        BuildNameIndex = function() error("BuildNameIndex must never be called") end,
    }
end

HARNESS.buildQuestie = buildQuestie
HARNESS.npcNames = {}
buildQuestie()

function HARNESS.addQuest(questId, fields)
    local entry = {
        name = "Quest " .. questId, questLevel = 10, requiredLevel = 0,
        requiredMaxLevel = 0, requiredRaces = 0, requiredClasses = 0,
        preQuestSingle = {}, preQuestGroup = {}, exclusiveTo = {},
    }
    for key, value in pairs(fields or {}) do
        entry[key] = value
    end
    HARNESS.quests[questId] = entry
    return questId
end

function HARNESS.startQuestsAt(npcId, ...)
    HARNESS.npcStarts[npcId] = { ... }
    HARNESS.npcNames[npcId] = { name = "NPC " .. npcId }
    return npcId
end

-- The NPCs that drop one quest item.
function HARNESS.setItemDrops(itemId, ...)
    HARNESS.itemDrops[itemId] = { ... }
end

-- extraObjectives: {spawns, zone, text, icon, reference[]}, references being
-- {"monster", npcId} and friends.
function HARNESS.setExtraObjectives(questId, monsters)
    local references = {}
    for index = 1, #monsters do
        references[index] = { "monster", monsters[index] }
    end
    HARNESS.questExtras[questId] = { { nil, 0, "special", 0, references } }
end

-- objectives[1] creature kills, objectives[5] kill credit.
function HARNESS.setObjectives(questId, creatures, killCredit, others)
    local tuple = {}
    if creatures then
        local rows = {}
        for index = 1, #creatures do
            rows[index] = { creatures[index], "slay", 10 }
        end
        tuple[1] = rows
    end
    if killCredit then
        tuple[5] = killCredit
    end
    for slot, value in pairs(others or {}) do
        tuple[slot] = value
    end
    HARNESS.questObjectives[questId] = tuple
end

-- The quest log ----------------------------------------------------------------------------

C_QuestLog = C_QuestLog or {}

function C_QuestLog.GetNumQuestLogEntries()
    if not HARNESS.questLogReadable then
        return HARNESS.SECRET, HARNESS.SECRET
    end
    local quests = 0
    for _, entry in ipairs(HARNESS.questLog) do
        if entry ~= false then
            quests = quests + 1
        end
    end
    local shown = HARNESS.questLogShownLimit or #HARNESS.questLog
    return shown, quests
end

function C_QuestLog.GetQuestIDForLogIndex(index)
    local entry = HARNESS.questLog[index]
    if entry == nil or entry == false then
        return nil
    end
    return entry
end

function C_QuestLog.IsQuestFlaggedCompleted(questId)
    return HARNESS.completedQuests[questId] == true
end

function C_QuestLog.GetLogIndexForQuestID(questId)
    for index, entry in ipairs(HARNESS.questLog) do
        if entry == questId then
            return index
        end
    end
    return nil
end

-- A log of quest ids; `false` stands for a header entry.
function HARNESS.setQuestLog(...)
    HARNESS.questLog = { ... }
    HARNESS.questLogShownLimit = nil
end

-- Difficulty colours -----------------------------------------------------------------------
--
-- Raw { r, g, b, font } tables with no GetRGB, which is the whole point of audit
-- finding 4: a check can prove the feature never calls a colour-mixin method on one.

-- The gossip frame's own label for the same list, so the header is locale-correct.
AVAILABLE_QUEST = "Available Quests"

QuestDifficultyColors = {
    impossible = { r = 1.00, g = 0.10, b = 0.10, font = "QuestDifficulty_Impossible" },
    verydifficult = { r = 1.00, g = 0.50, b = 0.25, font = "QuestDifficulty_VeryDifficult" },
    difficult = { r = 1.00, g = 0.82, b = 0.00, font = "QuestDifficulty_Difficult" },
    standard = { r = 0.25, g = 0.75, b = 0.25, font = "QuestDifficulty_Standard" },
    trivial = { r = 0.50, g = 0.50, b = 0.50, font = "QuestDifficulty_Trivial" },
}

HARNESS.difficultyCalls = 0
function GetQuestDifficultyColor(level)
    HARNESS.difficultyCalls = HARNESS.difficultyCalls + 1
    local diff = level - (HARNESS.playerLevel or 40)
    if diff >= 5 then return QuestDifficultyColors.impossible end
    if diff >= 3 then return QuestDifficultyColors.verydifficult end
    if diff >= -4 then return QuestDifficultyColors.difficult end
    return QuestDifficultyColors.standard
end

-- Units ------------------------------------------------------------------------------------

function UnitRace(token)
    if token ~= "player" or not HARNESS.raceReadable then
        return HARNESS.SECRET, HARNESS.SECRET, HARNESS.SECRET
    end
    return "Human", "Human", HARNESS.playerRaceId
end

function UnitClass(token)
    if token ~= "player" or not HARNESS.classReadable then
        return HARNESS.SECRET, HARNESS.SECRET
    end
    return "Warlock", HARNESS.playerClassFile
end

-- The tooltip ------------------------------------------------------------------------------
--
-- Records what the feature drew, and routes a SetUnit through the post-call chain the
-- way TooltipDataHandler does.

Enum = Enum or {}
Enum.TooltipDataType = { Item = 0, Spell = 1, Unit = 2, Corpse = 3 }

HARNESS.tooltipPostCalls = {}
HARNESS.tooltipRegistrations = 0

TooltipDataProcessor = {
    AllTypes = "ALL",
    AddTooltipPostCall = function(dataType, fn)
        HARNESS.tooltipRegistrations = HARNESS.tooltipRegistrations + 1
        HARNESS.tooltipPostCalls[#HARNESS.tooltipPostCalls + 1] = { dataType = dataType, fn = fn }
    end,
}

GameTooltip = {
    lines = {},
    unit = nil,
    GetUnit = function(self)
        if self.unit == nil then
            return nil, nil
        end
        return "Unit name", self.unit
    end,
    AddLine = function(self, text, r, g, b)
        self.lines[#self.lines + 1] = { text = tostring(text), r = r, g = g, b = b }
    end,
    AddDoubleLine = function() end,
    Show = function() end,
    NumLines = function(self) return #self.lines end,
}

function GameTooltip_AddBlankLineToTooltip(tooltip)
    tooltip.lines[#tooltip.lines + 1] = { text = "", blank = true }
end

-- Drives a unit tooltip: clears the lines, sets the unit, and runs every Unit
-- post-call as ProcessTooltipPostCalls would.
function HARNESS.hoverUnit(token)
    GameTooltip.lines = {}
    GameTooltip.unit = token
    for _, entry in ipairs(HARNESS.tooltipPostCalls) do
        if entry.dataType == Enum.TooltipDataType.Unit then
            entry.fn(GameTooltip, { type = Enum.TooltipDataType.Unit })
        end
    end
    return GameTooltip.lines
end

function HARNESS.tooltipText()
    local parts = {}
    for _, line in ipairs(GameTooltip.lines) do
        parts[#parts + 1] = line.blank and "<blank>" or line.text
    end
    return table.concat(parts, " | ")
end

-- GUIDs ------------------------------------------------------------------------------------
--
-- HARNESS.guids[token] = "Creature-0-1-2-3-<npcId>-000001", or HARNESS.SECRET for a
-- unit whose identity the client will not share.

HARNESS.guids = {}

function HARNESS.creatureGuid(npcId, spawn)
    return ("Creature-0-1-2-3-%d-%06X"):format(npcId, spawn or 1)
end

local priorUnitGUID = UnitGUID
function UnitGUID(token)
    local value = HARNESS.guids[token]
    if value ~= nil then
        return value
    end
    return priorUnitGUID and priorUnitGUID(token) or nil
end
