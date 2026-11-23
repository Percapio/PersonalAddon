-- Phase 22 offline checks (Architecture/20261122-Phase22.md section 14.1).
-- Sessions: "phase22", everything present; and "phase22-nohook", where
-- CompactUnitFrame_UpdateName is missing before login (H5).
-- Check names follow the design's table: N names, Y styles, H the hook, F faction,
-- C capability, O on and off, D distance, G the page.

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

local function occurrences(text, needle)
    local count, from = 0, 1
    while true do
        local at = text:find(needle, from, true)
        if not at then
            return count
        end
        count, from = count + 1, at + #needle
    end
end

local function setNow(feature, key, value)
    local ok, why = ns.ConfigStore.Set(feature, key, value)
    ns.Registry.NotifyConfigChanged(feature, key)
    return ok, why
end

local NOHOOK = (HARNESS_SESSION == "phase22-nohook")

-- Before login --------------------------------------------------------------------------------

-- Blizzard's update path, defined before login so the post-hooks install on it.
function CompactUnitFrame_SetUnit(_unitFrame, _token) end
function CompactUnitFrame_UpdateAll(_unitFrame) end
function CompactUnitFrame_UpdateHealth(_unitFrame) end
function CompactUnitFrame_UpdateHealthColor(_unitFrame) end

-- Blizzard's name write, as CompactUnitFrame_UpdateName makes it: white, or a class
-- colour when the plate has set colorNameWithClassColor. HARNESS.skipBlizzardName lets
-- the update run without the write, for a name that is already ours (H4).
local CLASS_COLOUR = { 0.96, 0.55, 0.73 }
local function blizzardName(unitFrame)
    local region = unitFrame and unitFrame.name
    if HARNESS.skipBlizzardName or not (region and region.BlizzardSetColour) then
        return
    end
    if unitFrame.colorNameWithClassColor then
        region:BlizzardSetColour(CLASS_COLOUR[1], CLASS_COLOUR[2], CLASS_COLOUR[3])
    else
        region:BlizzardSetColour(1, 1, 1)
    end
end
if not NOHOOK then
    function CompactUnitFrame_UpdateName(unitFrame)
        blizzardName(unitFrame)
    end
end

HARNESS.installNameOptions(NamePlateConstants.NAME_ANCHOR_STYLES.AboveHealthBar)
HARNESS.countAnchorReads()
HARNESS.installPlayerUnits()
HARNESS.installCVars({ nameplateShowEnemies = "1" })

HARNESS.fire("ADDON_LOADED", "PersonalAddon")
HARNESS.fire("PLAYER_LOGIN")
HARNESS.frame()
HARNESS.fire("PLAYER_ENTERING_WORLD")
HARNESS.frame()

-- Helpers ---------------------------------------------------------------------------------------

local Plates = ns.Nameplates

local function view()
    return Plates.Inspect()
end

local function names()
    return view().playerNames
end

local function counter(name)
    return (names().counters or {})[name] or 0
end

local function record(token)
    for _, plate in ipairs(Plates.TrackedPlates()) do
        if plate.unitToken == token then
            return plate
        end
    end
end

local function region(token)
    local frame = HARNESS.plates[token]
    return frame and frame.UnitFrame and frame.UnitFrame.name
end

local function near(left, right)
    return type(left) == "number" and math.abs(left - right) <= 0.01
end

local RED = { 1, 64 / 255, 64 / 255 }
local ORANGE = { 1, 192 / 255, 77 / 255 }
local WHITE = { 1, 1, 1 }
local GREEN = { 0, 1, 0 }

local function reads(token, colour)
    local named = region(token)
    return named ~= nil and near(named.vertex[1], colour[1]) and near(named.vertex[2], colour[2])
        and near(named.vertex[3], colour[3])
end

local function colourText(token)
    local named = region(token)
    if not named then
        return token .. ": no region"
    end
    return format("%s: %.3f,%.3f,%.3f", token, named.vertex[1], named.vertex[2], named.vertex[3])
end

local function unitReads()
    return HARNESS.unitIsPlayerCalls22 + HARNESS.canAttackCalls.you + HARNESS.canAttackCalls.they
        + HARNESS.youCalls
end

local function pass()
    HARNESS.advance(0.3)
end

-- One frame after the sweep has just run, so the next sweep is a known 0.25 s away.
local function justAfterASweep()
    local sweeps = view().sweeps
    for _ = 1, 100 do
        HARNESS.frame(0.01)
        if view().sweeps ~= sweeps then
            return
        end
    end
end

