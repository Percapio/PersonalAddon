-- Offline stand-ins for Phase 22 (Architecture/20261122-Phase22.md section 14.1).
-- Loaded after every earlier stub file, for every session. Everything here WRAPS;
-- nothing replaces (Phase 19's lesson: an earlier session asserts on the old stub,
-- and replacing it silently retires that check).
--
-- What loads for every session changes nothing an older session can see: the name
-- region gains colour methods no older code calls, the anchor table gains a third key,
-- and installCVars gains GetCVarInfo. The unit reads that DO change answers --
-- UnitIsPlayer above all, which testsPatch02 runs without -- are installed only by
-- HARNESS.installPlayerUnits(), which tests22 calls before login.
--
-- Knobs, by subject:
--
--   HARNESS.nameColourRefuse      "read": a name's GetVertexColor answers the secret
--                                 "write": SetVertexColor is a silent no-op
--                                 "raise": SetVertexColor raises
--   region.colourSecret           "read" for that one region (C6, C7)
--
--   unit.isPlayer, isPlayerSecret what UnitIsPlayer(unit) answers
--   unit.attacksPlayer            what UnitCanAttack(unit, "player") answers
--   unit.canAttackSecret          UnitCanAttack("player", unit) answers the secret
--   unit.attacksPlayerSecret      UnitCanAttack(unit, "player") answers the secret
--   unit.isYou, youSecret         what UnitIsUnit(unit, "player") answers
--
--   HARNESS.cvarInfo[name]        C_CVar.GetCVarInfo's seven returns, preset to the
--                                 user's dumps of 2026-11-22 (section 7.1)
--   HARNESS.anchorReads           reads of NamePlateSetupOptions.unitNameAnchorStyle,
--                                 once HARNESS.countAnchorReads() has run

-- A nameplate's name gains a colour ------------------------------------------------------
--
-- stubs20's region is its own table, with no metatable, so it has no GetVertexColor at
-- all; and stubs8's regions answer any unknown method with a silent no-op. Either way a
-- colour check would pass for the wrong reason. This region starts white, logs every
-- write, and counts its reads and writes (C8).

HARNESS.nameColourRefuse = nil
HARNESS.nameColourWrites = 0

