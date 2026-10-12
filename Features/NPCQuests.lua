-- Features/NPCQuests.lua
-- Which quests an NPC has for you, on its mouseover tooltip
-- (Architecture/20261011-Phase17.md section 3).
--
-- THE HOOK IS RULE 1-CLEAN AND A RULE 5 EXCEPTION, and both halves matter.
--
-- Clean, because TooltipDataProcessor.AddTooltipPostCall is Blizzard's own registry
-- for insecure callbacks and is built as a taint firewall: AddCall sees issecure()
-- is false for us, wraps our function in a closure that calls forceinsecure(), and
-- hands it to a SetForbidden() attribute delegate. The wrapper lands in a file-local
-- table -- nothing of ours in a public Blizzard table (rule 2) -- and at dispatch
-- each insecure callback runs under securecallfunction. Blizzard's own
-- TooltipDataRules.HealthBar uses the same door.
--
-- An exception, because our code runs INLINE in the tooltip build rather than a
-- frame later. It has to: ProcessTooltipPostCalls runs after ProcessLines and before
-- self:Show(), which is what makes AddLine work and the tooltip size itself. A frame
-- later would draw into a tooltip already shown, or the next unit's. Rule 5's
-- purpose -- keeping our execution out of Blizzard's -- is served here by Blizzard's
-- own construction instead of by our deferral. README records it as an exception.
--
-- AND THE REGISTRATION IS PERMANENT. TooltipDataHandler.lua publishes four Add*
-- functions and no Remove*. So the call is made at most once per UI load, behind a
-- module-level flag, and disable silences the handler through state.enabled rather
-- than unregistering -- registering per enable would put a second copy of the
-- handler in Blizzard's table and the tooltip would grow two identical blocks.

local ADDON_NAME, ns = ...

local FEATURE_ID = "npcQuests"

local format, type, pcall, tostring = string.format, type, pcall, tostring
local ClientRead = ns.ClientRead
local Bridge = ns.QuestieDBBridge

local REJECTION = {
    COMPLETED = "AlreadyCompleted",
    IN_LOG = "InLog",
    BELOW_LEVEL = "BelowRequiredLevel",
    ABOVE_LEVEL = "AboveMaximumLevel",
    WRONG_RACE = "WrongRace",
    WRONG_CLASS = "WrongClass",
    PREREQUISITE = "PrerequisiteMissing",
    EXCLUSIVE = "ExclusiveTaken",
    UNREADABLE = "Unreadable",
}

-- Module-level, not per enable: there is no way to unregister (see the header).
local registered = false

local state = {
    enabled = false,
    lastNpcId = nil,
    lastNpcName = nil,
    lastOffered = nil,
    lastRejections = nil,
    lastPlayer = nil,
}

local function counters()
    return ns.Diagnostics.CountersFor(FEATURE_ID)
end

local function bump(name)
    ns.Diagnostics.Bump(counters(), name)
end

-- The player (section 3.3) ------------------------------------------------------------

-- An Absent field rejects the quests whose test needs it. A QuestieDB mask of 0
-- means "any race", so defaulting an unreadable race to 0 would offer every
-- race-restricted quest to everyone -- the opposite of safe.
local function playerFacts()
    local facts = {}

    local levelKind, level = ClientRead.Call(_G.UnitLevel, "number", "player")
    if levelKind == ClientRead.PLAIN then
        facts.level = level
    end

    -- UnitRace's third return is the race ID, which is what raceMaskById is keyed by.
    local raceKind, _, _, raceId = ClientRead.CallMany(_G.UnitRace, 1, "string", "player")
    if raceKind == ClientRead.PLAIN then
        local idKind, resolvedId = ClientRead.Classify(raceId, "number")
        if idKind == ClientRead.PLAIN then
            facts.raceMask = Bridge.RaceMask(resolvedId)
        end
    end
    if facts.raceMask == nil then
        -- CallMany only promises the first return's type; read the third positionally.
        local ok, _, _, id = pcall(_G.UnitRace, "player")
        if ok and ClientRead.Classify(id, "number") == ClientRead.PLAIN then
            facts.raceMask = Bridge.RaceMask(id)
        end
    end

    -- UnitClass's second return is the file name ("WARRIOR"), which classKeys uses.
    local ok, _, fileName = pcall(_G.UnitClass, "player")
    if ok and ClientRead.Classify(fileName, "string") == ClientRead.PLAIN then
        facts.classMask = Bridge.ClassMask(fileName)
    end

    if facts.level == nil or facts.raceMask == nil or facts.classMask == nil then
        bump("playerFactUnreadable")
    end
    return facts
