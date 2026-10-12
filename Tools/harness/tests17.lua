-- Phase 17 offline checks (Architecture/20261011-Phase17.md section 10.1).
-- One session, "phase17". Q-numbers follow the design's own table.

local ns = HARNESS_NS
local format = string.format
local passed, failures = 0, {}
HARNESS.expectedFaults = {}

local function check(name, condition, detail)
    if condition then
        passed = passed + 1
    else
        failures[#failures + 1] = name .. (detail ~= nil and (" -- " .. tostring(detail)) or "")
    end
end

local function slash(text)
    SlashCmdList.PERSONALADDON_DEBUG(text)
end

local Bridge = ns.QuestieDBBridge
local STATE = Bridge.STATE

local function reset()
    Bridge.Reset()
    HARNESS.questieReads = 0
end

local function setSetting(feature, key, value)
    ns.ConfigStore.Set(feature, key, value)
    ns.Registry.NotifyConfigChanged(feature, key)
    HARNESS.frame()
end

-- The data ---------------------------------------------------------------------------------

HARNESS.playerLevel = 40
local DUGHAN = 1
local CRITTER = 99

local OFFERED_A = HARNESS.addQuest(10, { name = "Gold Dust Exchange", questLevel = 10 })
local OFFERED_B = HARNESS.addQuest(12, { name = "Further Concerns", questLevel = 12 })
local DONE = HARNESS.addQuest(20, { name = "Done Already", questLevel = 8 })
local IN_LOG = HARNESS.addQuest(21, { name = "Already Taken", questLevel = 9 })
local TOO_HIGH = HARNESS.addQuest(22, { name = "Too High", requiredLevel = 60 })
local TOO_LOW = HARNESS.addQuest(23, { name = "Expired", requiredMaxLevel = 20 })
local HORDE_ONLY = HARNESS.addQuest(24, { name = "Horde Only", requiredRaces = 2 + 16 + 32 + 128 })
local MAGE_ONLY = HARNESS.addQuest(25, { name = "Mage Only", requiredClasses = 128 })
local NEEDS_GROUP = HARNESS.addQuest(26, { name = "Needs Both", preQuestGroup = { 10, 12 } })
local NEEDS_ONE = HARNESS.addQuest(27, { name = "Needs Either", preQuestSingle = { 10, 12 } })
local EXCLUDED = HARNESS.addQuest(28, { name = "Locked Out", exclusiveTo = { 20 } })
local SKYBORNE = HARNESS.addQuest(29, { name = "Skyborne Only", requiredRaces = 4294967296 })
local NASTY = HARNESS.addQuest(30, { name = "|cffff0000Red|r |Hitem:1|h[x]|h", questLevel = 11 })

HARNESS.startQuestsAt(DUGHAN, OFFERED_A, OFFERED_B)
HARNESS.startQuestsAt(CRITTER)
HARNESS.guids.mouseover = HARNESS.creatureGuid(DUGHAN)

HARNESS.fire("ADDON_LOADED", "PersonalAddon")
HARNESS.fire("PLAYER_LOGIN")
HARNESS.frame()
HARNESS.fire("PLAYER_ENTERING_WORLD")
HARNESS.frame()
HARNESS.frame()

-- Q1-Q5: the gates (section 2.3) -----------------------------------------------------------

check("Q1 a present provider is Available", Bridge.State() == STATE.AVAILABLE, Bridge.Describe())

reset()
HARNESS.questiePresent = false
HARNESS.buildQuestie()
check("Q1 no LibQuestieDB is ProviderMissing", Bridge.State() == STATE.PROVIDER_MISSING)
check("Q1 and the features can be told why",
    Bridge.Describe():find("ProviderMissing", 1, true) ~= nil, Bridge.Describe())
HARNESS.questiePresent = true
HARNESS.buildQuestie()

reset()
HARNESS.questieContractOk = false
HARNESS.buildQuestie()
local kind, detail = Bridge.State()
check("Q2 a refused contract is ContractMismatch", kind == STATE.CONTRACT_MISMATCH, kind)
check("Q2 and the message is QuestieDB's own",
    tostring(detail):find("contract mismatch", 1, true) ~= nil, detail)
HARNESS.questieContractOk = true

reset()
HARNESS.questieContract = 9
HARNESS.buildQuestie()
check("Q3 a newer contract is still Available, because the check is a range",
    Bridge.State() == STATE.AVAILABLE, Bridge.Describe())
HARNESS.questieContract = 3

reset()
HARNESS.questieFlavor = "Cata"
HARNESS.buildQuestie()
kind, detail = Bridge.State()
check("Q4 a Cata flavour is WrongFlavor", kind == STATE.WRONG_FLAVOR, kind)
check("Q4 and names what it found", detail == "Cata", detail)
HARNESS.questieFlavor = "Forever"

reset()
HARNESS.questieRaises = true
HARNESS.buildQuestie()
check("Q5 a getter that raises is Errored", Bridge.State() == STATE.ERRORED, Bridge.Describe())
HARNESS.questieRaises = false
HARNESS.buildQuestie()
reset()

-- Q6-Q9: the cache (section 2.4) -----------------------------------------------------------

HARNESS.questieReads = 0
Bridge.QuestsStartedBy(DUGHAN)
local firstReads = HARNESS.questieReads
Bridge.QuestsStartedBy(DUGHAN)
check("Q6 a second lookup makes no QuestieDB read", HARNESS.questieReads == firstReads,
    HARNESS.questieReads - firstReads)

check("Q7 the bridge never calls IdsByName or BuildNameIndex", true)
-- The stub raises if either is called, so reaching here with everything above green
-- is the check. Belt and braces, call the whole surface once more:
Bridge.QuestFacts(OFFERED_A)
Bridge.KillTargetsForQuest(OFFERED_A)
Bridge.NpcName(DUGHAN)
check("Q7 and the surface above does not reach them", true)

local list = Bridge.QuestsStartedBy(DUGHAN)
list[#list + 1] = 99999
local again = Bridge.QuestsStartedBy(DUGHAN)
check("Q8 a caller cannot corrupt the cache through the list it was given",
    #again == #list or again[#again] ~= 99999, #again)

HARNESS.questieReads = 0
Bridge.QuestsStartedBy(CRITTER)
local critterReads = HARNESS.questieReads
Bridge.QuestsStartedBy(CRITTER)
Bridge.QuestsStartedBy(CRITTER)
check("Q18 a negative answer is cached too", HARNESS.questieReads == critterReads,
    HARNESS.questieReads - critterReads)

for id = 500, 500 + ns.QUEST_BRIDGE_CACHE_CAPACITY + 4 do
    HARNESS.startQuestsAt(id)
    Bridge.QuestsStartedBy(id)
end
check("Q9 overflowing the cache does not raise and still answers",
    type(Bridge.QuestsStartedBy(DUGHAN)) == "table")

-- The mask test (section 2.2) ---------------------------------------------------------------

check("mask: a 32-bit bit is held", Bridge.MaskHolds(2 + 16 + 32 + 128, 16))
check("mask: an absent bit is not", Bridge.MaskHolds(2 + 16, 128) == false)
-- The reason this is arithmetic and not bit.band: Forever's race bits 32 and 33.
check("mask: Forever's bit 32 survives", Bridge.MaskHolds(4294967296, 4294967296))
check("mask: Forever's bit 33 survives", Bridge.MaskHolds(8589934592, 8589934592))
check("mask: bit 33 is not confused with bit 32",
    Bridge.MaskHolds(8589934592, 4294967296) == false)

-- Q10-Q18: the tooltip filter (section 3.3) ------------------------------------------------

local function hoverAndText(npcId)
    HARNESS.guids.mouseover = HARNESS.creatureGuid(npcId)
    HARNESS.hoverUnit("mouseover")
    return HARNESS.tooltipText()
end

HARNESS.startQuestsAt(DUGHAN, OFFERED_A, OFFERED_B)
Bridge.Reset()
local text = hoverAndText(DUGHAN)
check("Q19 two offered quests draw a blank, a header and two lines",
    text:find("<blank>", 1, true) and text:find("Available Quests", 1, true)
    and text:find("Gold Dust Exchange", 1, true) and text:find("Further Concerns", 1, true), text)

HARNESS.completedQuests[DONE] = true
HARNESS.startQuestsAt(DUGHAN, DONE)
Bridge.Reset()
text = hoverAndText(DUGHAN)
check("Q10 a completed quest is not listed", text:find("Done Already", 1, true) == nil, text)
check("Q20 and an NPC with nothing offered draws no block at all",
    text:find("Available Quests", 1, true) == nil, text)

HARNESS.setQuestLog(IN_LOG)
HARNESS.startQuestsAt(DUGHAN, IN_LOG)
Bridge.Reset()
text = hoverAndText(DUGHAN)
check("Q11 a quest in the log is not listed", text:find("Already Taken", 1, true) == nil, text)
HARNESS.setQuestLog()

HARNESS.startQuestsAt(DUGHAN, TOO_HIGH, TOO_LOW, OFFERED_A)
Bridge.Reset()
text = hoverAndText(DUGHAN)
check("Q12 below the required level is not listed", text:find("Too High", 1, true) == nil, text)
check("Q13 above requiredMaxLevel is not listed", text:find("Expired", 1, true) == nil, text)
check("Q12 and the offered one still is", text:find("Gold Dust Exchange", 1, true) ~= nil, text)

HARNESS.startQuestsAt(DUGHAN, HORDE_ONLY, OFFERED_A)
Bridge.Reset()
text = hoverAndText(DUGHAN)
check("Q14 a race mask excluding the player is not listed",
    text:find("Horde Only", 1, true) == nil, text)

HARNESS.startQuestsAt(DUGHAN, MAGE_ONLY, OFFERED_A)
Bridge.Reset()
text = hoverAndText(DUGHAN)
check("Q15 a class mask excluding the player is not listed",
    text:find("Mage Only", 1, true) == nil, text)

HARNESS.playerRaceId = 95
HARNESS.startQuestsAt(DUGHAN, SKYBORNE)
Bridge.Reset()
text = hoverAndText(DUGHAN)
check("Q14 a Forever race on bit 32 matches its own quest",
    text:find("Skyborne Only", 1, true) ~= nil, text)
HARNESS.playerRaceId = 1

HARNESS.startQuestsAt(DUGHAN, NEEDS_GROUP)
HARNESS.completedQuests[OFFERED_A] = true
Bridge.Reset()
text = hoverAndText(DUGHAN)
check("Q16 preQuestGroup with one member incomplete is not listed",
    text:find("Needs Both", 1, true) == nil, text)
HARNESS.completedQuests[OFFERED_B] = true
Bridge.Reset()
text = hoverAndText(DUGHAN)
check("Q16 and with all complete it is", text:find("Needs Both", 1, true) ~= nil, text)
HARNESS.completedQuests[OFFERED_A] = nil
HARNESS.completedQuests[OFFERED_B] = nil

HARNESS.startQuestsAt(DUGHAN, NEEDS_ONE)
Bridge.Reset()
text = hoverAndText(DUGHAN)
check("Q17 preQuestSingle with none complete is not listed",
    text:find("Needs Either", 1, true) == nil, text)
HARNESS.completedQuests[OFFERED_B] = true
Bridge.Reset()
text = hoverAndText(DUGHAN)
check("Q17 and with one complete it is", text:find("Needs Either", 1, true) ~= nil, text)
HARNESS.completedQuests[OFFERED_B] = nil

HARNESS.startQuestsAt(DUGHAN, EXCLUDED)
Bridge.Reset()
text = hoverAndText(DUGHAN)
check("Q18 exclusiveTo holding a completed quest is not listed",
    text:find("Locked Out", 1, true) == nil, text)

-- Q21-Q26: drawing (section 3.4) -----------------------------------------------------------

HARNESS.startQuestsAt(DUGHAN, NASTY)
Bridge.Reset()
HARNESS.guids.mouseover = HARNESS.creatureGuid(DUGHAN)
HARNESS.hoverUnit("mouseover")
local drew = nil
for _, line in ipairs(GameTooltip.lines) do
    if tostring(line.text):find("Red", 1, true) then drew = line.text end
end
check("Q21 a quest name's escape codes are made inert before drawing",
    drew ~= nil and drew:find("||cffff0000", 1, true) ~= nil
    and drew:find("||Hitem", 1, true) ~= nil, drew)
-- The point of doubling is that no single-pipe escape survives for the client to act
-- on. Strip the doubled pairs and nothing escape-like may be left.
check("Q21 and no single-pipe escape survives",
    drew ~= nil and drew:gsub("||", ""):find("|", 1, true) == nil, drew)

local many = {}
for index = 1, 13 do
    many[index] = HARNESS.addQuest(600 + index, { name = "Many " .. index, questLevel = 10 })
end
HARNESS.startQuestsAt(DUGHAN, unpack(many))
Bridge.Reset()
text = hoverAndText(DUGHAN)
check("Q22 thirteen offered quests draw ten lines and a +3 more",
    text:find("+3 more", 1, true) ~= nil, text)

HARNESS.difficultyCalls = 0
HARNESS.startQuestsAt(DUGHAN, OFFERED_A)
Bridge.Reset()
HARNESS.hoverUnit("mouseover")
check("Q23 the colour comes from GetQuestDifficultyColor", HARNESS.difficultyCalls > 0,
    HARNESS.difficultyCalls)
local coloured = false
for _, line in ipairs(GameTooltip.lines) do
    if line.r ~= nil and line.g ~= nil and line.b ~= nil then coloured = true end
end
check("Q23 and is passed as components, not a colour object", coloured)

HARNESS.guids.mouseover = HARNESS.SECRET
HARNESS.hoverUnit("mouseover")
check("Q24 a withheld GUID draws nothing",
    HARNESS.tooltipText():find("Available Quests", 1, true) == nil, HARNESS.tooltipText())

HARNESS.guids.mouseover = "Player-1-00000001"
HARNESS.hoverUnit("mouseover")
check("Q25 a player GUID draws nothing",
    HARNESS.tooltipText():find("Available Quests", 1, true) == nil, HARNESS.tooltipText())

GameTooltip.unit = nil
HARNESS.hoverUnit(nil)
check("Q26 no unit at all draws nothing and does not raise",
    HARNESS.tooltipText():find("Available Quests", 1, true) == nil)

-- The registration is permanent (section 3.1, audit finding 10) ----------------------------

local registrationsBefore = HARNESS.tooltipRegistrations
ns.Registry.SetEnabled("npcQuests", false)
ns.Registry.SetEnabled("npcQuests", true)
check("the tooltip callback is registered once per UI load, not once per enable",
    HARNESS.tooltipRegistrations == registrationsBefore, HARNESS.tooltipRegistrations)
check("and /pa quests reports it as still registered",
    ns.NPCQuests.Inspect().registered == true)

ns.Registry.SetEnabled("npcQuests", false)
HARNESS.guids.mouseover = HARNESS.creatureGuid(DUGHAN)
HARNESS.startQuestsAt(DUGHAN, OFFERED_A)
Bridge.Reset()
HARNESS.hoverUnit("mouseover")
check("a disabled feature draws nothing even though its callback is still registered",
    HARNESS.tooltipText():find("Available Quests", 1, true) == nil, HARNESS.tooltipText())
ns.Registry.SetEnabled("npcQuests", true)

-- Q27-Q31: the kill-target set (section 4.2) -----------------------------------------------

local KILL_A = HARNESS.addQuest(40, { name = "Kill Rogues" })
local KILL_B = HARNESS.addQuest(41, { name = "Kill Credit" })
local GATHER = HARNESS.addQuest(42, { name = "Gather Things" })
HARNESS.setObjectives(KILL_A, { 111, 112 })
HARNESS.setObjectives(KILL_B, nil, { { { 201, 202, 203 }, 204, "slay", 10 } })
HARNESS.setObjectives(GATHER, nil, nil, {
    [2] = { { 301, "open", 1 } }, [3] = { { 302, "collect", 5 } },
    [4] = { 303, 100 }, [6] = { { 304, "cast", 305 } },
})

-- The two sources the first in-game run proved were missing (section 10.5): a quest
-- whose objective is an ITEM, whose droppers have nameplates, and one whose creature
-- is named only through extraObjectives.
local COLLECT = HARNESS.addQuest(43, { name = "Collect Fangs" })
local SPECIAL = HARNESS.addQuest(44, { name = "Special Objective" })
HARNESS.setObjectives(COLLECT, nil, nil, { [3] = { { 9001, "collect", 8 } } })
HARNESS.setItemDrops(9001, 401, 402)
HARNESS.setExtraObjectives(SPECIAL, { 501 })

HARNESS.setQuestLog(KILL_A, false, KILL_B, GATHER)
Bridge.Reset()
ns.Registry.SetEnabled("questMarkers", false)
ns.Registry.SetEnabled("questMarkers", true)
HARNESS.fire("QUEST_LOG_UPDATE")
HARNESS.frame()
HARNESS.frame()
local markers = ns.QuestMarkers.Inspect()
check("Q27 slot 1's creature ids are taken", markers.npcCount >= 2, markers.npcCount)
check("Q28 slot 5's whole npcId list and its credit id are taken too",
    markers.npcCount == 2 + 4, markers.npcCount)
check("Q29 slots 2, 3, 4 and 6 are ignored", markers.npcCount == 6, markers.npcCount)
check("Q31 the set says how many quests it saw", markers.questsSeen == 3, markers.questsSeen)
check("Q31 and whether that is all of them", markers.complete == true, markers.complete)

-- Q48: an item objective's droppers are targets (section 10.5's finding)
HARNESS.setQuestLog(COLLECT)
Bridge.Reset()
HARNESS.fire("QUEST_LOG_UPDATE")
HARNESS.frame()
HARNESS.frame()
local collectSet = ns.QuestMarkers.Inspect()
check("Q48 a quest that collects an item targets the NPCs that drop it",
    collectSet.npcCount == 2, collectSet.npcCount)
local ids = table.concat(collectSet.targetIds, ",")
check("Q48 and names both droppers", ids == "401,402", ids)

-- Q49: extraObjectives' monster references are targets
HARNESS.setQuestLog(SPECIAL)
Bridge.Reset()
HARNESS.fire("QUEST_LOG_UPDATE")
HARNESS.frame()
HARNESS.frame()
check("Q49 a creature named only through extraObjectives is a target",
    table.concat(ns.QuestMarkers.Inspect().targetIds, ",") == "501",
    table.concat(ns.QuestMarkers.Inspect().targetIds, ","))

-- Q50: objects and spells are still ignored -- an object has no nameplate
HARNESS.setQuestLog(GATHER)
Bridge.Reset()
HARNESS.fire("QUEST_LOG_UPDATE")
HARNESS.frame()
HARNESS.frame()
check("Q50 object and spell objectives still contribute nothing",
    ns.QuestMarkers.Inspect().npcCount == 0, ns.QuestMarkers.Inspect().npcCount)

-- Q51: one quest cannot fill the set on its own
local FLOOD = HARNESS.addQuest(45, { name = "Widely Dropped" })
HARNESS.setObjectives(FLOOD, nil, nil, { [3] = { { 9002, "collect", 1 } } })
local many = {}
for index = 1, ns.QUEST_TARGETS_PER_QUEST_MAXIMUM + 40 do
    many[index] = 20000 + index
end
HARNESS.setItemDrops(9002, unpack(many))
HARNESS.setQuestLog(FLOOD)
Bridge.Reset()
HARNESS.fire("QUEST_LOG_UPDATE")
HARNESS.frame()
HARNESS.frame()
check("Q51 a widely-dropped item is capped, not unbounded",
    ns.QuestMarkers.Inspect().npcCount == ns.QUEST_TARGETS_PER_QUEST_MAXIMUM,
    ns.QuestMarkers.Inspect().npcCount)

HARNESS.setQuestLog(KILL_A, false, KILL_B, GATHER)
Bridge.Reset()
HARNESS.fire("QUEST_LOG_UPDATE")
HARNESS.frame()
HARNESS.frame()

HARNESS.questLogReadable = false
local before = ns.QuestMarkers.Inspect().npcCount
HARNESS.fire("QUEST_LOG_UPDATE")
HARNESS.frame()
HARNESS.frame()
check("Q30 an unreadable log leaves the previous set in place",
    ns.QuestMarkers.Inspect().npcCount == before, ns.QuestMarkers.Inspect().npcCount)
HARNESS.questLogReadable = true

-- A collapsed header: fewer shown entries than quests (audit finding 15).
HARNESS.setQuestLog(KILL_A, false, KILL_B, GATHER)
HARNESS.questLogShownLimit = 2
Bridge.Reset()
HARNESS.fire("QUEST_LOG_UPDATE")
HARNESS.frame()
HARNESS.frame()
markers = ns.QuestMarkers.Inspect()
check("Q15 a short read is reported, not hidden",
    markers.complete == false and markers.questsSeen < markers.questsExpected,
    format("%s seen of %s", tostring(markers.questsSeen), tostring(markers.questsExpected)))
HARNESS.questLogShownLimit = nil
HARNESS.fire("QUEST_LOG_UPDATE")
HARNESS.frame()
HARNESS.frame()

-- Q32-Q45: the markers (section 4.4) -------------------------------------------------------

local function addPlate(token, npcId)
    HARNESS.guids[token] = npcId and HARNESS.creatureGuid(npcId) or HARNESS.SECRET
    HARNESS.addPlate(token, { reaction = 2, canAttack = true }, { 1, 0, 0 })
    local frame = HARNESS.plates[token]
    frame.unitToken = token
    local container = { height = 13 }
    function container:GetHeight() return self.height end
    function container:SetHeight(value) self.height = value end
    function container:GetWidth() return 190 end
    function container:GetName() return token .. "Container" end
    frame.UnitFrame.HealthBarsContainer = container
    -- addPlate fired NAME_PLATE_UNIT_ADDED before the container existed, so the
    -- plate resolved without one. Re-fire now that it does (tests15 does the same).
    HARNESS.fire("NAME_PLATE_UNIT_ADDED", token)
    HARNESS.frame()
    return frame
end

HARNESS.setQuestLog(KILL_A)
Bridge.Reset()
HARNESS.fire("QUEST_LOG_UPDATE")
HARNESS.frame()
HARNESS.frame()

addPlate("nameplate1", 111)
HARNESS.frame()
check("Q32 a plate whose npc is a target gets a marker",
    ns.QuestMarkers.Inspect().markers == 1, ns.QuestMarkers.Inspect().markers)

addPlate("nameplate2", 999)
HARNESS.frame()
check("Q32 a plate whose npc is not a target gets none",
    ns.QuestMarkers.Inspect().markers == 1, ns.QuestMarkers.Inspect().markers)

check("Q33 both plates are attached", ns.QuestMarkers.Inspect().attached == 2,
    ns.QuestMarkers.Inspect().attached)
HARNESS.fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
HARNESS.frame()
check("Q33 detach releases the marker and forgets the plate",
    ns.QuestMarkers.Inspect().markers == 0 and ns.QuestMarkers.Inspect().attached == 1,
    format("%d markers, %d attached", ns.QuestMarkers.Inspect().markers,
        ns.QuestMarkers.Inspect().attached))

-- Q38: a withheld GUID on an unrestricted map
addPlate("nameplate3", nil)
HARNESS.frame()
check("Q38 a withheld GUID gets no marker and does not disturb the others",
    ns.QuestMarkers.Inspect().markers == 0, ns.QuestMarkers.Inspect().markers)

-- Q45: the log changing updates a plate already on screen
HARNESS.fire("NAME_PLATE_UNIT_REMOVED", "nameplate2")
HARNESS.fire("NAME_PLATE_UNIT_REMOVED", "nameplate3")
HARNESS.frame()
addPlate("nameplate4", 201)
HARNESS.frame()
check("Q45 a plate for a mob of no active quest starts unmarked",
    ns.QuestMarkers.Inspect().markers == 0, ns.QuestMarkers.Inspect().markers)
HARNESS.setQuestLog(KILL_A, KILL_B)
HARNESS.fire("QUEST_LOG_UPDATE")
HARNESS.frame()
HARNESS.frame()
check("Q45 and accepting the quest marks it without the plate moving",
    ns.QuestMarkers.Inspect().markers == 1, ns.QuestMarkers.Inspect().markers)

-- Q35-Q37: restricted maps (section 4.3)
HARNESS.secretStanding = false
HARNESS.restricted = true
local priorRestriction = C_RestrictedActions
C_RestrictedActions = { IsAddOnRestrictionActive = function() return true end }
HARNESS.fire("PLAYER_ENTERING_WORLD")
HARNESS.frame()
HARNESS.frame()
check("Q35 a restricted map releases every marker",
    ns.QuestMarkers.Inspect().markers == 0, ns.QuestMarkers.Inspect().markers)
check("Q35 and says it stood down",
    ns.QuestMarkers.Inspect().capability == "StoodDown",
    ns.QuestMarkers.Inspect().capability)

C_RestrictedActions = { IsAddOnRestrictionActive = function() return HARNESS.SECRET end }
HARNESS.fire("PLAYER_ENTERING_WORLD")
HARNESS.frame()
HARNESS.frame()
check("Q36 an unreadable restriction also stands down -- could not tell is not permission",
    ns.QuestMarkers.Inspect().capability == "StoodDown",
    ns.QuestMarkers.Inspect().capability)

C_RestrictedActions = priorRestriction
HARNESS.fire("PLAYER_ENTERING_WORLD")
HARNESS.frame()
HARNESS.frame()
check("Q37 leaving the map draws markers again",
    ns.QuestMarkers.Inspect().capability == "Capable" and ns.QuestMarkers.Inspect().markers == 1,
    format("%s, %d markers", ns.QuestMarkers.Inspect().capability,
        ns.QuestMarkers.Inspect().markers))

-- Q40: the settings reach markers already on screen
setSetting("questMarkers", "markerScale", 1.4)
check("Q40 markerScale applies to markers already drawn",
    ns.QuestMarkers.Inspect().markerScale == 1.4, ns.QuestMarkers.Inspect().markerScale)
setSetting("questMarkers", "markerOffsetY", 12)
check("Q40 and so does markerOffsetY",
    ns.QuestMarkers.Inspect().markerOffsetY == 12, ns.QuestMarkers.Inspect().markerOffsetY)
setSetting("questMarkers", "markerScale", 1.0)
setSetting("questMarkers", "markerOffsetY", 0)

-- Q44: disable releases everything and leaves no timer
ns.Registry.SetEnabled("questMarkers", false)
check("Q44 disable releases every marker and forgets every plate",
    ns.QuestMarkers.Inspect().markers == 0 and ns.QuestMarkers.Inspect().attached == 0,
    format("%d markers, %d attached", ns.QuestMarkers.Inspect().markers,
        ns.QuestMarkers.Inspect().attached))
HARNESS.fire("QUEST_LOG_UPDATE")
HARNESS.advance(2)
check("Q44 and no rebuild fires into a disabled feature",
    ns.QuestMarkers.Inspect().enabled == false)
ns.Registry.SetEnabled("questMarkers", true)
HARNESS.frame()
HARNESS.frame()

-- Q46: a plate already up when the feature enables is adopted -------------------------------
-- The first in-game run could not have marked these at all: they were tracked
-- before the call-out existed, so they were never offered and stayed unmarked until
-- they recycled. A /reload with mobs on screen is the common case.
ns.Registry.SetEnabled("questMarkers", false)
HARNESS.frame()
addPlate("nameplate9", 111)
check("Q46 the plate is tracked while the marker feature is off",
    ns.QuestMarkers.Inspect().attached == 0, ns.QuestMarkers.Inspect().attached)
ns.Registry.SetEnabled("questMarkers", true)
HARNESS.frame()
HARNESS.fire("PLAYER_ENTERING_WORLD")
HARNESS.frame()
HARNESS.frame()
check("Q46 enabling adopts it and marks it without the plate moving",
    ns.QuestMarkers.Inspect().markers >= 1, ns.QuestMarkers.Inspect().markers)
check("Q46 and it is counted as attached",
    ns.QuestMarkers.Inspect().attached >= 1, ns.QuestMarkers.Inspect().attached)
HARNESS.fire("NAME_PLATE_UNIT_REMOVED", "nameplate9")
HARNESS.frame()

-- Q47: every reason a plate gets no marker is counted ----------------------------------------
-- The first run was undiagnosable because NotATarget covered three causes and none
-- of them bumped anything.
local view = ns.QuestMarkers.Inspect()
check("Q47 /pa quests lists the target ids", #view.targetIds > 0, #view.targetIds)
addPlate("nameplate10", 777)
check("Q47 a non-target plate is still recorded as seen",
    #ns.QuestMarkers.Inspect().seenIds > 0, #ns.QuestMarkers.Inspect().seenIds)
local sawNonTarget = false
for _, entry in ipairs(ns.QuestMarkers.Inspect().seenIds) do
    if tostring(entry):find("777", 1, true) then sawNonTarget = true end
end
check("Q47 and by its own npc id, so the two lists can be compared", sawNonTarget,
    table.concat(ns.QuestMarkers.Inspect().seenIds, ", "))
HARNESS.fire("NAME_PLATE_UNIT_REMOVED", "nameplate10")
HARNESS.frame()

-- Q43: nameplates off
ns.Registry.SetEnabled("nameplates", false)
HARNESS.frame()
check("Q43 with nameplates off no plate is offered and /pa quests says so",
    ns.QuestMarkers.Inspect().nameplatesOn == false)
ns.Registry.SetEnabled("nameplates", true)
HARNESS.frame()

-- Q1 again: both features stand down when the provider goes --------------------------------

ns.Registry.SetEnabled("npcQuests", false)
ns.Registry.SetEnabled("questMarkers", false)
HARNESS.questiePresent = false
HARNESS.buildQuestie()
Bridge.Reset()
local okQuests = ns.Registry.SetEnabled("npcQuests", true)
local okMarkers = ns.Registry.SetEnabled("questMarkers", true)
check("Q1 both features refuse to enable without the provider, and do not fault",
    okQuests ~= true and okMarkers ~= true,
    format("%s / %s", tostring(okQuests), tostring(okMarkers)))
HARNESS.questiePresent = true
HARNESS.buildQuestie()
Bridge.Reset()
ns.Registry.SetEnabled("npcQuests", true)
ns.Registry.SetEnabled("questMarkers", true)
HARNESS.frame()

-- /pa quests ---------------------------------------------------------------------------------

local chatMark = #HARNESS.chat
slash("quests")
local said, saidMarkers = false, false
for index = chatMark + 1, #HARNESS.chat do
    local line = tostring(HARNESS.chat[index])
    if line:find("QuestieDB:", 1, true) then said = true end
    if line:find("markers:", 1, true) then saidMarkers = true end
end
check("the command reports the bridge", said)
check("the command reports the markers", saidMarkers)

-- The probe's report survives to disk ---------------------------------------------------------

if ns.QuestProbe then
    slash("probe quests clear")
    slash("probe quests log")
    check("the quest probe saves its report, because chat is not a record",
        type(PersonalAddonSpikeLog) == "table" and #PersonalAddonSpikeLog.lines > 0,
        PersonalAddonSpikeLog and #PersonalAddonSpikeLog.lines)
    local sawCounts = false
    for _, line in ipairs(PersonalAddonSpikeLog.lines) do
        if tostring(line):find("numShownEntries", 1, true) then sawCounts = true end
    end
    check("and SQ2's report carries both quest-log counts", sawCounts,
        table.concat(PersonalAddonSpikeLog.lines, " | "))
end

-- Report ---------------------------------------------------------------------------------------

local errors = {}
for _, line in ipairs(HARNESS.chat) do
    if line:find("raised", 1, true) or line:find("faulted", 1, true) then
        errors[#errors + 1] = line
    end
end
HARNESS_RESULT = { passed = passed, failures = failures, errors = errors, chat = HARNESS.chat }
