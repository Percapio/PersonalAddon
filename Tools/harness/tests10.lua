-- Phase 10 offline checks (Architecture/20261002-Phase10.md section 10.2).
-- Sessions: "phase10" (E1, E2, E4, E5, E6) and "phase10-noenum" (E3: the
-- map-restriction enum absent from the client).

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

local function chatSince(mark)
    local lines = {}
    for index = mark + 1, #HARNESS.chat do
        lines[#lines + 1] = HARNESS.chat[index]
    end
    return table.concat(lines, "\n")
end

local function lootLink(itemId, name, colour)
    return string.format("|c%s|Hitem:%d::::::::60:::::|h[%s]|h|r", colour or "ff1eff00", itemId, name)
end

local GREEN = "You receive loot: " .. lootLink(2001, "Green Boots") .. "."
local WHITE = "You receive loot: " .. lootLink(2002, "Linen Cloth", "ffffffff") .. "."

-- Session variants, set before login ----------------------------------------------------
if HARNESS_SESSION == "phase10-noenum" then
    Enum.AddOnRestrictionType = nil
end

HARNESS.fire("ADDON_LOADED", "PersonalAddon")
HARNESS.fire("PLAYER_LOGIN")
HARNESS.frame()
check("toasts enabled", ns.Registry.State("toasts") == "ENABLED", ns.Registry.State("toasts"))

local function record()
    local sessions = PersonalAddonDiagnostics.sessions
    return sessions[#sessions]
end

if HARNESS_SESSION == "phase10" then
    -- E4: /pa toasts on a fresh UI load prints every count, absent ones as 0.
    local mark = #HARNESS.chat
    slash("toasts")
    local printed = chatSince(mark)
    check("E4 zero-filled counts", printed:find("posted=0 shown=0", 1, true) ~= nil, printed)
    check("E4 restricted-map line", printed:find("restricted map: messages=0 shown=0", 1, true) ~= nil, printed)

    -- E1: a green item looted reaches the diagnostics record with no save step.
    HARNESS.fire("CHAT_MSG_LOOT", GREEN)
    HARNESS.frame()
    local toasts = record().counters.toasts
    check("E1 shown on disk", toasts ~= nil and toasts.shown == 1, toasts and toasts.shown)
    check("E1 not a restricted map", (toasts.lootMessagesOnRestrictedMap or 0) == 0,
        toasts.lootMessagesOnRestrictedMap)

    -- E2: on a restricted map, a green item, a white item and money.
    HARNESS.restrictedMap = true
    HARNESS.fire("CHAT_MSG_LOOT", GREEN)
    HARNESS.fire("CHAT_MSG_LOOT", WHITE)
    HARNESS.fire("CHAT_MSG_MONEY", "You loot 7 Copper")
    HARNESS.frame()
    HARNESS.restrictedMap = false
    check("E2 messages on a restricted map", toasts.lootMessagesOnRestrictedMap == 3, toasts.lootMessagesOnRestrictedMap)
    check("E2 toasts on a restricted map", toasts.shownOnRestrictedMap == 2, toasts.shownOnRestrictedMap)
    check("E2 the white item made none", toasts.notShown == 1, toasts.notShown)
    mark = #HARNESS.chat
    slash("toasts")
    check("E2 /pa toasts reports them", chatSince(mark):find("restricted map: messages=3 shown=2", 1, true) ~= nil,
        chatSince(mark))

    -- E5: the self-test result is kept, and a failed case is noted.
    slash("blocked selftest")
    local blockWatch = record().counters.blockWatch
    check("E5 first run recorded", blockWatch.selftestRuns == 1 and blockWatch.selftestPassed == 17
        and blockWatch.selftestTotal == 17,
        string.format("%s %s %s", tostring(blockWatch.selftestRuns), tostring(blockWatch.selftestPassed),
            tostring(blockWatch.selftestTotal)))
    check("E5 a passing run notes nothing", #record().faults == 0, #record().faults)
    ns.BlockWatch.SelfTest({ { caseName = "forced", run = function() return false, "forced failure" end } })
    check("E5 second run recorded", blockWatch.selftestRuns == 2 and blockWatch.selftestPassed == 0
        and blockWatch.selftestTotal == 1)
    local faults = record().faults
    check("E5 one fault note naming the case", #faults == 1
        and faults[1].message:find("selftest forced: forced failure", 1, true) ~= nil,
        faults[1] and faults[1].message)

    -- E6: the hint names cursor state, as the README's known issue does.
    mark = #HARNESS.chat
    HARNESS.fire("ADDON_ACTION_FORBIDDEN", "BugSack", "SetPreferredGamepadInteractTarget()")
    check("E6 hint names cursor state", chatSince(mark):find("focus, binding and cursor state", 1, true) ~= nil,
        chatSince(mark))
end

if HARNESS_SESSION == "phase10-noenum" then
    -- E3: no enum, so no restricted-map toast counters, no client call, no error.
    HARNESS.restrictedMap = true
    HARNESS.fire("CHAT_MSG_LOOT", GREEN)
    HARNESS.frame()
    HARNESS.restrictedMap = false
    local toasts = record().counters.toasts
    check("E3 toast still shown", toasts.shown == 1, toasts.shown)
    check("E3 nothing counted as restricted", (toasts.lootMessagesOnRestrictedMap or 0) == 0
        and (toasts.shownOnRestrictedMap or 0) == 0)
    check("E3 nothing called", HARNESS.restrictionCalls == 0, HARNESS.restrictionCalls)
    local mark = #HARNESS.chat
    slash("plates")
    check("E3 /pa plates says unreadable", chatSince(mark):find("unreadable", 1, true) ~= nil, chatSince(mark))
end

-- Report -------------------------------------------------------------------------------
local errors = {}
for _, line in ipairs(HARNESS.chat) do
    if line:find("raised", 1, true) or line:find("faulted", 1, true) then
        errors[#errors + 1] = line
    end
end
HARNESS_RESULT = { passed = passed, failures = failures, errors = errors, chat = HARNESS.chat }
