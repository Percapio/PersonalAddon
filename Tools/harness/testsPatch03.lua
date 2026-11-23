-- Patch 03 offline checks (Architecture/20261122-Patch03.md section 14.1).
-- Session: "patch03", everything present.
-- Check names follow the design's groups: G the pages, F faction names, T ticks,
-- K tank colours, A Auto, B the role box, R /pa role. The audit's eight (F11, T15,
-- T16, K13, B15, B16, B17, R4) sit in their groups.

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

local function near(left, right, tolerance)
    return type(left) == "number" and math.abs(left - right) <= (tolerance or 0.011)
end

-- Before login ----------------------------------------------------------------------------------

-- Blizzard's update path, defined before login so the post-hooks install on it, and its
-- name write: white, as CompactUnitFrame_UpdateName makes it.
function CompactUnitFrame_SetUnit(_unitFrame, _token) end
function CompactUnitFrame_UpdateAll(_unitFrame) end
function CompactUnitFrame_UpdateHealth(_unitFrame) end
function CompactUnitFrame_UpdateHealthColor(_unitFrame) end
function CompactUnitFrame_UpdateName(unitFrame)
    local region = unitFrame and unitFrame.name
    if region and region.BlizzardSetColour then
        region:BlizzardSetColour(1, 1, 1)
    end
end

HARNESS.installNameOptions(NamePlateConstants.NAME_ANCHOR_STYLES.AboveHealthBar)
HARNESS.installPlayerUnits()
HARNESS.installCVars({ nameplateShowEnemies = "1" })

local FIREBALL, WAND = 133, 5019
HARNESS.spellCosts[FIREBALL] = { { type = 0, cost = 50, costPerSec = 0, requiredAuraID = 0 } }

HARNESS.fire("ADDON_LOADED", "PersonalAddon")
HARNESS.fire("PLAYER_LOGIN")
HARNESS.frame()
HARNESS.fire("PLAYER_ENTERING_WORLD")
HARNESS.frame()

for _, featureId in ipairs({ "nameplates", "threatPanel", "fiveSecondRule", "equippedSkills" }) do
    check("0 " .. featureId .. " is enabled", ns.Registry.State(featureId) == "ENABLED",
        ns.Registry.State(featureId))
end

local Plates = ns.Nameplates
local Threat = ns.Threat
local VERDICT = Threat.VERDICT

local function platesView()
    return Plates.Inspect()
end

local function platesSweeps()
    return platesView().sweeps
end

-- Advances until the plates have swept n more times.
local function platePasses(n)
    local start = platesSweeps()
    local guard = 0
    while platesSweeps() - start < n and guard < 400 do
        HARNESS.frame(0.05)
        guard = guard + 1
    end
end

local function counters(featureId)
    return ns.Diagnostics.CountersFor(featureId)
end

-- G: the pages ----------------------------------------------------------------------------------

local function initializersOf(name)
    for _, candidate in ipairs(HARNESS.settingsPages or {}) do
        if candidate.name == name then
            return candidate.layout.initializers or {}
        end
    end
    return {}
end

local function indexOf(initializers, prefix)
    for index, initializer in ipairs(initializers) do
        if type(initializer.name) == "string" and initializer.name:find(prefix, 1, true) == 1 then
            return index, initializer
        end
    end
end

-- A headed section puts a header carrying the feature's label before its switch; the
-- switch is the checkbox with that label.
local function switchOf(initializers, label)
    for _, initializer in ipairs(initializers) do
        if initializer.kind == "checkbox" and initializer.name == label then
            return initializer
        end
    end
end

