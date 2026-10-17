-- Core/QuestieDBBridge.lua
-- The one way into QuestieDB (Architecture/20261011-Phase17.md section 2).
--
-- QuestieDB is a separate addon that ships the database Questie consumes, and it
-- loads without Questie: its src/api.lua says so outright ("Questie is the first
-- consumer, but nothing here assumes it"). On this machine it is 1.0.5, contract 3,
-- baked mode, Forever flavour.
--
-- WHY A BRIDGE RATHER THAN CALLS FROM EACH FEATURE.
--
-- 1. EVERY TABLE READ ALLOCATES. src/read/shared.lua: "Table reads return a fresh,
--    mutable, deeply independent copy on every read." NpcDB.questStarts and
--    QuestDB.objectives would otherwise deep-copy on a tooltip mouseover and on
--    every quest-log change. Everything is copied in once here and cached per id.
-- 2. TWO GATES, NOT ONE. RequireContract covers the contract; nothing in QuestieDB
--    stops the user installing the Cata TOC, which answers every call with a
--    straight face and gives wrong quest levels. The flavour is checked too.
-- 3. ITS STRINGS ARE THIRD-PARTY DATA. RegisterCorrection is public, so any other
--    addon can inject a quest name. Everything that leaves here is neutralized
--    before it is drawn, for the reason Phase 15 neutralizes a guild name.
--
-- Nothing is ever written back. RegisterCorrection, SetCorrection and
-- InvalidateCache exist and are not called.

local ADDON_NAME, ns = ...

local QuestieDBBridge = {}
ns.QuestieDBBridge = QuestieDBBridge

local type, pcall, pairs, format, floor = type, pcall, pairs, string.format, math.floor
local ClientRead = ns.ClientRead

QuestieDBBridge.STATE = {
    AVAILABLE = "Available",
    PROVIDER_MISSING = "ProviderMissing",
    CONTRACT_MISMATCH = "ContractMismatch",
    WRONG_FLAVOR = "WrongFlavor",
    ERRORED = "Errored",
}
local STATE = QuestieDBBridge.STATE

local state = {
    resolved = false,
    kind = nil,
    detail = nil,
    contract = nil,
    mode = nil,
    flavor = nil,

    startsByNpc = {},
    startsCount = 0,
    factsByQuest = {},
    factsCount = 0,
    claimsByQuest = {},
    claimsCount = 0,

    reads = 0,
    hits = 0,
}

local function counters()
    return ns.Diagnostics.CountersFor("questieBridge")
end

-- Gates (section 2.3) -----------------------------------------------------------------

local function resolveState()
    if state.resolved then
        return state.kind, state.detail
    end
    state.resolved = true

    local lib = _G.LibQuestieDB
    if type(lib) ~= "table" or type(_G.QuestDB) ~= "table" or type(_G.NpcDB) ~= "table" then
        state.kind = STATE.PROVIDER_MISSING
        return state.kind
    end

    -- A range check, not equality: QuestieDB's own comment explains that a consumer
    -- written against an older contract keeps working across additive releases.
    local required = ns.QUESTIE_REQUIRED_CONTRACT
    local ok, accepted, message = pcall(lib.RequireContract, required)
    if not ok then
        state.kind, state.detail = STATE.ERRORED, "RequireContract raised"
        return state.kind, state.detail
    end
    if not accepted then
        state.kind = STATE.CONTRACT_MISMATCH
        state.detail = type(message) == "string" and message
            or format("this addon needs QuestieDB contract %d", required)
        return state.kind, state.detail
    end

    local contractKind, contract = ClientRead.Field(lib, "contractVersion", "number")
    state.contract = contractKind == ClientRead.PLAIN and contract or nil
    local modeKind, mode = ClientRead.Field(lib, "readMode", "string")
    state.mode = modeKind == ClientRead.PLAIN and mode or nil

    -- The gate RequireContract cannot do. Seven flavour TOCs sit in that folder; the
    -- wrong one answers everything and is wrong about all of it.
    local flavorKind, flavor = ClientRead.Field(lib, "flavor", "table")
    if flavorKind == ClientRead.PLAIN then
        local nameKind, name = ClientRead.Field(flavor, "name", "string")
        if nameKind == ClientRead.PLAIN then
            state.flavor = name
            if name ~= ns.QUESTIE_REQUIRED_FLAVOR then
                state.kind, state.detail = STATE.WRONG_FLAVOR, name
                return state.kind, state.detail
            end
        end
    end

    state.kind = STATE.AVAILABLE
    return state.kind
end

function QuestieDBBridge.State()
    local kind, detail = resolveState()
    return kind, detail
end

function QuestieDBBridge.IsAvailable()
    return (resolveState()) == STATE.AVAILABLE
end

function QuestieDBBridge.Describe()
    local kind, detail = resolveState()
    if kind == STATE.AVAILABLE then
        return format("Available (contract %s, %s mode, %s flavour)",
            tostring(state.contract), tostring(state.mode), tostring(state.flavor))
    end
    return detail and format("%s: %s", kind, tostring(detail)) or tostring(kind)
end

-- A mask test that survives Forever's bits 32 and 33 (section 2.2).
--
-- QuestieDB's expansions.lua:33 says why: "Adding distinct bits avoids truncating
-- Forever's bits 32/33 through the client's 32-bit bit library." Race IDs 95 and 96
-- carry 4294967296 and 8589934592, so bit.band would drop them and a Skyborne
-- character would fail every quest restricted to their own race.
function QuestieDBBridge.MaskHolds(mask, bit)
    if type(mask) ~= "number" or type(bit) ~= "number" or bit <= 0 then
        return false
    end
    return floor(mask / bit) % 2 == 1
end

-- The player's masks, in QuestieDB's numbering (section 3.3).
function QuestieDBBridge.RaceMask(raceId)
    if not QuestieDBBridge.IsAvailable() or type(raceId) ~= "number" then
        return nil
    end
    local enumKind, enum = ClientRead.Field(_G.LibQuestieDB, "Enum", "table")
    if enumKind ~= ClientRead.PLAIN then
        return nil
    end
    local byIdKind, byId = ClientRead.Field(enum, "raceMaskById", "table")
    if byIdKind ~= ClientRead.PLAIN then
        return nil
    end
    local maskKind, mask = ClientRead.Field(byId, raceId, "number")
    return maskKind == ClientRead.PLAIN and mask or nil
end

function QuestieDBBridge.ClassMask(classFileName)
    if not QuestieDBBridge.IsAvailable() or type(classFileName) ~= "string" then
        return nil
    end
    local lib = _G.LibQuestieDB
    local enumKind, enum = ClientRead.Field(lib, "Enum", "table")
    local flavorKind, flavor = ClientRead.Field(lib, "flavor", "table")
    if enumKind ~= ClientRead.PLAIN or flavorKind ~= ClientRead.PLAIN then
        return nil
    end
    local expansionKind, expansion = ClientRead.Field(flavor, "expansion", "string")
    local byExpansionKind, byExpansion = ClientRead.Field(enum, "byExpansion", "table")
    if expansionKind ~= ClientRead.PLAIN or byExpansionKind ~= ClientRead.PLAIN then
        return nil
    end
    local setKind, set = ClientRead.Field(byExpansion, expansion, "table")
    if setKind ~= ClientRead.PLAIN then
        return nil
    end
    local keysKind, keys = ClientRead.Field(set, "classKeys", "table")
    if keysKind ~= ClientRead.PLAIN then
        return nil
    end
    local maskKind, mask = ClientRead.Field(keys, classFileName, "number")
    return maskKind == ClientRead.PLAIN and mask or nil
end

-- Reads, each cached (section 2.4) ----------------------------------------------------

local function noteRead()
    state.reads = state.reads + 1
    ns.Diagnostics.Bump(counters(), "bridgeReads")
end

local function noteHit()
    state.hits = state.hits + 1
    ns.Diagnostics.Bump(counters(), "cacheHits")
end

local function roomFor(field, countField, capacity)
    if state[countField] >= capacity then
        state[field] = {}
        state[countField] = 0
        ns.Diagnostics.Bump(counters(), "cacheEmptied")
    end
end

-- A number from a named getter, or a default. Scalars are cheap to read and are not
-- what section 2.4 is about; they are cached with the rest of the quest's facts.
local function scalar(entity, getterName, id, fallback)
    local getter = entity[getterName]
    if type(getter) ~= "function" then
        return fallback
    end
    local kind, value = ClientRead.Call(getter, "number", id)
    if kind ~= ClientRead.PLAIN then
        return fallback
    end
    return value
end

-- A list of ids, copied into a table we own. QuestieDB handed us a fresh deep copy
-- and we do not keep it: an id list we retain cannot then be reached, or corrupted,
-- through a later read of theirs.
-- Returns the id list AND whether the read answered at all (Phase 18 section 5.1).
--
-- The second return is the distinction the Phase 17 cache defect collapsed. Four
-- situations used to come back as the same bare {}:
--
--   the getter is absent          -- not an answer
--   the getter raised             -- not an answer
--   the getter returned nil       -- AN ANSWER: "this entity has none of these",
--                                    and the commonest one QuestieDB gives
--   the getter returned an empty
--     or unusable table           -- an answer, emptily
--
-- Callers must cache the answers and must not cache the non-answers. Caching a
-- non-answer is what kept the quest markers empty until a relog; NOT caching the
-- nil answer would re-read QuestieDB on every mouseover of every guard, vendor and
-- critter in the world, which is the cache bypass Phase 17's audit finding 18
-- required negative caching to prevent. Both halves matter.
local function copyIdList(entity, getterName, id)
    local getter = entity[getterName]
    if type(getter) ~= "function" then
        return {}, false
    end
    local ok, value = pcall(getter, id)
    if not ok then
        return {}, false
    end
    -- A genuine nil is QuestieDB saying "none", which is an answer worth caching.
    if value == nil then
        return {}, true
    end
    if ClientRead.Classify(value, "table") ~= ClientRead.PLAIN then
        -- Withheld or the wrong shape: the getter ran but told us nothing usable.
        return {}, false
    end
    local out = {}
    for index = 1, #value do
        local entry = value[index]
        if ClientRead.Classify(entry, "number") == ClientRead.PLAIN then
            out[#out + 1] = entry
        end
    end
    return out, true
end

local function noteReadFailed()
    ns.Diagnostics.Bump(counters(), "readFailed")
end

-- Which quests one NPC starts. A negative answer is cached too: most of the world's
-- NPCs start no quest, and not caching that would defeat the cache on every critter,
-- guard and vendor hovered (audit finding 18).
function QuestieDBBridge.QuestsStartedBy(npcId)
    if not QuestieDBBridge.IsAvailable() or type(npcId) ~= "number" then
        return ns.EMPTY_LIST
    end
    local cached = state.startsByNpc[npcId]
    if cached then
        noteHit()
        return cached
    end
    noteRead()
    roomFor("startsByNpc", "startsCount", ns.QUEST_BRIDGE_CACHE_CAPACITY)
    local list, answered = copyIdList(_G.NpcDB, "questStarts", npcId)
    if not answered then
        -- Nothing cached, so the next hover asks again. An empty ANSWER still
        -- caches below -- that is the common case and the cache's whole point.
        noteReadFailed()
        return list
    end
    state.startsByNpc[npcId] = list
    state.startsCount = state.startsCount + 1
    return list
end

-- One quest's facts. The id lists are copies (audit finding 9): tests 7 to 9 of
-- section 3.3 need them, so "scalars only" was never a workable invariant -- the one
-- that matters is that nothing QuestieDB handed us is retained by reference.
function QuestieDBBridge.QuestFacts(questId)
    if not QuestieDBBridge.IsAvailable() or type(questId) ~= "number" then
        return nil
    end
    local cached = state.factsByQuest[questId]
    if cached ~= nil then
        noteHit()
        return cached ~= false and cached or nil
    end
    noteRead()
    roomFor("factsByQuest", "factsCount", ns.QUEST_BRIDGE_CACHE_CAPACITY)

    local quests = _G.QuestDB
    local nameKind, name
    local nameAnswered = false
    if type(quests.name) == "function" then
        nameKind, name = ClientRead.Call(quests.name, "string", questId)
        -- PLAIN is an answer. So is a call that ran and returned nothing usable
        -- for a quest id QuestieDB simply does not carry -- but a WITHHELD read
        -- caused by the call failing is not, and ClientRead distinguishes the two
        -- by its reason. Only CALL_FAILED and UNAVAILABLE mean "did not answer".
        if nameKind == ClientRead.PLAIN then
            nameAnswered = true
        elseif name ~= ClientRead.CALL_FAILED and name ~= ClientRead.UNAVAILABLE then
            nameAnswered = true
        end
    end
    local facts = {
        questId = questId,
        name = nameKind == ClientRead.PLAIN and name or nil,
        questLevel = scalar(quests, "questLevel", questId, 0),
        requiredLevel = scalar(quests, "requiredLevel", questId, 0),
        requiredMaxLevel = scalar(quests, "requiredMaxLevel", questId, 0),
        requiredRaces = scalar(quests, "requiredRaces", questId, 0),
        requiredClasses = scalar(quests, "requiredClasses", questId, 0),
        preQuestSingle = copyIdList(quests, "preQuestSingle", questId),
        preQuestGroup = copyIdList(quests, "preQuestGroup", questId),
        exclusiveTo = copyIdList(quests, "exclusiveTo", questId),
    }
    -- A quest QuestieDB does not know has no name and no level at all. Cached as
    -- false so the next lookup is a hit rather than another miss.
    --
    -- Phase 18 section 5.1: this test alone cannot tell an unknown quest from an
    -- unreadable one, because a failed read produces exactly the same three
    -- values -- scalar() falls back to 0 and name is nil whenever the read was not
    -- PLAIN. So false is cached only when the name read ANSWERED. Otherwise
    -- nothing is cached and the next lookup asks again, which is what the markers
    -- needed and did not have before a relog.
    if facts.name == nil and facts.questLevel == 0 and facts.requiredLevel == 0 then
        if not nameAnswered then
            noteReadFailed()
            return nil
        end
        state.factsByQuest[questId] = false
        state.factsCount = state.factsCount + 1
        return nil
    end
    state.factsByQuest[questId] = facts
    state.factsCount = state.factsCount + 1
    return facts
end

-- Which slot of QuestieDB's objectives tuple comes FIRST for one quest
-- (Phase 19 section 2.2).
--
-- LibQuestieDB.ObjectiveFirst is published API -- src/corrections/_end.lua:18, fed by
-- src/corrections/compat.lua:39-45, whose own comment calls these "consumer hints
-- about objective ordering, not entity data, so they are collected and published
-- rather than merged into the database". The Forever flavour carries four
-- (src/corrections/Forever/foreverQuestFixes.lua:15-18): quests 92682, 97277 and
-- 97485 put their item objective first and 94489 its kill-credit objective.
--
-- eventObjectiveFirst is deliberately not consulted. It names a client objective
-- QuestieDB models no row for, so a quest carrying it must fail the pairing's count
-- check and fall back to quest-level completion rather than be reordered into a
-- pairing that cannot be right.
--
-- Nothing here is a premise: the hints live in a third-party addon, which the patch
-- check cannot see (Phase 19 section 8). An absent, renamed or unreadable hint table
-- therefore answers nil, and the caller keeps the default slot order -- which is the
-- behaviour this bridge had before the hints were found.
function QuestieDBBridge.ObjectiveFirstSlot(questId)
    if not QuestieDBBridge.IsAvailable() or type(questId) ~= "number" then
        return nil
    end
    local hintsKind, hints = ClientRead.Field(_G.LibQuestieDB, "ObjectiveFirst", "table")
    if hintsKind ~= ClientRead.PLAIN then
        return nil
    end
    for index = 1, #ns.QUEST_OBJECTIVE_FIRST_FIELDS do
        local entry = ns.QUEST_OBJECTIVE_FIRST_FIELDS[index]
        local setKind, set = ClientRead.Field(hints, entry.field, "table")
        if setKind == ClientRead.PLAIN then
            local flagKind, flag = ClientRead.Field(set, questId, "boolean")
            if flagKind == ClientRead.PLAIN and flag then
                return entry.slot
            end
        end
    end
    return nil
end

-- The NPC ids one quest names as something to kill, each tagged with the objective
-- row that named it (Phase 19 section 3; Phase 17 section 4.2 for the sources).
--
-- FOUR SOURCES, and the first in-game run is why. An earlier version took only the
-- two that name a creature directly, and found three target ids for a whole quest
-- log: 26 nameplates were offered and 18 of them resolved an id that was not in the
-- set. The reasoning for excluding the others -- "items and objects have no
-- nameplate" -- was true and beside the point, because the CREATURES THAT DROP A
-- QUEST ITEM do have one, and most "go and kill those things" quests are item
-- collection quests underneath.
--
--   objectives[1]  creature kills       {npcId, text, count}
--   objectives[5]  kill credit          {npcId[], creditNpcId, text, count}
--   objectives[3]  item collection      {itemId, text, count}
--                    -> ItemDB.npcDrops(itemId), the NPCs that drop it
--   extraObjectives                     {spawns, zone, text, icon, reference[]}
--                    -> every reference of the form {"monster", npcId}
--
-- Objects (slot 2) and spells (slot 6) name no creature to kill, but their ROWS ARE
-- STILL COUNTED: they occupy client objective indices, and a slot whose rows are not
-- counted shifts every index after it (Phase 19 section 2.2).
--
-- SLOT 4 IS NOT A LIST. Types/General.t.lua:46 types the tuple as
-- {creature[], object[], item[], reputationPair, killCredit[], spell[]} -- slot 4 is
-- a single {factionId, amount} pair, so #objectives[4] is 2 and counting it that way
-- would inflate the row total by one and turn every reputation quest into a
-- CountMismatch (Phase 19 audit finding 5).
--
-- WHAT "ANSWERED" NOW COVERS. Phase 18 section 5 established that this cache may
-- keep an answer and must not keep a non-answer, because nothing invalidates it. The
-- item slot reaches a SECOND entity -- ItemDB.npcDrops -- and a failed read there is
-- indistinguishable from "nothing drops this item", so it counts as a non-answer
-- too. Caching it would hide the markers on every mob that drops a quest item until
-- the user relogged, which is Phase 18's defect in a new place (audit finding 7).
function QuestieDBBridge.KillClaimsForQuest(questId)
    if not QuestieDBBridge.IsAvailable() or type(questId) ~= "number" then
        return ns.EMPTY_CLAIM_SHAPE
    end
    local cached = state.claimsByQuest[questId]
    if cached then
        noteHit()
        return cached
    end
    noteRead()
    roomFor("claimsByQuest", "claimsCount", ns.QUEST_BRIDGE_CACHE_CAPACITY)

    local SLOT = ns.QUEST_OBJECTIVE_SLOT
    local claims, extraNpcIds = {}, {}
    local rowsBySlot = { [1] = 0, [2] = 0, [3] = 0, [4] = 0, [5] = 0, [6] = 0 }
    local claimed, extraSeen = {}, {}
    local budget = ns.QUEST_TARGETS_PER_QUEST_MAXIMUM
    local capped = false

    -- claims and extraNpcIds share one budget, so one quest cannot fill the marker
    -- set however its ids arrive (section 3).
    local function spent()
        return #claims + #extraNpcIds
    end

    -- Distinct by (npcId, slot, row), NOT by npcId: a creature that must be killed
    -- AND drops the quest's item is two claims, and collapsing them would drop its
    -- marker as soon as the first of the two finished (audit finding 8).
    local function addClaim(npcId, slot, row)
        if ClientRead.Classify(npcId, "number") ~= ClientRead.PLAIN then
            return
        end
        if spent() >= budget then
            capped = true
            return
        end
        local key = npcId .. ":" .. slot .. ":" .. row
        if claimed[key] then
            return
        end
        claimed[key] = true
        claims[#claims + 1] = { npcId = npcId, slot = slot, row = row }
    end

    -- Distinct by npcId, and never an id a paired claim already covers: a
    -- quest-level claim beside a paired one for the same mob could only keep a
    -- satisfied marker alive (section 3).
    local function addExtra(npcId)
        if ClientRead.Classify(npcId, "number") ~= ClientRead.PLAIN then
            return
        end
        if spent() >= budget then
            capped = true
            return
        end
        if extraSeen[npcId] then
            return
        end
        extraSeen[npcId] = true
        extraNpcIds[#extraNpcIds + 1] = npcId
    end

    local answered = true

    local getter = _G.QuestDB and _G.QuestDB.objectives
    if type(getter) ~= "function" then
        answered = false
    else
        local ok, objectives = pcall(getter, questId)
        if not ok then
            answered = false
        elseif objectives ~= nil
            and ClientRead.Classify(objectives, "table") ~= ClientRead.PLAIN then
            answered = false
        end
        if ok and ClientRead.Classify(objectives, "table") == ClientRead.PLAIN then
            -- Slot 1: {npcId, text, count}
            local creatures = objectives[SLOT.CREATURE_KILL]
            if type(creatures) == "table" then
                rowsBySlot[SLOT.CREATURE_KILL] = #creatures
                for row = 1, #creatures do
                    local entry = creatures[row]
                    if type(entry) == "table" then
                        addClaim(entry[1], SLOT.CREATURE_KILL, row)
                    end
                end
            end

            -- Slot 2: objects. No nameplate, so no claim -- but the rows count.
            local objects = objectives[SLOT.OBJECT]
            if type(objects) == "table" then
                rowsBySlot[SLOT.OBJECT] = #objects
            end

            -- Slot 3: {itemId, text, count}. The item has no nameplate; what drops
            -- it does. ItemDB.npcDrops is the published way across
            -- (Types/Item.t.lua), and its failure clears `answered`.
            local items = objectives[SLOT.ITEM]
            if type(items) == "table" then
                rowsBySlot[SLOT.ITEM] = #items
                local drops = _G.ItemDB and _G.ItemDB.npcDrops
                for row = 1, #items do
                    local entry = items[row]
                    if type(entry) == "table"
                        and ClientRead.Classify(entry[1], "number") == ClientRead.PLAIN then
                        if type(drops) ~= "function" then
                            answered = false
                        else
                            local dropOk, droppers = pcall(drops, entry[1])
                            if not dropOk then
                                answered = false
                            elseif droppers ~= nil
                                and ClientRead.Classify(droppers, "table") ~= ClientRead.PLAIN then
                                -- A genuine nil is an answer -- nothing drops it --
                                -- so only an unusable value clears `answered`.
                                answered = false
                            elseif droppers ~= nil then
                                for position = 1, #droppers do
                                    addClaim(droppers[position], SLOT.ITEM, row)
                                end
                            end
                        end
                    end
                end
            end

            -- Slot 4: a single {factionId, amount} pair. One row when it is there.
            local reputation = objectives[SLOT.REPUTATION]
            if type(reputation) == "table"
                and ClientRead.Classify(reputation[1], "number") == ClientRead.PLAIN then
                rowsBySlot[SLOT.REPUTATION] = 1
            end

            -- Slot 5: {npcId[], creditNpcId, text, count}
            local credits = objectives[SLOT.KILL_CREDIT]
            if type(credits) == "table" then
                rowsBySlot[SLOT.KILL_CREDIT] = #credits
                for row = 1, #credits do
                    local entry = credits[row]
                    if type(entry) == "table" then
                        local list = entry[1]
                        if type(list) == "table" then
                            for position = 1, #list do
                                addClaim(list[position], SLOT.KILL_CREDIT, row)
                            end
                        end
                        addClaim(entry[2], SLOT.KILL_CREDIT, row)
                    end
                end
            end

            -- Slot 6: spells. No creature named, but the rows count.
            local spells = objectives[SLOT.SPELL]
            if type(spells) == "table" then
                rowsBySlot[SLOT.SPELL] = #spells
            end
        end
    end

    -- extraObjectives: Questie's own "hidden special objectives", whose fifth slot
    -- holds references and whose "monster" references are npc ids. These have NO
    -- client objective, so they are never paired and always carry QUEST_LEVEL.
    local extraGetter = _G.QuestDB and _G.QuestDB.extraObjectives
    if type(extraGetter) ~= "function" then
        answered = false
    else
        local extraOk, extras = pcall(extraGetter, questId)
        if not extraOk then
            answered = false
        elseif extras ~= nil
            and ClientRead.Classify(extras, "table") ~= ClientRead.PLAIN then
            answered = false
        end
        if extraOk and ClientRead.Classify(extras, "table") == ClientRead.PLAIN then
            for index = 1, #extras do
                local row = extras[index]
                if type(row) == "table" and type(row[5]) == "table" then
                    local references = row[5]
                    for position = 1, #references do
                        local reference = references[position]
                        if type(reference) == "table" and reference[1] == "monster" then
                            addExtra(reference[2])
                        end
                    end
                end
            end
        end
    end

    if capped then
        ns.Diagnostics.Bump(counters(), "questTargetsCapped")
    end

    -- An id a paired claim already covers is dropped from the extras: a QUEST_LEVEL
    -- claim beside a paired one for the same mob could only keep a satisfied marker
    -- alive (section 3).
    if #extraNpcIds > 0 and #claims > 0 then
        local pairedNpcIds = {}
        for index = 1, #claims do
            pairedNpcIds[claims[index].npcId] = true
        end
        local kept = {}
        for index = 1, #extraNpcIds do
            local npcId = extraNpcIds[index]
            if not pairedNpcIds[npcId] then
                kept[#kept + 1] = npcId
            end
        end
        extraNpcIds = kept
    end

    local shape = {
        claims = claims,
        extraNpcIds = extraNpcIds,
        rowsBySlot = rowsBySlot,
        answered = answered,
    }

    -- Cached only if every source answered. An ANSWERED-EMPTY shape is cached, and
    -- deliberately: "this quest names no creature" is a true answer for an escort, a
    -- delivery or a talk-to quest, and re-reading those on every rebuild is what the
    -- cache exists to avoid. A non-answer caches nothing, so the next rebuild asks
    -- again instead of waiting for a relog (Phase 18 section 5).
    if not answered then
        noteReadFailed()
        return shape
    end
    state.claimsByQuest[questId] = shape
    state.claimsCount = state.claimsCount + 1
    return shape
end

-- The flat id list Phase 17 shipped, derived from the claims above.
--
-- Phase 19 section 3 said this accessor was replaced because QuestMarkers was its
-- only caller. That was wrong: tests17 and tests18 call it too, and an earlier
-- session that still passes is worth more than a deleted six-line accessor. The
-- cache lives once, in the claims path; this only flattens it.
function QuestieDBBridge.KillTargetsForQuest(questId)
    local shape = QuestieDBBridge.KillClaimsForQuest(questId)
    local out, seen = {}, {}
    for index = 1, #shape.claims do
        local npcId = shape.claims[index].npcId
        if not seen[npcId] then
            seen[npcId] = true
            out[#out + 1] = npcId
        end
    end
    for index = 1, #shape.extraNpcIds do
        local npcId = shape.extraNpcIds[index]
        if not seen[npcId] then
            seen[npcId] = true
            out[#out + 1] = npcId
        end
    end
    return out
end

-- An NPC's name, for /pa quests only. Neutralized by the caller before drawing.
function QuestieDBBridge.NpcName(npcId)
    if not QuestieDBBridge.IsAvailable() or type(npcId) ~= "number" then
        return nil
    end
    local getter = _G.NpcDB and _G.NpcDB.name
    if type(getter) ~= "function" then
        return nil
    end
    local kind, name = ClientRead.Call(getter, "string", npcId)
    return kind == ClientRead.PLAIN and name or nil
end

function QuestieDBBridge.Inspect()
    local kind, detail = resolveState()
    return {
        state = kind,
        detail = detail,
        described = QuestieDBBridge.Describe(),
        contract = state.contract,
        mode = state.mode,
        flavor = state.flavor,
        reads = state.reads,
        hits = state.hits,
        cachedNpcs = state.startsCount,
        cachedQuests = state.factsCount,
        cachedTargets = state.claimsCount,
    }
end

-- Tests reach this to start a session over; nothing in the addon calls it.
function QuestieDBBridge.Reset()
    state.resolved = false
    state.kind, state.detail = nil, nil
    state.contract, state.mode, state.flavor = nil, nil, nil
    state.startsByNpc, state.startsCount = {}, 0
    state.factsByQuest, state.factsCount = {}, 0
    state.claimsByQuest, state.claimsCount = {}, 0
    state.reads, state.hits = 0, 0
end