local priorNewNameRegion = HARNESS.newNameRegion
function HARNESS.newNameRegion(initial)
    local region = priorNewNameRegion(initial)
    region.vertex = { 1, 1, 1 }
    region.colourLog = {}
    region.colourReads = 0
    region.colourWrites = 0
    function region:GetVertexColor()
        self.colourReads = self.colourReads + 1
        if HARNESS.nameColourRefuse == "read" or self.colourSecret then
            return HARNESS.SECRET, HARNESS.SECRET, HARNESS.SECRET, 1
        end
        return self.vertex[1], self.vertex[2], self.vertex[3], 1
    end
    function region:SetVertexColor(red, green, blue)
        self.colourWrites = self.colourWrites + 1
        HARNESS.nameColourWrites = HARNESS.nameColourWrites + 1
        self.colourLog[#self.colourLog + 1] = { red, green, blue }
        if HARNESS.nameColourRefuse == "raise" then
            error("SetVertexColor refused")
        end
        if HARNESS.nameColourRefuse == "write" then
            return
        end
        self.vertex = { red, green, blue }
    end
    -- Blizzard's own write, for tests22's CompactUnitFrame_UpdateName: logged, marked,
    -- and never counted as ours, nor subject to the refusal knobs.
    function region:BlizzardSetColour(red, green, blue)
        self.vertex = { red, green, blue }
        self.colourLog[#self.colourLog + 1] = { red, green, blue, blizzard = true }
    end
    return region
end

-- The anchor styles ------------------------------------------------------------------------
--
-- stubs20 defines two of Camelot's three (stubs20.lua:286). The third is added to the
-- same table; read_name_anchor must cope with its absence too (Y10), which a test
-- shows by taking it away.
NamePlateConstants.NAME_ANCHOR_STYLES.CenteredAboveHealthBar = 3

function HARNESS.setPlateStyle(style)
    if not NamePlateSetupOptions then
        HARNESS.installNameOptions()
    end
    local styles = NamePlateConstants.NAME_ANCHOR_STYLES
    if style == "Above" then
        NamePlateSetupOptions.unitNameAnchorStyle = styles.AboveHealthBar
    elseif style == "Inside" then
        NamePlateSetupOptions.unitNameAnchorStyle = styles.InsideHealthBar
    elseif style == "Centred" then
        NamePlateSetupOptions.unitNameAnchorStyle = 3
    else
        NamePlateSetupOptions.unitNameAnchorStyle = HARNESS.SECRET
    end
end

-- A proxy in front of NamePlateSetupOptions that counts reads of the anchor style.
-- Writes pass through to the real table, so a direct assignment still lands.
HARNESS.anchorReads = 0
function HARNESS.countAnchorReads()
    local real = NamePlateSetupOptions or {}
    HARNESS.realNameOptions = real
    NamePlateSetupOptions = setmetatable({}, {
        __index = function(_, key)
            if key == "unitNameAnchorStyle" then
                HARNESS.anchorReads = HARNESS.anchorReads + 1
            end
            return real[key]
        end,
        __newindex = function(_, key, value)
            real[key] = value
        end,
    })
end

-- The unit reads, installed by tests22 alone ------------------------------------------------

HARNESS.canAttackCalls = { you = 0, they = 0 }
HARNESS.unitIsPlayerCalls22 = 0
HARNESS.youCalls = 0

function HARNESS.installPlayerUnits()
    -- stubs.lua's UnitCanAttack ignores its first argument (stubs.lua:217), so
    -- UnitCanAttack(token, "player") would read the player's own row.
    local priorCanAttack = UnitCanAttack
    function UnitCanAttack(left, right)
        if right == "player" and left ~= "player" then
            HARNESS.canAttackCalls.they = HARNESS.canAttackCalls.they + 1
            local unit = HARNESS.resolve(left)
            if unit and unit.attacksPlayerSecret then
                return HARNESS.SECRET
            end
            return unit ~= nil and unit.attacksPlayer == true
        end
        HARNESS.canAttackCalls.you = HARNESS.canAttackCalls.you + 1
        local unit = HARNESS.resolve(right)
        if unit and unit.canAttackSecret then
            return HARNESS.SECRET
        end
        return priorCanAttack(left, right)
    end

    local priorIsPlayer = UnitIsPlayer
    function UnitIsPlayer(token)
        HARNESS.unitIsPlayerCalls22 = HARNESS.unitIsPlayerCalls22 + 1
        local unit = HARNESS.resolve(token)
        if unit and unit.isPlayerSecret then
            return HARNESS.SECRET
        end
        if unit and unit.isPlayer ~= nil then
            return unit.isPlayer == true
        end
        if priorIsPlayer then
            return priorIsPlayer(token)
        end
        return false
    end

    local priorIsUnit = UnitIsUnit
    function UnitIsUnit(left, right)
        if right == "player" and left ~= "player" then
            HARNESS.youCalls = HARNESS.youCalls + 1
            local unit = HARNESS.resolve(left)
            if unit and unit.youSecret then
                return HARNESS.SECRET
            end
            if unit and unit.isYou ~= nil then
                return unit.isYou == true
            end
        end
        return priorIsUnit(left, right)
    end
end

-- A player's plate, built whole BEFORE NAME_PLATE_UNIT_ADDED fires once ---------------------
--
-- stubs20's addPlate20 fires the event before it returns (stubs20.lua:275), so fields
-- set afterwards would be missing when the attach runs (audit finding 9). The event is
-- silenced around the call, restored even if the call raises, and fired once at the end.
function HARNESS.addPlayerPlate(token, fields)
    fields = fields or {}
    local realFire = HARNESS.fire
    HARNESS.fire = function() end
    local ok, frame = pcall(HARNESS.addPlate20, token, {
        isPlayer = true,
        canAttack = fields.canAttack,
        friend = fields.friend,
        guild = fields.guild,
        showOnlyName = fields.showOnlyName,
        noName = fields.noName,
    })
    HARNESS.fire = realFire
    if not ok then
        error(frame)
    end
    local unit = HARNESS.units[token]
    unit.isPlayer = fields.isPlayer ~= false
    unit.isPlayerSecret = fields.isPlayerSecret
    unit.attacksPlayer = fields.attacksPlayer
    unit.canAttackSecret = fields.canAttackSecret
    unit.attacksPlayerSecret = fields.attacksPlayerSecret
    unit.isYou = fields.isYou
    unit.youSecret = fields.youSecret
    frame.UnitFrame.colorNameWithClassColor = fields.classColour
    if frame.UnitFrame.name then
        frame.UnitFrame.name.colourSecret = fields.colourSecret
    end
    HARNESS.fire("NAME_PLATE_UNIT_ADDED", token)
    return frame
end

-- The draw-distance settings ---------------------------------------------------------------

HARNESS.cvarInfo = {
    nameplateMaxDistance = { "45.000000", "45.000000", false, true, false, true, false },
    nameplatePlayerMaxDistance = { "40.000000", "40.000000", false, true, false, true, false },
}
HARNESS.cvarInfoCalls = 0
HARNESS.consoleExecCalls = 0
HARNESS.globalSetCVarCalls = 0

local priorInstallCVars = HARNESS.installCVars
function HARNESS.installCVars(values)
    priorInstallCVars(values)
    C_CVar.GetCVarInfo = function(name)
        HARNESS.cvarInfoCalls = HARNESS.cvarInfoCalls + 1
        local info = HARNESS.cvarInfo[name]
        if not info then
            return nil
        end
        return unpack(info, 1, 7)
    end
end

-- Recorded, never acted on: Phase 22 must never call either (D3).
if SetCVar == nil then
    function SetCVar()
        HARNESS.globalSetCVarCalls = HARNESS.globalSetCVarCalls + 1
    end
end
if ConsoleExec == nil then
    function ConsoleExec()
        HARNESS.consoleExecCalls = HARNESS.consoleExecCalls + 1
    end
end
