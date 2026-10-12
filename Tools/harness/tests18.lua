-- Phase 18 offline checks (Architecture/20261011-Phase18.md section 11.1).
-- One session, "phase18". Sixteen checks over three subjects: the guild label's
-- outline, the QuestieDB cache's answered/did-not-answer distinction, and the
-- marker's new anchor.
--
-- T6 and T9 to T12 exist because the two defects this phase fixes are the same
-- defect in two places: a call that reports failure by return value, read as
-- though silence meant success.

local ns = HARNESS_NS
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

function CompactUnitFrame_SetUnit(_unitFrame, _token) end
function CompactUnitFrame_UpdateHealthColor(_unitFrame) end
NamePlateSetupOptions = { healthBarHeight = 13 }

HARNESS.guilds = {}
HARNESS.players = {}
GetGuildInfo = function(token)
    local value = HARNESS.guilds[token]
    if value == nil then return nil end
    return value, "Rank", 1
end
UnitIsPlayer = function(token)
    local value = HARNESS.players[token]
    if value == nil then return true end
    return value
end

local containers = {}
local function addPlate(token, guild, npcId)
    HARNESS.guilds[token] = guild
    HARNESS.players[token] = guild ~= nil
    HARNESS.addPlate(token, { reaction = 5, canAttack = true }, { 0, 1, 0 })
    local plate = HARNESS.plates[token]
    plate.unitToken = token
    local container = { height = 13 }
    function container:GetHeight() return self.height end
    function container:SetHeight(value) self.height = value end
    function container:GetWidth() return 120 end
    plate.UnitFrame.HealthBarsContainer = container
    containers[token] = container
    if npcId then
        HARNESS.guids[token] = HARNESS.creatureGuid(npcId)
    end
    HARNESS.fire("NAME_PLATE_UNIT_ADDED", token)
    return plate
end

-- The addon's labels and markers are its own pooled frames under UIParent, so
-- they are found the way tests15 finds them rather than hung off the client's
-- plate table.
local function labelFor(guildText)
    for _, record in pairs(HARNESS.frames) do
        if record.parent == UIParent and record.text and record.text.text == guildText then
            return record
        end
    end
end

local function markerAnchoredTo(container)
    for _, record in pairs(HARNESS.frames) do
        local point = record.points and record.points[1]
        if point and point[2] == container then
            return record, point
        end
    end
end

local function setSetting(feature, key, value)
    ns.ConfigStore.Set(feature, key, value)
    ns.Registry.NotifyConfigChanged(feature, key)
    HARNESS.frame()
end

HARNESS.fire("ADDON_LOADED", "PersonalAddon")
HARNESS.fire("PLAYER_LOGIN")
HARNESS.frame()

-- The guild label's outline (section 2) ----------------------------------------------

setSetting("nameplates", "guildNames", true)
HARNESS.resetFontState()
addPlate("nameplate1", "The Silver Hand")
HARNESS.frame()

local view = ns.Nameplates.Inspect()
check("T1 a guild label is outlined", view.guildOutlined >= 1, view.guildOutlined)

-- The arguments, not just the outcome: the file has to come from GetFont, the size
-- from the setting, and the flag from the constant.
local outlineCall
for _, call in ipairs(HARNESS.setFontCalls) do
    if call.flags == ns.GUILD_LABEL_OUTLINE_FLAG then outlineCall = call end
end
check("T1b with the file from GetFont, the configured points and OUTLINE",
    outlineCall ~= nil
        and outlineCall.file == HARNESS.fontFile
        and outlineCall.height == ns.GUILD_FONT_DEFAULT,
    outlineCall and (tostring(outlineCall.file) .. "/" .. tostring(outlineCall.height)
        .. "/" .. tostring(outlineCall.flags)) or "no OUTLINE call")

-- T2: the pool hands out a Frame carrying the height, with the font on its child
-- font string. Revision 1's contract called GetFont on the frame, which would have
-- raised on this very first plate.
local label = labelFor("The Silver Hand")
check("T2 the font went to the child font string, not the frame",
    label ~= nil and outlineCall ~= nil and outlineCall.region == label.text,
    label and tostring(label.text) or "no label")
check("T2b and the frame carries the height",
    label ~= nil and label.height == ns.GUILD_FONT_DEFAULT + 2,
    label and label.height)

-- T3: a withheld font file ------------------------------------------------------
HARNESS.resetFontState()
HARNESS.fontFileMode = "secret"
addPlate("nameplate2", "Withheld Font Guild")
HARNESS.frame()
view = ns.Nameplates.Inspect()
check("T3 a withheld font file falls back, counted", view.guildOutlineFallbacks >= 1,
    view.guildOutlineFallbacks)
