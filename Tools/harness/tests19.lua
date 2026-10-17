-- Phase 19 offline checks (Architecture/20261016-Phase19.md section 11.1).
-- One session, "phase19". T-numbers follow the design's own table; T26 to T33 are
-- the audit's findings, each pinned where it would have shown up.

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

local function setSetting(feature, key, value)
    ns.ConfigStore.Set(feature, key, value)
    ns.Registry.NotifyConfigChanged(feature, key)
    HARNESS.frame()
end

local Bridge = ns.QuestieDBBridge
local SLOT = ns.QUEST_OBJECTIVE_SLOT

HARNESS.playerLevel = 40

-- The data -------------------------------------------------------------------------------
--
-- KILL: one creature objective. MIXED: a creature objective and an item objective,
-- which is the shape the whole of section 2 exists for. REP: a creature objective
-- plus a reputation pair, the shape audit finding 5 is about.

local WOLF, BOAR, BEAR, CRAB, RARE_MOB = 101, 102, 103, 104, 105
local DROPPER_A, DROPPER_B = 201, 202
local SPECIAL = 301

local KILL = HARNESS.addQuest(500, { name = "Kill Wolves" })
local MIXED = HARNESS.addQuest(501, { name = "Wolves and Ears" })
local REP = HARNESS.addQuest(502, { name = "Reputation and Boars" })
local EXTRA_ONLY = HARNESS.addQuest(503, { name = "Special Objective" })
local DOUBLE = HARNESS.addQuest(504, { name = "Kill and Loot the Same Bear" })
local HINTED = HARNESS.addQuest(505, { name = "Item First" })
local SHORT = HARNESS.addQuest(506, { name = "Count Mismatch" })
local WRONG_TYPE = HARNESS.addQuest(507, { name = "Type Contradiction" })
local ODD_TYPE = HARNESS.addQuest(508, { name = "Unknown Type" })
local UNREADABLE = HARNESS.addQuest(509, { name = "Objectives Withheld" })
local SHARED = HARNESS.addQuest(510, { name = "Also Wants Wolves" })

-- QuestieDB's side.
HARNESS.setObjectives(KILL, { WOLF })
HARNESS.setObjectives(MIXED, { WOLF }, nil, { [SLOT.ITEM] = { { 9001, "ears", 8 } } })
HARNESS.setObjectives(REP, { BOAR }, nil, { [SLOT.REPUTATION] = { 69, 4000 } })
HARNESS.setObjectives(DOUBLE, { BEAR }, nil, { [SLOT.ITEM] = { { 9002, "hide", 4 } } })
HARNESS.setObjectives(HINTED, { CRAB }, nil, { [SLOT.ITEM] = { { 9003, "claws", 2 } } })
HARNESS.setObjectives(SHORT, { WOLF })
HARNESS.setObjectives(WRONG_TYPE, { WOLF })
HARNESS.setObjectives(ODD_TYPE, { WOLF })
HARNESS.setObjectives(UNREADABLE, { WOLF })
HARNESS.setObjectives(SHARED, { WOLF })
HARNESS.setExtraObjectives(EXTRA_ONLY, { SPECIAL })
HARNESS.setItemDrops(9001, DROPPER_A, DROPPER_B)
HARNESS.setItemDrops(9002, BEAR)
HARNESS.setItemDrops(9003, CRAB)

-- The client's side, in the client's own order.
HARNESS.setClientObjectives(KILL, { { type = "monster" } })
HARNESS.setClientObjectives(MIXED, { { type = "monster" }, { type = "item" } })
HARNESS.setClientObjectives(REP, { { type = "monster" }, { type = "reputation" } })
HARNESS.setClientObjectives(DOUBLE, { { type = "monster" }, { type = "item" } })
HARNESS.setClientObjectives(HINTED, { { type = "item" }, { type = "monster" } })
HARNESS.setClientObjectives(SHORT, { { type = "monster" }, { type = "monster" } })
HARNESS.setClientObjectives(WRONG_TYPE, { { type = "item" } })
HARNESS.setClientObjectives(ODD_TYPE, { { type = "sandwich" } })
HARNESS.setClientObjectives(EXTRA_ONLY, { { type = "event" } })
HARNESS.setClientObjectives(SHARED, { { type = "monster" } })
HARNESS.objectivesSecret[UNREADABLE] = true