local function playerTokens()
    local tokens = {}
    for _, plate in ipairs(Plates.TrackedPlates()) do
        if plate.identity == "Player" then
            tokens[#tokens + 1] = plate.unitToken
        end
    end
    return tokens
end

local function allPlayersRead(colour)
    for _, token in ipairs(playerTokens()) do
        if not reads(token, colour) then
            return false, colourText(token)
        end
    end
    return true
end

if NOHOOK then
    -- H5: no name hook ---------------------------------------------------------------------------
    local atLogin = chatSince(0)
    check("H5 the missing function is not mentioned while the setting is off",
        not atLogin:find("CompactUnitFrame_UpdateName is missing", 1, true))
    HARNESS.addPlayerPlate("nameplate1", { canAttack = true })
    local mark = chatMark()
    setNow("nameplates", "playerNameColours", true)
    check("H5 one line names the missing function when the toggle turns on",
        occurrences(chatSince(mark), "CompactUnitFrame_UpdateName is missing") == 1, chatSince(mark))
    check("H5 hookTargets lacks it", names().hookInstalled == false
        and not tostring(view().hookTargets):find("UpdateName", 1, true), tostring(view().hookTargets))
    check("H5 the setting still paints", reads("nameplate1", RED), colourText("nameplate1"))
    region("nameplate1"):BlizzardSetColour(1, 1, 1)
    check("H5 Blizzard's white stands until the next pass", reads("nameplate1", WHITE))
    HARNESS.advance(0.25)
    check("H5 then reads red", reads("nameplate1", RED), colourText("nameplate1"))
    setNow("nameplates", "playerNameColours", false)
    setNow("nameplates", "playerNameColours", true)
    check("H5 said once across two turns on", occurrences(chatSince(mark), "CompactUnitFrame_UpdateName is missing") == 1)
end

if not NOHOOK then
    -- O1, Y8: off by default, and nothing read -------------------------------------------------
    check("O1 player name colours are off by default", names().on == false and names().capability == "NotYetProbed",
        tostring(names().on))
    local anchorBefore = HARNESS.anchorReads
    HARNESS.addPlayerPlate("nameplate1", { canAttack = true })
    HARNESS.addPlayerPlate("nameplate2", {})
    check("O1 a fresh profile writes no name and holds no record",
        region("nameplate1").colourWrites == 0 and region("nameplate2").colourWrites == 0 and names().recorded == 0)
    pass()
    for _ = 1, 10 do
        CompactUnitFrame_UpdateHealthColor(HARNESS.plates.nameplate1.UnitFrame)
        CompactUnitFrame_UpdateName(HARNESS.plates.nameplate1.UnitFrame)
    end
    check("Y8 both name features off: an attach, a pass and twenty hook fires read no anchor",
        HARNESS.anchorReads == anchorBefore, HARNESS.anchorReads - anchorBefore)
    check("O1 and the hook wrote nothing of ours", region("nameplate1").colourWrites == 0)

    -- O2, C1, N1, N3: on ------------------------------------------------------------------------
    setNow("nameplates", "playerNameColours", true)
    check("O2 turning it on paints every eligible plate at once",
        reads("nameplate1", RED) and reads("nameplate2", ORANGE),
        colourText("nameplate1") .. " / " .. colourText("nameplate2"))
    check("C1 the first paint probes: Verified", names().capability == "Verified"
        and counter("nameColourCapabilityVerified") == 1, names().capability)
    check("N1 you can attack them: ff4040", reads("nameplate1", RED), colourText("nameplate1"))
    check("N3 neither can attack: ffc04d", reads("nameplate2", ORANGE), colourText("nameplate2"))
    check("Y1 Above (Thin and Cast Focus) paints", record("nameplate1").namePainted == "CanFight"
        and record("nameplate2").namePainted == "OtherPlayer")
    check("O2 two records held", names().recorded == 2, names().recorded)

    -- N2, N4-N8 ---------------------------------------------------------------------------------
    HARNESS.addPlayerPlate("nameplate3", { attacksPlayer = true })
    check("N2 they can attack you, you not them: red", reads("nameplate3", RED), colourText("nameplate3"))

    local recordedBefore = names().recorded
    HARNESS.addPlate20("nameplate4", { npcId = 4001, canAttack = true })
    check("N4 an attackable NPC is never written", region("nameplate4").colourWrites == 0
        and record("nameplate4").identity == "NotAPlayer" and counter("nameColourDecidedToNotPlayer") == 1
        and names().recorded == recordedBefore, counter("nameColourDecidedToNotPlayer"))

    HARNESS.addPlayerPlate("nameplate5", { isYou = true })
    check("N5 your own plate is never written", region("nameplate5").colourWrites == 0
        and record("nameplate5").nameDecision == "Yourself", record("nameplate5").nameDecision)

    HARNESS.addPlayerPlate("nameplate6", { classColour = true, friend = true })
    check("N6 Blizzard's class colour wins over light orange", region("nameplate6").colourWrites == 0
        and record("nameplate6").nameDecision == "ClassColourWins", record("nameplate6").nameDecision)
    HARNESS.addPlayerPlate("nameplate7", { classColour = true, canAttack = true })
    check("N6 and red wins over Blizzard's class colour", reads("nameplate7", RED), colourText("nameplate7"))

    local playerWithheld = counter("nameColourPlayerWithheld")
    HARNESS.addPlayerPlate("nameplate8", { isPlayerSecret = true })
    check("N7 a withheld UnitIsPlayer writes nothing", region("nameplate8").colourWrites == 0
        and counter("nameColourPlayerWithheld") == playerWithheld + 1, counter("nameColourPlayerWithheld"))
    local isPlayerCalls = HARNESS.unitIsPlayerCalls22
    HARNESS.advance(0.25)
    check("N7 and the next pass asks again", HARNESS.unitIsPlayerCalls22 >= isPlayerCalls + 1
        and record("nameplate8").identity == nil, HARNESS.unitIsPlayerCalls22 - isPlayerCalls)
    HARNESS.removePlate("nameplate8")

    local attackWithheld = counter("nameColourAttackWithheld")
    HARNESS.addPlayerPlate("nameplate9", { canAttackSecret = true })
    check("N8 one attack read withheld, the other false: left to Blizzard", region("nameplate9").colourWrites == 0
        and record("nameplate9").nameDecision == "AttackUnreadable"
        and counter("nameColourAttackWithheld") == attackWithheld + 1, record("nameplate9").nameDecision)
    HARNESS.addPlayerPlate("nameplate10", { canAttackSecret = true, attacksPlayer = true })
    check("N8 one withheld and the other true: red", reads("nameplate10", RED), colourText("nameplate10"))

    -- D6 (half): the unreadable: line appears while a reason is unreadable.
    HARNESS.addPlayerPlate("nameplate17", { noName = true })
    local mark = chatMark()
    slash("plates")
    local out = chatSince(mark)
    check("D6 left: carries you= and noRegion=", out:find("left: notPlayer=1 you=1 insideBar=0 classColour=1 noRegion=1 unreadable=1", 1, true) ~= nil, out)
    check("D6 the unreadable: line while its sum is above zero", out:find("unreadable: player=0 style=0 attack=1 classColour=0", 1, true) ~= nil, out)
    HARNESS.removePlate("nameplate9")
    HARNESS.removePlate("nameplate10")
    HARNESS.removePlate("nameplate17")
    pass()
    mark = chatMark()
    slash("plates")
    out = chatSince(mark)
    check("D6 no unreadable: line while its sum is zero", out:find("    unreadable:", 1, true) == nil
        and out:find("unreadable=0", 1, true) ~= nil, out)

    -- N9: identity once per occupancy.
    local playerCalls, youCalls = HARNESS.unitIsPlayerCalls22, HARNESS.youCalls
    HARNESS.advance(1.0)
    check("N9 four passes ask neither UnitIsPlayer nor the self comparison again",
        HARNESS.unitIsPlayerCalls22 == playerCalls and HARNESS.youCalls == youCalls,
        format("%d %d", HARNESS.unitIsPlayerCalls22 - playerCalls, HARNESS.youCalls - youCalls))
    HARNESS.removePlate("nameplate3")
    playerCalls = HARNESS.unitIsPlayerCalls22
    HARNESS.addPlayerPlate("nameplate3", { attacksPlayer = true })
    check("N9 a new occupancy asks again", HARNESS.unitIsPlayerCalls22 == playerCalls + 1
        and reads("nameplate3", RED), HARNESS.unitIsPlayerCalls22 - playerCalls)

    -- Y: styles ---------------------------------------------------------------------------------
    HARNESS.setPlateStyle("Inside")
    pass()
    check("Y6 Above -> Inside: the next pass restores every painted name", reads("nameplate1", WHITE)
        and reads("nameplate2", WHITE) and names().recorded == 0, colourText("nameplate1"))
    check("Y2 Inside: no write, left insideBar", (names().left.InsideBar or 0) >= 3, names().left.InsideBar)
    HARNESS.addPlayerPlate("nameplate11", { showOnlyName = true })
    check("Y3 Inside with showOnlyName: painted", reads("nameplate11", ORANGE), colourText("nameplate11"))
    HARNESS.setPlateStyle("Centred")
    pass()
    check("Y4 Centred paints", reads("nameplate1", RED) and reads("nameplate2", ORANGE), colourText("nameplate1"))
    HARNESS.setPlateStyle("Unreadable")
    pass()
    check("Y5 Unreadable: left to Blizzard as StyleUnreadable", reads("nameplate1", WHITE)
        and (names().left.StyleUnreadable or 0) >= 1 and reads("nameplate11", ORANGE), colourText("nameplate1"))
    HARNESS.setPlateStyle("Above")
    pass()
    check("Y6 back to Above: the next pass paints them", reads("nameplate1", RED) and reads("nameplate2", ORANGE),
        colourText("nameplate1"))

    -- Y7: alignment unchanged by the shared anchor read.
    setNow("nameplates", "nameAlignLeft", true)
    check("Y7 alignment on, Above: aligned", region("nameplate1").justifyH == "LEFT"
        and view().nameAlignCapability == "Verified", region("nameplate1").justifyH)
    HARNESS.setPlateStyle("Inside")
    local styleSkips = view().nameAlignSkippedStyle
    HARNESS.layoutPass("nameplate1")
    check("Y7 alignment on, Inside: skipped on the style counter", region("nameplate1").justifyH == "CENTER"
        and view().nameAlignSkippedStyle > styleSkips, region("nameplate1").justifyH)
    HARNESS.setPlateStyle("Above")
    pass()

    -- Y9: the hooks read the anchor only for alignment; an attach reads it once.
    setNow("nameplates", "nameAlignLeft", false)
    local anchorReads = HARNESS.anchorReads
    for _ = 1, 10 do
        CompactUnitFrame_UpdateHealthColor(HARNESS.plates.nameplate1.UnitFrame)
    end
    check("Y9 colours on, alignment off: ten UpdateHealthColor fires read no anchor",
        HARNESS.anchorReads == anchorReads, HARNESS.anchorReads - anchorReads)
    setNow("nameplates", "nameAlignLeft", true)
    anchorReads = HARNESS.anchorReads
    HARNESS.addPlayerPlate("nameplate12", {})
    check("Y9 both on: one attach reads the anchor once", HARNESS.anchorReads == anchorReads + 1,
        HARNESS.anchorReads - anchorReads)
    setNow("nameplates", "nameAlignLeft", false)

    -- Y10: a missing constant is skipped, not fatal.
    NamePlateConstants.NAME_ANCHOR_STYLES.CenteredAboveHealthBar = nil
    HARNESS.addPlayerPlate("nameplate13", { canAttack = true })
    check("Y10 without CenteredAboveHealthBar, Above still paints", reads("nameplate13", RED), colourText("nameplate13"))
    setNow("nameplates", "nameAlignLeft", true)
    check("Y10 and alignment still aligns", region("nameplate13").justifyH == "LEFT", region("nameplate13").justifyH)
    setNow("nameplates", "nameAlignLeft", false)
    NamePlateConstants.NAME_ANCHOR_STYLES.CenteredAboveHealthBar = 3

    -- H: the hook -------------------------------------------------------------------------------
    local named = region("nameplate1")
    CompactUnitFrame_UpdateName(HARNESS.plates.nameplate1.UnitFrame)
    local log = named.colourLog
    check("H1 Blizzard's write is corrected in the same call", reads("nameplate1", RED)
        and log[#log - 1] ~= nil and log[#log - 1].blizzard == true and not log[#log].blizzard, colourText("nameplate1"))
    local unitCalls = unitReads()
    for _ = 1, 10 do
        CompactUnitFrame_UpdateName(HARNESS.plates.nameplate1.UnitFrame)
    end
    check("H2 ten name updates read no unit", unitReads() == unitCalls, unitReads() - unitCalls)
    local stranger = { name = HARNESS.newNameRegion() }
    local writes, pending = HARNESS.nameColourWrites, view().reassertPending
    CompactUnitFrame_UpdateName(stranger)
    check("H3 an untracked frame: nothing written or flagged", HARNESS.nameColourWrites == writes
        and view().reassertPending == pending and stranger.name.colourWrites == 0)
    local unchanged = counter("nameColourUnchanged")
    writes = HARNESS.nameColourWrites
    HARNESS.skipBlizzardName = true
    CompactUnitFrame_UpdateName(HARNESS.plates.nameplate1.UnitFrame)
    HARNESS.skipBlizzardName = nil
    check("H4 a name already ours: no write", HARNESS.nameColourWrites == writes
        and counter("nameColourUnchanged") == unchanged + 1)
    HARNESS.nameColourRefuse = "read"
    writes = HARNESS.nameColourWrites
    local readsWithheld = counter("nameColourReadsWithheld")
    CompactUnitFrame_UpdateName(HARNESS.plates.nameplate1.UnitFrame)
    HARNESS.nameColourRefuse = nil
    check("H6 an unreadable name after Verified: the hook writes nothing", HARNESS.nameColourWrites == writes
        and counter("nameColourReadsWithheld") == readsWithheld + 1 and names().capability == "Verified")
    CompactUnitFrame_UpdateName(HARNESS.plates.nameplate1.UnitFrame)
    check("H6 readable again: red", reads("nameplate1", RED))

    -- H7: a lost record is not a refusal (audit finding 1).
    local realReapply = ns.StyleLedger.Reapply
    ns.StyleLedger.Reapply = function()
        return false, "NOT_RECORDED"
    end
    local writeFailed = counter("nameColourWriteFailed")
    CompactUnitFrame_UpdateName(HARNESS.plates.nameplate1.UnitFrame)
    ns.StyleLedger.Reapply = realReapply
    check("H7 a lost record: LeftAlone, namePainted cleared, the capability kept",
        record("nameplate1").namePainted == nil and names().capability == "Verified"
        and counter("nameColourWriteFailed") == writeFailed, tostring(record("nameplate1").namePainted))
    pass()
    check("H7 and the next pass repaints it", reads("nameplate1", RED)
        and record("nameplate1").namePainted == "CanFight", colourText("nameplate1"))

    -- C6, C7: an unreadable original under Verified (audit findings 1 and 2a) -------------------
    readsWithheld = counter("nameColourReadsWithheld")
    HARNESS.addPlayerPlate("nameplate16", { canAttack = true, colourSecret = true })
    check("C6 an unreadable original under Verified: Unreadable, not a refusal",
        names().capability == "Verified" and counter("nameColourReadsWithheld") == readsWithheld + 1
        and record("nameplate16").namePainted == nil and region("nameplate16").colourWrites == 0,
        names().capability)
    for _ = 1, 10 do
        CompactUnitFrame_UpdateName(HARNESS.plates.nameplate16.UnitFrame)
    end
    check("C6 ten hook fires on it write nothing", region("nameplate16").colourWrites == 0)
    region("nameplate16").colourSecret = nil
    pass()
    check("C6 the knob cleared, the next pass paints it", reads("nameplate16", RED), colourText("nameplate16"))
    region("nameplate16").colourSecret = true
    HARNESS.units.nameplate16.canAttack = false
    pass()
    local sixteen = record("nameplate16")
    check("C7 decided OtherPlayer, still painted CanFight while its read is hidden",
        sixteen.nameDecision == "OtherPlayer" and sixteen.namePainted == "CanFight" and reads("nameplate16", RED),
        tostring(sixteen.nameDecision) .. "/" .. tostring(sixteen.namePainted))
    region("nameplate16").colourSecret = nil
    CompactUnitFrame_UpdateName(HARNESS.plates.nameplate16.UnitFrame)
    check("C7 readable again, the hook keeps what is painted, not what was decided", reads("nameplate16", RED)
        and record("nameplate16").namePainted == "CanFight", colourText("nameplate16"))
    pass()
    check("C7 the knob cleared, the next pass paints light orange", reads("nameplate16", ORANGE)
        and record("nameplate16").namePainted == "OtherPlayer", colourText("nameplate16"))

    -- F: faction --------------------------------------------------------------------------------
    HARNESS.units.nameplate2.canAttack = true
    unitCalls = unitReads()
    HARNESS.fire("UNIT_FACTION", "nameplate2")
    check("F1 the handler reads nothing", unitReads() == unitCalls and reads("nameplate2", ORANGE),
        unitReads() - unitCalls)
    HARNESS.frame()
    check("F1 a frame later it is red", reads("nameplate2", RED), colourText("nameplate2"))

    HARNESS.units.nameplate2.canAttack = false
    HARNESS.units.nameplate3.attacksPlayer = false
    HARNESS.units.nameplate12.attacksPlayer = true
    HARNESS.addPlate20("nameplate14", { npcId = 4002, canAttack = false })
    local scopeBefore = record("nameplate14").scope
    HARNESS.units.nameplate14.canAttack = true
    HARNESS.fire("UNIT_FACTION", "player")
    HARNESS.frame()
    check("F2 \"player\": every player plate re-decided", reads("nameplate2", ORANGE) and reads("nameplate3", ORANGE)
        and reads("nameplate12", RED), colourText("nameplate2") .. " " .. colourText("nameplate12"))
    -- By the plate, not by the total: the same flush rescopes every plate, so any plate
    -- whose attackability moved earlier without an event moves too.
    check("F2 and an NPC whose attackability changed is in scope", scopeBefore == "OutOfScope"
        and record("nameplate14").scope == "InScope", tostring(scopeBefore) .. " -> " .. tostring(record("nameplate14").scope))

    local flushes, flushAll = counter("factionFlushes"), counter("factionFlushAll")
    HARNESS.fire("UNIT_FACTION", "nameplate1")
    HARNESS.fire("UNIT_FACTION", "nameplate2")
    HARNESS.fire("UNIT_FACTION", "player")
    HARNESS.frame()
    check("F3 three events in one frame: one flush", counter("factionFlushes") == flushes + 1
        and counter("factionFlushAll") == flushAll + 1, counter("factionFlushes") - flushes)

    local bySweep = counter("nameColourChangedBySweep")
    HARNESS.units.nameplate3.attacksPlayer = true
    pass()
    check("F5 a change no event announces: red after the next pass", reads("nameplate3", RED)
        and counter("nameColourChangedBySweep") == bySweep + 1, counter("nameColourChangedBySweep") - bySweep)

    justAfterASweep()
    HARNESS.frame(0.235)
    bySweep = counter("nameColourChangedBySweep")
    local sweeps = view().sweeps
    HARNESS.units.nameplate3.attacksPlayer = false
    HARNESS.fire("UNIT_FACTION", "nameplate3")
    HARNESS.frame()
    check("F6 an announced change with a sweep in the same frame: the flush decides it",
        reads("nameplate3", ORANGE) and counter("nameColourChangedBySweep") == bySweep and view().sweeps == sweeps + 1,
        format("bySweep+%d sweeps+%d", counter("nameColourChangedBySweep") - bySweep, view().sweeps - sweeps))

    -- F7: a name step that raises in a flush.
    HARNESS.expectedFaults[#HARNESS.expectedFaults + 1] = "name colour faulted"
    HARNESS.plates.nameplate6.UnitFrame.colorNameWithClassColor = false
    HARNESS.units.nameplate2.canAttack = true
    local realApply = ns.StyleLedger.Apply
    ns.StyleLedger.Apply = function()
        error("Apply raised for F7")
    end
    local nameFaults = counter("nameColourFaults")
    HARNESS.fire("UNIT_FACTION", "nameplate6")
    HARNESS.fire("UNIT_FACTION", "nameplate2")
    HARNESS.frame()
    ns.StyleLedger.Apply = realApply
    check("F7 a name step that raises: counted, and the others still decided",
        counter("nameColourFaults") == nameFaults + 1 and reads("nameplate2", RED),
        format("faults+%d %s", counter("nameColourFaults") - nameFaults, colourText("nameplate2")))
    pass()
    check("F7 tried afresh: the next pass paints it", reads("nameplate6", ORANGE), colourText("nameplate6"))

    flushes = counter("factionFlushes")
    HARNESS.fire("UNIT_FACTION", "target")
    HARNESS.frame()
    check("F8 a token no plate carries schedules nothing", counter("factionFlushes") == flushes
        and names().flushPending == false)

    -- F9: a rescope that raises costs neither the name step nor the name counter.
    HARNESS.expectedFaults[#HARNESS.expectedFaults + 1] = "a nameplate faulted"
    pass()
    local realRestoreWidget = ns.StyleLedger.RestoreWidget
    ns.StyleLedger.RestoreWidget = function()
        error("RestoreWidget raised for F9")
    end
    local plateFaults = view().plateFaults
    nameFaults = counter("nameColourFaults")
    HARNESS.units.nameplate7.canAttack = false
    HARNESS.fire("UNIT_FACTION", "nameplate7")
    HARNESS.frame()
    ns.StyleLedger.RestoreWidget = realRestoreWidget
    check("F9 a rescope that raises: plateFaults, not nameColourFaults",
        view().plateFaults == plateFaults + 1 and counter("nameColourFaults") == nameFaults,
        format("plate+%d name+%d", view().plateFaults - plateFaults, counter("nameColourFaults") - nameFaults))
    check("F9 and the same flush re-decided the name", record("nameplate7").nameDecision == "ClassColourWins"
        and record("nameplate7").namePainted == nil, record("nameplate7").nameDecision)

    -- F10: no C_Timer.After.
    local realAfter = C_Timer.After
    C_Timer.After = nil
    mark = chatMark()
    HARNESS.units.nameplate2.canAttack = false
    HARNESS.fire("UNIT_FACTION", "nameplate2")
    check("F10 no C_Timer.After: settled inside the event", reads("nameplate2", ORANGE), colourText("nameplate2"))
    HARNESS.units.nameplate2.canAttack = true
    HARNESS.fire("UNIT_FACTION", "nameplate2")
    C_Timer.After = realAfter
    check("F10 one line, once across two events",
        occurrences(chatSince(mark), "has no C_Timer.After, so a faction change") == 1 and reads("nameplate2", RED),
        chatSince(mark))

    -- O3, O4, O5 ---------------------------------------------------------------------------------
    setNow("nameplates", "playerNameColours", false)
    local ok, which = allPlayersRead(WHITE)
    check("O3 off restores every painted name to white at once", ok and names().recorded == 0, which)
    setNow("nameplates", "playerNameColours", true)
    check("O2 on again paints at once", reads("nameplate1", RED) and reads("nameplate3", ORANGE),
        colourText("nameplate1"))
    setNow("nameplates", "nameColourOtherPlayer", "00ff00")
    check("O4 a colour change repaints every light-orange name at once", reads("nameplate3", GREEN)
        and reads("nameplate1", RED), colourText("nameplate3"))
    setNow("nameplates", "nameColourOtherPlayer", "ffc04d")
    check("O4 and back", reads("nameplate3", ORANGE), colourText("nameplate3"))
    local removed = region("nameplate1")
    HARNESS.removePlate("nameplate1")
    check("O5 a removed plate's name is restored before its record drops",
        near(removed.vertex[1], 1) and near(removed.vertex[2], 1) and near(removed.vertex[3], 1))
    HARNESS.addPlate20("nameplate1", { npcId = 4003 })
    check("O5 the token re-added for an NPC is never written", region("nameplate1").colourWrites == 0)

    -- D: the draw distance -----------------------------------------------------------------------
    local settings = Plates.DistanceSettings()
    check("D1 both settings, in order", #settings == 2 and settings[1].name == "nameplateMaxDistance"
        and settings[2].name == "nameplatePlayerMaxDistance", #settings)
    check("D1 45 and 40 yards, defaults 45 and 40, per character, secure",
        settings[1].yards == 45 and settings[1].defaultYards == 45 and settings[2].yards == 40
        and settings[2].defaultYards == 40 and settings[1].perCharacter == true and settings[2].perCharacter == true
        and settings[1].secure == true and settings[2].secure == true)
    local infoCalls = HARNESS.cvarInfoCalls
    pass()
    view()
    HARNESS.fire("UNIT_FACTION", "player")
    HARNESS.frame()
    CompactUnitFrame_UpdateName(HARNESS.plates.nameplate3.UnitFrame)
    check("D3 no sweep, hook, event or Inspect reads GetCVarInfo", HARNESS.cvarInfoCalls == infoCalls,
        HARNESS.cvarInfoCalls - infoCalls)
    mark = chatMark()
    slash("plates")
    out = chatSince(mark)
    check("D4 /pa plates prints yards as numbers", out:find("draw distance, all plates: 45 yd (default 45); secure, per character", 1, true) ~= nil
        and out:find("draw distance, players: 40 yd (default 40); secure, per character", 1, true) ~= nil
        and out:find("45.000000", 1, true) == nil, out)
    check("D4 a secure setting prints no console line", out:find("/console", 1, true) == nil)
    local savedInfo = HARNESS.cvarInfo
    HARNESS.cvarInfo = {
        nameplatePlayerMaxDistance = { "far", "40.000000", true, false, true, false, false },
    }
    mark = chatMark()
    slash("plates")
    out = chatSince(mark)
    HARNESS.cvarInfo = savedInfo
    check("D2 an unregistered setting says so", out:find("draw distance, all plates: nameplateMaxDistance is not registered on this client", 1, true) ~= nil, out)
    check("D5 one line each; ? for a value that does not parse; per account; locked",
        out:find("draw distance, players: ? yd (default 40); not secure, per account, locked", 1, true) ~= nil, out)
    check("D4 not secure prints the console line", out:find("not secure on this client: /console nameplatePlayerMaxDistance <yards> changes it", 1, true) ~= nil, out)
    check("D3 nothing ever wrote a CVar", HARNESS.cvarWrites == 0 and HARNESS.consoleExecCalls == 0
        and HARNESS.globalSetCVarCalls == 0)

    -- G: the page --------------------------------------------------------------------------------
    local page
    for _, candidate in ipairs(HARNESS.settingsPages or {}) do
        if candidate.name == "Nameplates" then
            page = candidate
        end
    end
    local initializers = page and page.layout.initializers or {}
    local toggle, toggleIndex, sizeIndex, switch
    local headerIndex, header, swatches = nil, nil, {}
    for index, initializer in ipairs(initializers) do
        if initializer.kind == "checkbox" and initializer.name == "Nameplates" then
            switch = initializer
        end
        if initializer.name == "Colour player names" then
            toggle, toggleIndex = initializer, index
        end
        -- The slider's label carries its unit: "Guild name and role size (px)".
        if type(initializer.name) == "string" and initializer.name:find("Guild name and role size", 1, true) == 1 then
            sizeIndex = index
        end
        if initializer.kind == "header" and initializer.name == "Player names" then
            headerIndex, header = index, initializer
        end
        if initializer.kind == "swatch" then
            swatches[#swatches + 1] = initializer.name
        end
    end
    check("G1 Colour player names is a checkbox under the Nameplates switch, after the label size",
        toggle ~= nil and toggle.kind == "checkbox" and toggle.parentInitializer == switch
        and sizeIndex ~= nil and toggleIndex == sizeIndex + 1, toggleIndex)
    check("G2 a Player names header precedes the first picker, with the group's tooltip",
        header ~= nil and initializers[headerIndex + 1] ~= nil
        and initializers[headerIndex + 1].name == "Can fight you, or you them"
        and header.tooltip == "Used by \"Colour player names\".", header and header.tooltip)
    -- Patch 03 (D3): the second picker is relabelled "The other faction"; key unchanged.
    check("G3 the pickers come after the threat colours",
        table.concat(swatches, "|"):find("Hostile, and attacking neither|Can fight you, or you them|The other faction", 1, true) ~= nil,
        table.concat(swatches, "|"))
    local accepted = ns.ConfigStore.Set("nameplates", "nameColourCanFight", "zzzzzz")
    check("G4 a colour that is not six hex digits is refused", accepted == false
        and ns.ConfigStore.Feature("nameplates").settings.nameColourCanFight == "ff4040")

    -- C2, C8, O7, C3, C5, C4, O6: the capability -------------------------------------------------
    local function regionCounts()
        local counts = {}
        for token, frame in pairs(HARNESS.plates) do
            local name = frame.UnitFrame and frame.UnitFrame.name
            if name and name.colourReads then
                counts[token] = { reads = name.colourReads, writes = name.colourWrites }
            end
        end
        return counts
    end

    ns.Registry.SetEnabled("nameplates", false)
    ok, which = allPlayersRead(WHITE)
    check("O6 disable restores every name", ok, which)
    check("O6 the capability is NotYetProbed again, and no flush pending", names().capability == "NotYetProbed"
        and names().flushPending == false, names().capability)

    HARNESS.nameColourRefuse = "write"
    local before = regionCounts()
    mark = chatMark()
    ns.Registry.SetEnabled("nameplates", true)
    check("C2 a write that does not stick: Refused", names().capability == "Refused", names().capability)
    ok, which = allPlayersRead(WHITE)
    check("C2 the names read their originals and no record is held", ok and names().recorded == 0, which)
    check("C2 one line", occurrences(chatSince(mark), "did not keep a nameplate name's colour") == 1, chatSince(mark))
    local probed, probeDelta = 0, ""
    for token, counts in pairs(regionCounts()) do
        local prior = before[token]
        if prior and (counts.reads ~= prior.reads or counts.writes ~= prior.writes) then
            probed = probed + 1
            probeDelta = format("%d reads, %d writes", counts.reads - prior.reads, counts.writes - prior.writes)
        end
    end
    check("C8 the probe: one region, two reads and two writes", probed == 1
        and probeDelta == "2 reads, 2 writes", probed .. " " .. probeDelta)
    writes = HARNESS.nameColourWrites
    HARNESS.addPlayerPlate("nameplate15", { canAttack = true })
    pass()
    check("C2 no later plate is written", HARNESS.nameColourWrites == writes, HARNESS.nameColourWrites - writes)

    writes, anchorReads = HARNESS.nameColourWrites, HARNESS.anchorReads
    setNow("nameplates", "playerNameColours", false)
    setNow("nameplates", "playerNameColours", true)
    setNow("nameplates", "nameColourOtherPlayer", "00ff00")
    setNow("nameplates", "nameColourOtherPlayer", "ffc04d")
    check("O7 while Refused: off and on, and a colour change, write and read nothing",
        HARNESS.nameColourWrites == writes and HARNESS.anchorReads == anchorReads and names().capability == "Refused",
        format("writes+%d anchor+%d %s", HARNESS.nameColourWrites - writes, HARNESS.anchorReads - anchorReads,
            names().capability))

    ns.Registry.SetEnabled("nameplates", false)
    HARNESS.nameColourRefuse = "read"
    writes = HARNESS.nameColourWrites
    mark = chatMark()
    ns.Registry.SetEnabled("nameplates", true)
    check("C3 a colour the client will not show: Unverifiable, nothing written",
        names().capability == "Unverifiable" and HARNESS.nameColourWrites == writes, names().capability)
    check("C3 one line", occurrences(chatSince(mark), "will not show a nameplate name's colour") == 1, chatSince(mark))

    ns.Registry.SetEnabled("nameplates", false)
    HARNESS.nameColourRefuse = nil
    ns.Registry.SetEnabled("nameplates", true)
    check("C5 the refusal cleared, a disable and enable probe again: Verified",
        names().capability == "Verified" and reads("nameplate15", RED), names().capability)

    HARNESS.nameColourRefuse = "raise"
    writeFailed = counter("nameColourWriteFailed")
    region("nameplate15"):BlizzardSetColour(1, 1, 1)
    pass()
    check("C4 a raising write after Verified: Refused, and no record left",
        names().capability == "Refused" and counter("nameColourWriteFailed") == writeFailed + 1
        and names().recorded == 0, format("%s failed+%d recorded=%d", names().capability,
            counter("nameColourWriteFailed") - writeFailed, names().recorded))
    writes = HARNESS.nameColourWrites
    pass()
    check("C4 and no write is attempted on the next pass", HARNESS.nameColourWrites == writes)
    HARNESS.nameColourRefuse = nil

    ns.Registry.SetEnabled("nameplates", false)
    ns.Registry.SetEnabled("nameplates", true)
    check("C5 and again after a raise: Verified", names().capability == "Verified" and reads("nameplate15", RED),
        names().capability)

    -- F4: a disable between an event and its flush.
    HARNESS.units.nameplate15.canAttack = false
    HARNESS.fire("UNIT_FACTION", "nameplate15")
    ns.Registry.SetEnabled("nameplates", false)
    unitCalls, writes = unitReads(), HARNESS.nameColourWrites
    anchorReads, flushes = HARNESS.anchorReads, counter("factionFlushes")
    HARNESS.frame()
    check("F4 a disable between the event and the frame: the flush does nothing",
        unitReads() == unitCalls and HARNESS.nameColourWrites == writes and HARNESS.anchorReads == anchorReads
        and counter("factionFlushes") == flushes,
        format("reads+%d writes+%d anchor+%d flushes+%d", unitReads() - unitCalls, HARNESS.nameColourWrites - writes,
            HARNESS.anchorReads - anchorReads, counter("factionFlushes") - flushes))
    ns.Registry.SetEnabled("nameplates", true)
end

-- Every session ---------------------------------------------------------------------------------

local function diagnosticsValid()
    local log = PersonalAddonDiagnostics
    if type(log) ~= "table" or type(log.sessions) ~= "table" then
        return false, "no saved log"
    end
    for _, sessionRecord in ipairs(log.sessions) do
        for featureId, counters in pairs(sessionRecord.counters or {}) do
            for name, value in pairs(counters) do
                if type(value) ~= "number" and type(value) ~= "boolean" then
                    return false, format("%s.%s = %s", tostring(featureId), tostring(name), tostring(value))
                end
            end
        end
    end
    return true
end
local valid, problem = diagnosticsValid()
check("the saved diagnostics still validate", valid, problem)

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