local secretLabel = labelFor("Withheld Font Guild")
check("T3b and the label still shows its name at the right size",
    secretLabel ~= nil and secretLabel.text.text == "Withheld Font Guild"
        and secretLabel.height == ns.GUILD_FONT_DEFAULT + 2,
    secretLabel and tostring(secretLabel.text.text))

-- T4: a nil font file is never passed on ----------------------------------------
-- RequiresValidFontAsset would refuse it, so SetFont must not be called at all.
HARNESS.resetFontState()
HARNESS.fontFileMode = "nil"
local fallbacksBefore = ns.Nameplates.Inspect().guildOutlineFallbacks
addPlate("nameplate3", "Nil Font Guild")
HARNESS.frame()
view = ns.Nameplates.Inspect()
check("T4 a nil font file falls back",
    view.guildOutlineFallbacks > fallbacksBefore, view.guildOutlineFallbacks)
check("T4b and SetFont was never called with it", #HARNESS.setFontCalls == 0,
    #HARNESS.setFontCalls)

-- T5: SetFont raising -----------------------------------------------------------
HARNESS.resetFontState()
HARNESS.setFontRaises = true
fallbacksBefore = ns.Nameplates.Inspect().guildOutlineFallbacks
addPlate("nameplate4", "Raising Guild")
HARNESS.frame()
view = ns.Nameplates.Inspect()
check("T5 SetFont raising falls back rather than faulting the feature",
    view.guildOutlineFallbacks > fallbacksBefore
        and ns.Registry.State("nameplates") == "ENABLED",
    ns.Registry.State("nameplates"))

-- T6: SetFont returning false ---------------------------------------------------
-- The check that would have caught treating a refusal as success. Nothing raises
-- here, so a contract reading only "did not raise" would report Outlined.
HARNESS.resetFontState()
HARNESS.setFontResult = false
local outlinedBefore = ns.Nameplates.Inspect().guildOutlined
fallbacksBefore = ns.Nameplates.Inspect().guildOutlineFallbacks
addPlate("nameplate5", "Refusing Guild")
HARNESS.frame()
view = ns.Nameplates.Inspect()
check("T6 SetFont returning false is a fallback, not an outline",
    view.guildOutlineFallbacks > fallbacksBefore and view.guildOutlined == outlinedBefore,
    view.guildOutlined .. "/" .. view.guildOutlineFallbacks)

-- T7: a fallback is never permanent ---------------------------------------------
-- The styling lives in the sizing path, which runs on every attach, so the plate
-- that just fell back is outlined the next time its label is used.
HARNESS.resetFontState()
outlinedBefore = ns.Nameplates.Inspect().guildOutlined
HARNESS.fire("NAME_PLATE_UNIT_REMOVED", "nameplate5")
HARNESS.frame()
addPlate("nameplate5", "Refusing Guild")
HARNESS.frame()
view = ns.Nameplates.Inspect()
check("T7 a label that fell back is outlined on its next attach",
    view.guildOutlined > outlinedBefore, view.guildOutlined)

-- T8: the size slider re-applies the outline ------------------------------------
HARNESS.resetFontState()
setSetting("nameplates", "guildFontSize", 14)
local resized
for _, call in ipairs(HARNESS.setFontCalls) do
    if call.height == 14 and call.flags == ns.GUILD_LABEL_OUTLINE_FLAG then resized = call end
end
check("T8 changing the font size re-outlines labels already on screen",
    resized ~= nil, #HARNESS.setFontCalls)

-- The cache's answered / did-not-answer distinction (section 5) -----------------

local Bridge = ns.QuestieDBBridge

-- T9: a getter that raises for ONE quest while the bridge stays Available. This is
-- the defect the user found by relogging: the empty list used to be cached for the
-- whole UI load, and nothing ever re-read it.
-- Cleared in place, never reassigned: the stub's getters closed over these exact
-- tables when QuestieDB was built, so a fresh table would silently orphan them.
for key in pairs(HARNESS.questObjectives) do HARNESS.questObjectives[key] = nil end
for key in pairs(HARNESS.questExtras) do HARNESS.questExtras[key] = nil end
local raiseFor = 4242
local realObjectives = QuestDB.objectives
QuestDB.objectives = function(questId)
    if questId == raiseFor then error("objectives refused") end
    return realObjectives(questId)
end

local targets = Bridge.KillTargetsForQuest(raiseFor)
check("T9 a raising getter returns an empty list", #targets == 0, #targets)
check("T9b and caches nothing", Bridge.Inspect().cachedTargets == 0,
    Bridge.Inspect().cachedTargets)
check("T9c and counts the failure", ns.Diagnostics.CountersFor("questieBridge").readFailed >= 1,
    ns.Diagnostics.CountersFor("questieBridge").readFailed)

-- The next read finds the targets, without a relog.
QuestDB.objectives = realObjectives
HARNESS.questObjectives[raiseFor] = { [1] = { { 777, "Kill it", 1 } } }
targets = Bridge.KillTargetsForQuest(raiseFor)
check("T9d and the next rebuild finds them", #targets == 1 and targets[1] == 777,
    #targets)

-- T10: an answered-empty read IS cached -----------------------------------------
-- QuestieDB answers nil for an NPC that starts no quests, which is the commonest
-- true answer it gives. Not caching it would re-read on every mouseover of every
-- guard, vendor and critter -- the cache bypass Phase 17's audit finding 18
-- required negative caching to prevent.
for key in pairs(HARNESS.npcStarts) do HARNESS.npcStarts[key] = nil end
local failedBefore = ns.Diagnostics.CountersFor("questieBridge").readFailed
local starts = Bridge.QuestsStartedBy(99001)
check("T10 an NPC that starts no quests answers empty", #starts == 0, #starts)
local readsAfterFirst = HARNESS.questieReads
starts = Bridge.QuestsStartedBy(99001)
check("T10b and the second ask is a cache hit, not another QuestieDB read",
    HARNESS.questieReads == readsAfterFirst,
    HARNESS.questieReads .. " vs " .. readsAfterFirst)
check("T10c with readFailed unmoved",
    ns.Diagnostics.CountersFor("questieBridge").readFailed == failedBefore,
    ns.Diagnostics.CountersFor("questieBridge").readFailed)

-- T11: an absent getter, and a raising one, are not cached ----------------------
local realStarts = NpcDB.questStarts
NpcDB.questStarts = function(_npcId) error("questStarts refused") end
failedBefore = ns.Diagnostics.CountersFor("questieBridge").readFailed
local cachedBefore = Bridge.Inspect().cachedNpcs
starts = Bridge.QuestsStartedBy(99002)
check("T11 a raising questStarts caches nothing",
    Bridge.Inspect().cachedNpcs == cachedBefore, Bridge.Inspect().cachedNpcs)
check("T11b and counts the failure",
    ns.Diagnostics.CountersFor("questieBridge").readFailed > failedBefore,
    ns.Diagnostics.CountersFor("questieBridge").readFailed)

NpcDB.questStarts = nil
failedBefore = ns.Diagnostics.CountersFor("questieBridge").readFailed
starts = Bridge.QuestsStartedBy(99003)
check("T11c an absent questStarts is a non-answer too",
    ns.Diagnostics.CountersFor("questieBridge").readFailed > failedBefore,
    ns.Diagnostics.CountersFor("questieBridge").readFailed)
NpcDB.questStarts = realStarts

-- T12: QuestFacts tells absent from unreadable ----------------------------------
-- Its test is "no name and no levels", which is exactly what a failed read
-- produces, so the name read having ANSWERED is what licenses caching false.
for key in pairs(HARNESS.quests) do HARNESS.quests[key] = nil end
local cachedQuestsBefore = Bridge.Inspect().cachedQuests
local facts = Bridge.QuestFacts(99101)
check("T12 a quest QuestieDB lacks reads as nil", facts == nil)
check("T12b and is cached as absent",
    Bridge.Inspect().cachedQuests > cachedQuestsBefore, Bridge.Inspect().cachedQuests)

local realName = QuestDB.name
QuestDB.name = function(_questId) error("name refused") end
cachedQuestsBefore = Bridge.Inspect().cachedQuests
failedBefore = ns.Diagnostics.CountersFor("questieBridge").readFailed
facts = Bridge.QuestFacts(99102)
check("T12c but an unreadable name caches nothing",
    facts == nil and Bridge.Inspect().cachedQuests == cachedQuestsBefore,
    Bridge.Inspect().cachedQuests)
check("T12d and counts the failure",
    ns.Diagnostics.CountersFor("questieBridge").readFailed > failedBefore,
    ns.Diagnostics.CountersFor("questieBridge").readFailed)
QuestDB.name = realName

-- The marker's anchor (section 3) -----------------------------------------------

-- The stub's quest log holds quest IDS, as GetQuestIDForLogIndex returns them.
HARNESS.questLog = { 7001 }
HARNESS.questObjectives[7001] = { [1] = { { 5150, "Kill them", 10 } } }
setSetting("questMarkers", "markerOffsetX", ns.QUEST_MARKER_OFFSET_X)
setSetting("questMarkers", "markerOffsetY", 0)
setSetting("questMarkers", "markerScale", 1.0)
HARNESS.fire("QUEST_LOG_UPDATE")
HARNESS.frame()
addPlate("nameplate9", nil, 5150)
HARNESS.frame()

local marker, point = markerAnchoredTo(containers["nameplate9"])
local mv = ns.QuestMarkers.Inspect()
local mc = ns.Diagnostics.CountersFor("questMarkers")
local why = table.concat({
    "state=" .. tostring(ns.Registry.State("questMarkers")),
    "cap=" .. tostring(mv.capability), "attached=" .. tostring(mv.attached),
    "markers=" .. tostring(mv.markers), "npcs=" .. tostring(mv.npcCount),
    "seen=" .. tostring(mv.questsSeen), "expected=" .. tostring(mv.questsExpected),
    "offered=" .. tostring(mc.platesOffered), "noContainer=" .. tostring(mc.noContainer),
    "unreadable=" .. tostring(mc.npcIdUnreadable), "notTargeted=" .. tostring(mc.notTargeted),
}, " ")
check("T13 the marker anchors RIGHT to the container's LEFT",
    point ~= nil and point[1] == "RIGHT" and point[3] == "LEFT",
    point and (tostring(point[1]) .. "->" .. tostring(point[3])) or ("no point: " .. why))
check("T13b a few pixels clear of the plate, by default",
    point ~= nil and point[4] == ns.QUEST_MARKER_OFFSET_X and point[5] == 0,
    point and (tostring(point[4]) .. "," .. tostring(point[5])))

-- T14: both sliders move markers already on screen, and the offsets are divided
-- by the scale so the numbers stay screen pixels at any marker size.
setSetting("questMarkers", "markerOffsetX", -20)
setSetting("questMarkers", "markerOffsetY", 12)
setSetting("questMarkers", "markerScale", 1.5)
marker, point = markerAnchoredTo(containers["nameplate9"])
check("T14 both sliders move a marker already on screen",
    point ~= nil and math.abs(point[4] - (-20 / 1.5)) < 0.001
        and math.abs(point[5] - (12 / 1.5)) < 0.001,
    point and (tostring(point[4]) .. "," .. tostring(point[5])))

-- T15: the full symmetric range is accepted. Phase 17's -20..40 encoded "above the
-- bar", which the new anchor retires: the vertical offset is now measured from the
-- bar's centre, so negative and positive mean the same distance either way.
local okLow = ns.ConfigStore.Set("questMarkers", "markerOffsetY", -ns.QUEST_MARKER_OFFSET_LIMIT)
local okHigh = ns.ConfigStore.Set("questMarkers", "markerOffsetY", ns.QUEST_MARKER_OFFSET_LIMIT)
local okPastLow = ns.ConfigStore.Set("questMarkers", "markerOffsetY",
    -ns.QUEST_MARKER_OFFSET_LIMIT - 1)
check("T15 the vertical offset accepts its full symmetric range", okLow and okHigh,
    tostring(okLow) .. "/" .. tostring(okHigh))
check("T15b and refuses past it", not okPastLow)

-- T16: /pa reports the new state ------------------------------------------------
local chatMark = #HARNESS.chat
slash("plates")
local saidStyling = false
for index = chatMark + 1, #HARNESS.chat do
    local line = tostring(HARNESS.chat[index])
    if line:find("outlin", 1, true) or line:find("Outlin", 1, true) then saidStyling = true end
end
check("T16 /pa plates reports the label's styling", saidStyling)

chatMark = #HARNESS.chat
slash("quests")
local saidPlacement, saidReadFailed = false, false
for index = chatMark + 1, #HARNESS.chat do
    local line = tostring(HARNESS.chat[index])
    if line:find("offset", 1, true) then saidPlacement = true end
    if line:find("readFailed", 1, true) then saidReadFailed = true end
end
check("T16b /pa quests reports the marker's placement", saidPlacement)
check("T16c and readFailed beside the other bridge counters", saidReadFailed)

-- Report ------------------------------------------------------------------------

local errors = {}
for _, line in ipairs(HARNESS.chat) do
    local text = tostring(line)
    if text:find("faulted", 1, true) and not text:find("fault probe", 1, true) then
        errors[#errors + 1] = text
    end
end

HARNESS_RESULT = {
    passed = passed,
    failures = failures,
    errors = errors,
    chat = HARNESS.chat,
}
