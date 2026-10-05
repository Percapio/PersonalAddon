-- Phase 9 offline checks (Architecture/20261002-Phase09.md section 9.1).
-- Sessions: "phase9", "phase9-raid", "phase9-baddiag", "phase9-noapi".

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

local function count(text, needle)
    local found, start = 0, 1
    while true do
        local at = text:find(needle, start, true)
        if not at then
            return found
        end
        found = found + 1
        start = at + #needle
    end
end

local function near(bar, red, green, blue)
    return math.abs(bar.r - red) < 0.011 and math.abs(bar.g - green) < 0.011
        and math.abs(bar.b - blue) < 0.011
end

local function colourOf(bar)
    return string.format("%.3f %.3f %.3f", bar.r or 0, bar.g or 0, bar.b or 0)
end

local RED, GREEN, WHITE = { 1, 0.251, 0.251 }, { 0.251, 1, 0.251 }, { 1, 1, 1 }
local GREY, YELLOW = { 0.902, 0.902, 0.902 }, { 1, 1, 0 }
local BLIZZARD_GREY, BLIZZARD_RED = { 0.9, 0.9, 0.9 }, { 1, 0, 0 }

-- Blizzard's own colour function, as tests.lua models it, defined before login so
-- the nameplate post-hooks install.
HARNESS.unitForFrame = {}
function CompactUnitFrame_UpdateHealthColor(unitFrame)
    local token = HARNESS.unitForFrame[unitFrame]
    local unit = token and HARNESS.units[token]
    if not unit then
        return
    end
    local r, g, b = 1, 0, 0
    if unit.tapDenied and not unit.controlled then
        r, g, b = 0.9, 0.9, 0.9
    elseif unit.reaction == 4 and not unit.inCombat then
        r, g, b = 1, 1, 0
    end
    unitFrame.healthBar:SetStatusBarColor(r, g, b)
end

local addPlate = HARNESS.addPlate
local function plate(token, unit, colour)
    local bar = addPlate(token, unit, colour)
    HARNESS.unitForFrame[HARNESS.plates[token].UnitFrame] = token
    return bar
end

-- Advances until the feature has swept n more times. The harness ticker drifts by
-- up to a frame per firing, so a fixed span of time is not a fixed sweep count.
local function sweeps(n)
    local start = ns.Nameplates.Inspect().sweeps
    local guard = 0
    while ns.Nameplates.Inspect().sweeps - start < n and guard < 2000 do
        HARNESS.frame(0.05)
        guard = guard + 1
    end
end

-- Session set-up, before login ------------------------------------------------------

local earlyCounters
if HARNESS_SESSION == "phase9" then
    -- G1: six records, one of them empty.
    local function seed(startedAt, sweepCount)
        return { startedAt = startedAt, clientBuild = "1.60.1.1", addonVersion = "seed",
            counters = { nameplates = { sweeps = sweepCount } }, faults = {} }
    end
    PersonalAddonDiagnostics = { formatVersion = 1, sessions = {
        seed(1, 1), seed(2, 0), seed(3, 3), seed(4, 4), seed(5, 5), seed(6, 6),
    } }
    -- D1: a saved value for the removed setting.
    PersonalAddonDB = { schemaVersion = 1, features = {
        damageBreakdown = { enabled = true, settings = { inCombatRefreshSeconds = 5 } },
    } }
    -- G6: a counter table asked for before the bind.
    earlyCounters = ns.Diagnostics.CountersFor("harnessEarly")
    earlyCounters.before = 1
    -- F1, F2: a mana bar, so the five-second rule can enable.
    local manaBar = CreateFrame("StatusBar", "PlayerFrameManaBar", PlayerFrame)
    manaBar:SetWidth(120)
    manaBar:SetHeight(10)
elseif HARNESS_SESSION == "phase9-raid" then
    HARNESS.group = "Raid"
    HARNESS.groupSize = 25
    for index = 1, 25 do
        HARNESS.units["raid" .. index] = { id = "raid" .. index }
    end
elseif HARNESS_SESSION == "phase9-baddiag" then
    PersonalAddonDiagnostics = { formatVersion = 1, sessions = { { startedAt = "yesterday" } } }
elseif HARNESS_SESSION == "phase9-noapi" then
    UnitThreatSituation = nil
    Enum.AddOnRestrictionType = nil
