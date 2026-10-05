-- Offline stand-ins for the client APIs PersonalAddon touches. Just enough to
-- load every TOC file, drive login, and exercise Phase 7's two changes.

HARNESS_NS = {}
HARNESS = {
    now = 100.0,
    timers = {},
    frames = {},
    chat = {},
    stackMode = "readable",
    callContext = {},
    units = {},
    plates = {},
    selectedTarget = nil,
    playerInCombat = false,
    secretStanding = false,
    watchList = {},
    watchTypes = {},
    eventMode = "deferred",
    pendingEvents = {},
    quests = {},
    superTracked = nil,
    clearSuperTrackOnRemove = false,
    settingsControls = {},
}
HARNESS.SECRET = setmetatable({}, { __tostring = function() return "<secret>" end })

-- Chat --------------------------------------------------------------------------------
DEFAULT_CHAT_FRAME = {
    AddMessage = function(_, text)
        HARNESS.chat[#HARNESS.chat + 1] = tostring(text)
    end,
}
ChatFrame1 = DEFAULT_CHAT_FRAME
function print(...)
    HARNESS.chat[#HARNESS.chat + 1] = table.concat({ ... }, " ")
end

-- Time and timers ------------------------------------------------------------------------
function GetTime() return HARNESS.now end
function time() return 1790000000 end
function date() return "2026-09-26 12:00:00" end
function GetBuildInfo() return "1.60.1", "99999", "Sep 24 2026", 16001 end
function debugprofilestop() return HARNESS.now * 1000 end

C_Timer = {}
local function addTimer(delay, fn, interval)
    local timer = { at = HARNESS.now + delay, fn = fn, interval = interval, cancelled = false }
    function timer:Cancel() self.cancelled = true end
    function timer:IsCancelled() return self.cancelled end
    HARNESS.timers[#HARNESS.timers + 1] = timer
    return timer
end
function C_Timer.After(delay, fn) addTimer(delay, fn) end
function C_Timer.NewTimer(delay, fn) return addTimer(delay, fn) end
function C_Timer.NewTicker(interval, fn) return addTimer(interval, fn, interval) end

-- Advances one frame: time moves, due timers run, OnUpdate scripts run.
function HARNESS.frame(elapsed)
    elapsed = elapsed or 0.016
    HARNESS.now = HARNESS.now + elapsed
    local due, keep = {}, {}
    for _, timer in ipairs(HARNESS.timers) do
        if not timer.cancelled then
            if timer.at <= HARNESS.now then
                due[#due + 1] = timer
                if timer.interval then
                    timer.at = HARNESS.now + timer.interval
                    keep[#keep + 1] = timer
                end
            else
                keep[#keep + 1] = timer
            end
        end
    end
    HARNESS.timers = keep
    for _, timer in ipairs(due) do
        if not timer.cancelled then
            timer.fn(timer)
        end
    end
    for _, frame in ipairs(HARNESS.frames) do
        local onUpdate = frame.scripts.OnUpdate
        if onUpdate then
            onUpdate(frame, elapsed)
        end
    end
end

function HARNESS.advance(seconds)
    local steps = math.ceil(seconds / 0.05)
    for _ = 1, steps do
        HARNESS.frame(0.05)
    end
end

-- Frames and events ----------------------------------------------------------------------
local frameMethods = {}
function frameMethods:RegisterEvent(eventName) self.events[eventName] = true return true end
function frameMethods:UnregisterEvent(eventName) self.events[eventName] = nil end
function frameMethods:RegisterAllEvents() self.allEvents = true end
function frameMethods:UnregisterAllEvents() self.events = {} self.allEvents = false end
function frameMethods:SetScript(name, fn) self.scripts[name] = fn end
function frameMethods:GetScript(name) return self.scripts[name] end
function frameMethods:IsShown() return self.shown end
function frameMethods:Show() self.shown = true end
function frameMethods:Hide() self.shown = false end

function CreateFrame()
    local frame = { scripts = {}, events = {}, allEvents = false, shown = false }
    setmetatable(frame, {
        __index = function(_, key)
            if frameMethods[key] then
                return frameMethods[key]
            end
            return function() end
        end,
    })
    HARNESS.frames[#HARNESS.frames + 1] = frame
    return frame
end

function HARNESS.fire(eventName, ...)
    local snapshot = {}
    for _, frame in ipairs(HARNESS.frames) do
        snapshot[#snapshot + 1] = frame
    end
    for _, frame in ipairs(snapshot) do
        if (frame.events[eventName] or frame.allEvents) and frame.scripts.OnEvent then
            frame.scripts.OnEvent(frame, eventName, ...)
        end
    end
end

function HARNESS.flushEvents()
    local pending = HARNESS.pendingEvents
    HARNESS.pendingEvents = {}
    for _, event in ipairs(pending) do
        HARNESS.fire(unpack(event, 1, event.n))
    end
end

-- Security and stacks -------------------------------------------------------------------
function issecretvalue(value) return value == HARNESS.SECRET end
function issecurevariable() return true end
function InCombatLockdown() return HARNESS.playerInCombat end

function debugstack()
    if HARNESS.stackMode == "withheld" then
        return HARNESS.SECRET
    end
    local lines = {
        '[string "@Interface/AddOns/PersonalAddon/Spikes/QuestWatchProbe.lua"]:380: in function <Interface/AddOns/PersonalAddon/Spikes/QuestWatchProbe.lua:376>',
        '[string "@Interface/AddOns/PersonalAddon/Core/Dispatch.lua"]:165: in function <Interface/AddOns/PersonalAddon/Core/Dispatch.lua:164>',
    }
    for index = #HARNESS.callContext, 1, -1 do
        lines[#lines + 1] = HARNESS.callContext[index]
    end
    lines[#lines + 1] = "[C]: ?"
    return table.concat(lines, "\n")
end

function hooksecurefunc(first, second, third)
    local owner, name, hook
    if type(first) == "table" then
        owner, name, hook = first, second, third
    else
        owner, name, hook = _G, first, second
    end
    local original = owner[name]
    assert(type(original) == "function", "hooksecurefunc: no function " .. tostring(name))
    owner[name] = function(...)
        local results = { original(...) }
        hook(...)
        return unpack(results)
    end
end

SlashCmdList = {}
Enum = {
    PowerType = { Mana = 0 },
    QuestWatchType = { Automatic = 0, Manual = 1 },
}

-- Units and nameplates --------------------------------------------------------------------
local function resolve(token)
    if type(token) ~= "string" then
        return nil
    end
    if token == "target" then
        return HARNESS.selectedTarget and HARNESS.units[HARNESS.selectedTarget] or nil
    end
    local base = token:match("^(.+)target$")
    if base and HARNESS.units[base] then
        local unit = HARNESS.units[base]
        if unit.hiddenTarget then
            return nil
        end
        return unit.targetId and HARNESS.units[unit.targetId] or nil
    end
    return HARNESS.units[token]
end
HARNESS.resolve = resolve

HARNESS.units.player = { id = "player" }
HARNESS.units.party1 = { id = "party1", inParty = true }
HARNESS.units.stranger = { id = "stranger" }

function UnitExists(token) return resolve(token) ~= nil end
function UnitIsUnit(left, right)
    local a, b = resolve(left), resolve(right)
    if not a or not b then
        return false
    end
    return a.id == b.id
end
function UnitCanAttack(_, token) local unit = resolve(token) return unit and unit.canAttack == true or false end
function UnitIsTapDenied(token)
    if HARNESS.secretStanding then
        return HARNESS.SECRET
    end
    local unit = resolve(token)
    return unit and unit.tapDenied == true or false
end
function UnitPlayerControlled(token) local unit = resolve(token) return unit and unit.controlled == true or false end
function UnitReaction(_, token) local unit = resolve(token) return unit and unit.reaction or nil end
function UnitAffectingCombat(token)
    if token == "player" then
        return HARNESS.playerInCombat
    end
    local unit = resolve(token)
    return unit and unit.inCombat == true or false
end
function UnitInParty(token) local unit = resolve(token) return unit and unit.inParty == true or false end
function UnitInRaid() return nil end
function UnitPowerType() return 0, "MANA" end

C_NamePlate = {
    GetNamePlateForUnit = function(token) return HARNESS.plates[token] end,
    GetNamePlates = function()
        local list = {}
        for token, frame in pairs(HARNESS.plates) do
            list[#list + 1] = frame
        end
        return list
    end,
}

-- Adds a nameplate whose bar starts in Blizzard's colour for that unit.
function HARNESS.addPlate(token, unit, blizzardColour)
    unit.id = token
    HARNESS.units[token] = unit
    local bar = { r = blizzardColour[1], g = blizzardColour[2], b = blizzardColour[3] }
    function bar:GetStatusBarColor() return self.r, self.g, self.b, 1 end
    function bar:SetStatusBarColor(r, g, b) self.r, self.g, self.b = r, g, b end
    local frame = { UnitFrame = { healthBar = bar }, namePlateUnitToken = token }
    HARNESS.plates[token] = frame
    HARNESS.fire("NAME_PLATE_UNIT_ADDED", token)
    return bar
end

-- Quest watches ---------------------------------------------------------------------------
local function emitWatchEvent(questId, added)
    if HARNESS.eventMode == "none" then
        return
    end
    if HARNESS.eventMode == "sync" then
        HARNESS.fire("QUEST_WATCH_LIST_CHANGED", questId, added)
    else
        HARNESS.pendingEvents[#HARNESS.pendingEvents + 1] =
            { n = 3, "QUEST_WATCH_LIST_CHANGED", questId, added }
    end
end
HARNESS.emitWatchEvent = emitWatchEvent

local function indexIn(list, value)
    for index, entry in ipairs(list) do
        if entry == value then
            return index
        end
    end
    return nil
end

C_QuestLog = {}
function C_QuestLog.GetNumQuestWatches() return #HARNESS.watchList end
function C_QuestLog.GetQuestIDForQuestWatchIndex(index) return HARNESS.watchList[index] end
function C_QuestLog.GetQuestWatchType(questId) return HARNESS.watchTypes[questId] end
function C_QuestLog.AddQuestWatch(questId)
    table.insert(HARNESS.callContext, "[C]: in function 'AddQuestWatch'")
    local added = false
    if not indexIn(HARNESS.watchList, questId) then
        table.insert(HARNESS.watchList, questId)
        HARNESS.watchTypes[questId] = HARNESS.reAddType or 1
        added = true
        emitWatchEvent(questId, true)
    end
    table.remove(HARNESS.callContext)
    return added
end
function C_QuestLog.RemoveQuestWatch(questId)
    table.insert(HARNESS.callContext, "[C]: in function 'RemoveQuestWatch'")
    local index = indexIn(HARNESS.watchList, questId)
    local removed = false
    if index then
        table.remove(HARNESS.watchList, index)
        HARNESS.watchTypes[questId] = nil
        removed = true
        if HARNESS.clearSuperTrackOnRemove and HARNESS.superTracked == questId then
            HARNESS.superTracked = nil
        end
        emitWatchEvent(questId, false)
    end
    table.remove(HARNESS.callContext)
    return removed
end
function C_QuestLog.SortQuestWatches()
    table.sort(HARNESS.watchList, function(a, b)
        return (HARNESS.quests[a].distance or 1e12) < (HARNESS.quests[b].distance or 1e12)
    end)
end
function C_QuestLog.GetQuestDifficultyLevel(questId) return HARNESS.quests[questId].level end
function C_QuestLog.GetLogIndexForQuestID(questId) return HARNESS.quests[questId] and HARNESS.quests[questId].logIndex end
function C_QuestLog.GetInfo(logIndex)
    for _, quest in pairs(HARNESS.quests) do
        if quest.logIndex == logIndex then
            return { level = quest.logLevel or quest.level }
        end
    end
    return nil
end
function C_QuestLog.GetDistanceSqToQuest(questId)
    local quest = HARNESS.quests[questId]
    if not quest or not quest.distance then
        return nil
    end
    return quest.distance, true
end
function C_QuestLog.GetTitleForQuestID(questId) return HARNESS.quests[questId] and HARNESS.quests[questId].title end

C_SuperTrack = {
    GetSuperTrackedQuestID = function() return HARNESS.superTracked or 0 end,
    SetSuperTrackedQuestID = function(questId) HARNESS.superTracked = questId end,
}
C_PlayerInfo = { IsPlayerNPERestricted = function() return false end }

-- Settings (C4's Blizzard-stored settings, Patch 01 section 7) ---------------------------
Settings = {
    VarType = { Boolean = "boolean", Number = "number", String = "string" },
    RegisterVerticalLayoutCategory = function(name) return { ID = name, name = name }, {} end,
    RegisterAddOnCategory = function() end,
    RegisterAddOnSetting = function(_, variable, variableKey, variableTable, _, name)
        local setting = { variable = variable, name = name, callbacks = {} }
        function setting:SetValueChangedCallback(fn) self.callbacks[#self.callbacks + 1] = fn end
        function setting:SetValue(value)
            variableTable[variableKey] = value
            for _, fn in ipairs(self.callbacks) do fn(self, value) end
        end
        return setting
    end,
    CreateCheckbox = function(_, setting) HARNESS.settingsControls[#HARNESS.settingsControls + 1] = "checkbox:" .. setting.name end,
    CreateSlider = function(_, setting) HARNESS.settingsControls[#HARNESS.settingsControls + 1] = "slider:" .. setting.name end,
    CreateSliderOptions = function() return {} end,
    CreateColorSwatch = function(_, setting) HARNESS.settingsControls[#HARNESS.settingsControls + 1] = "swatch:" .. setting.name end,
    OpenToCategory = function() end,
}