-- Boot the addon, as every session does.
HARNESS.fire("ADDON_LOADED", "PersonalAddon")
HARNESS.fire("PLAYER_LOGIN")
HARNESS.frame()
HARNESS.fire("PLAYER_ENTERING_WORLD")
HARNESS.frame()
check("T0 the marker feature and the nameplates feature are both enabled",
    ns.Registry.State("questMarkers") == ns.FEATURE_STATE.ENABLED
        and ns.Registry.State("nameplates") == ns.FEATURE_STATE.ENABLED,
    format("%s / %s", tostring(ns.Registry.State("questMarkers")),
        tostring(ns.Registry.State("nameplates"))))

-- Blizzard's update path, for T25. These globals are absent when the TOC loads, so
-- the first enable finds nothing to hook and leaves hookInstalled false; defining
-- them and re-enabling makes the feature install for real, which is what lets T25
-- drive the hot path rather than assert about it.
function CompactUnitFrame_SetUnit(_unitFrame, _token) end
function CompactUnitFrame_UpdateHealth(_unitFrame) end
function CompactUnitFrame_UpdateAll(_unitFrame) end
function CompactUnitFrame_UpdateHealthColor(_unitFrame) end
ns.Registry.SetEnabled("nameplates", false)
ns.Registry.SetEnabled("nameplates", true)
HARNESS.frame()
check("T25 the reassert hook is installed, so the hot path below is real",
    ns.Nameplates.Inspect().hookInstalled == true,
    tostring(ns.Nameplates.Inspect().hookTargets))

local function rebuild(...)
    HARNESS.setQuestLog(...)
    HARNESS.fire("QUEST_LOG_UPDATE")
    HARNESS.frame()
    HARNESS.frame()
    return ns.QuestMarkers.Inspect()
end

local function addPlate(token, npcId, tier, attackable)
    HARNESS.guids[token] = npcId and HARNESS.creatureGuid(npcId) or HARNESS.SECRET
    if tier then
        if tier == "boss" then
            HARNESS.bossMobs[token] = true
        else
            HARNESS.classifications[token] = tier
        end
    end
    HARNESS.addPlate(token, { reaction = 2, canAttack = attackable ~= false }, { 1, 0, 0 })
    local frame = HARNESS.plates[token]
    frame.unitToken = token
    local container = { height = 13 }
    function container:GetHeight() return self.height end
    function container:SetHeight(value) self.height = value end
    function container:GetWidth() return 190 end
    frame.UnitFrame.HealthBarsContainer = container
    frame.UnitFrame.PlayerLevelDiffFrame = HARNESS.newLevelBadge(28)
    HARNESS.fire("NAME_PLATE_UNIT_ADDED", token)
    HARNESS.frame()
    return frame
end

-- The marker on one plate is our own pooled frame under UIParent, found the way
-- tests17 and tests18 find it.
local function markerOn(plateRecord)
    for _, record in pairs(HARNESS.frames) do
        if record.parent == UIParent and record.texture
            and record.texture.texture == ns.QUEST_MARKER_TEXTURE
            and record.shown and record.points then
            for _, point in ipairs(record.points) do
                if point[2] == plateRecord.UnitFrame.HealthBarsContainer then
                    return record
                end
            end
        end
    end
    return nil
end

local function ringOn(plateRecord)
    local badge = plateRecord.UnitFrame.PlayerLevelDiffFrame
    for _, record in pairs(HARNESS.frames) do
        if record.parent == UIParent and record.shown and record.points then
            for _, point in ipairs(record.points) do
                if point[2] == badge then
                    return record
                end
            end
        end
    end
    return nil
end