do
    local combat = initializersOf("Combat")
    local fsrSwitch = switchOf(combat, "Five-second rule indicator")
    local opacityIndex = indexOf(combat, "Line opacity")
    local ticksIndex, ticks = indexOf(combat, "Show regen ticks")
    local colourIndex, colour = indexOf(combat, "Tick line colour")
    check("G1 Show regen ticks and Tick line colour follow Line opacity",
        opacityIndex ~= nil and ticksIndex == opacityIndex + 1 and colourIndex == opacityIndex + 2,
        format("%s/%s/%s", tostring(opacityIndex), tostring(ticksIndex), tostring(colourIndex)))
    check("G1 a checkbox under the five-second rule's switch, then a swatch",
        ticks ~= nil and ticks.kind == "checkbox" and ticks.parentInitializer == fsrSwitch
        and colour ~= nil and colour.kind == "swatch",
        ticks and ticks.kind)

    local nameplatesPage = initializersOf("Nameplates")
    check("G2 the Nameplates page has no control for the role",
        #nameplatesPage > 0 and indexOf(nameplatesPage, "Threat colours for") == nil
        and indexOf(nameplatesPage, "Tank colours") == nil, #nameplatesPage)

    local bags = initializersOf("Bags & loot")
    local skillsSwitch = switchOf(bags, "Equipped skills")
    local _, roleToggle = indexOf(bags, "Show the Tank / DPS / Auto choice")
    check("G3 Show the Tank / DPS / Auto choice under the skills switch",
        roleToggle ~= nil and roleToggle.kind == "checkbox" and roleToggle.parentInitializer == skillsSwitch,
        roleToggle and roleToggle.kind)

    local swatches = {}
    for _, initializer in ipairs(initializersOf("Nameplates")) do
        if initializer.kind == "swatch" then
            swatches[#swatches + 1] = initializer.name
        end
    end
    local joined = table.concat(swatches, "|")
    check("G4 The other faction replaces Every other player",
        joined:find("The other faction", 1, true) ~= nil and joined:find("Every other player", 1, true) == nil,
        joined)

    local accepted = ns.ConfigStore.Set("fiveSecondRule", "tickColour", "zzzzzz")
    check("G5 a tick colour that is not six hex digits is refused", accepted == false
        and ns.ConfigStore.Get("fiveSecondRule", "tickColour") == "ffd100",
        ns.ConfigStore.Get("fiveSecondRule", "tickColour"))
end

-- F: player names by faction --------------------------------------------------------------------

local function names()
    return platesView().playerNames
end

local function nameRegion(token)
    local frame = HARNESS.plates[token]
    return frame and frame.UnitFrame and frame.UnitFrame.name
end

local function nameReads(token, colour)
    local region = nameRegion(token)
    return region ~= nil and near(region.vertex[1], colour[1]) and near(region.vertex[2], colour[2])
        and near(region.vertex[3], colour[3])
end

local function nameText(token)
    local region = nameRegion(token)
    if not region then
        return token .. ": no region"
    end
    return format("%s: %.3f,%.3f,%.3f", token, region.vertex[1], region.vertex[2], region.vertex[3])
end

local RED_NAME = { 1, 64 / 255, 64 / 255 }
local LIGHT_ORANGE = { 1, 192 / 255, 77 / 255 }
local WHITE = { 1, 1, 1 }

-- A player's plate whose faction is set before the attach runs; a nil faction reads as
-- the other faction (stubsPatch03). addPlayerPlate fires once at its end, so the event
-- is silenced around it and fired once here.
local function addFactionPlayer(token, fields, faction)
    local realFire = HARNESS.fire
    HARNESS.fire = function() end
    local ok, frame = pcall(HARNESS.addPlayerPlate, token, fields or {})
    HARNESS.fire = realFire
    if not ok then
        error(frame)
    end
    HARNESS.units[token].faction = faction
    HARNESS.fire("NAME_PLATE_UNIT_ADDED", token)
    return frame
end

local function totalFactionCalls()
    local total = 0
    for _, calls in pairs(HARNESS.factionCalls) do
        total = total + calls
    end
    return total
end

do
    setNow("nameplates", "playerNameColours", true)
    local recordedBefore = names().recorded

    addFactionPlayer("nameplate1", {}, "Alliance")
    local first = nameRegion("nameplate1")
    check("F1 your faction, neither can attack: not written",
        first ~= nil and first.colourWrites == 0 and nameReads("nameplate1", WHITE), nameText("nameplate1"))
    check("F1 left as SameFaction", (names().left or {}).SameFaction == 1, (names().left or {}).SameFaction)
    check("F1 no NameColour record", names().recorded == recordedBefore, names().recorded)

    addFactionPlayer("nameplate2", { canAttack = true }, "Alliance")
    check("F2 your faction, able to fight you: red (D2)", nameReads("nameplate2", RED_NAME), nameText("nameplate2"))

    addFactionPlayer("nameplate3", {}, "Horde")
    check("F3 the other faction, neither can attack: light orange", nameReads("nameplate3", LIGHT_ORANGE),
        nameText("nameplate3"))

    addFactionPlayer("nameplate4", {}, HARNESS.SECRET)
    check("F4 a secret faction: not written", nameRegion("nameplate4").colourWrites == 0, nameText("nameplate4"))
    check("F4 left as FactionUnreadable", (names().left or {}).FactionUnreadable == 1,
        (names().left or {}).FactionUnreadable)
    local asked = HARNESS.factionCallCount("nameplate4")
    platePasses(1)
    check("F4 asked again next pass", HARNESS.factionCallCount("nameplate4") == asked + 1,
        HARNESS.factionCallCount("nameplate4") - asked)

    HARNESS.playerFactionSecret = true
    platePasses(1)
    local left = names().left or {}
    check("F5 your faction secret: every player who cannot fight you is FactionUnreadable",
        left.FactionUnreadable == 3 and left.SameFaction == nil, format("%s/%s", tostring(left.FactionUnreadable), tostring(left.SameFaction)))
    check("F5 and none of them is light orange", nameReads("nameplate3", WHITE) and nameReads("nameplate2", RED_NAME),
        nameText("nameplate3") .. " " .. nameText("nameplate2"))
    HARNESS.playerFactionSecret = false
    platePasses(1)
    check("F5 readable again: light orange again", nameReads("nameplate3", LIGHT_ORANGE), nameText("nameplate3"))

    HARNESS.removePlate("nameplate3")
    addFactionPlayer("nameplate3", {}, "Alliance")
    check("F6 re-added as your faction: white, and never written",
        nameReads("nameplate3", WHITE) and nameRegion("nameplate3").colourWrites == 0, nameText("nameplate3"))

    local before = HARNESS.factionCallCount("nameplate1")
    platePasses(4)
    check("F7 four passes ask a Plain faction nothing", HARNESS.factionCallCount("nameplate1") == before,
        HARNESS.factionCallCount("nameplate1") - before)
    HARNESS.removePlate("nameplate1")
    addFactionPlayer("nameplate1", {}, "Alliance")
    check("F7 a re-added plate is asked again", HARNESS.factionCallCount("nameplate1") == before + 1,
        HARNESS.factionCallCount("nameplate1") - before)

    local playerBefore, sweepsBefore = HARNESS.factionCallCount("player"), platesSweeps()
    platePasses(4)
    local passes = platesSweeps() - sweepsBefore
    check("F8 your faction once per pass, not once per plate",
        HARNESS.factionCallCount("player") - playerBefore == passes,
        format("%d reads over %d passes", HARNESS.factionCallCount("player") - playerBefore, passes))

    setNow("nameplates", "playerNameColours", false)
    local callsOff = totalFactionCalls()
    addFactionPlayer("nameplate5", {}, "Alliance")
    platePasses(1)
    HARNESS.fire("UNIT_FACTION", "player")
    HARNESS.frame()
    check("F9 colours off: no faction read across an attach, a pass and a flush",
        totalFactionCalls() == callsOff, totalFactionCalls() - callsOff)
    setNow("nameplates", "playerNameColours", true)

    HARNESS.removePlate("nameplate4")
    platePasses(1)
    local mark = chatMark()
    slash("plates")
    local out = chatSince(mark)
    check("F10 /pa plates prints sameFaction=", out:find("sameFaction=3", 1, true) ~= nil, out)
    check("F10 no unreadable: line while its sum is zero", out:find("    unreadable:", 1, true) == nil, out)

    addFactionPlayer("nameplate4", {}, HARNESS.SECRET)
    mark = chatMark()
    slash("plates")
    out = chatSince(mark)
    check("F11 only a faction unreadable: the unreadable: line prints, with faction=1",
        out:find("unreadable: player=0 style=0 attack=0 classColour=0 faction=1", 1, true) ~= nil, out)

    setNow("nameplates", "playerNameColours", false)
    for _, token in ipairs({ "nameplate1", "nameplate2", "nameplate3", "nameplate4", "nameplate5" }) do
        if HARNESS.plates[token] then
            HARNESS.removePlate(token)
        end
    end
end

-- T: regen ticks -------------------------------------------------------------------------------

local fsr = ns.FiveSecondRule
local STATE = ns.TRACKER_STATE

local function fsrView()
    return fsr.Inspect()
end

local function fsrCounter(name)
    return counters("fiveSecondRule")[name] or 0
end

local function cast(spellId)
    HARNESS.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-" .. tostring(spellId), spellId)
end

local function marker()
    local bar = _G.PlayerFrameManaBar
    for _, region in ipairs(bar and bar.regions or {}) do
        if region.kind == "Texture" then
            return region
        end
    end
end

local function markerX()
    local points = marker().points
    local last = points[#points]
    return last and last[4]
end

local function markerColourText()
    local colour = marker().colorTexture or {}
    return format("%.3f,%.3f,%.3f", colour[1] or -1, colour[2] or -1, colour[3] or -1)
end

local function markerIs(red, green, blue)
    local colour = marker().colorTexture or {}
    return near(colour[1], red) and near(colour[2], green) and near(colour[3], blue)
end

local function isGold()
    return markerIs(1, 209 / 255, 0)
end

local function isWhite()
    return markerIs(1, 1, 1)
end

-- In combat, a mana cast, then the window's end: Ticking, anchored at the window's end.
-- Leaves the clock 0.05 s past the anchor.
local function startTicking()
    HARNESS.playerInCombat = true
    cast(FIREBALL)
    HARNESS.frame(5.0)
    HARNESS.frame(0.05)
end

local RAGE = function() return 1, "RAGE" end
local realPowerType = UnitPowerType

do
    local view = fsrView()
    check("T16 tickFraction is 0 while regenerating", view.state == STATE.REGENERATING and view.tickFraction == 0,
        view.state .. "/" .. tostring(view.tickFraction))

    HARNESS.playerInCombat = true
    cast(FIREBALL)
    HARNESS.frame(1.0)
    view = fsrView()
    check("T16 tickFraction is 0 a second into the window", view.state == STATE.IN_FSR and view.tickFraction == 0
        and view.elapsedFraction > 0, view.state .. "/" .. tostring(view.tickFraction))
    HARNESS.frame(4.0)
    check("T1 still the window just before its end", fsrView().state == STATE.IN_FSR, fsrView().state)
    HARNESS.frame(0.05)
    view = fsrView()
    check("T1 the window's end in combat: Ticking", view.state == STATE.TICKING and fsrCounter("ticksStarted") == 1,
        view.state .. "/" .. fsrCounter("ticksStarted"))
    check("T1 the line in the tick colour", isGold(), markerColourText())
    check("T1 at the left edge", near(markerX(), 3, 0.5), markerX())
    HARNESS.frame(0.95)
    check("T2 at +1.0 s, half the bar's width", near(markerX(), 60, 0.5), markerX())
    HARNESS.frame(1.1)
    check("T2 at +2.1 s, back near the left edge", near(markerX(), 6, 0.5), markerX())
    HARNESS.frame(0.4)
    check("T2 at +2.5 s, a quarter", near(markerX(), 30, 0.5), markerX())

    cast(FIREBALL)
    view = fsrView()
    check("T7 a mana cast while ticking: the window again, white", view.state == STATE.IN_FSR and isWhite()
        and fsrCounter("tickStopsCast") == 1, view.state .. "/" .. markerColourText())
    HARNESS.frame(5.0)
    HARNESS.frame(0.05)
    check("T7 and its end ticks again", fsrView().state == STATE.TICKING, fsrView().state)

    cast(WAND)
    check("T8 a free cast while ticking changes nothing", fsrView().state == STATE.TICKING, fsrView().state)

    setNow("fiveSecondRule", "tickColour", "00ff00")
    check("T10 a new tick colour while ticking: recoloured at once", markerIs(0, 1, 0), markerColourText())
    setNow("fiveSecondRule", "tickColour", "ffd100")

    local mark = chatMark()
    slash("fsr")
    local out = chatSince(mark)
    check("T14 /pa fsr prints Ticking and the ticks line",
        out:find("state=TICKING", 1, true) ~= nil and out:find("ticks: on, every 2.0s; started=2", 1, true) ~= nil, out)

    UnitPowerType = RAGE
    HARNESS.fire("UNIT_DISPLAYPOWER", "player")
    view = fsrView()
    check("T13 a non-mana form while ticking: hidden, still Ticking",
        view.state == STATE.TICKING and marker().shown == false, view.state)
    check("T15 the driver keeps running while the line is hidden", view.driverRunning == true)
    UnitPowerType = realPowerType
    HARNESS.fire("UNIT_DISPLAYPOWER", "player")
    check("T13 back to mana, in combat: shown", fsrView().state == STATE.TICKING and marker().shown == true)

    HARNESS.fire("PLAYER_REGEN_ENABLED")
    view = fsrView()
    check("T5 the fight's end: Regenerating, hidden, white",
        view.state == STATE.REGENERATING and marker().shown == false and isWhite()
        and fsrCounter("tickStopsFightEnded") == 1, view.state .. "/" .. markerColourText())
    check("T16 tickFraction is 0 once ticks end", view.tickFraction == 0, view.tickFraction)

    startTicking()
    HARNESS.playerInCombat = false
    local calls = HARNESS.combatCalls
    for _ = 1, 10 do
        HARNESS.frame(0.05)
    end
    check("T6 between boundaries no combat read", HARNESS.combatCalls == calls, HARNESS.combatCalls - calls)
    check("T6 still Ticking until the boundary", fsrView().state == STATE.TICKING, fsrView().state)
    HARNESS.frame(1.5)
    check("T6 the boundary reads out of combat: stopped",
        fsrView().state == STATE.REGENERATING and fsrCounter("tickStopsBackstop") == 1,
        fsrView().state .. "/" .. fsrCounter("tickStopsBackstop"))

    HARNESS.playerInCombat = false
    cast(FIREBALL)
    HARNESS.frame(5.0)
    HARNESS.frame(0.05)
    check("T3 out of combat at the window's end: no ticks",
        fsrView().state == STATE.REGENERATING and marker().shown == false
        and fsrCounter("ticksSkippedOutOfCombat") == 1, fsrView().state)

    HARNESS.combatSecret = true
    cast(FIREBALL)
    HARNESS.frame(5.0)
    HARNESS.frame(0.05)
    check("T4 combat unread at the window's end: no ticks",
        fsrView().state == STATE.REGENERATING and fsrCounter("ticksSkippedCombatUnread") == 1, fsrView().state)
    HARNESS.combatSecret = false

    startTicking()
    setNow("fiveSecondRule", "showTicks", false)
    check("T9 switched off while ticking: stopped at once",
        fsrView().state == STATE.REGENERATING and fsrCounter("tickStopsSwitchedOff") == 1, fsrView().state)
    cast(FIREBALL)
    HARNESS.frame(5.0)
    HARNESS.frame(0.05)
    check("T9 off at the window's end: no ticks",
        fsrView().state == STATE.REGENERATING and fsrCounter("ticksSkippedOff") == 1, fsrView().state)
    setNow("fiveSecondRule", "showTicks", true)

    startTicking()
    HARNESS.fire("PLAYER_ENTERING_WORLD")
    HARNESS.frame()
    check("T11 a loading screen ends the ticks",
        fsrView().state == STATE.REGENERATING and fsrCounter("tickStopsLoadingScreen") == 1, fsrView().state)

    startTicking()
    slash("off fiveSecondRule")
    view = fsrView()
    check("T12 disabled while ticking: no OnUpdate script on the driver, regenerating",
        view.driverRunning == false and view.state == STATE.REGENERATING, tostring(view.driverRunning))
    slash("on fiveSecondRule")
    check("T12 enabled again", ns.Registry.State("fiveSecondRule") == "ENABLED")

    cast(FIREBALL)
    local started = fsrCounter("ticksStarted")
    slash("off fiveSecondRule")
    HARNESS.frame(5.0)
    HARNESS.frame(0.5)
    check("T12 disabled inside the window: no timer left to end it into ticks",
        fsrCounter("ticksStarted") == started and fsrView().state == STATE.REGENERATING
        and fsrView().driverRunning == false, fsrView().state)
    slash("on fiveSecondRule")
    HARNESS.playerInCombat = false

    -- T15, the audit's: hidden ticks keep their backstop, and never flash on the way back.
    startTicking()
    UnitPowerType = RAGE
    HARNESS.fire("UNIT_DISPLAYPOWER", "player")
    HARNESS.playerInCombat = false
    local stops = fsrCounter("tickStopsBackstop")
    HARNESS.frame(2.1)
    check("T15 hidden, the fight over unannounced: stopped at the boundary",
        fsrView().state == STATE.REGENERATING and fsrCounter("tickStopsBackstop") == stops + 1, fsrView().state)
    UnitPowerType = realPowerType
    HARNESS.fire("UNIT_DISPLAYPOWER", "player")

    startTicking()
    UnitPowerType = RAGE
    HARNESS.fire("UNIT_DISPLAYPOWER", "player")
    HARNESS.playerInCombat = false
    UnitPowerType = realPowerType
    local line = marker()
    local shows = 0
    rawset(line, "Show", function(self)
        shows = shows + 1
        self.shown = true
    end)
    stops = fsrCounter("tickStopsBackstop")
    HARNESS.fire("UNIT_DISPLAYPOWER", "player")
    rawset(line, "Show", nil)
    check("T15 back to mana after the fight ended unannounced: never shown, stopped",
        shows == 0 and line.shown == false and fsrView().state == STATE.REGENERATING
        and fsrCounter("tickStopsBackstop") == stops + 1, format("shows=%d state=%s", shows, fsrView().state))
end

-- K: tank colours -------------------------------------------------------------------------------

local BAR_RED = { 1, 64 / 255, 64 / 255 }
local BAR_ORANGE = { 1, 128 / 255, 0 }
local BAR_GREEN = { 64 / 255, 1, 64 / 255 }

local mobs, nextMob = {}, 100

-- A hostile mob with a plate, fields set before the attach runs.
local function mob(fields)
    nextMob = nextMob + 1
    local token = "nameplate" .. nextMob
    local realFire = HARNESS.fire
    HARNESS.fire = function() end
    local ok, frame = pcall(HARNESS.addPlate20, token, { canAttack = true, reaction = fields.reaction or 2 })
    HARNESS.fire = realFire
    if not ok then
        error(frame)
    end
    local unit = HARNESS.units[token]
    unit.inCombat = true
    for key, value in pairs(fields) do
        unit[key] = value
    end
    HARNESS.fire("NAME_PLATE_UNIT_ADDED", token)
    mobs[#mobs + 1] = token
    return token
end

local function clearMobs()
    for _, token in ipairs(mobs) do
        if HARNESS.plates[token] then
            HARNESS.removePlate(token)
        end
    end
    mobs = {}
end

local function barOf(token)
    local frame = HARNESS.plates[token]
    return frame and frame.UnitFrame.healthBar
end

local function barReads(token, colour)
    local bar = barOf(token)
    return bar ~= nil and near(bar.r, colour[1]) and near(bar.g, colour[2]) and near(bar.b, colour[3])
end

local function barText(token)
    local bar = barOf(token)
    return bar and format("%s: %.3f,%.3f,%.3f", token, bar.r, bar.g, bar.b) or (token .. ": no bar")
end

local function verdictOf(token)
    for _, plate in ipairs(Plates.TrackedPlates()) do
        if plate.unitToken == token then
            return plate.lastVerdict
        end
    end
end

local panel = ns.ThreatPanel

local function panelSweeps()
    return panel.Inspect().sweeps
end

local function settlePanel(n)
    local start = panelSweeps()
    local guard = 0
    while panelSweeps() - start < (n or 2) and guard < 400 do
        HARNESS.frame(0.05)
        guard = guard + 1
    end
end

local function rowReads(token, colour)
    for _, row in ipairs(panel.Inspect().rows) do
        if row.token == token then
            local bar = row.frame and row.frame.bar
            return bar ~= nil and near(bar.r, colour[1]) and near(bar.g, colour[2]) and near(bar.b, colour[3])
        end
    end
    return false
end

local function startCombat()
    HARNESS.playerInCombat = true
    HARNESS.fire("PLAYER_REGEN_DISABLED")
    HARNESS.frame()
end

local function endCombat()
    HARNESS.playerInCombat = false
    HARNESS.fire("PLAYER_REGEN_ENABLED")
    HARNESS.frame()
end

local held, slipping, pulling, loose
do
    setNow("nameplates", "threatRole", "Dps")
    held = mob({ threat = { player = 3 } })
    slipping = mob({ threat = { player = 2 } })
    platePasses(1)
    check("K1 DPS: held securely, OnPlayer red", verdictOf(held) == VERDICT.ON_PLAYER and barReads(held, BAR_RED),
        tostring(verdictOf(held)) .. " " .. barText(held))
    check("K1 DPS: out-threatened, OnPlayer red", verdictOf(slipping) == VERDICT.ON_PLAYER
        and barReads(slipping, BAR_RED), tostring(verdictOf(slipping)) .. " " .. barText(slipping))

    pulling = mob({ threat = { player = 1 } })
    loose = mob({ threat = { party1 = 2 } })
    setNow("nameplates", "threatRole", "Tank")
    check("K2 Tank: held securely, TankHolding in the group colour",
        verdictOf(held) == VERDICT.TANK_HOLDING and barReads(held, BAR_GREEN), tostring(verdictOf(held)) .. " " .. barText(held))
    check("K3 Tank: out-threatened, TankSlipping in the about-to-pull colour",
        verdictOf(slipping) == VERDICT.TANK_SLIPPING and barReads(slipping, BAR_ORANGE),
        tostring(verdictOf(slipping)) .. " " .. barText(slipping))
    check("K4 Tank: above whoever holds it, AboutToPull",
        verdictOf(pulling) == VERDICT.ABOUT_TO_PULL and barReads(pulling, BAR_ORANGE), tostring(verdictOf(pulling)))
    check("K5 Tank: on the group, TankLoose in the attacking-you colour",
        verdictOf(loose) == VERDICT.TANK_LOOSE and barReads(loose, BAR_RED), tostring(verdictOf(loose)) .. " " .. barText(loose))

    local tappedLoose = mob({ threat = { party1 = 2 }, tapDenied = true })
    platePasses(1)
    check("K6 Tank: a tapped mob on the group is TankLoose, above grey (D13)",
        verdictOf(tappedLoose) == VERDICT.TANK_LOOSE, tostring(verdictOf(tappedLoose)))
    setNow("nameplates", "threatRole", "Dps")
    check("K6 DPS: the same mob is TapDenied", verdictOf(tappedLoose) == VERDICT.TAP_DENIED,
        tostring(verdictOf(tappedLoose)))
    setNow("nameplates", "threatRole", "Tank")

    local tappedIdle = mob({ tapDenied = true })
    local hidden = mob({ threatSecret = true })
    local neutral = mob({ reaction = 4 })
    platePasses(1)
    check("K7 Tank: tapped and on nobody, TapDenied", verdictOf(tappedIdle) == VERDICT.TAP_DENIED,
        tostring(verdictOf(tappedIdle)))
    check("K7 Tank: a withheld threat read, Ceded", verdictOf(hidden) == VERDICT.CEDED, tostring(verdictOf(hidden)))
    check("K7 Tank: neutral and on nobody, Neutral", verdictOf(neutral) == VERDICT.NEUTRAL, tostring(verdictOf(neutral)))

    setNow("nameplates", "colourOnGroup", "00ffff")
    check("K8 Tank: the group colour changed, a held mob repaints at once", barReads(held, { 0, 1, 1 }), barText(held))
    setNow("nameplates", "colourOnGroup", "40ff40")

    startCombat()
    settlePanel(2)
    check("K9 Tank: the panel row and the plate agree on a held mob",
        rowReads(held, BAR_GREEN) and barReads(held, BAR_GREEN), barText(held))
    setNow("nameplates", "threatRole", "Dps")
    settlePanel(1)
    check("K9 DPS: they agree again", rowReads(held, BAR_RED) and barReads(held, BAR_RED), barText(held))
    check("K11 the panel follows a role change at its next sweep", panel.Inspect().role == Threat.ROLE.DPS,
        tostring(panel.Inspect().role))

    setNow("nameplates", "threatRole", "Tank")
    settlePanel(1)
    local mark = chatMark()
    slash("plates")
    local out = chatSince(mark)
    check("K12 /pa plates counts the tank verdicts", out:find("holding=1 slipping=1 loose=2", 1, true) ~= nil, out)
    check("K12 /pa plates names the role", out:find("colours for: Tank", 1, true) ~= nil, out)
    mark = chatMark()
    slash("threat")
    out = chatSince(mark)
    check("K12 /pa threat names the role", out:find("role=Tank", 1, true) ~= nil, out)
    endCombat()

    HARNESS.setStoredRole("tank")
    ns.Registry.NotifyConfigChanged("nameplates", "threatRole")
    check("K10 a raw stored lower-case tank reads as DPS", platesView().roleChoice == Threat.ROLE_CHOICE.DPS,
        platesView().roleChoice)
    local accepted = ns.ConfigStore.Set("nameplates", "threatRole", "Bear")
    check("K10 ConfigStore.Set refuses anything but Dps, Tank and Auto", accepted == false)
    setNow("nameplates", "threatRole", "Dps")

    slash("role tank")
    mark = chatMark()
    slash("threat")
    out = chatSince(mark)
    check("K13 out of combat, after /pa role tank: /pa threat prints role=Tank",
        out:find("role=Tank", 1, true) ~= nil, out)
    check("K13 and the panel's Inspect reads the choice from the store",
        panel.Inspect().roleChoice == Threat.ROLE_CHOICE.TANK, panel.Inspect().roleChoice)
    setNow("nameplates", "threatRole", "Dps")
end

-- A: Auto ---------------------------------------------------------------------------------------

local function autoReads(name)
    return counters("nameplates")[name] or 0
end

local skills = ns.EquippedSkills

local function roleBox()
    return skills.Inspect().roleBox
end

local function isLit(button)
    local colour = button and button.background and button.background.colorTexture
    return colour ~= nil and near(colour[1], 0.22) and near(colour[3], 0.80)
end

local function openBags()
    ContainerFrameCombinedBags:Show()
    HARNESS.frame()
end

local function closeBags()
    ContainerFrameCombinedBags:Hide()
    HARNESS.frame()
end

do
    setNow("nameplates", "threatRole", "Auto")
    HARNESS.effectivelyTank = false
    platePasses(1)
    check("A1 Auto with the test false: DPS colours", verdictOf(held) == VERDICT.ON_PLAYER and barReads(held, BAR_RED),
        tostring(verdictOf(held)) .. " " .. barText(held))
    HARNESS.effectivelyTank = true
    platePasses(1)
    check("A2 the test true: TankHolding, green", verdictOf(held) == VERDICT.TANK_HOLDING and barReads(held, BAR_GREEN),
        tostring(verdictOf(held)) .. " " .. barText(held))
    startCombat()
    settlePanel(2)
    check("A2 the panel row matches", rowReads(held, BAR_GREEN))
    HARNESS.effectivelyTank = false
    platePasses(1)
    check("A3 in combat, the test turned false: the next pass repaints, with no settings change",
        verdictOf(held) == VERDICT.ON_PLAYER and barReads(held, BAR_RED), barText(held))
    HARNESS.effectivelyTank = true
    platePasses(1)
    check("A3 and turned true again: green at the next pass, still with no settings change",
        verdictOf(held) == VERDICT.TANK_HOLDING and barReads(held, BAR_GREEN), barText(held))
    HARNESS.effectivelyTank = false
    platePasses(1)
    endCombat()

    clearMobs()
    for _ = 1, 5 do
        mob({ threat = { player = 3 } })
    end
    held = mobs[1]
    local calls, sweeps = HARNESS.tankTestCalls, platesSweeps()
    platePasses(4)
    local passes = platesSweeps() - sweeps
    check("A4 five held plates make one test read per pass, not one per plate",
        HARNESS.tankTestCalls - calls == passes, format("%d reads over %d passes", HARNESS.tankTestCalls - calls, passes))

    setNow("nameplates", "threatRole", "Tank")
    calls = HARNESS.tankTestCalls
    platePasses(2)
    startCombat()
    settlePanel(1)
    endCombat()
    openBags()
    HARNESS.advance(1.1)
    closeBags()
    setNow("nameplates", "threatRole", "Dps")
    platePasses(1)
    check("A5 under Tank and Dps the test is never read: plates, panel or box",
        HARNESS.tankTestCalls == calls, HARNESS.tankTestCalls - calls)

    setNow("nameplates", "threatRole", "Auto")
    HARNESS.effectivelyTankSecret = true
    local unread, plain = autoReads("autoRoleReadsUnread"), autoReads("autoRoleReadsPlain")
    platePasses(1)
    check("A6 a secret test: DPS colours", barReads(held, BAR_RED), barText(held))
    check("A6 counted unread", autoReads("autoRoleReadsUnread") > unread)
    openBags()
    check("A6 the box reads Auto: ?", roleBox().buttons.Auto.label.text == "Auto: ?", roleBox().buttons.Auto.label.text)
    closeBags()
    HARNESS.effectivelyTankSecret = false

    HARNESS.effectivelyTankSilent = true
    unread, plain = autoReads("autoRoleReadsUnread"), autoReads("autoRoleReadsPlain")
    platePasses(1)
    check("A7 a silent test: DPS colours, unread, never a Plain read",
        barReads(held, BAR_RED) and autoReads("autoRoleReadsUnread") > unread and autoReads("autoRoleReadsPlain") == plain,
        barText(held))
    openBags()
    check("A7 the box reads Auto: ?", roleBox().buttons.Auto.label.text == "Auto: ?", roleBox().buttons.Auto.label.text)
    closeBags()
    HARNESS.effectivelyTankSilent = false

    HARNESS.removeTankTest()
    local mark = chatMark()
    platePasses(2)
    local out = chatSince(mark)
    check("A8 the function missing: DPS colours", barReads(held, BAR_RED), barText(held))
    check("A8 one line, said once over two passes", occurrences(out, "has no UnitHasEffectivelyTankAura") == 1, out)
    openBags()
    check("A8 the box reads Auto: ?", roleBox().buttons.Auto.label.text == "Auto: ?", roleBox().buttons.Auto.label.text)
    closeBags()
    HARNESS.restoreTankTest()

    HARNESS.effectivelyTank = true
    openBags()
    local box = roleBox()
    check("A9 the box under Auto: Auto lit, reading Auto: Tank",
        isLit(box.buttons.Auto) and box.buttons.Auto.label.text == "Auto: Tank"
        and not isLit(box.buttons.Tank) and not isLit(box.buttons.Dps), box.buttons.Auto.label.text)
    HARNESS.effectivelyTank = false
    HARNESS.advance(1.1)
    check("A9 the test turned false: Auto: DPS within one poll", box.buttons.Auto.label.text == "Auto: DPS",
        box.buttons.Auto.label.text)
    closeBags()

    setNow("nameplates", "threatRole", "Dps")
    HARNESS.effectivelyTank = true
    mark = chatMark()
    slash("role auto")
    out = chatSince(mark)
    check("A10 /pa role auto stores Auto", ns.ConfigStore.Get("nameplates", "threatRole") == "Auto")
    check("A10 /pa role prints the live answer and the test's line",
        out:find("role: Auto, now Tank", 1, true) ~= nil and out:find("the game's tank test: true", 1, true) ~= nil, out)

    mark = chatMark()
    slash("set nameplates threatRole Bear")
    out = chatSince(mark)
    check("A11 /pa set refuses a value that is not a choice",
        ns.ConfigStore.Get("nameplates", "threatRole") == "Auto" and out:find("NotAChoice", 1, true) ~= nil, out)
    HARNESS.setStoredRole("auto")
    ns.Registry.NotifyConfigChanged("nameplates", "threatRole")
    check("A11 a raw stored lower-case auto reads as DPS", platesView().roleChoice == Threat.ROLE_CHOICE.DPS,
        platesView().roleChoice)
    setNow("nameplates", "threatRole", "Auto")

    platePasses(1)
    mark = chatMark()
    slash("plates")
    out = chatSince(mark)
    check("A12 /pa plates prints colours for: Tank (Auto)", out:find("colours for: Tank (Auto)", 1, true) ~= nil, out)
    mark = chatMark()
    slash("threat")
    out = chatSince(mark)
    check("A12 /pa threat prints role=Tank (Auto)", out:find("role=Tank (Auto)", 1, true) ~= nil, out)

    HARNESS.effectivelyTank = false
    HARNESS.compositeTank = true
    local composite = HARNESS.compositeCalls
    platePasses(1)
    mark = chatMark()
    slash("role")
    out = chatSince(mark)
    check("A13 Blizzard's composite says tank, the test does not: Auto reads DPS",
        barReads(held, BAR_RED) and out:find("role: Auto, now DPS", 1, true) ~= nil, out)
    check("A13 and the composite is never asked", HARNESS.compositeCalls == composite,
        HARNESS.compositeCalls - composite)
    HARNESS.compositeTank = false
    setNow("nameplates", "threatRole", "Dps")
end

-- B: the role box -------------------------------------------------------------------------------

local function hasPoint(frame, point, relativeTo, relativePoint, x, y)
    for _, entry in ipairs(frame.points or {}) do
        if entry[1] == point and entry[2] == relativeTo and entry[3] == relativePoint
            and near(entry[4], x, 0.001) and near(entry[5], y, 0.001) then
            return true
        end
    end
    return false
end

do
    local skillsPanel = _G.PersonalAddonEquippedSkills
    local uiPanelsBefore = HARNESS.uiPanelCalls
    openBags()
    local box = roleBox()
    local boxFrame = box.frame
    check("B1 bags open: the box is shown", box.shown == true and box.created == true)
    check("B1 its top-left 2 px below the panel's bottom-left, its top-right on the panel's bottom-right",
        hasPoint(boxFrame, "TOPLEFT", skillsPanel, "BOTTOMLEFT", 0, -2)
        and hasPoint(boxFrame, "TOPRIGHT", skillsPanel, "BOTTOMRIGHT", 0, -2))

    local tank, dps, auto = box.buttons.Tank, box.buttons.Dps, box.buttons.Auto
    check("B17 Tank runs from the box's left edge to its top centre",
        hasPoint(tank, "TOPLEFT", boxFrame, "TOPLEFT", 4, -4) and hasPoint(tank, "TOPRIGHT", boxFrame, "TOP", -1, -4))
    check("B17 DPS from the top centre to the right edge",
        hasPoint(dps, "TOPLEFT", boxFrame, "TOP", 1, -4) and hasPoint(dps, "TOPRIGHT", boxFrame, "TOPRIGHT", -4, -4))
    check("B17 Auto spans them, a row below",
        hasPoint(auto, "TOPLEFT", tank, "BOTTOMLEFT", 0, -2) and hasPoint(auto, "TOPRIGHT", dps, "BOTTOMRIGHT", 0, -2))
    check("B17 the box is 42 px tall", boxFrame.height == 42, boxFrame.height)

    check("B3 a fresh choice: DPS lit, Tank and Auto dimmed, Auto reading Auto",
        isLit(dps) and not isLit(tank) and not isLit(auto) and auto.label.text == "Auto"
        and ns.ConfigStore.Get("nameplates", "threatRole") == "Dps", auto.label.text)

    local allScripts = true
    for _, button in pairs(box.buttons) do
        allScripts = allScripts and button:GetScript("OnClick") ~= nil
            and button:GetScript("OnEnter") == nil and button:GetScript("OnLeave") == nil
    end
    check("B6 each button has an OnClick and no OnEnter or OnLeave", allScripts)
    check("B6 the box frame itself is not mouse-enabled", boxFrame:IsMouseEnabled() == false)

    check("B7 the box's parent is the skills panel", rawget(boxFrame, "parent") == skillsPanel)
    check("B7 nothing of the box descends from the bag", not HARNESS.descendsFrom(boxFrame, ContainerFrameCombinedBags))

    clearMobs()
    local heldB = mob({ threat = { player = 3 } })
    platePasses(1)
    HARNESS.click(tank)
    check("B4 a click on Tank stores Tank", ns.ConfigStore.Get("nameplates", "threatRole") == "Tank")
    check("B4 Tank lit at once", isLit(tank) and not isLit(dps))
    check("B4 and the held plate is green in the same call", barReads(heldB, BAR_GREEN), barText(heldB))

    local writes = counters("nameplates").roleWrites or 0
    local setCalls, realSetForCount = 0, ns.ConfigStore.Set
    ns.ConfigStore.Set = function(...)
        setCalls = setCalls + 1
        return realSetForCount(...)
    end
    HARNESS.click(tank)
    ns.ConfigStore.Set = realSetForCount
    check("B5 a click on the active choice writes nothing: no Set call, roleWrites unchanged",
        setCalls == 0 and (counters("nameplates").roleWrites or 0) == writes, setCalls)

    local created = #HARNESS.createdFrames
    closeBags()
    check("B2 bags closed: hidden with the panel", roleBox().shown == false)
    openBags()
    check("B7 opening and closing the bags creates no frame", #HARNESS.createdFrames == created,
        #HARNESS.createdFrames - created)

    setNow("equippedSkills", "roleChoice", false)
    check("B8 roleChoice off: hidden with the bags open", roleBox().shown == false)
    HARNESS.setStoredRole("Auto")
    HARNESS.effectivelyTank = true
    setNow("equippedSkills", "roleChoice", true)
    check("B8 on: shown", roleBox().shown == true)
    check("B16 turned on with the bags open: relit at once, to the stored choice",
        isLit(auto) and auto.label.text == "Auto: Tank", auto.label.text)
    setNow("nameplates", "threatRole", "Dps")

    HARNESS.advance(1.1)
    slash("role tank")
    check("B9 /pa role touches no box: not relit before the poll", isLit(dps) and not isLit(tank))
    HARNESS.advance(1.1)
    check("B9 relit within one poll", isLit(tank) and not isLit(dps))

    setNow("equippedSkills", "panelAlpha", 0.5)
    check("B15 the box's background follows the panel's opacity",
        near(boxFrame.background.alpha, 0.5) and near(skillsPanel.background.alpha, 0.5),
        tostring(boxFrame.background.alpha))
    skills.Refresh()
    check("B15 a render keeps it", near(boxFrame.background.alpha, 0.5), tostring(boxFrame.background.alpha))

    local realSet = ns.ConfigStore.Set
    ns.ConfigStore.Set = function()
        return false, "refused for the check"
    end
    local refused = counters("nameplates").roleWritesRefused or 0
    local mark = chatMark()
    HARNESS.click(auto)
    HARNESS.click(auto)
    ns.ConfigStore.Set = realSet
    local out = chatSince(mark)
    check("B13 a refused write relights nothing", isLit(tank) and not isLit(auto))
    check("B13 counted, one line over two refusals",
        (counters("nameplates").roleWritesRefused or 0) == refused + 2
        and occurrences(out, "could not be stored") == 1, out)

    HARNESS.effectivelyTank = true
    HARNESS.click(auto)
    check("B14 a click on Auto with the test true: Auto stored, lit, reading Auto: Tank",
        ns.ConfigStore.Get("nameplates", "threatRole") == "Auto" and isLit(auto) and auto.label.text == "Auto: Tank",
        auto.label.text)
    check("B14 and the held plate is green", barReads(heldB, BAR_GREEN), barText(heldB))

    closeBags()
    slash("preview on")
    check("B11 the preview shows the box with the sample rows", roleBox().shown == true)
    check("B15 the preview keeps the box's opacity", near(boxFrame.background.alpha, 0.5))
    check("B16 the preview shows the stored choice", isLit(auto) and auto.label.text == "Auto: Tank", auto.label.text)
    slash("preview off")
    setNow("equippedSkills", "panelAlpha", 0.8)

    slash("off equippedSkills")
    mark = chatMark()
    slash("role tank")
    out = chatSince(mark)
    check("B10 the skills panel off: no box", roleBox().shown == false)
    check("B10 /pa role still sets the role, and says the box is unavailable",
        ns.ConfigStore.Get("nameplates", "threatRole") == "Tank"
        and out:find("box: unavailable (skills window off)", 1, true) ~= nil, out)
    platePasses(1)
    check("B10 and the plates follow", barReads(heldB, BAR_GREEN), barText(heldB))
    slash("on equippedSkills")

    check("B12 the box never called ShowUIPanel or HideUIPanel", HARNESS.uiPanelCalls == uiPanelsBefore,
        HARNESS.uiPanelCalls - uiPanelsBefore)
    HARNESS.effectivelyTank = false
    setNow("nameplates", "threatRole", "Dps")
end

-- R: /pa role -----------------------------------------------------------------------------------

do
    local mark = chatMark()
    slash("role")
    local out = chatSince(mark)
    check("R1 /pa role prints DPS", out:find("role: DPS (per account)", 1, true) ~= nil, out)

    mark = chatMark()
    slash("role tank")
    out = chatSince(mark)
    check("R2 /pa role tank sets and prints Tank",
        ns.ConfigStore.Get("nameplates", "threatRole") == "Tank" and out:find("role: Tank", 1, true) ~= nil, out)

    mark = chatMark()
    slash("role bear")
    out = chatSince(mark)
    check("R3 /pa role bear prints the usage line and writes nothing",
        out:find("/pa role [tank | dps | auto]", 1, true) ~= nil
        and ns.ConfigStore.Get("nameplates", "threatRole") == "Tank", out)

    setNow("nameplates", "threatRole", "Dps")
    slash("off nameplates")
    slash("off equippedSkills")
    local writes = counters("nameplates").roleWrites or 0
    mark = chatMark()
    slash("role tank")
    slash("role")
    out = chatSince(mark)
    check("R4 both features off: /pa role tank stores Tank, counted in the nameplates table",
        ns.ConfigStore.Get("nameplates", "threatRole") == "Tank"
        and (counters("nameplates").roleWrites or 0) == writes + 1, out)
    check("R4 and /pa role prints it", out:find("role: Tank (per account); box: unavailable", 1, true) ~= nil, out)
    setNow("nameplates", "threatRole", "Auto")
    HARNESS.effectivelyTank = true
    mark = chatMark()
    slash("role")
    out = chatSince(mark)
    check("R4 under Auto the counters printed are the three consumers' sums",
        out:find("the game's tank test: true; reads plain=", 1, true) ~= nil, out)
    HARNESS.effectivelyTank = false
    slash("on nameplates")
    slash("on equippedSkills")
    check("R4 both enabled again", ns.Registry.State("nameplates") == "ENABLED"
        and ns.Registry.State("equippedSkills") == "ENABLED")
    setNow("nameplates", "threatRole", "Dps")
end

-- The saved diagnostics stay numbers ------------------------------------------------------------

local function diagnosticsValid()
    local log = PersonalAddonDiagnostics
    if type(log) ~= "table" or type(log.sessions) ~= "table" then
        return false, "no saved log"
    end
    for _, sessionRecord in ipairs(log.sessions) do
        for featureId, values in pairs(sessionRecord.counters or {}) do
            for name, value in pairs(values) do
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

-- Report ----------------------------------------------------------------------------------------
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
