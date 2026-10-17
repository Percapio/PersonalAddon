-- Features/QuestMarkers.lua
-- A marker over any monster an active quest names
-- (Architecture/20261011-Phase17.md section 4).
--
-- WHAT THE MARKER MEANS, exactly: "an objective of an active quest still wants this
-- mob" (Architecture/20261016-Phase19.md section 2). Phase 17 meant only "an active
-- quest names this mob" and said tracking progress would need a read per quest and a
-- plate sweep per kill; the second half was wrong. Progress is announced, not
-- sampled: C_QuestLog.GetQuestObjectives carries a finished flag per objective, and
-- QUEST_LOG_UPDATE -- the trigger this feature already coalesces -- follows every
-- objective that moves. Two client calls per quest per burst, and no per-kill sweep.
--
-- The one setting that changes the meaning back is markersIgnoreProgress (D6). When
-- it is on, no objective and no completion is read and every claim is outstanding,
-- which is Phase 17's marker exactly. /pa quests states which meaning is in force,
-- because nothing on the plate can.
--
-- NAMEPLATES OWNS THE LIFECYCLE. Phase 15 already owns the plate record and its
-- attach and detach, and Phase 15 section 3.4 recorded that the order between our
-- NAME_PLATE_UNIT_ADDED handler and anyone else's is not ours to choose. A second
-- subscription here would race it for the same record, so the two call-outs in
-- trackPlate and untrackPlate are the only way in -- and the set they build is the
-- only way to reach a plate already on screen, because state.plates over there is
-- file-local and exports nothing.
--
-- IT STANDS DOWN IN DUNGEONS AND RAIDS (D9). UnitGUID is
-- SecretWhenUnitIdentityRestricted, so the NPC behind a plate cannot be identified
-- on a restricted map. Marking whichever plates happened to read would make the
-- ABSENCE of a marker meaningless, which is worse than no markers at all in a place
-- where plates are read under pressure.

local ADDON_NAME, ns = ...

local FEATURE_ID = "questMarkers"

local format, type, pcall, pairs = string.format, type, pcall, pairs
local ClientRead = ns.ClientRead
local Bridge = ns.QuestieDBBridge

local READING = {
    SHOWN = "Shown",
    NOT_A_TARGET = "NotATarget",
    RELEASED = "Released",
    WITHHELD = "Withheld",
    STOOD_DOWN = "StoodDown",
    -- A mob that IS named by a quest in the log and whose every claim is done.
    -- Separate from NotATarget because they are different facts about the world,
    -- and an arm that counts nothing is the arm that cannot be diagnosed.
    SATISFIED = "Satisfied",
}

-- Why a quest's rows could not be paired to the client's objectives. Each is
-- counted; each means the same thing for behaviour -- that quest's claims become
-- quest-level and follow IsComplete (section 2.2).
local REJECTION = {
    COUNT_MISMATCH = "CountMismatch",
    TYPE_CONTRADICTION = "TypeContradiction",
    UNKNOWN_TYPE = "UnknownObjectiveType",
}

local STATE = { OUTSTANDING = "Outstanding", SATISFIED = "Satisfied", UNREADABLE = "Unreadable" }

local QUEST_CLAIM_QUEST_LEVEL = ns.QUEST_CLAIM_QUEST_LEVEL
local QUEST_LEVEL = QUEST_CLAIM_QUEST_LEVEL

local CAPABILITY = { CAPABLE = "Capable", STOOD_DOWN = "StoodDown" }

-- Forward declaration: enable and onEnteringWorld share it (see below).
local applyCapability

local state = {
    enabled = false,
    tokens = {},
    pool = nil,
    -- Every plate Nameplates has handed us and not taken back. The only way to
    -- reach a plate already on screen (section 4.1).
    attached = {},
    attachedCount = 0,
    markerCount = 0,

    targets = nil,
    -- Which NPC ids the plates we were offered actually resolved to, so /pa quests
    -- can be compared against the target set by eye.
    lastNpcIds = {},
    rebuildToken = nil,
    capability = CAPABILITY.CAPABLE,
    capabilityReason = nil,

    settings = {
        markerScale = 1.0,
        markerOffsetX = ns.QUEST_MARKER_OFFSET_X,
        markerOffsetY = ns.QUEST_MARKER_OFFSET_Y,
        markersIgnoreProgress = false,
    },
}

local function counters()
    return ns.Diagnostics.CountersFor(FEATURE_ID)
end

local function bump(name, amount)
    ns.Diagnostics.Bump(counters(), name, amount)
end

