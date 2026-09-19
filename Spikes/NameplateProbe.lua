-- Spikes/NameplateProbe.lua
-- The Phase 2 capability spike (section 4). Answers what this client permits,
-- once, on paper, so section 7 and section 9 are written against observation
-- rather than an assumed API. Three Phase 1 assumptions about this client were
-- falsified; assuming again costs more than a probe.
--
-- Attempt tracking is built in from the start, which Phase 1's gossip probe
-- lacked: a question that was never asked must never report as a pass.
--
-- Delete this file once section 4.6 is filled in.

local ADDON_NAME, ns = ...

local FEATURE_ID = "nameplateProbe"
local format, tostring, pcall, type = string.format, tostring, pcall, type

ns.NameplateProbe = ns.NameplateProbe or {}

local VERDICT = {
    AVAILABLE = "Available",
    WITHHELD = "Withheld",
    ABSENT = "Absent",
    NOT_TESTED = "NotTested",
}

local findings = {}

local function record(key, verdict, detail)
    findings[key] = { verdict = verdict, detail = detail }
end

-- Arithmetic is the operation the restriction system refuses, so that is what we
-- test. A value we can hold but not compute with is Withheld, not Available.
local function probeArithmetic(reader, ...)
    if type(reader) ~= "function" then
        return VERDICT.ABSENT, "api absent"
    end
    local ok, value = pcall(reader, ...)
    if not ok then
        return VERDICT.WITHHELD, "read raised"
    end
    if value == nil then
        return VERDICT.ABSENT, "returned nil"
    end
    local computable = pcall(function() return value + 0 - 0 end)
    if not computable then
        return VERDICT.WITHHELD, "value is protected"
    end
    return VERDICT.AVAILABLE, tostring(value)
end

local function probePredicate(reader, ...)
    if type(reader) ~= "function" then
        return VERDICT.ABSENT, "api absent"
    end
    local ok, value = pcall(reader, ...)
    if not ok then
        return VERDICT.WITHHELD, "read raised"
    end
    return VERDICT.AVAILABLE, tostring(value)
end

local function plateApi()
    return C_NamePlate and C_NamePlate.GetNamePlateForUnit and C_NamePlate or nil
end

local function resolveParts(frame)
    local unitFrame = frame.UnitFrame or frame.unitFrame or frame
    local healthBar = unitFrame.healthBar or unitFrame.HealthBar or unitFrame.healthbar
    local nameText = unitFrame.name or unitFrame.Name
    return unitFrame, healthBar, nameText
end

-- 4.1 -------------------------------------------------------------------------
local function probeHealth(unitToken)
    local verdict, detail = probeArithmetic(UnitHealth, unitToken)
    record("health", verdict, detail)
    local maxVerdict, maxDetail = probeArithmetic(UnitHealthMax, unitToken)
    record("healthMax", maxVerdict, maxDetail)
end

-- 4.2 -------------------------------------------------------------------------
local function probeAggroSource(unitToken)
    local mobTarget = unitToken .. "target"

    local existsVerdict, existsDetail = probePredicate(UnitExists, mobTarget)
    record("targetOfTarget", existsVerdict, existsDetail)

    local combatVerdict, combatDetail = probePredicate(UnitAffectingCombat, unitToken)
    record("combatState", combatVerdict, combatDetail)

    local threatReader = _G.UnitThreatSituation
    if type(threatReader) ~= "function" then
        record("threatSituation", VERDICT.ABSENT, "UnitThreatSituation absent")
    else
        local verdict, detail = probeArithmetic(threatReader, "player", unitToken)
        record("threatSituation", verdict, detail)
    end

    -- The discriminating case: in combat with no resolvable target means the
    -- client is withholding it (section 9.2).
    --
    -- Note the explicit ok checks. select(2, pcall(...)) yields the error message
    -- on failure, and a message is truthy -- the bug that painted plates red.
    local combatOk, inCombatRaw = pcall(UnitAffectingCombat, unitToken)
    local inCombat = combatOk and inCombatRaw == true
    local existsOk, existsRaw = pcall(UnitExists, mobTarget)
    local targetExists = existsOk and existsRaw == true
    if inCombat and not targetExists then
        record("aggroWithheldEvidence", VERDICT.WITHHELD,
            "unit is in combat but its target does not resolve")
    elseif targetExists then
        record("aggroWithheldEvidence", VERDICT.AVAILABLE,
            "target resolved: " .. tostring(select(2, pcall(UnitName, mobTarget))))
    else
        record("aggroWithheldEvidence", VERDICT.NOT_TESTED,
            "unit was not in combat; re-run while it is fighting something")
    end
end