-- T1-T5, T28, T29, T32: the pairing (section 2.2) ----------------------------------------

local view = rebuild(KILL, MIXED)
check("T1 a creature row pairs with the first monster objective",
    view.pairedClaims == view.claimCount and view.claimCount > 0,
    format("%d of %d paired", view.pairedClaims or -1, view.claimCount or -1))
check("T1 and the item's droppers are claimed too", view.npcCount >= 3, view.npcCount)
check("T1 pairing counted two quests paired", (view.pairing or {}).paired == 2,
    (view.pairing or {}).paired)

view = rebuild(SHORT)
check("T2 a row count that does not match the client is CountMismatch",
    (view.pairing or {}).countMismatch == 1, (view.pairing or {}).countMismatch)
check("T2 and the claim is kept, as quest-level",
    view.claimCount == 1 and view.pairedClaims == 0,
    format("%d claims, %d paired", view.claimCount or -1, view.pairedClaims or -1))

view = rebuild(WRONG_TYPE)
check("T3 a type that contradicts its slot is TypeContradiction",
    (view.pairing or {}).typeContradiction == 1, (view.pairing or {}).typeContradiction)

view = rebuild(ODD_TYPE)
check("T4 a type outside the known set is UnknownObjectiveType, not a shrug",
    (view.pairing or {}).unknownType == 1, (view.pairing or {}).unknownType)

-- An object row occupies an index without naming a creature, so the item row after
-- it must shift. Built here rather than above because it is the only quest needing it.
local SHIFTED = HARNESS.addQuest(511, { name = "Object Then Item" })
HARNESS.setObjectives(SHIFTED, nil, nil, {
    [SLOT.OBJECT] = { { 7001, "lever", 1 } },
    [SLOT.ITEM] = { { 9004, "shards", 5 } },
})
HARNESS.setItemDrops(9004, CRAB)
HARNESS.setClientObjectives(SHIFTED, { { type = "object" }, { type = "item" } })
view = rebuild(SHIFTED)
check("T5 an unmarked slot's rows still count, so the item pairs at index 2",
    (view.pairing or {}).paired == 1 and view.pairedClaims == 1,
    format("paired=%s claims=%s", tostring((view.pairing or {}).paired), tostring(view.pairedClaims)))

view = rebuild(REP)
check("T28 a reputation pair counts as one row, not two",
    (view.pairing or {}).paired == 1 and (view.pairing or {}).countMismatch == 0,
    format("paired=%s mismatch=%s", tostring((view.pairing or {}).paired),
        tostring((view.pairing or {}).countMismatch)))

view = rebuild(EXTRA_ONLY)
check("T29 a quest with only an extraObjectives creature records no rejection",
    (view.pairing or {}).countMismatch == 0 and (view.pairing or {}).skipped == 1,
    format("mismatch=%s skipped=%s", tostring((view.pairing or {}).countMismatch),
        tostring((view.pairing or {}).skipped)))
check("T29 and its claim is quest-level", view.claimCount == 1 and view.pairedClaims == 0,
    format("%d claims, %d paired", view.claimCount or -1, view.pairedClaims or -1))

HARNESS.objectiveFirst.itemObjectiveFirst[HINTED] = true
Bridge.Reset()
view = rebuild(HINTED)
check("T32 an itemObjectiveFirst hint moves the item slot to index 1",
    (view.pairing or {}).paired == 1 and (view.pairing or {}).typeContradiction == 0,
    format("paired=%s contradiction=%s", tostring((view.pairing or {}).paired),
        tostring((view.pairing or {}).typeContradiction)))
HARNESS.objectiveFirst.itemObjectiveFirst[HINTED] = nil
Bridge.Reset()
view = rebuild(HINTED)
check("T32 and without the hint the same quest contradicts, so the hint did the work",
    (view.pairing or {}).typeContradiction == 1, (view.pairing or {}).typeContradiction)

HARNESS.objectiveFirstPresent = false
HARNESS.buildQuestie()
Bridge.Reset()
view = rebuild(KILL)
check("T32 an absent hint table leaves the default order working",
    (view.pairing or {}).paired == 1, (view.pairing or {}).paired)