local function now()
    return _G.GetTime and _G.GetTime() or 0
end

-- The pool (section 4.4) --------------------------------------------------------------

local function ensurePool()
    if state.pool then
        return state.pool
    end
    state.pool = ns.FramePool.Create({
        poolName = "questMarkers",
        capacity = ns.QUEST_MARKER_POOL_CAPACITY,
        dropPolicy = ns.DROP_POLICY.SURFACE_AND_FAIL,
        factory = function()
            -- Ours, parented to UIParent, never to the plate (rule 6). A frame with
            -- one anchor and no size is 0x0 and draws nothing, so the size is set.
            local frame = CreateFrame("Frame", nil, _G.UIParent)
            frame:SetSize(ns.QUEST_MARKER_SIZE, ns.QUEST_MARKER_SIZE)
            frame:Hide()
            local texture = frame:CreateTexture(nil, "OVERLAY")
            texture:SetAllPoints(frame)
            texture:SetTexture(ns.QUEST_MARKER_TEXTURE)
            frame.texture = texture
            return frame
        end,
        reset = function(frame)
            frame:Hide()
            frame:ClearAllPoints()
            frame:SetScale(1)
        end,
    })
    return state.pool
end

-- Capability (section 4.3) ------------------------------------------------------------

local function readCapability()
    local reading, detail = ns.MapRestriction.Read()
    if reading == ns.MapRestriction.RESTRICTED then
        return CAPABILITY.STOOD_DOWN,
            "this map does not let an addon see which monster a nameplate belongs to"
    end
    if reading == ns.MapRestriction.UNREADABLE then
        -- "Could not tell" is not permission (rule 10).
        return CAPABILITY.STOOD_DOWN,
            format("could not tell whether this map restricts addons (%s)", tostring(detail))
    end
    return CAPABILITY.CAPABLE
end

-- The kill-target set and the satisfaction snapshot (Phase 19 section 2) ------------

