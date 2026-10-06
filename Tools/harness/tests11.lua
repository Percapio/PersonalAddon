-- Phase 11 offline checks (Architecture/20261005-Phase11.md section 10.1).
-- Sessions: "phase11" (P1-P6, P8-P11, P13, P14, P17, P18), "phase11-hidden" (P7)
-- and "phase11-noplates" (P12). P15 is every other session passing unchanged; P16
-- is the lint, which run.py runs first.

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

local function chatSince(mark)
    local lines = {}
    for index = mark + 1, #HARNESS.chat do
        lines[#lines + 1] = HARNESS.chat[index]
    end
    return table.concat(lines, "\n")
end

local function count(text, needle)
    local found, start = 0, 1
    while true do
        local at = text:find(needle, start, true)
        if not at then
            return found
        end
        found = found + 1
        start = at + #needle
    end
end

local function near(expected, red, green, blue)
    return type(red) == "number" and math.abs(red - expected[1]) < 0.011
        and math.abs(green - expected[2]) < 0.011 and math.abs(blue - expected[3]) < 0.011
end

local function colourText(red, green, blue)
    return string.format("%.3f %.3f %.3f", red or -1, green or -1, blue or -1)
end

local RED, ORANGE, GREEN = { 1, 0.251, 0.251 }, { 1, 0.502, 0 }, { 0.251, 1, 0.251 }
local NEW_GREEN = { 0, 1, 0 }
local EM_DASH = "\226\128\148"

-- Blizzard's own colour function, as tests9.lua models it, defined before login so
-- the nameplate post-hooks install.
HARNESS.unitForFrame = {}
function CompactUnitFrame_UpdateHealthColor(unitFrame)
    local token = HARNESS.unitForFrame[unitFrame]
    local unit = token and HARNESS.units[token]
    if not unit then
        return
    end
    local r, g, b = 1, 0, 0
    if unit.tapDenied and not unit.controlled then
        r, g, b = 0.9, 0.9, 0.9
    elseif unit.reaction == 4 and not unit.inCombat then
        r, g, b = 1, 1, 0
    end
    unitFrame.healthBar:SetStatusBarColor(r, g, b)
end

-- Session set-up, before login ---------------------------------------------------------
HARNESS.installCVars({ nameplateShowEnemies = (HARNESS_SESSION == "phase11-noplates") and "0" or "1" })
if HARNESS_SESSION == "phase11-hidden" then
    HARNESS.hiddenNames = true
end
HARNESS.units.party2 = { id = "party2", inParty = true }
HARNESS.groupSize = 3

HARNESS.fire("ADDON_LOADED", "PersonalAddon")
HARNESS.fire("PLAYER_LOGIN")
HARNESS.frame()
check("threat panel enabled", ns.Registry.State("threatPanel") == "ENABLED", ns.Registry.State("threatPanel"))
check("nameplates enabled", ns.Registry.State("nameplates") == "ENABLED", ns.Registry.State("nameplates"))

local function view()
    return ns.ThreatPanel.Inspect()
end

local function counters()
    return ns.Diagnostics.CountersFor("threatPanel")
end

-- Advances until the panel, and the nameplates unless panelOnly, have swept n more
-- times; the harness ticker drifts by up to a frame per firing.
local function settle(n, panelOnly)
    n = n or 2
    local panelStart, platesStart = view().sweeps, ns.Nameplates.Inspect().sweeps
    local guard = 0
    while (view().sweeps - panelStart < n
        or (not panelOnly and ns.Nameplates.Inspect().sweeps - platesStart < n))
        and guard < 2000 do
        HARNESS.frame(0.05)
        guard = guard + 1
    end
end

local function startCombat()
    HARNESS.playerInCombat = true
    HARNESS.fire("PLAYER_REGEN_DISABLED")
end

local function endCombat()
    HARNESS.playerInCombat = false
    HARNESS.fire("PLAYER_REGEN_ENABLED")
end

local nextPlate = 0

-- A hostile mob in combat with a plate; fields override the defaults.
local function mob(fields)
    nextPlate = nextPlate + 1
    local token = "nameplate" .. nextPlate
    local unit = { canAttack = true, inCombat = true, reaction = 2 }
    for key, value in pairs(fields or {}) do
        unit[key] = value
    end
    local bar = HARNESS.addPlate(token, unit, { 1, 0, 0 })
    HARNESS.unitForFrame[HARNESS.plates[token].UnitFrame] = token
    return token, bar
end

local function clearMobs()
    for index = #HARNESS.plateOrder, 1, -1 do
        local token = HARNESS.plateOrder[index]
        if HARNESS.plates[token] then
            HARNESS.removePlate(token)
        end
        HARNESS.plateOrder[index] = nil
    end
    HARNESS.selectedTarget = nil
end

-- A fight: the mobs are set up out of combat, combat starts, both features settle.
local function beginFight(setup)
    endCombat()
    HARNESS.frame()
    clearMobs()
    local made = { setup() }
    startCombat()
    HARNESS.frame()
    settle()
    return unpack(made)
end

local function rowFor(token)
    for index, row in ipairs(view().rows) do
        if row.token == token then
            return row, index
        end
    end
    return nil
end

local function rowTokens()
    local tokens = {}
    for index, row in ipairs(view().rows) do
        tokens[index] = row.token
    end
    return table.concat(tokens, ",")
end

local function rowColour(token)
    local row = rowFor(token)
    if not row then
        return nil
    end
    local bar = row.frame.bar
    return bar.r, bar.g, bar.b
end

local function plateColour(bar)
    return bar.r, bar.g, bar.b
end

if HARNESS_SESSION == "phase11" then
    -- P10: idle out of combat; the event only schedules; a frame later it sweeps.
    clearMobs()
    local first = mob({ name = "Defias Pillager", targetId = "player", threatPercent = { player = 100 } })
    HARNESS.frame()
    check("P10 hidden out of combat", view().panelShown == false and view().sweeping == false)
    startCombat()
    check("P10 the handler only schedules", view().panelShown == false and view().sweeps == 0, view().sweeps)
    HARNESS.frame()
    check("P10 shown a frame later", view().panelShown == true and view().rowsDrawn == 1, view().rowsDrawn)
    check("P10 sweeping", view().sweeping == true)
    endCombat()
    check("P10 still drawn until the next frame", view().panelShown == true)
    HARNESS.frame()
    local idle = view()
    check("P10 hidden after combat", idle.panelShown == false and idle.sweeping == false)
    check("P10 rows released", idle.poolLive == 0 and idle.rowsDrawn == 0, idle.poolLive)
    check("P10 the pool was built at enable", idle.poolConstructed == ns.THREAT_ROW_CAPACITY, idle.poolConstructed)

    -- P1: status 1 on a mob party1 tanks is AboutToPull: orange on the plate and the row.
    local pull, pullPlate = beginFight(function()
        return mob({ name = "Defias Looter", targetId = "party1", threat = { player = 1 },
            threatPercent = { player = 92 } })
    end)
    local pullRow = rowFor(pull)
    check("P1 listed", pullRow ~= nil, rowTokens())
    check("P1 aggro AboutToPull", pullRow and pullRow.verdict == "AboutToPull", pullRow and pullRow.verdict)
    check("P1 the row is orange", near(ORANGE, rowColour(pull)) == true, colourText(rowColour(pull)))
    check("P1 the plate is orange", near(ORANGE, plateColour(pullPlate)) == true,
        colourText(plateColour(pullPlate)))
    check("P1 counted on the plates", (ns.Nameplates.Inspect().verdicts.AboutToPull or 0) == 1,
        ns.Nameplates.Inspect().verdicts.AboutToPull)
    local mark = #HARNESS.chat
    slash("plates")
    check("P1 /pa plates counts it", chatSince(mark):find("aboutToPull=1", 1, true) ~= nil, chatSince(mark))

    -- P2: on tapped mobs, orange and red both outrank grey.
    local tappedPull, tappedPullPlate, tappedOn, tappedOnPlate
    beginFight(function()
        tappedPull, tappedPullPlate = mob({ tapDenied = true, targetId = "party1",
            threat = { player = 1 }, threatPercent = { player = 95 } })
        tappedOn, tappedOnPlate = mob({ tapDenied = true, threat = { player = 2 },
            threatPercent = { player = 100 } })
    end)
    check("P2 tapped and about to pull: orange row", near(ORANGE, rowColour(tappedPull)) == true,
        colourText(rowColour(tappedPull)))
    check("P2 tapped and about to pull: orange plate", near(ORANGE, plateColour(tappedPullPlate)) == true,
        colourText(plateColour(tappedPullPlate)))
    check("P2 tapped and on you: red row", near(RED, rowColour(tappedOn)) == true,
        colourText(rowColour(tappedOn)))
    check("P2 tapped and on you: red plate", near(RED, plateColour(tappedOnPlate)) == true,
        colourText(plateColour(tappedOnPlate)))

    -- P3: only the mob on a group member's threat list is listed.
    local onParty2
    beginFight(function()
        mob({ targetId = "stranger" })
        mob({ dead = true, targetId = "player", threatPercent = { player = 100 } })
        mob({ canAttack = false, targetId = "party1" })
        mob({ inCombat = false })
        onParty2 = mob({ threat = { party2 = 0 } })
    end)
    check("P3 only the mob on party2's list", rowTokens() == onParty2, rowTokens())
    check("P3 not on your list", rowFor(onParty2) and rowFor(onParty2).threat == "not on your list")

    -- P4: readable threat, highest first, then the mob not on your list.
    local m100, m92, m40, mNone
    beginFight(function()
        m40 = mob({ targetId = "party1", threat = { player = 0 }, threatPercent = { player = 40 } })
        mNone = mob({ targetId = "party1" })
        m100 = mob({ targetId = "player", threatPercent = { player = 100 } })
        m92 = mob({ targetId = "party1", threat = { player = 1 }, threatPercent = { player = 92 } })
    end)
    check("P4 order", rowTokens() == table.concat({ m100, m92, m40, mNone }, ","), rowTokens())
    local cells = {}
    for index, row in ipairs(view().rows) do
        cells[index] = row.frame.threat.text
    end
    check("P4 threat cells", table.concat(cells, " ") == "100% 92% 40% " .. EM_DASH, table.concat(cells, " "))

    -- P5: eight mobs, six drawn, two counted.
    beginFight(function()
        for index = 1, 8 do
            mob({ targetId = "player", threatPercent = { player = 100 - index } })
        end
    end)
    check("P5 six drawn", view().rowsDrawn == 6, view().rowsDrawn)
    check("P5 two truncated", view().rowsTruncated == 2 and counters().rowsTruncated == 2,
        tostring(view().rowsTruncated) .. " " .. tostring(counters().rowsTruncated))
    check("P5 rowsShownMax", counters().rowsShownMax == 6, counters().rowsShownMax)

    -- P6: health and maximum health are handed to the bar hidden.
    local hiddenBefore = counters().valuesPassedHidden or 0
    local firstRow = view().rows[1]
    local bar = firstRow and firstRow.frame.bar
    check("P6 range passed hidden", bar and bar.minValue == 0 and bar.maxValue == HARNESS.SECRET,
        bar and tostring(bar.maxValue))
    check("P6 value passed hidden", bar and bar.value == HARNESS.SECRET, bar and tostring(bar.value))
    settle(1)
    check("P6 counted", (counters().valuesPassedHidden or 0) >= hiddenBefore + 12,
        tostring(counters().valuesPassedHidden) .. " from " .. tostring(hiddenBefore))
    check("P6 no failures", (counters().passFailures or 0) == 0, counters().passFailures)

    -- P8: the target's row alone is marked, by plate identity, never by UnitIsUnit.
    local t1, t2, t3 = beginFight(function()
        return mob({ targetId = "player", threatPercent = { player = 100 } }),
            mob({ targetId = "party1", threat = { player = 0 }, threatPercent = { player = 80 } }),
            mob({ targetId = "party1", threat = { player = 0 }, threatPercent = { player = 60 } })
    end)
    HARNESS.selectedTarget = t2
    settle(1)
    local marks = {}
    for index, row in ipairs(view().rows) do
        marks[index] = (row.isTarget and "T" or "-") .. (row.frame.marker.shown and "M" or "-")
    end
    check("P8 the second row alone is marked", table.concat(marks, " ") == "-- TM --", table.concat(marks, " "))
    check("P8 counted", (counters().targetMarked or 0) >= 1, counters().targetMarked)
    slash("off nameplates")
    HARNESS.unitIsUnitCalls = 0
    settle(3, true)
    check("P8 the panel never calls UnitIsUnit", HARNESS.unitIsUnitCalls == 0, HARNESS.unitIsUnitCalls)
    slash("on nameplates")
    HARNESS.selectedTarget = nil
    settle(1)
    check("P8 no mark without a target", rowFor(t2) and rowFor(t2).isTarget == false
        and rowFor(t2).frame.marker.shown == false)
    check("P8 the other rows", rowFor(t1) ~= nil and rowFor(t3) ~= nil)

    -- P9: level and elite tags.
    local elite, rareElite, boss, plain = beginFight(function()
        return mob({ targetId = "player", threatPercent = { player = 100 }, level = 62, classification = "elite" }),
            mob({ targetId = "party1", threat = { player = 0 }, threatPercent = { player = 90 },
                level = 61, classification = "rareelite" }),
            mob({ targetId = "party1", threat = { player = 0 }, threatPercent = { player = 80 },
                level = -1, classification = "worldboss" }),
            mob({ targetId = "party1", threat = { player = 0 }, threatPercent = { player = 70 }, level = 60 })
    end)
    local tags = {}
    for _, token in ipairs({ elite, rareElite, boss, plain }) do
        local row = rowFor(token)
        tags[#tags + 1] = row and row.frame.tag.text or "?"
    end
    check("P9 tags", table.concat(tags, " ") == "62+ 61r+ ?? 60", table.concat(tags, " "))
    slash("set threatPanel showLevel false")
    settle(1)
    check("P9 tag off", rowFor(elite).frame.tag.text == "", rowFor(elite).frame.tag.text)
    slash("set threatPanel showLevel true")

    -- P10, continued: enabled during a fight with three mobs on screen, it lists all
    -- three at once.
    endCombat()
    HARNESS.frame()
    slash("off threatPanel")
    clearMobs()
    for index = 1, 3 do
        mob({ targetId = "player", threatPercent = { player = 100 - index } })
    end
    startCombat()
    HARNESS.frame()
    slash("on threatPanel")
    check("P10 enabled in combat: shown at once", view().panelShown == true and view().rowsDrawn == 3,
        view().rowsDrawn)

    -- P11: the breakdown hides for the fight and draws it after.
    endCombat()
    HARNESS.frame()
    check("P11 breakdown shown out of combat", ns.DamageBreakdown.Inspect().panelShown == true)
    startCombat()
    check("P11 breakdown hidden in combat", ns.DamageBreakdown.Inspect().panelShown == false)
    endCombat()
    check("P11 breakdown draws the fight", ns.DamageBreakdown.Inspect().panelShown == true)
    slash("set damageBreakdown hideInCombat false")
    startCombat()
    check("P11 with hideInCombat off it stays", ns.DamageBreakdown.Inspect().panelShown == true)
    endCombat()
    slash("set damageBreakdown hideInCombat true")
    HARNESS.frame()

    -- P13: a colour changed while nameplates are off still reaches the panel.
    local grouped = beginFight(function()
        return mob({ targetId = "party1", threat = { player = 0 }, threatPercent = { player = 50 } })
    end)
    slash("off nameplates")
    check("P13 green before", near(GREEN, rowColour(grouped)) == true, colourText(rowColour(grouped)))
    slash("set nameplates colourOnGroup 00ff00")
    settle(1, true)
    check("P13 the new green", near(NEW_GREEN, rowColour(grouped)) == true, colourText(rowColour(grouped)))
    slash("set nameplates colourOnGroup 40ff40")
    slash("on nameplates")

    -- P18: a plate whose frame has no unitToken is skipped and counted.
    local tokenless, listed = beginFight(function()
        return mob({ targetId = "player", threatPercent = { player = 100 } }),
            mob({ targetId = "player", threatPercent = { player = 90 } })
    end)
    HARNESS.plates[tokenless].unitToken = nil
    settle(1)
    check("P18 skipped", rowFor(tokenless) == nil and rowFor(listed) ~= nil, rowTokens())
    check("P18 counted", (counters().platesWithoutToken or 0) >= 1, counters().platesWithoutToken)

    -- /pa threat in a fight prints the state, each row and the counters.
    mark = #HARNESS.chat
    slash("threat")
    local printed = chatSince(mark)
    check("/pa threat state", printed:find("rows=1/6", 1, true) ~= nil and printed:find("timer=running", 1, true) ~= nil,
        printed)
    check("/pa threat row", printed:find(listed .. " OnPlayer 90%", 1, true) ~= nil, printed)
    check("/pa threat counters", printed:find("platesWithoutToken=", 1, true) ~= nil, printed)

    -- P17: a reused row shows nothing of the last mob when the reads come back empty.
    local named = beginFight(function()
        return mob({ name = "Kobold Miner", targetId = "player", threatPercent = { player = 100 } })
    end)
    local reused = view().rows[1].frame
    check("P17 the first mob drawn", reused.name.text == "Kobold Miner" and reused.bar.value == HARNESS.SECRET
        and reused.threat.text == "100%", tostring(reused.name.text))
    HARNESS.units[named].dead = true
    local empty = mob({ targetId = "party1", healthAbsent = true, percentText = "n/a" })
    settle(1)
    local row = view().rows[1]
    check("P17 the second mob listed", row and row.token == empty and row.threat == "hidden", rowTokens())
    check("P17 the same frame", row and row.frame == reused)
    check("P17 name blank", reused.name.text == "", tostring(reused.name.text))
    check("P17 bar at 0 of 1", reused.bar.value == 0 and reused.bar.minValue == 0 and reused.bar.maxValue == 1,
        tostring(reused.bar.value) .. "/" .. tostring(reused.bar.maxValue))
    check("P17 threat blank", reused.threat.text == "", tostring(reused.threat.text))
    check("P17 the failed hand-over counted", (counters().passFailures or 0) >= 1, counters().passFailures)
    endCombat()
    HARNESS.frame()

    -- P14: nothing was created in a fight.
    check("P14 no frame created in combat", HARNESS.framesCreatedInCombat == 0, HARNESS.framesCreatedInCombat)
    check("no sweep raised", (counters().sweepFaults or 0) == 0, counters().sweepFaults)
    check("still enabled", ns.Registry.State("threatPanel") == "ENABLED", ns.Registry.State("threatPanel"))
end

if HARNESS_SESSION == "phase11-hidden" then
    -- P7: hidden threat % and names pass through; hidden rows follow the readable one
    -- and keep their order when the plate order changes.
    local hiddenA, hiddenB, readable
    beginFight(function()
        hiddenA = mob({ name = "Hidden A", targetId = "party1", threat = { player = 0 },
            threatPercent = { player = 70 }, percentSecret = true })
        readable = mob({ name = "Readable", targetId = "party1", threat = { player = 0 },
            threatPercent = { player = 50 } })
        hiddenB = mob({ name = "Hidden B", targetId = "party1", threat = { player = 0 },
            threatPercent = { player = 60 }, percentSecret = true })
    end)
    local expected = table.concat({ readable, hiddenA, hiddenB }, ",")
    check("P7 readable first, then hidden", rowTokens() == expected, rowTokens())
    local order = HARNESS.plateOrder
    order[1], order[3] = order[3], order[1]
    settle(2)
    check("P7 stable when the plates reorder", rowTokens() == expected, rowTokens())
    local hiddenRow, readableRow = rowFor(hiddenA), rowFor(readable)
    check("P7 hidden threat passed through", hiddenRow and hiddenRow.frame.threat.text == HARNESS.SECRET
        and hiddenRow.threat == "hidden")
    check("P7 readable threat formatted", readableRow and readableRow.frame.threat.text == "50%")
    check("P7 hidden names passed through", hiddenRow and hiddenRow.frame.name.text == HARNESS.SECRET
        and readableRow.frame.name.text == HARNESS.SECRET)
    check("P7 counted", (counters().percentReadsWithheld or 0) >= 2 and (counters().percentReadsPlain or 0) >= 1,
        counters().percentReadsWithheld)
    check("P7 no failures", (counters().passFailures or 0) == 0, counters().passFailures)
    endCombat()
    HARNESS.frame()
    check("P7 no sweep raised", (counters().sweepFaults or 0) == 0, counters().sweepFaults)
end

if HARNESS_SESSION == "phase11-noplates" then
    -- P12: enemy nameplates off: said once per UI load, counted per fight, never changed.
    local mark = #HARNESS.chat
    beginFight(function()
        return mob({ targetId = "player", threatPercent = { player = 100 } })
    end)
    beginFight(function()
        return mob({ targetId = "player", threatPercent = { player = 100 } })
    end)
    endCombat()
    HARNESS.frame()
    local said = chatSince(mark)
    check("P12 said once", count(said, "enemy nameplates are off") == 1, said)
    check("P12 counted per fight", counters().enemyPlatesOff == 2, counters().enemyPlatesOff)
    check("P12 the CVar untouched", HARNESS.cvarWrites == 0 and HARNESS.cvars.nameplateShowEnemies == "0")
end

-- Report -------------------------------------------------------------------------------
local errors = {}
for _, line in ipairs(HARNESS.chat) do
    if line:find("raised", 1, true) or line:find("faulted", 1, true) then
        errors[#errors + 1] = line
    end
end
HARNESS_RESULT = { passed = passed, failures = failures, errors = errors, chat = HARNESS.chat }