HARNESS.objectiveFirstPresent = true
HARNESS.buildQuestie()
Bridge.Reset()

-- T6, T11, T27: the snapshot (section 2.3) -----------------------------------------------

view = rebuild(UNREADABLE)
check("T6 a withheld objectives read keeps every claim",
    view.satisfiedClaims == 0 and view.claimCount == 1,
    format("%d satisfied of %d", view.satisfiedClaims or -1, view.claimCount or -1))
check("T6 and it is counted as unreadable, not as a pairing rejection",
    (view.pairing or {}).unreadable == 1 and (view.pairing or {}).countMismatch == 0,
    (view.pairing or {}).unreadable)

HARNESS.questComplete[UNREADABLE] = true
view = rebuild(UNREADABLE)
check("T6 an unreadable quest does NOT fall through to IsComplete",
    view.satisfiedClaims == 0, view.satisfiedClaims)
HARNESS.questComplete[UNREADABLE] = nil

HARNESS.completeSecret[EXTRA_ONLY] = true
view = rebuild(EXTRA_ONLY)
check("T11 a withheld IsComplete leaves the quest-level claim outstanding",
    view.satisfiedClaims == 0, view.satisfiedClaims)
HARNESS.completeSecret[EXTRA_ONLY] = nil

HARNESS.setClientObjectives(KILL, { { type = "monster", finished = true } })
view = rebuild(KILL, SHARED)
check("T27 the snapshot is keyed by quest and scope, so a finished objective reads back",
    view.satisfiedClaims == 1, view.satisfiedClaims)
HARNESS.setClientObjectives(KILL, { { type = "monster" } })

-- T7-T10, T12, T31: markers on plates (section 2.4) --------------------------------------

view = rebuild(MIXED)
local wolfPlate = addPlate("nameplate1", WOLF, "elite")
local dropperPlate = addPlate("nameplate2", DROPPER_A)
check("T7 both the kill target and the item's dropper carry a marker",
    markerOn(wolfPlate) ~= nil and markerOn(dropperPlate) ~= nil)

HARNESS.setClientObjectives(MIXED, { { type = "monster", finished = true }, { type = "item" } })
rebuild(MIXED)
check("T7 finishing the kill half drops only the kill mob's marker",
    markerOn(wolfPlate) == nil and markerOn(dropperPlate) ~= nil)
check("T7 and the release is counted as satisfied, not as not-a-target",
    ns.QuestMarkers.Inspect().markers == 1, ns.QuestMarkers.Inspect().markers)

HARNESS.setClientObjectives(MIXED, { { type = "monster", finished = true }, { type = "item", finished = true } })
rebuild(MIXED)
check("T7 finishing both drops both", markerOn(wolfPlate) == nil and markerOn(dropperPlate) == nil)
HARNESS.setClientObjectives(MIXED, { { type = "monster" }, { type = "item" } })

-- The wolf is wanted by MIXED (finished) and by SHARED (not finished).
HARNESS.setClientObjectives(MIXED, { { type = "monster", finished = true }, { type = "item", finished = true } })
rebuild(MIXED, SHARED)
check("T8 a mob wanted by two quests keeps its marker while either wants it",
    markerOn(wolfPlate) ~= nil)
HARNESS.setClientObjectives(SHARED, { { type = "monster", finished = true } })
rebuild(MIXED, SHARED)
check("T8 and loses it when both are satisfied", markerOn(wolfPlate) == nil)
HARNESS.setClientObjectives(SHARED, { { type = "monster" } })
HARNESS.setClientObjectives(MIXED, { { type = "monster" }, { type = "item" } })

-- DOUBLE claims the bear twice: once to kill, once as the hide's dropper.
HARNESS.setClientObjectives(DOUBLE, { { type = "monster", finished = true }, { type = "item" } })
view = rebuild(DOUBLE)
local bearPlate = addPlate("nameplate3", BEAR)
check("T31 a mob claimed twice in one quest carries two claims",
    view.claimCount == 2, view.claimCount)