end

-- Boot -----------------------------------------------------------------------------
HARNESS.fire("ADDON_LOADED", "PersonalAddon")

-- G7: the log binds in ADDON_LOADED, before any feature enables.
check("G7 bound at ADDON_LOADED", ns.Diagnostics.IsBound() == true)
check("G7 no feature enabled before login", ns.Registry.State("nameplates") == "REGISTERED",
    ns.Registry.State("nameplates"))

HARNESS.fire("PLAYER_LOGIN")
HARNESS.frame()
check("nameplates enabled", ns.Registry.State("nameplates") == "ENABLED", ns.Registry.State("nameplates"))

local function sessionRecord()
    local sessions = PersonalAddonDiagnostics.sessions
    return sessions[#sessions], sessions
end

-- phase9 ------------------------------------------------------------------------------
if HARNESS_SESSION == "phase9" then
    local CR = ns.ClientRead

    -- C1-C3: the seam itself.
    local function raises() error("boom") end
    check("C1 call_many on a raising function", select(2, CR.CallMany(raises, 2, "number")) == CR.CALL_FAILED)
    check("C1 call_many on nil", select(2, CR.CallMany(nil, 2, "number")) == CR.UNAVAILABLE)
    local touched = false
    local raisingIndex = setmetatable({}, { __index = function() touched = true error("index boom") end })
    check("C2 field on nil", select(2, CR.Field(nil, "x", "number")) == CR.UNEXPECTED_TYPE)
    check("C2 field on a string", select(2, CR.Field("text", "len", "function")) == CR.UNEXPECTED_TYPE)
    check("C2 field on a raising index", select(2, CR.Field(raisingIndex, "x", "number")) == CR.CALL_FAILED and touched)
    check("C2 field on a secret table", select(2, CR.Field(HARNESS.SECRET_TABLE, "x", "number")) == CR.SECRET_VALUE)
    check("C3 classify secret", select(2, CR.Classify(HARNESS.SECRET, "boolean")) == CR.SECRET_VALUE)
    check("C3 classify nil", CR.Classify(nil, "boolean") == CR.ABSENT)
    check("C3 classify wrong type", select(2, CR.Classify("yes", "boolean")) == CR.UNEXPECTED_TYPE)
    check("C3 classify plain", select(2, CR.Classify(true, "boolean")) == true)

    -- G1, G6: the bind kept five records, compacted the empty one, adopted the early table.
    local current, sessions = sessionRecord()
    check("G1 five records kept", #sessions == 5, #sessions)
    check("G1 oldest dropped, empty compacted", sessions[1].startedAt == 3, sessions[1].startedAt)
    check("G1 current is last", current.addonVersion == ns.VERSION, current.addonVersion)
    check("G6 early table adopted", current.counters.harnessEarly == earlyCounters
        and earlyCounters.before == 1)

    -- D1: the removed setting is pruned and not offered.
    check("D1 pruned from the store",
        PersonalAddonDB.features.damageBreakdown.settings.inCombatRefreshSeconds == nil)
    local mark = #HARNESS.chat
    slash("get damageBreakdown")
    check("D1 not listed", not chatSince(mark):find("inCombatRefreshSeconds", 1, true), chatSince(mark))

    -- Nameplates: threat verdicts (N1-N5).
    HARNESS.units.party2 = { id = "party2" }
    HARNESS.units.party3 = { id = "party3" }
    local bars = {
        onYou = plate("nameplate1", { canAttack = true, reaction = 2, targetId = "player", inCombat = true }, BLIZZARD_RED),
        onParty2 = plate("nameplate2", { canAttack = true, reaction = 2, threat = { party2 = 2 }, inCombat = true }, BLIZZARD_RED),
        playerSecret = plate("nameplate3", { canAttack = true, reaction = 2, secretFor = { player = true }, targetId = "party1", inCombat = true }, BLIZZARD_RED),
        allySecret = plate("nameplate4", { canAttack = true, reaction = 2, threat = { player = 0 }, secretFor = { party3 = true }, inCombat = true }, BLIZZARD_RED),
        neutralIdle = plate("nameplate5", { canAttack = true, reaction = 4 }, YELLOW),
        friendlyish = plate("nameplate6", { canAttack = true, reaction = 5 }, BLIZZARD_RED),
    }
    sweeps(2)
    check("N1 player tanking: red", near(bars.onYou, unpack(RED)), colourOf(bars.onYou))
    check("N2 party2 tanking: green", near(bars.onParty2, unpack(GREEN)), colourOf(bars.onParty2))
    check("N3 player withheld, party1 tanking: green", near(bars.playerSecret, unpack(GREEN)), colourOf(bars.playerSecret))
    check("N4 ally withheld, none tanking: Blizzard's colour", near(bars.allySecret, unpack(BLIZZARD_RED)), colourOf(bars.allySecret))
    check("N5 neutral, idle: yellow", near(bars.neutralIdle, unpack(YELLOW)), colourOf(bars.neutralIdle))
    check("N5 reaction 5: white", near(bars.friendlyish, unpack(WHITE)), colourOf(bars.friendlyish))
    local view = ns.Nameplates.Inspect()
    check("N threat reads counted", view.threatReadsPlain > 0 and view.threatReadsWithheld > 0,
        string.format("plain=%d withheld=%d", view.threatReadsPlain, view.threatReadsWithheld))
    check("N threat withheld surfaced once", count(table.concat(HARNESS.chat, "\n"), "threat reads were withheld") == 1)

    -- N9: a bar whose colour is secret is left alone, and colouring stays on.
    local secretBar = plate("nameplate7", { canAttack = true, reaction = 2, targetId = "player", inCombat = true }, BLIZZARD_RED)
    function secretBar:GetStatusBarColor() return HARNESS.SECRET, HARNESS.SECRET, HARNESS.SECRET, 1 end
    sweeps(2)
    view = ns.Nameplates.Inspect()
    check("N9 secret bar untouched", near(secretBar, unpack(BLIZZARD_RED)), colourOf(secretBar))
    check("N9 counted", view.barColourReadsWithheld > 0, view.barColourReadsWithheld)
    check("N9 colouring still on", view.barRecolourable == true and view.colouringActive == true)

    -- N10: yield with a withheld comparison cedes that plate.
    local unitIsUnit = UnitIsUnit
    UnitIsUnit = function(left, right)
        if left == "nameplate1" and right == "target" then
            return HARNESS.SECRET
        end
        return unitIsUnit(left, right)
    end
    slash("set nameplates yieldSelectedTarget true")
    sweeps(2)
    check("N10 withheld yield cedes", near(bars.onYou, unpack(BLIZZARD_RED)), colourOf(bars.onYou))
    check("N10 counted", ns.Nameplates.Inspect().comparisonReadsWithheld > 0)
    UnitIsUnit = unitIsUnit
    slash("set nameplates yieldSelectedTarget false")
    sweeps(2)
    check("N10 restored after yield off", near(bars.onYou, unpack(RED)), colourOf(bars.onYou))

    -- N12: a restricted map is sampled and changes no verdict.
    local before = ns.Nameplates.Inspect().verdicts
    HARNESS.restrictedMap = true
    sweeps(16)
    local diag = ns.Diagnostics.CountersFor("nameplates")
    check("N12 sampled", (diag.restrictedMapSamples or 0) >= 2 and diag.restrictedMapSeen == true,
        tostring(diag.restrictedMapSamples))
    local after = ns.Nameplates.Inspect().verdicts
    local same = true
    for verdict, number in pairs(before) do
        if after[verdict] ~= number then
            same = false
        end
    end
    check("N12 verdicts unchanged", same)
    check("N12 /pa plates says restricted", (function()
        local m = #HARNESS.chat
        slash("plates")
        return chatSince(m):find("restricted map now=yes", 1, true) ~= nil
    end)())
    HARNESS.restrictedMap = false

    -- N7, N8, N11: one plate faults every sweep; the rest stay coloured.
    HARNESS.expectedFaults[#HARNESS.expectedFaults + 1] = "a nameplate faulted"
    local ledger = ns.StyleLedger
    local apply, reapply, reads = ledger.Apply, ledger.Reapply, ledger.Reads
    local faultBar = bars.onParty2
    local function guard(original)
        return function(theLedger, widget, ...)
            if widget == faultBar then
                error("deliberate plate fault |cffff0000escape|r")
            end
            return original(theLedger, widget, ...)
        end
    end
    ledger.Apply, ledger.Reapply, ledger.Reads = guard(apply), guard(reapply), guard(reads)
    local faultsBefore = ns.Nameplates.Inspect().plateFaults
    local sweepsBefore = ns.Nameplates.Inspect().sweeps
    local chatMark = #HARNESS.chat
    sweeps(5)
    ledger.Apply, ledger.Reapply, ledger.Reads = apply, reapply, reads
    view = ns.Nameplates.Inspect()
    check("N7 one fault per sweep", view.plateFaults - faultsBefore == view.sweeps - sweepsBefore
        and view.sweeps - sweepsBefore >= 5,
        string.format("faults=%d sweeps=%d", view.plateFaults - faultsBefore, view.sweeps - sweepsBefore))
    check("N7 faulted plate handed back", near(faultBar, unpack(BLIZZARD_RED)), colourOf(faultBar))
    check("N7 other plates still coloured", near(bars.onYou, unpack(RED)) and near(bars.playerSecret, unpack(GREEN)))
    check("N8 one chat line", count(chatSince(chatMark), "a nameplate faulted") == 1, chatSince(chatMark))
    local notes = sessionRecord().faults
    check("N11 fault noted, neutralized", #notes >= 1 and notes[1].message:find("||cffff0000", 1, true) ~= nil,
        notes[1] and notes[1].message)
    sweeps(2)
    check("N7 recovers when the fault stops", near(faultBar, unpack(GREEN)), colourOf(faultBar))

    -- G3: counters are the saved table.
    check("G3 counters live in the saved variable",
        (sessionRecord().counters.nameplates.sweeps or 0) > 0)

    -- D2, D3: withheld damage figures keep the last render; the settle read retries.
    local dps = ns.DamageBreakdown
    dps.Refresh()
    check("D baseline rows", dps.Inspect().rowsShown == 2, dps.Inspect().rowsShown)
    local source = C_DamageMeter.GetCombatSessionSourceFromType
    C_DamageMeter.GetCombatSessionSourceFromType = function() return HARNESS.SECRET end
    dps.Refresh()
    check("D2 last render kept", dps.Inspect().rowsShown == 2, dps.Inspect().rowsShown)
    check("D2 counted", dps.Inspect().withheldReads == 1, dps.Inspect().withheldReads)
    check("D2 surfaced once", count(table.concat(HARNESS.chat, "\n"), "figures were withheld") == 1)
    HARNESS.fire("PLAYER_REGEN_DISABLED")
    HARNESS.fire("PLAYER_REGEN_ENABLED")
    C_DamageMeter.GetCombatSessionSourceFromType = source
    HARNESS.advance(0.7)
    check("D3 settle read renders", dps.Inspect().rowsShown == 2 and dps.Inspect().withheldReads == 2,
        string.format("rows=%d withheld=%d", dps.Inspect().rowsShown, dps.Inspect().withheldReads))

    -- F1, F2: the spellcast payload and the mana bar's geometry.
    check("five-second rule enabled", ns.Registry.State("fiveSecondRule") == "ENABLED",
        ns.Registry.State("fiveSecondRule"))
    HARNESS.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", HARNESS.SECRET)
    local fsr = ns.FiveSecondRule.Inspect()
    check("F1 withheld spell opens the window", fsr.state == "IN_FSR", fsr.state)
    check("F1 counted", fsr.withheldSpellIds == 1, fsr.withheldSpellIds)
    HARNESS.fire("UNIT_SPELLCAST_SUCCEEDED", HARNESS.SECRET, "Cast-2", 133)
    check("F1 withheld unit ignored", ns.FiveSecondRule.Inspect().withheldSpellIds == 1)
    function PlayerFrameManaBar:GetWidth() return HARNESS.SECRET end
    HARNESS.frame()
    HARNESS.frame()
    check("F2 withheld width counted", ns.FiveSecondRule.Inspect().withheldBarGeometry >= 1,
        ns.FiveSecondRule.Inspect().withheldBarGeometry)

    -- W1: a withheld bag read sorts nothing and hides the skills window.
    local sortsBefore = ns.AutoSortBags.Inspect().sorts
    ContainerFrameCombinedBags:Show()
    HARNESS.frame()
    ContainerFrameCombinedBags.IsShown = function() return HARNESS.SECRET end
    ContainerFrameCombinedBags:Hide()
    HARNESS.frame()
    HARNESS.frame()
    check("W1 no sort on a withheld read", ns.AutoSortBags.Inspect().sorts == sortsBefore,
        ns.AutoSortBags.Inspect().sorts)
    check("W1 skills window hidden", _G.PersonalAddonEquippedSkills.shown == false)
    check("W1 counted", (ns.Diagnostics.CountersFor("autoSortBags").bagReadsWithheld or 0) >= 1)
    ContainerFrameCombinedBags.IsShown = nil
    ContainerFrameCombinedBags:Show()
    HARNESS.frame()
    ContainerFrameCombinedBags:Hide()
    HARNESS.frame()
    HARNESS.frame()
    check("W1 control: a plain close does sort", ns.AutoSortBags.Inspect().sorts == sortsBefore + 1,
        ns.AutoSortBags.Inspect().sorts)

    -- B1: the recorder's own self-test.
    local m = #HARNESS.chat
    slash("blocked selftest")
    check("B1 selftest 17/17", chatSince(m):find("selftest: 17/17 passed", 1, true) ~= nil, chatSince(m))

    -- B3: another addon's known defect: one hint, no record.
    local bw = ns.Diagnostics.CountersFor("blockWatch")
    m = #HARNESS.chat
    HARNESS.fire("ADDON_ACTION_FORBIDDEN", "BugSack", "SetPreferredGamepadInteractTarget()")
    check("B3 hint names BugSack", chatSince(m):find("blamed on BugSack", 1, true) ~= nil, chatSince(m))
    check("B3 no record", #ns.BlockWatch.Records() == 0, #ns.BlockWatch.Records())
    check("B3 counted", bw.refusalsOthersKnownDefect == 1 and bw.knownDefectHintShown == true)

    -- B4: nineteen refusals within a second stay Quiet.
    HARNESS.now = HARNESS.now + 15
    m = #HARNESS.chat
    for _ = 1, 19 do
        HARNESS.now = HARNESS.now + 0.05
        HARNESS.fire("ADDON_ACTION_FORBIDDEN", "PersonalAddon", "UseAction()")
    end
    check("B4 still Quiet", not ns.BlockWatch.StormSummary().storming
        and not chatSince(m):find("refusals in 10 s", 1, true))

    -- B2: twenty-five known-defect refusals in two seconds: the twentieth trips it.
    HARNESS.now = HARNESS.now + 15
    HARNESS.callContext = {
        "[Interface/AddOns/Blizzard_GamepadActionBars/MainActionBarFrame.lua]:255: in function 'UpdateInteractIcons'",
        "[C]: in function 'SetPreferredGamepadInteractTarget'",
    }
    local debugReads = 0
    local realDebugstack = debugstack
    debugstack = function(...)
        debugReads = debugReads + 1
        return realDebugstack(...)
    end
    m = #HARNESS.chat
    for _ = 1, 25 do
        HARNESS.now = HARNESS.now + 0.05
        HARNESS.fire("ADDON_ACTION_FORBIDDEN", "PersonalAddon", "SetPreferredGamepadInteractTarget()")
    end
    debugstack = realDebugstack
    HARNESS.callContext = {}
    local said = chatSince(m)
    check("B2 one storm line", count(said, "refusals in 10 s") == 1, said)
    check("B2 refusals during the storm", bw.refusalsDuringStorm == 6, bw.refusalsDuringStorm)
    check("B2 storms entered", bw.stormsEntered == 1, bw.stormsEntered)
    check("B2 stack reads bounded", debugReads == 20, debugReads)
    check("B2 recorded as the known defect", (function()
        for index, record in ipairs(ns.BlockWatch.Records()) do
            if ns.BlockWatch.Describe(index, record):find("KnownDefect", 1, true) then
                return true
            end
        end
        return false
    end)())
    m = #HARNESS.chat
    slash("blocked")
    check("B2 /pa blocked lists the storm", chatSince(m):find("STORM since", 1, true) ~= nil, chatSince(m))

    -- G5: /pa diag, newest first, and clear.
    m = #HARNESS.chat
    slash("diag")
    local diagText = chatSince(m)
    check("G5 lists records", diagText:find("5 session record(s), newest first", 1, true) ~= nil, diagText)
    check("G5 marks the current one", diagText:find("\n* ", 1, true) ~= nil or diagText:find("* 2026", 1, true) ~= nil, diagText)
    check("G5 shows nameplate counters", diagText:find("nameplates: ", 1, true) ~= nil, diagText)
    slash("diag clear")
    check("G5 clear keeps the current record", #PersonalAddonDiagnostics.sessions == 1
        and sessionRecord() == ns.Diagnostics.Sessions()[1])

-- phase9-raid --------------------------------------------------------------------------
elseif HARNESS_SESSION == "phase9-raid" then
    local bar = plate("nameplate1", { canAttack = true, reaction = 2, targetId = "raid17", inCombat = true }, BLIZZARD_RED)
    sweeps(2)
    check("N13 raid member tanking: green", near(bar, unpack(GREEN)), colourOf(bar))
    local callsBefore, sweepsBefore = HARNESS.threatCalls, ns.Nameplates.Inspect().sweeps
    sweeps(4)
    local perSweep = (HARNESS.threatCalls - callsBefore) / (ns.Nameplates.Inspect().sweeps - sweepsBefore)
    check("N13 reads stop at the tank", perSweep == 19, perSweep)

-- phase9-baddiag -----------------------------------------------------------------------
elseif HARNESS_SESSION == "phase9-baddiag" then
    local all = table.concat(HARNESS.chat, "\n")
    check("G2 reset once", count(all, "saved diagnostics log was unreadable (WrongShape)") == 1, all)
    local current, sessions = sessionRecord()
    check("G2 only the current record", #sessions == 1)
    plate("nameplate1", { canAttack = true, reaction = 2 }, BLIZZARD_RED)
    sweeps(2)
    check("G2 counting still works", (current.counters.nameplates.sweeps or 0) > 0)
    local long = string.rep("|cffff0000x|r", 60)
    for index = 1, 10 do
        ns.Diagnostics.NoteFault("harnessFaults", "fault " .. index .. " " .. long)
    end
    check("G4 eight notes kept", #current.faults == 8, #current.faults)
    check("G4 dropped counted", ns.Diagnostics.CountersFor("harnessFaults").faultNotesDropped == 2)
    local neutral, bounded = true, true
    for _, note in ipairs(current.faults) do
        if not note.message:find("||cff", 1, true) then
            neutral = false
        end
        if #note.message > 300 then
            bounded = false
        end
    end
    check("G4 neutralized", neutral)
    check("G4 cut to 300", bounded)

-- phase9-noapi -------------------------------------------------------------------------
elseif HARNESS_SESSION == "phase9-noapi" then
    local hostile = plate("nameplate1", { canAttack = true, reaction = 2, targetId = "player", inCombat = true }, BLIZZARD_RED)
    local tapped = plate("nameplate2", { canAttack = true, tapDenied = true, reaction = 2, targetId = "player", inCombat = true }, BLIZZARD_GREY)
    sweeps(9)
    check("N14 hostile keeps Blizzard's colour", near(hostile, unpack(BLIZZARD_RED)), colourOf(hostile))
    check("N14 tapped still grey", near(tapped, unpack(GREY)), colourOf(tapped))
    local all = table.concat(HARNESS.chat, "\n")
    check("N14 surfaced once", count(all, "has no UnitThreatSituation") == 1, all)
    local diag = ns.Diagnostics.CountersFor("nameplates")
    check("N15 unreadable counted", (diag.restrictedMapUnreadable or 0) >= 1, diag.restrictedMapUnreadable)
    check("N15 nothing called", HARNESS.restrictionCalls == 0, HARNESS.restrictionCalls)
end

-- Report -------------------------------------------------------------------------------
local errors = {}
local function expectedFault(index)
    for _, needle in ipairs(HARNESS.expectedFaults or {}) do
        local line, nextLine = HARNESS.chat[index], HARNESS.chat[index + 1] or ""
        if line:find(needle, 1, true) or nextLine:find(needle, 1, true) then
            return true
        end
    end
    return false
end
for index, line in ipairs(HARNESS.chat) do
    if (line:find("raised", 1, true) or line:find("faulted", 1, true)) and not expectedFault(index) then
        errors[#errors + 1] = line
    end
end
HARNESS_RESULT = { passed = passed, failures = failures, errors = errors, chat = HARNESS.chat }