-- 4.3 and 4.5 -----------------------------------------------------------------
local function probeMutability(unitToken)
    local api = plateApi()
    if not api then
        record("frameReachable", VERDICT.ABSENT, "C_NamePlate.GetNamePlateForUnit absent")
        return
    end

    local ok, frame = pcall(api.GetNamePlateForUnit, unitToken)
    if not ok or not frame then
        record("frameReachable", VERDICT.WITHHELD, ok and "returned nil" or "lookup raised")
        return
    end
    record("frameReachable", VERDICT.AVAILABLE, "frame returned")

    local unitFrame, healthBar, nameText = resolveParts(frame)
    record("plateShape", healthBar and VERDICT.AVAILABLE or VERDICT.ABSENT, format(
        "unitFrame=%s healthBar=%s nameText=%s",
        unitFrame and "yes" or "no",
        healthBar and "yes" or "no",
        nameText and "yes" or "no"))

    if not healthBar then
        record("barResizable", VERDICT.ABSENT, "no health bar found")
        record("barRecolourable", VERDICT.ABSENT, "no health bar found")
    else
        -- Read, write the same value back, and see whether the write is allowed.
        -- Writing the current value means a permitted write changes nothing.
        local readOk, currentHeight = pcall(healthBar.GetHeight, healthBar)
        if not readOk or not currentHeight then
            record("barResizable", VERDICT.WITHHELD, "height not readable")
        else
            local writeOk = pcall(healthBar.SetHeight, healthBar, currentHeight)
            record("barResizable", writeOk and VERDICT.AVAILABLE or VERDICT.WITHHELD,
                format("height was %.1f", currentHeight))
        end

        if not healthBar.GetStatusBarColor then
            record("barRecolourable", VERDICT.ABSENT, "not a status bar")
        else
            local colourOk, red, green, blue = pcall(healthBar.GetStatusBarColor, healthBar)
            if not colourOk then
                record("barRecolourable", VERDICT.WITHHELD, "colour not readable")
            else
                local writeOk = pcall(healthBar.SetStatusBarColor, healthBar, red, green, blue)
                record("barRecolourable", writeOk and VERDICT.AVAILABLE or VERDICT.WITHHELD,
                    format("was %.2f %.2f %.2f", red or 0, green or 0, blue or 0))
            end
        end
    end

    if not nameText then
        record("nameTextMovable", VERDICT.ABSENT, "no name font string found")
    elseif nameText.IsForbidden and select(2, pcall(nameText.IsForbidden, nameText)) == true then
        -- Cheap pre-check: a forbidden region needs no measurement attempt, so
        -- it costs no taint complaint.
        record("nameTextMovable", VERDICT.WITHHELD, "forbidden region")
    else
        local countOk, count = pcall(nameText.GetNumPoints, nameText)
        if not countOk or not count or count == 0 then
            record("nameTextMovable", VERDICT.WITHHELD, "anchor count not readable")
        else
            -- ONE measurement attempt. On this client it is a restricted
            -- measurement, which the client LOGS rather than raises, so pcall
            -- returns success with a nil value. Treat nil as refusal.
            local pointOk, point, relativeTo, relativePoint, offsetX, offsetY =
                pcall(nameText.GetPoint, nameText, 1)
            if not pointOk or point == nil then
                record("nameTextMovable", VERDICT.WITHHELD,
                    "restricted region: the client refuses to measure it")
            else
                local writeOk = pcall(function()
                    nameText:ClearAllPoints()
                    nameText:SetPoint(point, relativeTo, relativePoint, offsetX, offsetY)
                end)
                record("nameTextMovable", writeOk and VERDICT.AVAILABLE or VERDICT.WITHHELD,
                    format("%d point(s), first is %s", count, tostring(point)))
            end
        end
    end

    -- Enumerate rather than stop at the first match: which of these exist decides
    -- whether a colour overwrite can be corrected in the same frame or only on
    -- the next sweep.
    local found = {}
    for _, name in ipairs({ "CompactUnitFrame_UpdateHealthColor",
                            "CompactUnitFrame_UpdateHealth",
                            "CompactUnitFrame_UpdateAll",
                            "CompactUnitFrame_SetUnit",
                            "CompactUnitFrame_UpdateName",
                            "DefaultCompactNamePlateFrameSetup" }) do
        if type(_G[name]) == "function" then
            found[#found + 1] = name
        end
    end
    record("revertingUpdatePath", #found > 0 and VERDICT.AVAILABLE or VERDICT.ABSENT,
        #found > 0 and table.concat(found, ", ") or "none of the known candidates exist")
    record("securePostHookAllowed",
        hooksecurefunc and VERDICT.AVAILABLE or VERDICT.ABSENT,
        hooksecurefunc and "hooksecurefunc present" or "hooksecurefunc absent")
end

-- 4.4 -------------------------------------------------------------------------
-- The first version of this probe asked only "did UnitPVPName return a string",
-- which it does: it returns the BARE NAME for an NPC with no title. That is not a
-- title source, and reporting it as Available was a false positive. The question
-- is whether the decorated name DIFFERS from the plain one.
local function probeNpcTitle(unitToken)
    local direct = _G.UnitPVPName
    if type(direct) ~= "function" then
        record("npcTitleSource", VERDICT.ABSENT, "UnitPVPName absent")
        return
    end

    local decoratedOk, decorated = pcall(direct, unitToken)
    if not decoratedOk or type(decorated) ~= "string" then
        record("npcTitleSource", VERDICT.WITHHELD, "UnitPVPName unreadable")
        return
    end

    local plainOk, plainName = pcall(UnitName, unitToken)
    if not plainOk or type(plainName) ~= "string" then
        record("npcTitleSource", VERDICT.NOT_TESTED,
            "could not read the plain name to compare against")
        return
    end

    if decorated == plainName then
        record("npcTitleSource", VERDICT.NOT_TESTED, format(
            "returned the bare name (%s), which is not a title; re-test on an NPC that has one, e.g. an innkeeper",
            plainName))
        return
    end

    record("npcTitleSource", VERDICT.AVAILABLE,
        format("%s -> %s", plainName, decorated))
end

-- Report ----------------------------------------------------------------------

local ROWS = {
    { "health", "4.1 health readable" },
    { "healthMax", "4.1 health max readable" },
    { "targetOfTarget", "4.2 target-of-target" },
    { "threatSituation", "4.2 threat situation" },
    { "combatState", "4.2 combat state" },
    { "aggroWithheldEvidence", "4.2 aggro evidence" },
    { "frameReachable", "4.3 frame reachable" },
    { "barResizable", "4.3 bar resizable" },
    { "barRecolourable", "4.3 bar recolourable" },
    { "nameTextMovable", "4.3 name text movable" },
    { "revertingUpdatePath", "4.3 reverting update path" },
    { "securePostHookAllowed", "4.3 secure post-hook" },
    { "npcTitleSource", "4.4 NPC title source" },
    { "plateShape", "4.5 frame shape" },
}

local function colourFor(verdict)
    if verdict == VERDICT.AVAILABLE then
        return "|cff55ff55"
    end
    if verdict == VERDICT.WITHHELD then
        return "|cffff5555"
    end
    if verdict == VERDICT.ABSENT then
        return "|cffffcc00"
    end
    return "|cff999999"
end

local function reportFindings()
    ns.Log.Info("nameplate capability spike, section 4:")
    local untested = 0
    for index = 1, #ROWS do
        local key, label = ROWS[index][1], ROWS[index][2]
        local found = findings[key]
        local verdict = found and found.verdict or VERDICT.NOT_TESTED
        if verdict == VERDICT.NOT_TESTED then
            untested = untested + 1
        end
        ns.Log.Info(format("  %-26s %s%s|r  %s", label,
            colourFor(verdict), verdict, found and tostring(found.detail) or "probe never ran"))
    end
    if untested > 0 then
        ns.Log.Warn(format("%d of %d questions are NotTested; that is not a pass",
            untested, #ROWS))
        ns.Log.Warn("target a hostile unit that is fighting something, then run /pa probe plates")
    else
        ns.Log.Info("all questions answered; record them in Architecture/20260919-Phase02.md section 4.6")
    end
    return true
end

function ns.NameplateProbe.Command(argument)
    if ns.Registry.State(FEATURE_ID) ~= ns.FEATURE_STATE.ENABLED then
        return false, "enable it first: /pa on " .. FEATURE_ID
    end

    if argument == "status" then
        return reportFindings()
    end

    local api = plateApi()
    if not api then
        record("frameReachable", VERDICT.ABSENT, "C_NamePlate absent")
        reportFindings()
        return false, "this client exposes no nameplate API; Phase 2 cannot proceed"
    end

    -- The target is the one unit we can be sure has a nameplate up and is the
    -- unit the user chose, so the probe is reproducible.
    local unitToken = "target"
    local ok, exists = pcall(UnitExists, unitToken)
    if not ok or not exists then
        return false, "target a hostile unit with a nameplate visible, ideally one in combat"
    end

    local attackable = select(2, pcall(UnitCanAttack, "player", unitToken))
    if not attackable then
        return false, "target an attackable unit; friendly plates are out of scope"
    end

    probeHealth(unitToken)
    probeAggroSource(unitToken)
    probeMutability(unitToken)
    probeNpcTitle(unitToken)

    return reportFindings()
end

local function enable()
    ns.Log.Info("nameplate probe armed; target a hostile unit in combat and run /pa probe plates")
    return true
end

local function disable()
end

ns.Registry.Register(FEATURE_ID, {
    enabledByDefault = false,
    settings = {},
}, {
    enable = enable,
    disable = disable,
    onConfigChanged = function()
        return ns.CONFIG_RESULT.APPLIED
    end,
})