end

-- The filter (section 3.3) ------------------------------------------------------------

local function isCompleted(questId)
    local api = _G.C_QuestLog
    local kind, completed = ClientRead.Call(api and api.IsQuestFlaggedCompleted,
        "boolean", questId)
    if kind ~= ClientRead.PLAIN then
        return nil
    end
    return completed
end

local function isInLog(questId)
    local api = _G.C_QuestLog
    local kind, index = ClientRead.Call(api and api.GetLogIndexForQuestID,
        "number", questId)
    if kind == ClientRead.ABSENT then
        return false
    end
    if kind ~= ClientRead.PLAIN then
        return nil
    end
    return index > 0
end

local function allCompleted(ids)
    for index = 1, #ids do
        if isCompleted(ids[index]) ~= true then
            return false, ids[index]
        end
    end
    return true
end

local function anyCompleted(ids)
    if #ids == 0 then
        return true
    end
    for index = 1, #ids do
        if isCompleted(ids[index]) == true then
            return true
        end
    end
    return false, ids[1]
end

-- Cheapest test first: 1 and 2 are client calls on an id already in hand, and most
-- ids fall out there. 3 to 9 need the bridge's cache.
local function judgeQuest(questId, player)
    if isCompleted(questId) == true then
        return nil, REJECTION.COMPLETED
    end
    if isInLog(questId) == true then
        return nil, REJECTION.IN_LOG
    end

    local facts = Bridge.QuestFacts(questId)
    if not facts then
        return nil, REJECTION.UNREADABLE
    end

    if facts.requiredLevel > 0 or facts.requiredMaxLevel > 0 then
        if player.level == nil then
            return nil, REJECTION.UNREADABLE
        end
        if player.level < facts.requiredLevel then
            return nil, REJECTION.BELOW_LEVEL
        end
        if facts.requiredMaxLevel > 0 and player.level > facts.requiredMaxLevel then
            return nil, REJECTION.ABOVE_LEVEL
        end
    end

    if facts.requiredRaces > 0 then
        if player.raceMask == nil then
            return nil, REJECTION.UNREADABLE
        end
        if not Bridge.MaskHolds(facts.requiredRaces, player.raceMask) then
            return nil, REJECTION.WRONG_RACE
        end
    end

    if facts.requiredClasses > 0 then
        if player.classMask == nil then
            return nil, REJECTION.UNREADABLE
        end
        if not Bridge.MaskHolds(facts.requiredClasses, player.classMask) then
            return nil, REJECTION.WRONG_CLASS
        end
    end

    local groupOk = allCompleted(facts.preQuestGroup)
    if not groupOk then
        return nil, REJECTION.PREREQUISITE
    end
    local singleOk = anyCompleted(facts.preQuestSingle)
    if not singleOk then
        return nil, REJECTION.PREREQUISITE
    end

    for index = 1, #facts.exclusiveTo do
        local other = facts.exclusiveTo[index]
        if isCompleted(other) == true or isInLog(other) == true then
            return nil, REJECTION.EXCLUSIVE
        end
    end

    return {
        questId = questId,
        name = facts.name or format("Quest %d", questId),
        level = facts.questLevel,
    }
end

