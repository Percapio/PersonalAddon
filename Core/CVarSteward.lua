-- Core/CVarSteward.lua
-- Records a CVar's original value before we overwrite it, so it can be put back
-- exactly (Phase 5 section 5).
--
-- The same shape as the style ledger in Phase 2, and for the same reason: we are
-- changing state we do not own, so restoring means writing back what was ACTUALLY
-- there rather than what we believe the default to be. A CVar outlives the addon,
-- so an addon that changes one and leaves it has permanently altered the user's
-- client -- invisibly, and with no way for them to know which addon did it.
--
-- It has no queue and no lifecycle. It records, writes, and reports one of three
-- outcomes; it subscribes to nothing and schedules nothing. A caller that wants to
-- retry a refused write owns that retry, so disable can clear it.

local ADDON_NAME, ns = ...

local CVarSteward = {}
ns.CVarSteward = CVarSteward

local type, tostring, tonumber, pairs, pcall = type, tostring, tonumber, pairs, pcall
local format = string.format

CVarSteward.OUTCOME = {
    APPLIED = "Applied",
    REFUSED_OUTRIGHT = "RefusedOutright",
    REFUSED_IN_COMBAT = "RefusedInCombat",
    ABSENT = "Absent",
}

local OUTCOME = CVarSteward.OUTCOME

-- Accessors resolved rather than assumed: this client has already proved a
-- namespace can exist while a specific function in it does not.
local function readCVar(name)
    local reader = (C_CVar and C_CVar.GetCVar) or _G.GetCVar
    if type(reader) ~= "function" then
        return nil
    end
    local ok, value = pcall(reader, name)
    if not ok then
        return nil
    end
    return value
end

local function writeCVar(name, value)
    local writer = (C_CVar and C_CVar.SetCVar) or _G.SetCVar
    if type(writer) ~= "function" then
        return false
    end
    return pcall(writer, name, value)
end

local function inCombat()
    local ok, combat = pcall(UnitAffectingCombat, "player")
    return ok and combat == true
end

-- CVars are strings, and the client normalises them: asking for "15" reads back
-- "15.000000". So a write is verified numerically where both sides parse as
-- numbers, and textually otherwise.
local function valuesMatch(left, right)
    if left == right then
        return true
    end
    local leftNumber, rightNumber = tonumber(left), tonumber(right)
    if leftNumber and rightNumber then
        return math.abs(leftNumber - rightNumber) < 0.0001
    end
    return false
end

function CVarSteward.Create(stewardName)
    return {
        stewardName = stewardName or "unnamed",
        records = {},
        recordCount = 0,
        restored = 0,
        refused = 0,
        absent = 0,
    }
end

function CVarSteward.Exists(cvarName)
    return readCVar(cvarName) ~= nil
end

-- Returns an OUTCOME. On any refusal NOTHING is recorded: a record for a CVar we
-- never changed would make restore overwrite a value the client is managing, which
-- is the defect Phase 2's ledger shipped with and the harness caught.
function CVarSteward.Apply(steward, cvarName, newValue)
    local original = readCVar(cvarName)
    if original == nil then
        steward.absent = steward.absent + 1
        return OUTCOME.ABSENT
    end

    local wrote = writeCVar(cvarName, newValue)
    local readBack = readCVar(cvarName)

    if not wrote or not valuesMatch(readBack, newValue) then
        steward.refused = steward.refused + 1
        -- Distinguishing the two refusals costs one check and makes a future
        -- client patch's behaviour diagnosable. Acting on the distinction is the
        -- caller's business, not the steward's.
        if inCombat() then
            return OUTCOME.REFUSED_IN_COMBAT
        end
        return OUTCOME.REFUSED_OUTRIGHT
    end

    -- Record-once. The original is whatever was there before WE touched it;
    -- re-recording on a second write captures our own value and makes restore a
    -- no-op, which is how an addon permanently alters a client setting.
    local existing = steward.records[cvarName]
    if existing then
        existing.appliedValue = tostring(newValue)
    else
        steward.records[cvarName] = {
            name = cvarName,
            originalValue = original,
            appliedValue = tostring(newValue),
        }
        steward.recordCount = steward.recordCount + 1
    end

    return OUTCOME.APPLIED
end

function CVarSteward.OriginalOf(steward, cvarName)
    local record = steward.records[cvarName]
    return record and record.originalValue or nil
end

function CVarSteward.RestoreOne(steward, cvarName)
    local record = steward.records[cvarName]
    if not record then
        return false
    end

    local wrote = writeCVar(cvarName, record.originalValue)
    steward.records[cvarName] = nil
    steward.recordCount = steward.recordCount - 1

    if wrote then
        steward.restored = steward.restored + 1
    else
        steward.refused = steward.refused + 1
    end
    return wrote
end

-- Counts THIS call, not the steward's lifetime. Returning the cumulative counters
-- reported "restored 2, refused 2" when two restores succeeded and the two refusals
-- had happened earlier, during Apply -- a report that conflates two different
-- failures, which is the wrong-but-believable class of defect.
function CVarSteward.RestoreAll(steward)
    local names = {}
    for name in pairs(steward.records) do
        names[#names + 1] = name
    end

    local restored, refused = 0, 0
    for index = 1, #names do
        if CVarSteward.RestoreOne(steward, names[index]) then
            restored = restored + 1
        else
            refused = refused + 1
        end
    end

    return {
        restored = restored,
        refused = refused,
        absent = 0,
        lifetimeRefused = steward.refused,
    }
end

function CVarSteward.Stats(steward)
    return steward.recordCount, steward.restored, steward.refused, steward.absent
end

-- Every record as a printable line, so the values to restore by hand are always
-- visible. A client crash leaves a CVar modified and nothing can prevent that; the
-- least this can do is say what to put back.
function CVarSteward.Describe(steward)
    local lines = {}
    for name, record in pairs(steward.records) do
        lines[#lines + 1] = format("%s: ours=%s original=%s",
            name, tostring(record.appliedValue), tostring(record.originalValue))
    end
    table.sort(lines)
    return lines
end
