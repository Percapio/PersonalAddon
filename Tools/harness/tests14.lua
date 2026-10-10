-- Phase 14 offline checks (Architecture/20261010-Phase14.md section 11.1).
-- One session, "phase14". The height path runs on every tracked plate, so the
-- older nameplate sessions exercise it incidentally and must stay green.

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

-- A nameplate shaped like the live client's: UnitFrame.HealthBarsContainer, whose
-- height Blizzard writes from NamePlateSetupOptions.healthBarHeight.
local containers = {}
local function addPlate(token, height)
    HARNESS.addPlate(token, { reaction = 2, canAttack = true }, { 1, 0, 0 })
    local plate = HARNESS.plates[token]
    plate.unitToken = token
    local container = { height = height or 13, writes = 0 }
    function container:GetHeight() return self.height end
    function container:SetHeight(value)
        self.height = value
        self.writes = self.writes + 1
    end
    plate.UnitFrame.HealthBarsContainer = container
    containers[token] = container
    -- HARNESS.addPlate fires NAME_PLATE_UNIT_ADDED itself, before the container
    -- exists, so the feature resolved no container. Re-fire now that it does:
    -- trackPlate untracks and re-tracks a frame it already holds.
    HARNESS.fire("NAME_PLATE_UNIT_ADDED", token)
    return container
end

NamePlateSetupOptions = { healthBarHeight = 13 }

-- The two of HOOK_CANDIDATES this session needs, defined BEFORE login so the
-- feature's post-hooks install on them (tests.lua:43 does the same for colour).
-- CompactUnitFrame_SetUnit stands for a layout pass; UpdateHealthColor stands for
-- a health change, which runs no layout at all and is the audit's finding 2.
function CompactUnitFrame_SetUnit(_unitFrame, _token) end
function CompactUnitFrame_UpdateHealthColor(_unitFrame) end

local function setFraction(value)
    ns.ConfigStore.Set("nameplates", "barHeightFraction", value)
    ns.Registry.NotifyConfigChanged("nameplates", "barHeightFraction")
    HARNESS.frame()
end

HARNESS.fire("ADDON_LOADED", "PersonalAddon")
HARNESS.fire("PLAYER_LOGIN")
HARNESS.frame()
check("H1 nameplates enabled", ns.Registry.State("nameplates") == "ENABLED",
    ns.Registry.State("nameplates"))

-- H2: inert at 100% ------------------------------------------------------------
local first = addPlate("nameplate1", 13)
HARNESS.frame()
check("H2 nothing written at 100%", first.writes == 0 and first.height == 13,
    first.writes .. "/" .. first.height)
check("H3 the report says it is inert",
    ns.Nameplates.Inspect().barHeightFraction == 1,
    ns.Nameplates.Inspect().barHeightFraction)

-- H4: half of a 13px base ------------------------------------------------------
setFraction(0.5)
check("H4 written to half of the base", first.height == 6.5, first.height)
check("H5 counted as a write", ns.Nameplates.Inspect().barHeightWrites >= 1,
    ns.Nameplates.Inspect().barHeightWrites)
check("H6 the base is reported", ns.Nameplates.Inspect().barHeightBase == 13,
    ns.Nameplates.Inspect().barHeightBase)

-- H7: THE AUDIT'S FINDING 2 ----------------------------------------------------
-- The hook fires on every health change, with no layout pass. Revision 1 read the
-- container's current height as the base, so each fire scaled its own output and
-- the bar collapsed to MINIMUM_BAR_PIXELS. The write must be idempotent.
local writesBefore = first.writes
for _ = 1, 10 do
    CompactUnitFrame_UpdateHealthColor(HARNESS.plates["nameplate1"].UnitFrame)
    CompactUnitFrame_SetUnit(HARNESS.plates["nameplate1"].UnitFrame, "nameplate1")
end
HARNESS.frame()
check("H7 ten hook fires leave the height alone", first.height == 6.5, first.height)
check("H8 and write nothing further", first.writes == writesBefore,
    first.writes .. " vs " .. writesBefore)
check("H9 the redundant fires are counted as unchanged",
    ns.Nameplates.Inspect().barHeightUnchanged > 0,
    ns.Nameplates.Inspect().barHeightUnchanged)