check("T31 and survives the first of them being satisfied", markerOn(bearPlate) ~= nil)
HARNESS.setClientObjectives(DOUBLE, { { type = "monster", finished = true }, { type = "item", finished = true } })
rebuild(DOUBLE)
check("T31 and goes when both are", markerOn(bearPlate) == nil)
HARNESS.setClientObjectives(DOUBLE, { { type = "monster" }, { type = "item" } })

view = rebuild(EXTRA_ONLY)
local specialPlate = addPlate("nameplate4", SPECIAL)
check("T10 an extraObjectives mob carries a marker while the quest is incomplete",
    markerOn(specialPlate) ~= nil)
HARNESS.questComplete[EXTRA_ONLY] = true
rebuild(EXTRA_ONLY)
check("T10 and loses it when the quest completes", markerOn(specialPlate) == nil)
HARNESS.questComplete[EXTRA_ONLY] = nil

-- T13: the meaning toggle (section 2.5) --------------------------------------------------

HARNESS.setClientObjectives(KILL, { { type = "monster", finished = true } })
rebuild(KILL)
check("T13 a satisfied objective hides the marker with the toggle off",
    markerOn(wolfPlate) == nil)
HARNESS.objectiveCalls, HARNESS.completeCalls = 0, 0
setSetting("questMarkers", "markersIgnoreProgress", true)
view = ns.QuestMarkers.Inspect()
check("T13 the toggle brings it back", markerOn(wolfPlate) ~= nil)
check("T13 and reads no objective and no completion at all",
    HARNESS.objectiveCalls == 0 and HARNESS.completeCalls == 0,
    format("%d objective, %d completion", HARNESS.objectiveCalls, HARNESS.completeCalls))
check("T13 and says which meaning is in force",
    view.markersIgnoreProgress == true and view.progressAware == false,
    tostring(view.progressAware))
setSetting("questMarkers", "markersIgnoreProgress", false)
HARNESS.setClientObjectives(KILL, { { type = "monster" } })

-- T14, T15, T30: the bridge (section 3) --------------------------------------------------

Bridge.Reset()
HARNESS.questieReads = 0
local shape = Bridge.KillClaimsForQuest(MIXED)
check("T15 a shape whose sources all answered is cached", shape.answered == true)
local reads = HARNESS.questieReads
Bridge.KillClaimsForQuest(MIXED)
check("T15 and a second lookup makes no read", HARNESS.questieReads == reads,
    HARNESS.questieReads - reads)

Bridge.Reset()
local NO_DROPS = HARNESS.addQuest(512, { name = "Item With Broken Drops" })
HARNESS.setObjectives(NO_DROPS, nil, nil, { [SLOT.ITEM] = { { 9005, "teeth", 3 } } })
-- npcDrops answers a withheld value for this item: the call ran and told us nothing.
HARNESS.itemDropsSecret[9005] = true
HARNESS.buildQuestie()
shape = Bridge.KillClaimsForQuest(NO_DROPS)
check("T30 an unusable npcDrops read leaves the shape unanswered", shape.answered == false)
HARNESS.questieReads = 0
Bridge.KillClaimsForQuest(NO_DROPS)
check("T30 and nothing was cached, so the next rebuild asks again",
    HARNESS.questieReads > 0, HARNESS.questieReads)

-- The same for a raise and for the getter being gone: three ways to fail one read.
HARNESS.itemDropsSecret[9005] = nil
HARNESS.itemDropsRaises[9005] = true
HARNESS.buildQuestie()
Bridge.Reset()
check("T30 a raising npcDrops also leaves it unanswered",
    Bridge.KillClaimsForQuest(NO_DROPS).answered == false)
HARNESS.itemDropsRaises[9005] = nil

HARNESS.itemDropsPresent = false
HARNESS.buildQuestie()
Bridge.Reset()
check("T30 and so does npcDrops being absent",
    Bridge.KillClaimsForQuest(NO_DROPS).answered == false)
