-- Patch 02 offline checks (Architecture/20261104-Patch02.md section 9.1). Check names
-- follow the design's P-numbers.
--
-- Sessions:
--   "patch02"             QuestieDB 1.0.10's shape: Enum.classKeys published and no
--                         classKeys under Enum.byExpansion.Forever -- the shape whose class
--                         mask the shipped bridge could not read (F3). Also the tidy bags
--                         and listener-origin checks, which do not depend on QuestieDB.
--   "patch02-oldprovider" QuestieDB 1.0.6's shape: classKeys under byExpansion only.
--   "patch02-noprovider"  no QuestieDB at login, with NPC roles stored on.

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

local function chatMark()
    return #HARNESS.chat
end

local function chatSince(mark)
    local lines = {}
    for index = mark + 1, #HARNESS.chat do
        lines[#lines + 1] = HARNESS.chat[index]
    end
    return table.concat(lines, "\n")
end

local function count(text, needle)
    local found, from = 0, 1
    while true do
        local at = text:find(needle, from, true)
        if not at then
            return found
        end
        found = found + 1
        from = at + #needle
    end
end

local function setSetting(feature, key, value)
    ns.ConfigStore.Set(feature, key, value)
    ns.Registry.NotifyConfigChanged(feature, key)
    HARNESS.frame()
end

local SESSION = HARNESS_SESSION
local Bridge = ns.QuestieDBBridge
local STATE = ns.FEATURE_STATE

-- Before login ------------------------------------------------------------------------------
--
-- P11's stored config: 1.10.0's, holding Phase 19's four ring keys. NPC roles are on, so
-- the roles checks need no toggle.
PersonalAddonDB = { schemaVersion = 1, features = {
    nameplates = { enabled = true, settings = {
        npcRoles = true,
        rarityRings = true, rarityRingSize = 1.25, rarityRingOffsetX = 2, rarityRingOffsetY = -1,
    } },
} }

HARNESS.playerLevel = 40
HARNESS.playerClassFile = "WARLOCK" -- 256 in QuestieDB's class keys
if SESSION == "patch02-noprovider" then
    HARNESS.questiePresent = false
elseif SESSION == "patch02" then
    HARNESS.questieShape = "1.0.10"
end
HARNESS.buildQuestie()

-- A class quest at a trainer, for P1 and P3.
local TRAINER = 4001
local WARLOCK_QUEST = HARNESS.addQuest(4101, { name = "Warlock Business", requiredClasses = 256, questLevel = 38 })
HARNESS.startQuestsAt(TRAINER, WARLOCK_QUEST)

local bootMark = chatMark()
HARNESS.fire("ADDON_LOADED", "PersonalAddon")
HARNESS.fire("PLAYER_LOGIN")
HARNESS.frame()
HARNESS.fire("PLAYER_ENTERING_WORLD")
HARNESS.frame()
HARNESS.frame()
local bootChat = chatSince(bootMark)

-- P11: the ring retired (section 5) -----------------------------------------------------------

check("P11 the four ring keys are pruned at hydration, one notice each",
    count(bootChat, "pruned obsolete key 'nameplates.rarityRing") == 4, bootChat)
local storedPlates = PersonalAddonDB.features.nameplates.settings
check("P11 and none survives in the stored config",
    storedPlates.rarityRings == nil and storedPlates.rarityRingSize == nil
        and storedPlates.rarityRingOffsetX == nil and storedPlates.rarityRingOffsetY == nil)
local defaultsHaveRing = false
for key in pairs(ns.Registry.Defaults("nameplates").settings) do
    if key:find("^rarity") then
        defaultsHaveRing = true
    end
end
check("P11 and no default claims a ring key", not defaultsHaveRing)
local platesView = ns.Nameplates.Inspect()
check("P11 and the nameplates report carries no ring",
    platesView.rarityRings == nil and platesView.ringsDrawnNow == nil
        and platesView.classificationWithheld == nil)
local platesMark = chatMark()
slash("plates")
check("P11 and /pa plates prints no ring line", chatSince(platesMark):find("rarity", 1, true) == nil,
    chatSince(platesMark))

-- P6: a two-value failure is still a fault (section 4.5) ----------------------------------------

local probeMark = chatMark()
local okProbe = ns.Registry.SetEnabled("enableFailProbe", true)
check("P6 a two-value nil, reason is still FAULTED, with its line",
    okProbe == false and ns.Registry.State("enableFailProbe") == STATE.FAULTED
        and chatSince(probeMark):find("faulted", 1, true) ~= nil,
    chatSince(probeMark))
ns.Registry.SetEnabled("enableFailProbe", false)

if SESSION == "patch02-noprovider" then

    -- P4, P5: one notice, and UNAVAILABLE rather than FAULTED (sections 4.4, 4.5) --------------

    check("P4 no provider, roles on: exactly one QuestieDB line at login",
        count(bootChat, "QuestieDB is not loaded") == 1, bootChat)
    check("P4 and nothing at login calls it a fault", bootChat:find("faulted", 1, true) == nil, bootChat)
    local unmet = Bridge.Inspect().unmetConsumers
    check("P4 and the bridge lists three consumers, in the order they asked",
        table.concat(unmet, ",") == "nameplates.npcRoles,npcQuests,questMarkers", table.concat(unmet, ","))
    check("P5 both quest features are UNAVAILABLE, not FAULTED",
        ns.Registry.State("npcQuests") == STATE.UNAVAILABLE
            and ns.Registry.State("questMarkers") == STATE.UNAVAILABLE,
        format("%s / %s", tostring(ns.Registry.State("npcQuests")), tostring(ns.Registry.State("questMarkers"))))
    check("P5 and nothing of theirs is left subscribed",
        ns.Dispatch.SubscriptionCount("questMarkers") == 0 and ns.Dispatch.SubscriptionCount("npcQuests") == 0)

    -- P7: the roles stand down once, and no plate asks (section 4.6) --------------------------

    local rolesView = ns.Nameplates.Inspect()
    check("P7 the roles stood down at enable, counted once",
        rolesView.roleCapability == "StoodDown" and rolesView.roleCapabilityStoodDown == 1,
        format("%s / %s", tostring(rolesView.roleCapability), tostring(rolesView.roleCapabilityStoodDown)))
    local friendCalls, subNames = HARNESS.unitIsFriendCalls, HARNESS.subNameCalls
    for index = 1, 5 do
        HARNESS.addPlate20("nameplate" .. index, { npcId = 5000 + index, friend = true })
    end
    HARNESS.frame()
    check("P7 five friendly plates make no friendship and no role read",
        HARNESS.unitIsFriendCalls == friendCalls and HARNESS.subNameCalls == subNames,
        format("friend %d -> %d", friendCalls, HARNESS.unitIsFriendCalls))
    local labelled = 0
    for _, plate in ipairs(ns.Nameplates.TrackedPlates()) do
        if plate.label then
            labelled = labelled + 1
        end
    end
    check("P7 and none carries a label", labelled == 0, labelled)
    check("P7 and the stand-down is still counted once", ns.Nameplates.Inspect().roleCapabilityStoodDown == 1)

    -- P14: /pa on says UNAVAILABLE as information ------------------------------------------------

    local onMark = chatMark()
    slash("on npcQuests")
    local onChat = chatSince(onMark)
    check("P14 /pa on prints UNAVAILABLE as information, not as an error",
        onChat:find("npcQuests -> UNAVAILABLE", 1, true) ~= nil and onChat:find("|cffff5555", 1, true) == nil,
        onChat)

    -- P5: off and on again --------------------------------------------------------------------------

    local okOff = ns.Registry.SetEnabled("questMarkers", false)
    check("P5 an UNAVAILABLE feature disables cleanly",
        okOff == true and ns.Registry.State("questMarkers") == STATE.DISABLED,
        tostring(ns.Registry.State("questMarkers")))
    local okOn, reason = ns.Registry.SetEnabled("questMarkers", true)
    check("P5 and enabling it again answers UNAVAILABLE again, with the reason",
        okOn == false and ns.Registry.State("questMarkers") == STATE.UNAVAILABLE
            and tostring(reason):find("ProviderMissing", 1, true) ~= nil,
        tostring(reason))

    -- P4, second half: with roles off, two consumers ---------------------------------------------

    Bridge.Reset()
    setSetting("nameplates", "npcRoles", false)
    ns.Registry.SetEnabled("npcQuests", false)
    ns.Registry.SetEnabled("npcQuests", true)
    ns.Registry.SetEnabled("questMarkers", false)
    ns.Registry.SetEnabled("questMarkers", true)
    local unmetOff = Bridge.Inspect().unmetConsumers
    check("P4 with roles off: two consumers, and the roles are Off",
        table.concat(unmetOff, ",") == "npcQuests,questMarkers" and ns.Nameplates.Inspect().roleCapability == "Off",
        table.concat(unmetOff, ",") .. " / " .. tostring(ns.Nameplates.Inspect().roleCapability))
    check("P4 and the whole session printed one QuestieDB line", count(chatSince(0), "QuestieDB is not loaded") == 1)
    local questsMark = chatMark()
    slash("quests")
    check("P4 and /pa quests lists what is off",
        chatSince(questsMark):find("off for want of it: npcQuests, questMarkers", 1, true) ~= nil,
        chatSince(questsMark))

else

    local expectedSource = SESSION == "patch02-oldprovider" and "ByExpansion" or "Published"

    check("P4 with the provider there, no QuestieDB line at all",
        count(bootChat, "QuestieDB") == 0 or bootChat:find("QuestieDB is not loaded", 1, true) == nil, bootChat)
    check("P4 and the roles are Available", ns.Nameplates.Inspect().roleCapability == "Available",
        tostring(ns.Nameplates.Inspect().roleCapability))

    -- P13 first, while nothing has been hovered (audit finding 7) --------------------------------

    local unreadableBefore = ns.Diagnostics.CountersFor("npcQuests").playerFactUnreadable or 0
    local questsMark = chatMark()
    slash("quests")
    local questsChat = chatSince(questsMark)
    check("P13 before any hover, /pa quests reads the player's facts now",
        questsChat:find("classMask=256 (" .. expectedSource .. ")", 1, true) ~= nil
            and questsChat:find("nothing hovered yet", 1, true) ~= nil,
        questsChat)
    check("P13 and does not move playerFactUnreadable",
        (ns.Diagnostics.CountersFor("npcQuests").playerFactUnreadable or 0) == unreadableBefore)

    -- P1, P2: the class mask, from where this provider keeps it (section 4.3) ------------------

    local mask, source = Bridge.ClassMask("WARLOCK")
    if SESSION == "patch02-oldprovider" then
        check("P2 1.0.6's shape is read from byExpansion", mask == 256 and source == "ByExpansion",
            format("%s %s", tostring(mask), tostring(source)))
    else
        check("P1 1.0.10's shape is read from the published keys", mask == 256 and source == "Published",
            format("%s %s", tostring(mask), tostring(source)))
    end
    check("P1 and WARRIOR is 1", (Bridge.ClassMask("WARRIOR")) == 1)
    HARNESS.guids.mouseover = HARNESS.creatureGuid(TRAINER)
    HARNESS.hoverUnit("mouseover")
    local offeredText = HARNESS.tooltipText()
    check("P1 the class quest is offered to its class", offeredText:find("Warlock Business", 1, true) ~= nil,
        offeredText)

    if SESSION == "patch02" then

        -- P3: neither table, then an Enum that is not a table ---------------------------------

        HARNESS.questieShape = "none"
        HARNESS.buildQuestie()
        Bridge.Reset()
        local unreadable = ns.Diagnostics.CountersFor("npcQuests").playerFactUnreadable or 0
        local noneMask, noneSource = Bridge.ClassMask("WARLOCK")
        check("P3 with class keys nowhere, the answer is NoClassKeys",
            noneMask == nil and noneSource == "NoClassKeys", tostring(noneSource))
        HARNESS.hoverUnit("mouseover")
        local noneText = HARNESS.tooltipText()
        check("P3 and the class quest is not offered", noneText:find("Warlock Business", 1, true) == nil, noneText)
        check("P3 and the player's facts count as unreadable",
            (ns.Diagnostics.CountersFor("npcQuests").playerFactUnreadable or 0) > unreadable)
        local rejected = table.concat(ns.NPCQuests.Inspect().rejected, ",")
        check("P3 and the rejection is Unreadable, never WrongClass",
            rejected:find("4101=Unreadable", 1, true) ~= nil, rejected)

        HARNESS.questieShape = "enumNotTable"
        HARNESS.buildQuestie()
        Bridge.Reset()
        local ok, oddMask, oddSource = pcall(Bridge.ClassMask, "WARLOCK")
        check("P3 an Enum that is not a table answers NoClassKeys without raising",
            ok and oddMask == nil and oddSource == "NoClassKeys",
            format("%s %s %s", tostring(ok), tostring(oddMask), tostring(oddSource)))

        HARNESS.questieShape = "1.0.10"
        HARNESS.buildQuestie()
        Bridge.Reset()

        -- P8: who created a listening frame (section 3.3) --------------------------------------

        local CallWindow = ns.CallWindow
        local ORIGIN, REASON = CallWindow.ORIGIN, CallWindow.UNKNOWN_REASON
        local function originOf(answer)
            return CallWindow.ListenerOrigin(HARNESS.setSourceLocation(CreateFrame("Frame"), answer))
        end
        local kind, detail = originOf("Interface/AddOns/QuestieTrace/QuestieTrace.lua:719")
        check("P8 an addon's file names the addon", kind == ORIGIN.ADDON and detail == "QuestieTrace",
            format("%s %s", tostring(kind), tostring(detail)))
        kind, detail = originOf("Interface\\AddOns\\questieTrace\\Modules\\x.lua:3")
        check("P8 backslashes and case are tolerated, and the folder keeps its own case",
            kind == ORIGIN.ADDON and detail == "questieTrace", format("%s %s", tostring(kind), tostring(detail)))
        kind = originOf("@Interface/AddOns/Blizzard_CooldownViewer/CooldownViewer.lua:742")
        check("P8 a Blizzard_ folder is Blizzard", kind == ORIGIN.BLIZZARD, tostring(kind))
        kind = originOf("INTERFACE/FRAMEXML/UIParent.lua:1")
        check("P8 a FrameXML path is Blizzard", kind == ORIGIN.BLIZZARD, tostring(kind))
        kind, detail = originOf(HARNESS.SECRET)
        check("P8 a secret location is Unknown(Withheld)", kind == ORIGIN.UNKNOWN and detail == REASON.WITHHELD,
            tostring(detail))
        kind, detail = originOf(false)
        check("P8 a missing method is Unknown(NoLocation), not Withheld (audit finding 1)",
            kind == ORIGIN.UNKNOWN and detail == REASON.NO_LOCATION, tostring(detail))
        kind, detail = originOf("raise")
        check("P8 a raising method is Unknown(NoLocation)", kind == ORIGIN.UNKNOWN and detail == REASON.NO_LOCATION,
            tostring(detail))
        kind, detail = originOf(nil)
        check("P8 a nil answer is Unknown(NoLocation)", detail == REASON.NO_LOCATION, tostring(detail))
        kind, detail = originOf("")
        check("P8 an empty answer is Unknown(NoLocation)", detail == REASON.NO_LOCATION, tostring(detail))
        kind, detail = originOf(42)
        check("P8 a number is Unknown(Unparsed)", kind == ORIGIN.UNKNOWN and detail == REASON.UNPARSED,
            tostring(detail))
        kind, detail = originOf("somewhere else entirely")
        check("P8 a string no rule matches is Unknown(Unparsed)", detail == REASON.UNPARSED, tostring(detail))
        local evilFrame = HARNESS.setSourceLocation(CreateFrame("Frame"), "Interface/AddOns/Evil|cffff0000Red/x.lua:1")
        local _, evilFolder = CallWindow.ListenerOrigin(evilFrame)
        local evilNotice = CallWindow.HoldBackNotice({ ITEM_LOCK_CHANGED = {
            { label = "<unnamed>", origin = ORIGIN.ADDON, folder = evilFolder, frame = evilFrame } }, ITEM_LOCKED = {} })
        check("P8 a folder holding pipes is neutralized in the notice",
            evilNotice:find("Evil||cffff0000Red", 1, true) ~= nil and evilNotice:find("Evil|cff", 1, true) == nil,
            evilNotice)

        -- P15: the notice's wording (section 3.3, audit finding 4) ------------------------------

        local f1, f2, f3 = CreateFrame("Frame"), CreateFrame("Frame"), CreateFrame("Frame")
        local twoOwners = CallWindow.HoldBackNotice({
            ITEM_LOCK_CHANGED = {
                { label = "<unnamed>", origin = ORIGIN.ADDON, folder = "Alpha", frame = f1 },
                { label = "<unnamed>", origin = ORIGIN.ADDON, folder = "Beta", frame = f2 },
            },
            ITEM_LOCKED = {},
        })
        check("P15 two owners are joined by a comma in both places, with listen",
            twoOwners:find("while Alpha, Beta listen for item locks", 1, true) ~= nil
                and twoOwners:find("Disable Alpha, Beta, or", 1, true) ~= nil,
            twoOwners)
        local oneOwner = CallWindow.HoldBackNotice({ ITEM_LOCK_CHANGED = {
            { label = "<unnamed>", origin = ORIGIN.ADDON, folder = "QuestieTrace", frame = f1 } }, ITEM_LOCKED = {} })
        check("P15 one owner takes listens, in the design's exact words",
            oneOwner == "tidy bags is off while QuestieTrace listens for item locks: a sort would run their code "
                .. "inside this addon's call. Disable QuestieTrace, or use Clean Up Bags from the bag menu.",
            oneOwner)
        local unnamedThree = CallWindow.HoldBackNotice({ ITEM_LOCK_CHANGED = {
            { label = "<unnamed>", origin = ORIGIN.UNKNOWN, reason = REASON.NO_LOCATION, frame = f1 },
            { label = "<unnamed>", origin = ORIGIN.UNKNOWN, reason = REASON.NO_LOCATION, frame = f2 },
            { label = "<unnamed>", origin = ORIGIN.BLIZZARD, frame = f3 } }, ITEM_LOCKED = {} })
        check("P15 three unnamed Blizzard-side frames read <unnamed> x3, with listen",
            unnamedThree:find("tidy bags is waiting: <unnamed> x3 listen for item locks", 1, true) ~= nil,
            unnamedThree)
        local bothEvents = CallWindow.HoldBackNotice({
            ITEM_LOCK_CHANGED = { { label = "CharacterHeadSlot", origin = ORIGIN.BLIZZARD, frame = f1 } },
            ITEM_LOCKED = { { label = "CharacterHeadSlot", origin = ORIGIN.BLIZZARD, frame = f1 } },
        })
        check("P15 a frame listening to both events is named once",
            bothEvents:find("waiting: CharacterHeadSlot listens for item locks", 1, true) ~= nil
                and count(bothEvents, "CharacterHeadSlot") == 1,
            bothEvents)

        -- P9, P10, P12: tidy bags held by an addon (sections 3.2, 3.4) -------------------------

        local function closeBag()
            ContainerFrameCombinedBags:Show()
            HARNESS.frame()
            ContainerFrameCombinedBags:Hide()
            HARNESS.frame()
            HARNESS.frame()
        end
        local function faultNotes()
            local sessions = PersonalAddonDiagnostics and PersonalAddonDiagnostics.sessions
            local record = sessions and sessions[#sessions]
            return record and record.faults or {}
        end
        local function notesContaining(needle)
            local found = 0
            for _, note in ipairs(faultNotes()) do
                if tostring(note.message):find(needle, 1, true) then
                    found = found + 1
                end
            end
            return found
        end

        check("P9 tidy bags is enabled", ns.Registry.State("autoSortBags") == STATE.ENABLED,
            tostring(ns.Registry.State("autoSortBags")))
        -- QuestieTrace as the live client showed it: an unnamed frame registered at load.
        local trace = HARNESS.setSourceLocation(CreateFrame("Frame"), "Interface/AddOns/QuestieTrace/QuestieTrace.lua:719")
        rawset(trace, "GetDebugName", function() return "" end)
        trace:RegisterEvent("ITEM_LOCK_CHANGED")
        HARNESS.sortCalls = 0
        HARNESS.advance(61)
        local bagMark = chatMark()
        closeBag()
        local bagChat = chatSince(bagMark)
        check("P9 an addon-only listener still holds the sort (D1)",
            HARNESS.sortCalls == 0 and ns.AutoSortBags.Inspect().lastSkip == "ListenersPresent",
            format("sorts=%d last=%s", HARNESS.sortCalls, tostring(ns.AutoSortBags.Inspect().lastSkip)))
        check("P9 and the notice names the addon",
            bagChat:find("tidy bags is off while QuestieTrace listens for item locks", 1, true) ~= nil, bagChat)
        local diag = ns.Diagnostics.CountersFor("autoSortBags")
        check("P10 the skip and its owner are counted where they survive a reload",
            (diag.skipListenersPresent or 0) == 1 and (diag.holdBacksByAddOn or 0) == 1,
            format("skip=%s addOn=%s", tostring(diag.skipListenersPresent), tostring(diag.holdBacksByAddOn)))
        -- Describe sorts its parts, and "ITEM_LOCKED" sorts before "ITEM_LOCK_CHANGED".
        check("P10 and one note carries the description",
            notesContaining("tidy bags held back: ITEM_LOCKED: none; ITEM_LOCK_CHANGED: <unnamed> (QuestieTrace)") == 1,
            notesContaining("tidy bags held back"))

        HARNESS.advance(61)
        local againMark = chatMark()
        closeBag()
        check("P10 the same listeners again: counted, with no second line and no second note",
            (diag.skipListenersPresent or 0) == 2 and chatSince(againMark):find("tidy bags is off", 1, true) == nil
                and notesContaining("tidy bags held back") == 1,
            chatSince(againMark))

        local bagsMark = chatMark()
        slash("bags")
        local bagsReport = chatSince(bagsMark)
        check("P12 /pa bags names the owner now and for the last hold-back, and prints the counters",
            bagsReport:find("listening now: ITEM_LOCKED: none; ITEM_LOCK_CHANGED: <unnamed> (QuestieTrace)", 1, true) ~= nil
                and bagsReport:find("last held back by: ITEM_LOCKED: none; ITEM_LOCK_CHANGED: <unnamed> (QuestieTrace)", 1, true) ~= nil
                and bagsReport:find("held back: addon=2", 1, true) ~= nil,
            bagsReport)

        -- Past the note capacity: every new listener set is a new description.
        local extras = {}
        for index = 1, ns.DIAGNOSTICS_FAULT_NOTE_CAPACITY + 1 do
            local extra = CreateFrame("Frame", "ExtraListener" .. index)
            extra:RegisterEvent("ITEM_LOCK_CHANGED")
            extras[#extras + 1] = extra
            HARNESS.advance(61)
            closeBag()
        end
        check("P10 past the note capacity, the refusal is counted and the notes stay bounded",
            (diag.faultNotesDropped or 0) >= 1 and #faultNotes() <= ns.DIAGNOSTICS_FAULT_NOTE_CAPACITY,
            format("dropped=%s notes=%d", tostring(diag.faultNotesDropped), #faultNotes()))

        trace:UnregisterEvent("ITEM_LOCK_CHANGED")
        for _, extra in ipairs(extras) do
            extra:UnregisterEvent("ITEM_LOCK_CHANGED")
        end
        HARNESS.advance(61)
        local sortsBefore = HARNESS.sortCalls
        closeBag()
        check("P9 with nothing listening, the sort runs", HARNESS.sortCalls == sortsBefore + 1,
            format("%d -> %d", sortsBefore, HARNESS.sortCalls))
        HARNESS.flushEvents()
    end
end

HARNESS_RESULT = { passed = passed, failures = failures,
                   errors = HARNESS.errors or {}, chat = HARNESS.chat or {} }