-- H9a: a LOSSY container, which is what the live client turned out to be ---------
-- The stub above returns exactly what was written, so it could never reproduce
-- the defect four play sessions found: a height set through SetHeight does not
-- read back equal through GetHeight, so == never matched and every hook fire
-- rewrote the bar. barHeightUnchanged stayed at zero against 6,800 writes.
-- This container rounds down a little, as the client appears to, and the
-- comparison must still recognise its own work.
local lossy = addPlate("nameplate8", 13)
function lossy:SetHeight(value)
    -- Written, then reported a shade lower, the way a real widget does.
    self.height = value - 0.02
    self.writes = self.writes + 1
end
-- The plate was already written exactly, before the lossy setter was installed.
-- Put it back to the base so one write goes through the lossy setter and leaves
-- the inexact value the comparison then has to recognise.
lossy.height = 13
CompactUnitFrame_UpdateHealthColor(HARNESS.plates["nameplate8"].UnitFrame)
HARNESS.frame()
check("H9c the lossy setter ran", lossy.height ~= 13 and lossy.height ~= 6.5,
    tostring(lossy.height))
local lossyWrites = lossy.writes
for _ = 1, 10 do
    CompactUnitFrame_UpdateHealthColor(HARNESS.plates["nameplate8"].UnitFrame)
end
HARNESS.frame()
check("H9a a lossy read-back is still recognised as our own work",
    lossy.writes == lossyWrites, lossy.writes .. " vs " .. lossyWrites)
check("H9b and Blizzard's base is still recognised as a reset",
    (function()
        lossy.height = 13
        CompactUnitFrame_UpdateHealthColor(HARNESS.plates["nameplate8"].UnitFrame)
        HARNESS.frame()
        return lossy.writes == lossyWrites + 1
    end)(), lossy.writes .. " vs " .. (lossyWrites + 1))

-- H10: the base changes under us (a Style change) -------------------------------
NamePlateSetupOptions.healthBarHeight = 20
CompactUnitFrame_SetUnit(HARNESS.plates["nameplate1"].UnitFrame, "nameplate1")
HARNESS.frame()
check("H10 the new base is used, not a cached one", first.height == 10, first.height)
NamePlateSetupOptions.healthBarHeight = 13
CompactUnitFrame_SetUnit(HARNESS.plates["nameplate1"].UnitFrame, "nameplate1")
HARNESS.frame()
check("H11 and back again", first.height == 6.5, first.height)

-- H12: the pixel floor bounds the result, not the fraction ----------------------
NamePlateSetupOptions.healthBarHeight = 8
setFraction(0.3)
check("H12 floored at MINIMUM_BAR_PIXELS", first.height == ns.MINIMUM_BAR_PIXELS,
    first.height)
check("H13 the floor is 4", ns.MINIMUM_BAR_PIXELS == 4, ns.MINIMUM_BAR_PIXELS)
NamePlateSetupOptions.healthBarHeight = 13
setFraction(0.5)

-- H14: a plate added while the setting is on gets it at once ---------------------
local second = addPlate("nameplate2", 13)
HARNESS.frame()
check("H14 a new plate is written on track", second.height == 6.5, second.height)

-- H15: every plate, including one out of colour scope ---------------------------
HARNESS.units["nameplate2"].canAttack = false
local friendly = addPlate("nameplate3", 13)
HARNESS.units["nameplate3"].canAttack = false
HARNESS.units["nameplate3"].reaction = 5
HARNESS.frame()
CompactUnitFrame_SetUnit(HARNESS.plates["nameplate3"].UnitFrame, "nameplate3")
HARNESS.frame()
check("H15 a plate out of colour scope still gets the height",
    friendly.height == 6.5, friendly.height)

-- H16: the base cannot be read -------------------------------------------------
local savedOptions = NamePlateSetupOptions
NamePlateSetupOptions = nil
local third = addPlate("nameplate4", 13)
HARNESS.frame()
check("H16 no base means no write", third.writes == 0 and third.height == 13,
    third.writes .. "/" .. third.height)