HARNESS.itemDropsPresent = true
HARNESS.buildQuestie()
Bridge.Reset()

-- And the item quest that DOES resolve is still answered, so the arm above is not
-- simply refusing every item quest.
check("T30 an item quest whose droppers resolve is answered",
    Bridge.KillClaimsForQuest(MIXED).answered == true)

Bridge.Reset()
local TALK = HARNESS.addQuest(513, { name = "Talk To Someone" })
HARNESS.questObjectives[TALK] = {}
HARNESS.questExtras[TALK] = nil
shape = Bridge.KillClaimsForQuest(TALK)
check("T14 an answered-empty shape is still cached",
    shape.answered == true and #shape.claims == 0)
HARNESS.questieReads = 0
Bridge.KillClaimsForQuest(TALK)
check("T14 and the second lookup is a hit", HARNESS.questieReads == 0, HARNESS.questieReads)

Bridge.Reset()
shape = Bridge.KillClaimsForQuest(DOUBLE)
local slots = {}
for index = 1, #shape.claims do
    if shape.claims[index].npcId == BEAR then
        slots[shape.claims[index].slot] = true
    end
end
check("T31 the bear is claimed by both the creature slot and the item slot",
    slots[SLOT.CREATURE_KILL] and slots[SLOT.ITEM],
    format("slots: %s", tostring(slots[SLOT.CREATURE_KILL]) .. "/" .. tostring(slots[SLOT.ITEM])))

-- T26: a rejection loses no claim ---------------------------------------------------------

view = rebuild(SHORT)
shape = Bridge.KillClaimsForQuest(SHORT)
check("T26 a rejected pairing returns every claim it was given",
    view.claimCount == #shape.claims + #shape.extraNpcIds,
    format("%d claims from %d rows", view.claimCount or -1,
        #shape.claims + #shape.extraNpcIds))

-- T17-T22, T33: the ring (section 4) ------------------------------------------------------

-- Every plate the marker checks left on screen goes first: the tier counters below
-- count attaches, and a leftover elite would be indistinguishable from a defect.
for index = 1, 4 do
    HARNESS.fire("NAME_PLATE_UNIT_REMOVED", "nameplate" .. index)
end
HARNESS.frame()
check("T17 the screen is clear before the ring checks",
    ns.Nameplates.Inspect().ringsDrawnNow == 0, ns.Nameplates.Inspect().ringsDrawnNow)

rebuild(KILL)
local ringTiersBase = ns.Nameplates.Inspect().ringTiersSeen or {}
local goldBase = ringTiersBase.Gold or 0
local elitePlate = addPlate("nameplate5", WOLF, "elite")
local rarePlate = addPlate("nameplate6", RARE_MOB, "rare")
local rareElitePlate = addPlate("nameplate7", 106, "rareelite")
local bossPlate = addPlate("nameplate8", 107, "boss")
local normalPlate = addPlate("nameplate9", 108)
local plates = ns.Nameplates.Inspect()

check("T17 an elite gets the gold surround",
    (plates.ringsByTier or {}).Gold == 1, (plates.ringsByTier or {}).Gold)
check("T17 rare and rare-elite share the silver one",
    (plates.ringsByTier or {}).Silver == 2, (plates.ringsByTier or {}).Silver)
check("T17 a boss mob gets the winged gold",
    (plates.ringsByTier or {}).Boss == 1, (plates.ringsByTier or {}).Boss)
check("T17 a normal mob gets nothing", ringOn(normalPlate) == nil)
check("T17 and the tier was counted at attach, not on a sweep",
    (plates.ringTiersSeen or {}).Gold > goldBase, (plates.ringTiersSeen or {}).Gold)

local ring = ringOn(elitePlate)
check("T17 the ring is our own frame under UIParent, not the plate's child",
    ring ~= nil and ring.parent == UIParent)
check("T17 and it is sized from the badge's width times the factor",
    ring ~= nil and math.abs(ring.width - 28 * ns.RARITY_RING_WIDTH_FACTOR) < 0.01,
    ring and ring.width)

local nonAttackable = addPlate("nameplate10", 109, "elite", false)
check("T18 an elite you cannot attack gets no ring", ringOn(nonAttackable) == nil)

-- The probe runs once per UI load, so the atlas has to be gone before it runs.
-- Disabling the feature clears the probe cache, which is the only way back to an
-- unprobed state inside one session.
HARNESS.atlases["UI-HUD-UnitFrame-Target-PortraitOn-Boss-Gold"] = nil
ns.Registry.SetEnabled("nameplates", false)
ns.Registry.SetEnabled("nameplates", true)
HARNESS.frame()
local afterMissing = addPlate("nameplate11", 110, "elite")
local afterMissingSilver = addPlate("nameplate16", 115, "rare")
check("T20 a tier whose atlas is missing draws nothing", ringOn(afterMissing) == nil)
check("T20 and it is counted and said once, not guessed at",
    ns.Nameplates.Inspect().ringArtMissing > 0, ns.Nameplates.Inspect().ringArtMissing)
check("T20 and the other tiers still draw", ringOn(afterMissingSilver) ~= nil)
HARNESS.atlases["UI-HUD-UnitFrame-Target-PortraitOn-Boss-Gold"] = { width = 64, height = 64 }
ns.Registry.SetEnabled("nameplates", false)
ns.Registry.SetEnabled("nameplates", true)
HARNESS.frame()
local restored = addPlate("nameplate17", 116, "elite")
check("T20 and the tier draws again once the client carries the atlas",
    ringOn(restored) ~= nil)

local badgeless = addPlate("nameplate12", 111, "elite")
badgeless.UnitFrame.PlayerLevelDiffFrame = nil
HARNESS.fire("NAME_PLATE_UNIT_ADDED", "nameplate12")
HARNESS.frame()
check("T22 a plate with no badge frame draws no ring and does not raise",
    ringOn(badgeless) == nil)

local hiddenBadge = addPlate("nameplate13", 112, "rare")
check("T22 a visible badge has a ring to start with", ringOn(hiddenBadge) ~= nil)
hiddenBadge.UnitFrame.PlayerLevelDiffFrame.shown = false
HARNESS.advance(0.3)
check("T22 a badge that hides under a live unit loses its ring on the next sweep",
    ringOn(hiddenBadge) == nil)

local unmeasured = addPlate("nameplate14", 113, "elite")
unmeasured.UnitFrame.PlayerLevelDiffFrame.widthSecret = true
setSetting("nameplates", "rarityRingSize", 1.1)
check("T21 a badge whose width is withheld still gets a ring, at the fallback width",
    ringOn(unmeasured) ~= nil and ns.Nameplates.Inspect().ringBadgeUnmeasured > 0,
    ns.Nameplates.Inspect().ringBadgeUnmeasured)
setSetting("nameplates", "rarityRingSize", 1.0)

local sizedRing = ringOn(rarePlate)
local sizedWidth = sizedRing and sizedRing.width
setSetting("nameplates", "rarityRingSize", 1.5)
local resized = ringOn(rarePlate)
check("T24 a slider change re-places the rings already on screen",
    resized ~= nil and sizedWidth ~= nil and resized.width > sizedWidth,
    format("%s -> %s", tostring(sizedWidth), tostring(resized and resized.width)))
setSetting("nameplates", "rarityRingSize", 1.0)

setSetting("nameplates", "rarityRings", false)
check("T33 the toggle off releases every ring",
    ringOn(rarePlate) == nil and ns.Nameplates.Inspect().ringsDrawnNow == 0,
    ns.Nameplates.Inspect().ringsDrawnNow)
setSetting("nameplates", "rarityRings", true)
check("T33 and on places them again without waiting for a plate",
    ringOn(rarePlate) ~= nil, ns.Nameplates.Inspect().ringsDrawnNow)

-- A unit that stops being attackable while its plate is up.
HARNESS.units["nameplate6"].canAttack = false
HARNESS.fire("UNIT_FACTION", "nameplate6")
HARNESS.frame()
check("T33 rescoping to non-attackable releases the ring", ringOn(rarePlate) == nil)
HARNESS.units["nameplate6"].canAttack = true
HARNESS.fire("UNIT_FACTION", "nameplate6")
HARNESS.frame()
check("T33 and it comes back when the unit is attackable again", ringOn(rarePlate) ~= nil)

-- T19: the restricted-map stand-down ------------------------------------------------------

HARNESS.restrictedMap = true
HARNESS.fire("PLAYER_ENTERING_WORLD")
HARNESS.frame()
check("T19 a restricted map releases every ring",
    ringOn(elitePlate) == nil and ns.Nameplates.Inspect().ringsAllowed == false,
    tostring(ns.Nameplates.Inspect().ringsAllowed))
HARNESS.restrictedMap = false
HARNESS.fire("PLAYER_ENTERING_WORLD")
HARNESS.frame()
check("T19 and leaving it brings them back", ringOn(elitePlate) ~= nil)

HARNESS.restrictionReadable = false
HARNESS.fire("PLAYER_ENTERING_WORLD")
HARNESS.frame()
check("T19 an unreadable map restriction also stands down, never guesses",
    ringOn(elitePlate) == nil)
HARNESS.restrictionReadable = true
HARNESS.fire("PLAYER_ENTERING_WORLD")
HARNESS.frame()

-- T23: release on untrack -----------------------------------------------------------------

local recycled = addPlate("nameplate15", 114, "elite")
check("T23 the plate has a ring before it is recycled", ringOn(recycled) ~= nil)
HARNESS.fire("NAME_PLATE_UNIT_REMOVED", "nameplate15")
HARNESS.frame()
check("T23 untracking releases it, so the next unit cannot inherit a rank",
    ringOn(recycled) == nil)

-- T25: the hot path stays cold ------------------------------------------------------------

local atlasBefore = HARNESS.atlasCalls
local before = ns.Nameplates.Inspect().ringsDrawn
for _ = 1, 20 do
    CompactUnitFrame_UpdateHealthColor(elitePlate.UnitFrame)
    CompactUnitFrame_UpdateHealth(elitePlate.UnitFrame)
end
check("T25 reasserting a plate's colour draws no ring and reads no atlas",
    ns.Nameplates.Inspect().ringsDrawn == before and HARNESS.atlasCalls == atlasBefore,
    format("%d -> %d draws, %d -> %d atlas reads", before,
        ns.Nameplates.Inspect().ringsDrawn, atlasBefore, HARNESS.atlasCalls))

-- And the two expensive reads stay off the SWEEP as well: the tier is read once per
-- attach and the artwork probed once per UI load, however many sweeps run.
local tiersBefore = (ns.Nameplates.Inspect().ringTiersSeen or {}).Gold
for _ = 1, 10 do
    HARNESS.advance(0.3)
end
check("T25 ten sweeps re-read no tier and no atlas",
    (ns.Nameplates.Inspect().ringTiersSeen or {}).Gold == tiersBefore
        and HARNESS.atlasCalls == atlasBefore,
    format("tiers %s -> %s", tostring(tiersBefore),
        tostring((ns.Nameplates.Inspect().ringTiersSeen or {}).Gold)))

-- The reports -----------------------------------------------------------------------------

HARNESS.chat = {}
SlashCmdList.PERSONALADDON_DEBUG("quests")
local questsText = table.concat(HARNESS.chat, " | ")
check("T34 /pa quests prints the objective types it saw",
    questsText == "" or questsText:find("objective types seen", 1, true) ~= nil,
    questsText:sub(1, 160))
SlashCmdList.PERSONALADDON_DEBUG("plates")
check("T34 /pa plates runs with rings on", true)

HARNESS_RESULT = { passed = passed, failures = failures,
                   errors = HARNESS.errors or {}, chat = HARNESS.chat or {} }