-- Which slot comes first for this quest, as a full slot order. QuestieDB publishes
-- per-quest exceptions to the default order and ObjectiveFirstSlot reads them; a nil
-- answer keeps the default, which is what an absent hint table also produces.
local function slotOrderForQuest(questId)
    local first = Bridge.ObjectiveFirstSlot(questId)
    if not first then
        return ns.QUEST_OBJECTIVE_SLOT_ORDER
    end
    local order = { first }
    for index = 1, #ns.QUEST_OBJECTIVE_SLOT_ORDER do
        local slot = ns.QUEST_OBJECTIVE_SLOT_ORDER[index]
        if slot ~= first then
            order[#order + 1] = slot
        end
    end
    return order
end

local function objectiveIndexForRow(slot, row, rowsBySlot, order)
    local preceding = 0
    for index = 1, #order do
        local earlier = order[index]
        if earlier == slot then
            break
        end
        preceding = preceding + (rowsBySlot[earlier] or 0)
    end
    return preceding + row
end

-- Every claim this quest owns, with nothing but the quest's own completion behind
-- it. Both arms of resolveClaims return through here, so the rejection arm loses no
-- claim -- which the first draft's contract promised and its code did not do.
local function questLevelClaims(questId, shape)
    local out = {}
    for index = 1, #shape.claims do
        out[#out + 1] = {
            npcId = shape.claims[index].npcId,
            questId = questId,
            scope = QUEST_LEVEL,
        }
    end
    for index = 1, #shape.extraNpcIds do
        out[#out + 1] = {
            npcId = shape.extraNpcIds[index],
            questId = questId,
            scope = QUEST_LEVEL,
        }
    end
    return out
end

-- Pairs QuestieDB's objective rows to the client's objective list, all-or-nothing
-- per quest (section 2.2).
--
-- The pairing assumption -- the client's list is QuestieDB's slots concatenated in
-- slot order, with the published per-quest exception applied -- comes from another
-- addon's behaviour, not from a contract. So it is CHECKED before it is used, by row
-- count and by objective type, and a quest that fails any check gets quest-level
-- claims instead. A partially-trusted pairing is rejected whole: one wrong row
-- shifts every index after it.
--
-- An unknown type string is a rejection, not a shrug. The five type strings this
-- compares against are not in the UI export, so if they are wrong on this client
-- every quest lands here and the feature degrades to "markers go when the quest is
-- done" -- correct, and visible in one /pa quests. The alternative, accepting an
-- unknown type and hoping the order holds, risks hiding a marker on the wrong mob,
-- and an absent marker is indistinguishable from "not a quest mob" (section 2.2).
local function resolveClaims(questId, shape, clientObjectives)
    -- Nothing to index: a quest whose only creature reference comes from
    -- extraObjectives would otherwise be counted as a CountMismatch it could never
    -- avoid (audit finding 6).
    if #shape.claims == 0 then
        return questLevelClaims(questId, shape), nil
    end

    local order = slotOrderForQuest(questId)
    local totalRows = 0
    for slot = 1, 6 do
        totalRows = totalRows + (shape.rowsBySlot[slot] or 0)
    end
    if totalRows ~= #clientObjectives then
        return questLevelClaims(questId, shape), REJECTION.COUNT_MISMATCH
    end

    for index = 1, #shape.claims do
        local claim = shape.claims[index]
        local objectiveIndex = objectiveIndexForRow(claim.slot, claim.row, shape.rowsBySlot, order)
        local objective = clientObjectives[objectiveIndex]
        local actual = type(objective) == "table" and objective.type or nil
        if type(actual) ~= "string" or not ns.KNOWN_OBJECTIVE_TYPES[actual] then
            return questLevelClaims(questId, shape), REJECTION.UNKNOWN_TYPE
        end
        if actual ~= ns.CLIENT_OBJECTIVE_TYPE_FOR_SLOT[claim.slot] then
            return questLevelClaims(questId, shape), REJECTION.TYPE_CONTRADICTION
        end
    end

    local paired = {}
    for index = 1, #shape.claims do
        local claim = shape.claims[index]
        paired[#paired + 1] = {
            npcId = claim.npcId,
            questId = questId,
            scope = objectiveIndexForRow(claim.slot, claim.row, shape.rowsBySlot, order),
        }
    end
    for index = 1, #shape.extraNpcIds do
        paired[#paired + 1] = {
            npcId = shape.extraNpcIds[index],
            questId = questId,
            scope = QUEST_LEVEL,
        }
    end
    return paired, nil
end

-- The client's objective list for one quest, as a readable value or nothing.
-- GetQuestObjectives is MayReturnNothing, so "did not answer" is a real arm and is
-- never read as "no objectives".
local function readClientObjectives(questId)
    local api = _G.C_QuestLog
    local getter = api and api.GetQuestObjectives
    if type(getter) ~= "function" then
        return nil
    end
    local kind, objectives = ClientRead.Call(getter, "table", questId)
    if kind ~= ClientRead.PLAIN then
        return nil
    end
    -- Every row is read through ClientRead as well: the list being plain says
    -- nothing about what is in it.
    local rows = {}
    for index = 1, #objectives do
        local row = objectives[index]
        if ClientRead.Classify(row, "table") ~= ClientRead.PLAIN then
            return nil
        end
        local typeKind, objectiveType = ClientRead.Field(row, "type", "string")
        local finishedKind, finished = ClientRead.Field(row, "finished", "boolean")
        rows[index] = {
            type = typeKind == ClientRead.PLAIN and objectiveType or nil,
            finished = finishedKind == ClientRead.PLAIN and finished or nil,
            finishedReadable = finishedKind == ClientRead.PLAIN,
        }
    end
    return rows
end

-- One quest's objective states (section 2.3).
--
-- Unreadable keeps a marker. "Could not tell" is not permission to hide something
-- (README rule 10), and an index past the end of the list the client just returned
-- is Unreadable rather than Satisfied: the pairing passed the count check when the
-- set was built, so a short list now means the log moved under us.
local function readObjectiveStates(questId, scopes, clientObjectives, states)
    local byScope = states[questId]
    if not byScope then
        byScope = {}
        states[questId] = byScope
    end

    for scope in pairs(scopes) do
        if scope == QUEST_LEVEL then
            local api = _G.C_QuestLog
            local kind, complete = ClientRead.Call(api and api.IsComplete, "boolean", questId)
            if kind ~= ClientRead.PLAIN then
                byScope[scope] = STATE.UNREADABLE
                bump("completionUnreadable")
            else
                byScope[scope] = complete and STATE.SATISFIED or STATE.OUTSTANDING
            end
        elseif clientObjectives == nil then
            byScope[scope] = STATE.UNREADABLE
        else
            local objective = clientObjectives[scope]
            if objective == nil or not objective.finishedReadable then
                byScope[scope] = STATE.UNREADABLE
            else
                byScope[scope] = objective.finished and STATE.SATISFIED or STATE.OUTSTANDING
            end
        end
    end
end

-- GetQuestIDForLogIndex answers "only for actual quests, not headers", so no
-- isHeader test is needed. questsSeen against the second return of
-- GetNumQuestLogEntries is how a collapsed header's hidden quests are noticed
-- rather than silently lost; no header is ever expanded, because ExpandQuestHeader
-- would raise QUEST_LOG_UPDATE from inside our own call -- the defect shape Phase 7
-- section 6.4 abandoned the quest-level sort over.
--
-- Phase 19: this builds the claim map and the satisfaction snapshot in one pass, so
-- the plate path is a table lookup and never a client call (section 2.3).
local function buildTargetSet(previous)
    local api = _G.C_QuestLog
    local countKind, shown, total = ClientRead.CallMany(
        api and api.GetNumQuestLogEntries, 2, "number")
    if countKind ~= ClientRead.PLAIN then
        bump("logUnreadable")
        -- Not an empty log. The previous set stays: markers must not all vanish
        -- because of one unreadable read.
        return previous
    end

    local byNpcId, npcCount, questsSeen = {}, 0, 0
    local satisfied = {}
    local typesSeen = {}
    local pairing = { paired = 0, skipped = 0, countMismatch = 0,
                      typeContradiction = 0, unknownType = 0, unreadable = 0 }
    local ignoreProgress = state.settings.markersIgnoreProgress == true

    local limit = shown
    if limit > ns.QUEST_LOG_INDEX_MAXIMUM then
        limit = ns.QUEST_LOG_INDEX_MAXIMUM
    end
    for index = 1, limit do
        local kind, questId = ClientRead.Call(api.GetQuestIDForLogIndex, "number", index)
        if kind == ClientRead.PLAIN and questId > 0 then
            questsSeen = questsSeen + 1
            local shape = Bridge.KillClaimsForQuest(questId)
            if #shape.claims > 0 or #shape.extraNpcIds > 0 then
                local claims, rejection
                if ignoreProgress then
                    -- No objective read at all: every claim is Outstanding by
                    -- construction, which is Phase 17's behaviour exactly (D6).
                    claims = questLevelClaims(questId, shape)
                else
                    local clientObjectives = readClientObjectives(questId)
                    if clientObjectives == nil then
                        -- Not a pairing outcome: an unreadable objectives list makes
                        -- every scope Unreadable, which keeps the markers. It must
                        -- NOT fall through to IsComplete, or a complete quest we
                        -- just failed to read would drop every marker it owns
                        -- (audit finding 4).
                        claims = questLevelClaims(questId, shape)
                        pairing.unreadable = pairing.unreadable + 1
                        bump("objectivesUnreadable")
                        local byScope = satisfied[questId] or {}
                        byScope[QUEST_LEVEL] = STATE.UNREADABLE
                        satisfied[questId] = byScope
                    else
                        for position = 1, #clientObjectives do
                            local objectiveType = clientObjectives[position].type
                            if type(objectiveType) == "string" then
                                typesSeen[objectiveType] = (typesSeen[objectiveType] or 0) + 1
                            end
                        end
                        claims, rejection = resolveClaims(questId, shape, clientObjectives)
                        if rejection == nil then
                            if #shape.claims == 0 then
                                pairing.skipped = pairing.skipped + 1
                            else
                                pairing.paired = pairing.paired + 1
                                bump("pairingPaired")
                            end
                        elseif rejection == REJECTION.COUNT_MISMATCH then
                            pairing.countMismatch = pairing.countMismatch + 1
                            bump("pairingCountMismatch")
                        elseif rejection == REJECTION.TYPE_CONTRADICTION then
                            pairing.typeContradiction = pairing.typeContradiction + 1
                            bump("pairingTypeContradiction")
                        else
                            pairing.unknownType = pairing.unknownType + 1
                            bump("pairingUnknownType")
                        end

                        local scopes = {}
                        for position = 1, #claims do
                            scopes[claims[position].scope] = true
                        end
                        readObjectiveStates(questId, scopes, clientObjectives, satisfied)
                    end
                end

                for position = 1, #claims do
                    local claim = claims[position]
                    local list = byNpcId[claim.npcId]
                    if not list then
                        list = {}
                        byNpcId[claim.npcId] = list
                        npcCount = npcCount + 1
                    end
                    list[#list + 1] = claim
                end
            end
        end
    end

    local hidden = total - questsSeen
    if hidden > 0 then
        bump("questsHidden", hidden)
    end
    bump("setRebuilds")
    bump("targetsFound", npcCount)
    return {
        byNpcId = byNpcId,
        satisfied = satisfied,
        typesSeen = typesSeen,
        pairing = pairing,
        npcCount = npcCount,
        questsSeen = questsSeen,
        questsExpected = total,
        builtAt = now(),
        complete = (questsSeen == total),
        progressAware = not ignoreProgress,
    }
end

local function targets()
    if not state.targets then
        state.targets = buildTargetSet(nil) or {
            byNpcId = {}, satisfied = {}, typesSeen = {},
            pairing = { paired = 0, skipped = 0, countMismatch = 0,
                        typeContradiction = 0, unknownType = 0, unreadable = 0 },
            npcCount = 0, questsSeen = 0, questsExpected = 0,
            builtAt = now(), complete = true, progressAware = true,
        }
    end
    return state.targets
end

-- Whether a marker belongs on this NPC id (section 2.4).
--
-- A claim is satisfied only when the snapshot says so. Outstanding and Unreadable
-- both keep the marker, and a scope absent from the snapshot is Outstanding -- which
-- is what makes markersIgnoreProgress a no-read path rather than a second code path.
local function markerWanted(set, npcId)
    local claims = set.byNpcId[npcId]
    if not claims then
        return false
    end
    for index = 1, #claims do
        local claim = claims[index]
        local byScope = set.satisfied[claim.questId]
        if not byScope or byScope[claim.scope] ~= STATE.SATISFIED then
            return true
        end
    end
    return false
end

-- The marker (section 4.4) ------------------------------------------------------------

local function npcIdForPlate(plate)
    local kind, guid = ClientRead.Call(_G.UnitGUID, "string", plate.unitToken)
    if kind ~= ClientRead.PLAIN then
        return nil, kind
    end
    local guidType = guid:match("^(%a+)")
    if guidType ~= "Creature" and guidType ~= "Vehicle" then
        return nil
    end
    return tonumber(guid:match("-(%d+)-%x+$"))
end

local function detachMarker(plate)
    if not plate or not plate.questMarker then
        return READING.NOT_A_TARGET
    end
    ns.FramePool.Release(state.pool, plate.questMarker)
    plate.questMarker = nil
    state.markerCount = state.markerCount - 1
    bump("markersReleased")
    return READING.RELEASED
end

-- Every arm counts something. The first in-game run could not be diagnosed from
-- its counters at all: NotATarget covered "no container", "could not read the
-- unit" and "not a quest mob", and neither it nor StoodDown bumped anything, so
-- the commonest outcome was the one with no evidence behind it. Phase 16's lesson
-- was measure rather than infer, and this is the same lesson on the marker side.
local function attachMarker(plate)
    bump("platesOffered")
    if state.capability ~= CAPABILITY.CAPABLE then
        detachMarker(plate)
        bump("offeredWhileStoodDown")
        return READING.STOOD_DOWN, state.capabilityReason
    end
    if not plate.container then
        detachMarker(plate)
        bump("noContainer")
        return READING.NOT_A_TARGET
    end

    local npcId, readKind = npcIdForPlate(plate)
    if npcId == nil then
        detachMarker(plate)
        if readKind ~= nil and readKind ~= ClientRead.ABSENT then
            bump("guidWithheld")
            return READING.WITHHELD
        end
        bump("npcIdUnreadable")
        return READING.NOT_A_TARGET
    end
    state.lastNpcIds[npcId] = (state.lastNpcIds[npcId] or 0) + 1

    local set = targets()
    if not set.byNpcId[npcId] then
        detachMarker(plate)
        bump("notTargeted")
        return READING.NOT_A_TARGET
    end
    -- Phase 19 section 2.4. Every claim on this mob is done, so the marker goes --
    -- counted apart from notTargeted because "you finished this one" and "this was
    -- never a quest mob" are different facts and only one of them is news.
    if not markerWanted(set, npcId) then
        local had = plate.questMarker ~= nil
        detachMarker(plate)
        bump("satisfied")
        if had then
            bump("markersSatisfied")
        end
        return READING.SATISFIED
    end

    -- A plate that already has one keeps it and is re-measured, rather than
    -- acquiring a second.
    local marker = plate.questMarker
    if not marker then
        marker = ns.FramePool.Acquire(ensurePool())
        if not marker then
            bump("poolExhausted")
            ns.Log.Once("questmarkers:poolexhausted", format(
                "the quest marker pool of %d is exhausted, so some plates have no marker",
                ns.QUEST_MARKER_POOL_CAPACITY))
            return READING.NOT_A_TARGET
        end
        plate.questMarker = marker
        state.markerCount = state.markerCount + 1
        bump("markersShown")
    end

    marker:ClearAllPoints()
    marker:SetScale(state.settings.markerScale)
    -- The container, not UnitFrame: Phase 14 made the bar's height a setting, and
    -- the container is the frame whose height follows it (premise
    -- PLATE-BAR-CONTAINER-HEIGHT). A marker on UnitFrame would drift as the bar
    -- shrinks, and the container's left edge is also where the bar's left edge
    -- actually is. The guild label hangs below the same container.
    --
    -- Phase 18 section 3: the marker's RIGHT edge against the container's LEFT, so
    -- the default sits a few pixels clear of the plate rather than on top of it.
    -- markerOffsetY is therefore measured from the bar's vertical CENTRE, not its
    -- top, which is why its range is symmetric now. Phase 17's centred-above
    -- placement is not reachable from these two sliders -- re-centring would need
    -- about +68px on a 120px bar, past the slider and dependent on a plate width we
    -- do not read -- and section 3.1 says so rather than implying otherwise.
    --
    -- Each offset is divided by the scale so the numbers stay screen pixels at any
    -- marker size (Phase 12 section 4's rule).
    local scale = state.settings.markerScale
    local offsetX = state.settings.markerOffsetX / scale
    local offsetY = state.settings.markerOffsetY / scale
    marker:SetPoint("RIGHT", plate.container, "LEFT", offsetX, offsetY)
    marker:Show()
    return READING.SHOWN
end

-- Everything on screen, brought to what the set and the settings now say. The only
-- way to reach these plates is state.attached (section 4.1).
local function refreshMarkers()
    local tally = {}
    for plate in pairs(state.attached) do
        local reading = attachMarker(plate)
        tally[reading] = (tally[reading] or 0) + 1
    end
    bump("sweeps")
    return tally
end

local function releaseAll()
    for plate in pairs(state.attached) do
        detachMarker(plate)
    end
end

-- Triggers (section 4.2) --------------------------------------------------------------

local function cancelRebuild()
    if state.rebuildToken then
        if type(state.rebuildToken) == "table" and type(state.rebuildToken.Cancel) == "function" then
            pcall(state.rebuildToken.Cancel, state.rebuildToken)
        end
        state.rebuildToken = nil
    end
end

-- A cancellable timer, not C_Timer.After: QUEST_LOG_UPDATE fires in bursts, and a
-- pending After() would rebuild into a disabled feature a frame later. Phase 16
-- section 5.2 made the same correction.
local function scheduleRebuild()
    if not state.enabled or state.rebuildToken then
        return
    end
    state.rebuildToken = _G.C_Timer and _G.C_Timer.NewTimer
        and _G.C_Timer.NewTimer(0, function()
            state.rebuildToken = nil
            if not state.enabled then
                return
            end
            state.targets = buildTargetSet(state.targets)
            refreshMarkers()
        end) or nil
end

-- Shared by enable and PLAYER_ENTERING_WORLD so both count and announce.
function applyCapability(capability, reason)  -- luacheck: ignore
    if capability == state.capability then
        return false
    end
    state.capability = capability
    state.capabilityReason = reason
    if capability == CAPABILITY.STOOD_DOWN then
        bump("stoodDown")
        ns.Log.Once("questmarkers:stooddown", format(
            "quest markers are off here: %s", tostring(reason)))
        releaseAll()
    else
        refreshMarkers()
    end
    return true
end

-- Plates Nameplates is already tracking when this feature enables. They were
-- tracked before our call-out existed, so they were never offered -- a /reload
-- with mobs on screen left every one of them unmarked until it recycled. Phase 15
-- hit the same shape and solved it the same way, by re-reading what is already up.
local function adoptTrackedPlates()
    local tracked = ns.Nameplates and ns.Nameplates.TrackedPlates
        and ns.Nameplates.TrackedPlates()
    if type(tracked) ~= "table" then
        return 0
    end
    local adopted = 0
    for _, plate in pairs(tracked) do
        if type(plate) == "table" and not state.attached[plate] then
            state.attached[plate] = true
            state.attachedCount = state.attachedCount + 1
            adopted = adopted + 1
            attachMarker(plate)
        end
    end
    if adopted > 0 then
        bump("platesAdopted", adopted)
    end
    return adopted
end

local function onEnteringWorld()
    applyCapability(readCapability())
    adoptTrackedPlates()
    scheduleRebuild()
end

-- Called from Nameplates (section 4.1) ------------------------------------------------

local function readSettings(config)
    local settings = config and config.settings
    if settings then
        -- Compared against nil, not truthiness: every one of these is a number a
        -- player can legitimately set to 0, and an offset of 0 is a position.
        if settings.markerScale ~= nil then
            state.settings.markerScale = settings.markerScale
        end
        if settings.markerOffsetX ~= nil then
            state.settings.markerOffsetX = settings.markerOffsetX
        end
        if settings.markerOffsetY ~= nil then
            state.settings.markerOffsetY = settings.markerOffsetY
        end
        -- A toggle, so truthiness is the right test here, unlike the three numbers
        -- above where 0 is a legitimate value.
        state.settings.markersIgnoreProgress = (settings.markersIgnoreProgress == true)
    end
end

local function enable(config)
    readSettings(config)
    local bridgeState = Bridge.State()
    if bridgeState ~= ns.QuestieDBBridge.STATE.AVAILABLE then
        ns.Log.Once("questmarkers:bridge:" .. tostring(bridgeState), format(
            "quest markers need the QuestieDB addon: %s",
            ns.EscapeGuard.Neutralize(Bridge.Describe())))
        return nil, format("QuestieDB is %s", tostring(bridgeState))
    end

    -- QUEST_LOG_UPDATE only, and it is a UniqueEvent so it cannot arrive inside a
    -- Lua call. QUEST_ACCEPTED, QUEST_REMOVED and QUEST_TURNED_IN are all
    -- SynchronousEvent, and Phase 7 section 6.4 is the record of what subscribing to
    -- one of those cost; QUEST_LOG_UPDATE follows all three anyway.
    for _, eventName in ipairs({ "QUEST_LOG_UPDATE", "PLAYER_ENTERING_WORLD" }) do
        local handler = eventName == "PLAYER_ENTERING_WORLD" and onEnteringWorld
            or scheduleRebuild
        local token, reason = ns.Dispatch.Subscribe(FEATURE_ID, eventName, handler)
        if not token then
            return nil, format("cannot follow %s (%s)", eventName, tostring(reason))
        end
        state.tokens[#state.tokens + 1] = token
    end

    -- Through the same path onEnteringWorld uses, so a capability that is stood
     -- down at enable is counted and said once. Setting it directly here meant a
     -- feature that could never draw anything and reported nothing.
    state.capability, state.capabilityReason = CAPABILITY.CAPABLE, nil
    state.enabled = true
    applyCapability(readCapability())
    adoptTrackedPlates()
    scheduleRebuild()
    return true
end

-- Tolerates a partial enable (Phase 1 section 6.1). Every marker, the timer and the
-- subscriptions all go; Registry calls Dispatch.UnsubscribeAll after this too.
local function disable()
    state.enabled = false
    cancelRebuild()
    releaseAll()
    for index = #state.tokens, 1, -1 do
        ns.Dispatch.Unsubscribe(state.tokens[index])
        state.tokens[index] = nil
    end
    state.attached = {}
    state.attachedCount = 0
    state.targets = nil
end

local function onConfigChanged(config)
    local wasIgnoring = state.settings.markersIgnoreProgress
    readSettings(config)
    -- The meaning toggle changes what the SET says, not where the markers sit, so
    -- the set is rebuilt before the sweep. Rebuilt here and now rather than through
    -- scheduleRebuild's timer: a slider move is one user action, not a burst, and
    -- the player should see the markers change as they release the control.
    if state.settings.markersIgnoreProgress ~= wasIgnoring then
        state.targets = buildTargetSet(state.targets)
    end
    -- Markers already on screen move and resize, rather than waiting for a plate.
    refreshMarkers()
    return ns.CONFIG_RESULT.APPLIED
end

ns.Registry.Register(FEATURE_ID, {
    enabledByDefault = true,
    label = "Quest markers on nameplates",
    description = "A marker over any monster an active quest still wants. It goes when you have killed or collected enough for that objective. Needs nameplates on and the QuestieDB addon enabled, and it switches itself off in dungeons and raids.",
    settingsPage = ns.SETTINGS_PAGE.QUESTS,
    settingsOrder = 20,
    settings = {
        markerScale = 1.0,
        markerOffsetX = ns.QUEST_MARKER_OFFSET_X,
        markerOffsetY = ns.QUEST_MARKER_OFFSET_Y,
        markersIgnoreProgress = false,
    },
    schema = {
        -- The two offsets read together, above the size, in the order a player
        -- scans them. Neither label says "above the bar": Phase 18 moved the
        -- anchor to the container's left edge, which makes that false for the
        -- vertical offset and meaningless for the horizontal one.
        markerOffsetX = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Marker offset, left and right", order = 1,
            unit = ns.ConfigSchema.UNIT.PIXELS,
            minimum = -ns.QUEST_MARKER_OFFSET_LIMIT, maximum = ns.QUEST_MARKER_OFFSET_LIMIT, step = 1,
        },
        markerOffsetY = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Marker offset, up and down", order = 2,
            unit = ns.ConfigSchema.UNIT.PIXELS,
            minimum = -ns.QUEST_MARKER_OFFSET_LIMIT, maximum = ns.QUEST_MARKER_OFFSET_LIMIT, step = 1,
        },
        markerScale = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Marker size", order = 3,
            unit = ns.ConfigSchema.UNIT.FRACTION,
            minimum = 0.8, maximum = 1.5, step = 0.05,
        },
        -- Phase 19 D6. Last, because it is the one control here that changes what a
        -- marker MEANS rather than where it sits or how big it is.
        markersIgnoreProgress = {
            kind = ns.ConfigSchema.KIND.TOGGLE,
            label = "Keep markers until the quest leaves the log", order = 4,
            description = "Off, a marker goes as soon as you have killed or collected enough for the objective that named the mob. On, it stays while the quest is in your log, which is what you want if you are farming a mob you have already finished with.",
        },
    },
}, {
    enable = enable,
    disable = disable,
    onConfigChanged = onConfigChanged,
})

ns.QuestMarkers = {
    -- Nameplates calls these two from its own plate lifecycle. They are the only
    -- source of state.attached, and so the only way anything here reaches a plate.
    OnPlateAttached = function(plate)
        if not state.enabled or type(plate) ~= "table" then
            return
        end
        if not state.attached[plate] then
            state.attached[plate] = true
            state.attachedCount = state.attachedCount + 1
        end
        attachMarker(plate)
    end,

    OnPlateDetached = function(plate)
        if type(plate) ~= "table" then
            return
        end
        detachMarker(plate)
        if state.attached[plate] then
            state.attached[plate] = nil
            state.attachedCount = state.attachedCount - 1
        end
    end,

    Inspect = function()
        local set = state.targets
        return {
            enabled = state.enabled,
            capability = state.capability,
            capabilityReason = state.capabilityReason,
            attached = state.attachedCount,
            markers = state.markerCount,
            npcCount = set and set.npcCount or 0,
            questsSeen = set and set.questsSeen or 0,
            questsExpected = set and set.questsExpected or 0,
            complete = set and set.complete,
            builtAt = set and set.builtAt or nil,
            progressAware = set and set.progressAware,
            markersIgnoreProgress = state.settings.markersIgnoreProgress,
            pairing = set and set.pairing or nil,
            claimCount = (function()
                local total = 0
                for _, claims in pairs(set and set.byNpcId or {}) do
                    total = total + #claims
                end
                return total
            end)(),
            pairedClaims = (function()
                local total = 0
                for _, claims in pairs(set and set.byNpcId or {}) do
                    for index = 1, #claims do
                        if claims[index].scope ~= QUEST_LEVEL then
                            total = total + 1
                        end
                    end
                end
                return total
            end)(),
            satisfiedClaims = (function()
                local total = 0
                for _, claims in pairs(set and set.byNpcId or {}) do
                    for index = 1, #claims do
                        local claim = claims[index]
                        local byScope = set.satisfied[claim.questId]
                        if byScope and byScope[claim.scope] == STATE.SATISFIED then
                            total = total + 1
                        end
                    end
                end
                return total
            end)(),
            objectiveTypesSeen = (function()
                local seen = {}
                for objectiveType, count in pairs(set and set.typesSeen or {}) do
                    seen[#seen + 1] = format("%s x%d", objectiveType, count)
                end
                table.sort(seen)
                return seen
            end)(),
            markerScale = state.settings.markerScale,
            markerOffsetX = state.settings.markerOffsetX,
            markerOffsetY = state.settings.markerOffsetY,
            poolStats = state.pool and ns.FramePool.Stats(state.pool) or nil,
            targetIds = (function()
                local ids = {}
                for npcId in pairs(set and set.byNpcId or {}) do
                    ids[#ids + 1] = npcId
                end
                table.sort(ids)
                return ids
            end)(),
            seenIds = (function()
                local ids = {}
                for npcId, count in pairs(state.lastNpcIds) do
                    ids[#ids + 1] = format("%d x%d", npcId, count)
                end
                table.sort(ids)
                return ids
            end)(),
            nameplatesOn = ns.Registry.State("nameplates") == ns.FEATURE_STATE.ENABLED,
        }
    end,
}