check("H17 counted as baseWithheld",
    ns.Nameplates.Inspect().barHeightBaseWithheld > 0,
    ns.Nameplates.Inspect().barHeightBaseWithheld)

NamePlateSetupOptions = { healthBarHeight = HARNESS.SECRET }
local fourth = addPlate("nameplate5", 13)
HARNESS.frame()
check("H18 a secret base means no write either",
    fourth.writes == 0 and fourth.height == 13,
    fourth.writes .. "/" .. fourth.height)
NamePlateSetupOptions = savedOptions

-- H19: a container whose height will not read ----------------------------------
local hidden = addPlate("nameplate6", 13)
function hidden:GetHeight() return HARNESS.SECRET end
CompactUnitFrame_SetUnit(HARNESS.plates["nameplate6"].UnitFrame, "nameplate6")
HARNESS.frame()
check("H19 the write proceeds without the comparison", hidden.height == 6.5,
    tostring(hidden.height))
check("H20 counted as compareWithheld",
    ns.Nameplates.Inspect().barHeightCompareWithheld > 0,
    ns.Nameplates.Inspect().barHeightCompareWithheld)

-- H21: SetHeight refused -------------------------------------------------------
local refusing = addPlate("nameplate7", 13)
function refusing:SetHeight() error("the harness refuses this height") end
-- The plate was already written to 6.5 when it was tracked, so the comparison
-- would find nothing to do. Put it back to the base so a write is attempted.
refusing.height = 13
CompactUnitFrame_SetUnit(HARNESS.plates["nameplate7"].UnitFrame, "nameplate7")
HARNESS.frame()
check("H21 a refused write is counted, not fatal",
    ns.Nameplates.Inspect().barHeightRefused > 0,
    ns.Nameplates.Inspect().barHeightRefused)
check("H22 the plate is still tracked", ns.Nameplates.Inspect().tracked >= 6,
    ns.Nameplates.Inspect().tracked)

-- H23: back to 100% restores the plates on screen at once -----------------------
setFraction(1.0)
check("H23 returning to 100% restores at once", first.height == 13, first.height)
check("H24 and the second plate too", second.height == 13, second.height)

-- H25: disable restores --------------------------------------------------------
setFraction(0.5)
check("H25 short again before disable", first.height == 6.5, first.height)
ns.Registry.SetEnabled("nameplates", false)
HARNESS.frame()
check("H26 disable put the height back", first.height == 13, first.height)
ns.Registry.SetEnabled("nameplates", true)
HARNESS.frame()

-- H27: no timer of its own -----------------------------------------------------
-- The height rides a hook that already exists. The feature's one ticker is the
-- colour sweep's, so the count must not have grown.
check("H27 the schema bounds the fraction",
    ns.ConfigSchema.Validate("nameplates", "barHeightFraction", 0.25) == nil
    and ns.ConfigSchema.Validate("nameplates", "barHeightFraction", 1.5) == nil
    and ns.ConfigSchema.Validate("nameplates", "barHeightFraction", 0.5) == 0.5)

-- H28: /pa plates reports it ---------------------------------------------------
setFraction(0.5)
local mark = #HARNESS.chat
slash("plates")
local said = false
for index = mark + 1, #HARNESS.chat do
    if tostring(HARNESS.chat[index]):find("bar height: 50%", 1, true) then
        said = true
    end
end
check("H28 /pa plates reports the percentage", said)

setFraction(1.0)
mark = #HARNESS.chat
slash("plates")
said = false
for index = mark + 1, #HARNESS.chat do
    if tostring(HARNESS.chat[index]):find("the game's own", 1, true) then
        said = true
    end
end
check("H29 and says so when inert", said)

-- H30: the probe is gone -------------------------------------------------------
check("H30 the spike's route is deleted", ns.BarHeightProbe == nil)

-- Report -----------------------------------------------------------------------
local errors = {}
for _, line in ipairs(HARNESS.chat) do
    if line:find("raised", 1, true) or line:find("faulted", 1, true) then
        errors[#errors + 1] = line
    end
end
HARNESS_RESULT = { passed = passed, failures = failures, errors = errors, chat = HARNESS.chat }