local function offeredQuests(npcId, player)
    local offered, rejections = {}, {}
    local ids = Bridge.QuestsStartedBy(npcId)
    for index = 1, #ids do
        local questId = ids[index]
        local summary, rejection = judgeQuest(questId, player)
        if summary then
            offered[#offered + 1] = summary
            bump("questsOffered")
        else
            rejections[questId] = rejection
            bump("questsRejected")
        end
    end
    return offered, rejections
end

-- The NPC behind the tooltip (section 3.2) --------------------------------------------

local RESOLUTION = { RESOLVED = "Resolved", NOT_AN_NPC = "NotAnNpc",
    WITHHELD = "Withheld", ABSENT = "Absent" }

-- UnitGUID carries SecretWhenUnitIdentityRestricted, so the GUID is classified
-- before any string operation: strsplit on a withheld value raises in our code
-- (rule 10), and the secret-read lint exists for exactly this line.
local function npcIdForTooltip(tooltip)
    local getUnit = type(tooltip) == "table" and tooltip.GetUnit
    if type(getUnit) ~= "function" then
        return RESOLUTION.ABSENT
    end
    local ok, _, unit = pcall(getUnit, tooltip)
    if not ok or ClientRead.Classify(unit, "string") ~= ClientRead.PLAIN then
        return RESOLUTION.ABSENT
    end

    local kind, guid = ClientRead.Call(_G.UnitGUID, "string", unit)
    if kind == ClientRead.ABSENT then
        return RESOLUTION.ABSENT
    end
    if kind ~= ClientRead.PLAIN then
        bump("guidWithheld")
        return RESOLUTION.WITHHELD
    end

    -- Creature-0-<server>-<instance>-<zone>-<npcId>-<spawn>. The first field says
    -- what it is: a player's GUID has no NPC id, and a pet's belongs to its owner.
    local guidType = guid:match("^(%a+)")
    if guidType == "Player" then
        bump("notAnNpc")
        return RESOLUTION.NOT_AN_NPC
    end
    if guidType ~= "Creature" and guidType ~= "Vehicle" then
        return RESOLUTION.NOT_AN_NPC
    end
    local npcId = tonumber(guid:match("-(%d+)-%x+$"))
    if npcId == nil then
        return RESOLUTION.ABSENT
    end
    bump("npcsResolved")
    return RESOLUTION.RESOLVED, npcId
end

-- Drawing (section 3.4) ---------------------------------------------------------------

-- GetQuestDifficultyColor returns an entry of QuestDifficultyColors, which is a raw
-- { r, g, b, font } table (Blizzard_FrameXMLBase/Constants.lua:195-203) with no
-- GetRGB method -- so GameTooltip_AddColoredLine, which calls color:GetRGB(), would
-- raise. Inside the tooltip build, where our pcall would swallow it and the block
-- would simply never appear. The components go in positionally instead.
local function difficultyColour(level)
    local getter = _G.GetQuestDifficultyColor
    if type(getter) ~= "function" or type(level) ~= "number" then
        return nil
    end
    local ok, colour = pcall(getter, level)
    if not ok or ClientRead.Classify(colour, "table") ~= ClientRead.PLAIN then
        return nil
    end
    local rKind, red = ClientRead.Field(colour, "r", "number")
    local gKind, green = ClientRead.Field(colour, "g", "number")
    local bKind, blue = ClientRead.Field(colour, "b", "number")
    if rKind ~= ClientRead.PLAIN or gKind ~= ClientRead.PLAIN or bKind ~= ClientRead.PLAIN then
        return nil
    end
    return red, green, blue
end

-- The client's word for it, not ours: AVAILABLE_QUEST is what the gossip frame
-- labels the same list with, so the header matches the game in any locale. Resolved
-- once per UI load, as the consumable classifier resolves its reference names.
local headerText
local function questsHeader()
    if headerText then
        return headerText
    end
    local kind, text = ClientRead.Classify(_G.AVAILABLE_QUEST, "string")
    if kind == ClientRead.PLAIN and text ~= "" then
        headerText = text
    else
        headerText = ns.NPC_QUESTS_HEADER_FALLBACK
    end
    return headerText
end

local function drawBlock(tooltip, offered)
    local blank = _G.GameTooltip_AddBlankLineToTooltip
    if type(blank) == "function" then
        pcall(blank, tooltip)
    end
    pcall(tooltip.AddLine, tooltip, questsHeader(), 1, 0.82, 0)

    local shown = 0
    for index = 1, #offered do
        if shown >= ns.NPC_QUEST_LINE_CAPACITY then
            bump("linesCapped")
            pcall(tooltip.AddLine, tooltip,
                format("  +%d more", #offered - shown), 0.6, 0.6, 0.6)
            break
        end
        local summary = offered[index]
        -- A quest name is third-party data: QuestieDB's RegisterCorrection is
        -- public, so any other addon can inject one. Neutralized before drawing,
        -- for the reason Phase 15 neutralizes a guild name.
        local text = format("  [%d] %s", summary.level,
            ns.EscapeGuard.Neutralize(summary.name))
        local red, green, blue = difficultyColour(summary.level)
        if red then
            pcall(tooltip.AddLine, tooltip, text, red, green, blue)
        else
            pcall(tooltip.AddLine, tooltip, text)
        end
        shown = shown + 1
    end
end

local function onUnitTooltip(tooltip, _tooltipData)
    if not state.enabled then
        return
    end
    bump("tooltips")
    if not Bridge.IsAvailable() then
        return
    end

    local resolution, npcId = npcIdForTooltip(tooltip)
    if resolution ~= RESOLUTION.RESOLVED then
        return
    end

    local player = playerFacts()
    local offered, rejections = offeredQuests(npcId, player)

    state.lastNpcId = npcId
    state.lastNpcName = Bridge.NpcName(npcId)
    state.lastOffered = offered
    state.lastRejections = rejections
    state.lastPlayer = player

    if #offered == 0 then
        -- No block at all, not a header with nothing under it (D10).
        return
    end
    drawBlock(tooltip, offered)
end

-- Lifecycle -----------------------------------------------------------------------------

local function enable()
    local processor = _G.TooltipDataProcessor
    local dataType = _G.Enum and _G.Enum.TooltipDataType and _G.Enum.TooltipDataType.Unit
    if type(processor) ~= "table" or type(processor.AddTooltipPostCall) ~= "function"
        or type(dataType) ~= "number" then
        return nil, "this client has no tooltip data processor"
    end

    local bridgeState, detail = Bridge.State()
    if bridgeState ~= ns.QuestieDBBridge.STATE.AVAILABLE then
        ns.Log.Once("npcquests:bridge:" .. tostring(bridgeState), format(
            "available quests on tooltips need the QuestieDB addon: %s",
            ns.EscapeGuard.Neutralize(Bridge.Describe())))
        return nil, format("QuestieDB is %s%s", tostring(bridgeState),
            detail and (" -- " .. tostring(detail)) or "")
    end

    -- At most once per UI load. There is no RemoveTooltipPostCall, so registering
    -- per enable would leave a second copy of the handler in Blizzard's table.
    if not registered then
        local ok = pcall(processor.AddTooltipPostCall, dataType, function(tooltip, data)
            -- Contained: a defect of ours must not break the tooltip for the
            -- consumers behind us in Blizzard's list.
            local handled, err = pcall(onUnitTooltip, tooltip, data)
            if not handled then
                ns.Diagnostics.Bump(ns.Diagnostics.CountersFor(FEATURE_ID), "handlerRaises")
                ns.Log.OnceError("npcquests:raised",
                    "the NPC quest tooltip raised: " .. ns.EscapeGuard.Neutralize(tostring(err)))
            end
        end)
        if not ok then
            return nil, "the tooltip processor refused our callback"
        end
        registered = true
    end

    state.enabled = true
    return true
end

local function disable()
    -- Nothing to unregister: the handler stays in Blizzard's table for the UI load
    -- and returns immediately on this flag. /pa quests says it is still registered.
    state.enabled = false
    state.lastNpcId = nil
    state.lastOffered = nil
    state.lastRejections = nil
end

ns.Registry.Register(FEATURE_ID, {
    enabledByDefault = true,
    label = "Available quests on NPC tooltips",
    description = "Which quests an NPC has for you, on its mouseover tooltip. Needs the QuestieDB addon enabled.",
    settingsPage = ns.SETTINGS_PAGE.QUESTS,
    settingsOrder = 10,
    settings = {},
}, {
    enable = enable,
    disable = disable,
})

ns.NPCQuests = {
    Inspect = function()
        local offered = {}
        for index = 1, #(state.lastOffered or {}) do
            local summary = state.lastOffered[index]
            offered[#offered + 1] = format("[%d] %s", summary.level,
                ns.EscapeGuard.Neutralize(summary.name))
        end
        local rejected = {}
        for questId, reason in pairs(state.lastRejections or {}) do
            rejected[#rejected + 1] = format("%d=%s", questId, tostring(reason))
        end
        table.sort(rejected)
        local player = state.lastPlayer or {}
        return {
            enabled = state.enabled,
            registered = registered,
            lastNpcId = state.lastNpcId,
            lastNpcName = state.lastNpcName and ns.EscapeGuard.Neutralize(state.lastNpcName) or nil,
            offered = offered,
            rejected = rejected,
            playerLevel = player.level or "unreadable",
            playerRaceMask = player.raceMask or "unreadable",
            playerClassMask = player.classMask or "unreadable",
        }
    end,
}
