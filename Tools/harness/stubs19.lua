-- Offline stand-ins for objective progress and unit classification
-- (Architecture/20261016-Phase19.md section 11.1). The atlas reader and the level badge
-- that stood in for the rare/elite ring went with the ring
-- (Architecture/20261104-Patch02.md section 5.3); the classification wrapper stays,
-- because the threat panel's +/r tags are checked against it in other sessions.
--
-- The knobs, because the design's failure arms differ:
--
--   HARNESS.clientObjectives[questId]   the rows GetQuestObjectives answers with,
--                                       each {type=, finished=}. nil means the call
--                                       RETURNS NOTHING, which is the MayReturnNothing
--                                       arm and must keep markers rather than hide them
--   HARNESS.objectivesSecret[questId]   the call answers a withheld value instead
--   HARNESS.questComplete[questId]      what IsComplete answers
--   HARNESS.completeSecret[questId]     IsComplete answers a withheld value
--
--   HARNESS.classifications[token]      what UnitClassification answers
--   HARNESS.bossMobs[token]             what UnitIsBossMob answers
--   HARNESS.objectiveFirst              LibQuestieDB.ObjectiveFirst's five sets

HARNESS.clientObjectives = {}
HARNESS.objectivesSecret = {}
HARNESS.questComplete = {}
HARNESS.completeSecret = {}
HARNESS.objectiveCalls = 0
HARNESS.completeCalls = 0

C_QuestLog = C_QuestLog or {}

-- MayReturnNothing is the whole point: a quest with no entry here gets NOTHING back,
-- not an empty list, and the feature must tell those two apart.
function C_QuestLog.GetQuestObjectives(questId)
    HARNESS.objectiveCalls = HARNESS.objectiveCalls + 1
    if HARNESS.objectivesSecret[questId] then
        return HARNESS.SECRET
    end
    local rows = HARNESS.clientObjectives[questId]
    if rows == nil then
        return nil
    end
    -- A fresh copy per call: the real one allocates, and a test that mutated ours
    -- would be testing its own fixture.
    local out = {}
    for index = 1, #rows do
        local row = rows[index]
        out[index] = {
            text = row.text or "objective",
            type = row.type,
            finished = row.finished == true,
            numFulfilled = row.numFulfilled or (row.finished and 10 or 3),
            numRequired = row.numRequired or 10,
        }
    end
    return out
end

function C_QuestLog.IsComplete(questId)
    HARNESS.completeCalls = HARNESS.completeCalls + 1
    if HARNESS.completeSecret[questId] then
        return HARNESS.SECRET
    end
    return HARNESS.questComplete[questId] == true
end

-- One row per client objective, in the client's own order.
function HARNESS.setClientObjectives(questId, rows)
    HARNESS.clientObjectives[questId] = rows
end

-- Classification -------------------------------------------------------------------------

HARNESS.classifications = {}
HARNESS.bossMobs = {}
HARNESS.classificationSecret = {}

-- Wrapped, not replaced: stubs11's version reads unit.classification and the threat
-- panel's +/r tags are checked against it. Replacing it outright silently retired
-- that check, which is the aliasing trap the harness notes warn about.
local priorUnitClassification = UnitClassification
function UnitClassification(token)
    if HARNESS.classificationSecret[token] then
        return HARNESS.SECRET
    end
    local own = HARNESS.classifications[token]
    if own ~= nil then
        return own
    end
    return priorUnitClassification and priorUnitClassification(token) or "normal"
end

local priorUnitIsBossMob = UnitIsBossMob
function UnitIsBossMob(token)
    if HARNESS.bossMobs[token] ~= nil then
        return HARNESS.bossMobs[token] == true
    end
    return priorUnitIsBossMob and priorUnitIsBossMob(token) or false
end

-- LibQuestieDB.ObjectiveFirst -------------------------------------------------------------
--
-- Published hints, per src/corrections/_end.lua:18. Kept as a harness table so a
-- check can add an entry and prove the pairing order moved.

HARNESS.objectiveFirst = {
    killCreditObjectiveFirst = {},
    objectObjectiveFirst = {},
    itemObjectiveFirst = {},
    eventObjectiveFirst = {},
    spellObjectiveFirst = {},
}
HARNESS.objectiveFirstPresent = true

-- ItemDB.npcDrops, per item, for the arm section 3 added to `answered`.
--
-- stubs17's getter hands back freshCopy(entry), and freshCopy of HARNESS.SECRET is a
-- NEW plain table -- the sentinel is an identity, so a deep copy launders it into a
-- readable empty list. Setting HARNESS.itemDrops[id] = HARNESS.SECRET therefore tests
-- nothing at all. These two knobs reach the getter itself.
HARNESS.itemDropsSecret = {}
HARNESS.itemDropsRaises = {}
HARNESS.itemDropsPresent = true

local priorBuildQuestie = HARNESS.buildQuestie
HARNESS.buildQuestie = function()
    priorBuildQuestie()
    if LibQuestieDB and HARNESS.objectiveFirstPresent then
        LibQuestieDB.ObjectiveFirst = HARNESS.objectiveFirst
    end
    if ItemDB then
        if not HARNESS.itemDropsPresent then
            ItemDB.npcDrops = nil
        else
            local priorDrops = ItemDB.npcDrops
            ItemDB.npcDrops = function(itemId)
                if HARNESS.itemDropsRaises[itemId] then
                    error("npcDrops raised")
                end
                if HARNESS.itemDropsSecret[itemId] then
                    return HARNESS.SECRET
                end
                return priorDrops(itemId)
            end
        end
    end
end
HARNESS.buildQuestie()

function HARNESS.resetPhase19()
    HARNESS.clientObjectives = {}
    HARNESS.objectivesSecret = {}
    HARNESS.questComplete = {}
    HARNESS.completeSecret = {}
    HARNESS.objectiveCalls = 0
    HARNESS.completeCalls = 0
    HARNESS.classifications = {}
    HARNESS.bossMobs = {}
    HARNESS.classificationSecret = {}
    for field in pairs(HARNESS.objectiveFirst) do
        HARNESS.objectiveFirst[field] = {}
    end
end

-- Recording SetSize, SetAtlas and the restriction knob ------------------------------------
--
-- stubs8's frame and region metatables answer any unknown PascalCase method with a
-- no-op, which is the trap the harness notes warn about: SetSize and SetAtlas would
-- both "work" and record nothing, and every size and artwork check would pass for
-- the wrong reason. stubs8's method tables are file-local, so the recording versions
-- are rawset per instance, as stubs18 does for a font string.

local priorCreateFrame = CreateFrame

local function wrapTexture(region)
    rawset(region, "SetAtlas", function(self, atlas, useAtlasSize)
        self.atlas = atlas
        self.useAtlasSize = useAtlasSize
        HARNESS.atlasSets = (HARNESS.atlasSets or 0) + 1
    end)
    rawset(region, "GetAtlas", function(self) return self.atlas end)
    return region
end

function CreateFrame(...)
    local frame = priorCreateFrame(...)
    rawset(frame, "SetSize", function(self, width, height)
        self.width = width
        self.height = height
    end)
    local priorCreateTexture = frame.CreateTexture
    rawset(frame, "CreateTexture", function(self, ...)
        return wrapTexture(priorCreateTexture(self, ...))
    end)
    return frame
end

HARNESS.restrictionReadable = true
local priorIsRestricted = C_RestrictedActions.IsAddOnRestrictionActive
C_RestrictedActions.IsAddOnRestrictionActive = function(restrictionType)
    if not HARNESS.restrictionReadable then
        return HARNESS.SECRET
    end
    return priorIsRestricted(restrictionType)
end
