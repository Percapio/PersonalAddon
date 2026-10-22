-- Phase 20 offline checks (Architecture/20261021-Phase20.md section 16.1).
-- Sessions: "phase20", and "phase20-nocostapi", which removes C_Spell.GetSpellPowerCost
-- before login and runs only the F checks. Check names follow the design's table:
-- F five-second rule, B breakdown, M merchant visit, R roles, A alignment, U identity.

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

local function count(text, needle)
    local found, from = 0, 1
    while true do
        local at = text:find(needle, from, true)
        if not at then
            return found
        end
        found = found + 1
        from = at + #needle
    end
end

-- Without advancing a frame, so "at once" means before any sweep, hook or timer.
local function setNow(feature, key, value)
    ns.ConfigStore.Set(feature, key, value)
    ns.Registry.NotifyConfigChanged(feature, key)
end

local function setSetting(feature, key, value)
    setNow(feature, key, value)
    HARNESS.frame()
end

-- This UI load's counters as they will be saved.
local function savedCounters(featureId)
    local sessions = PersonalAddonDiagnostics and PersonalAddonDiagnostics.sessions
    local record = sessions and sessions[#sessions]
    return record and record.counters and record.counters[featureId] or {}
end

-- Core/Diagnostics.lua's isValidCounters, applied to every saved record: a counter that
-- is not a number or a boolean discards the whole log on the next load.
local function diagnosticsValid()
    local log = PersonalAddonDiagnostics
    if type(log) ~= "table" or type(log.sessions) ~= "table" then
        return false, "no saved log"
    end
    for _, record in ipairs(log.sessions) do
        for featureId, counters in pairs(record.counters or {}) do
            if type(featureId) ~= "string" or type(counters) ~= "table" then
                return false, tostring(featureId)
            end
            for name, value in pairs(counters) do
                if type(name) ~= "string" or (type(value) ~= "number" and type(value) ~= "boolean") then
                    return false, format("%s.%s = %s", featureId, tostring(name), tostring(value))
                end
            end
        end
    end
    return true
end

local NOCOST = (HARNESS_SESSION == "phase20-nocostapi")

-- Before login ----------------------------------------------------------------------------

if NOCOST then
    C_Spell.GetSpellPowerCost = nil
end

-- Blizzard's update path, defined before login so the post-hooks install on it.
function CompactUnitFrame_SetUnit(_unitFrame, _token) end
function CompactUnitFrame_UpdateAll(_unitFrame) end
function CompactUnitFrame_UpdateHealth(_unitFrame) end
function CompactUnitFrame_UpdateHealthColor(_unitFrame) end

HARNESS.installNameOptions(NamePlateConstants.NAME_ANCHOR_STYLES.AboveHealthBar)

-- Counted, so R15 can prove an attach with both toggles off asks nothing.
HARNESS.unitIsPlayerCalls = 0
UnitIsPlayer = function(token)
    HARNESS.unitIsPlayerCalls = HARNESS.unitIsPlayerCalls + 1
    local unit = HARNESS.resolve(token)
    if unit and unit.isPlayerSecret then
        return HARNESS.SECRET
    end
    return unit ~= nil and unit.isPlayer == true
end
GetGuildInfo = function(token)
    local unit = HARNESS.resolve(token)
    if not unit or unit.guild == nil then
        return nil
    end
    return unit.guild, "Rank", 1
end

HARNESS.fire("ADDON_LOADED", "PersonalAddon")
HARNESS.fire("PLAYER_LOGIN")
HARNESS.frame()
HARNESS.fire("PLAYER_ENTERING_WORLD")
HARNESS.frame()

-- F: the five-second rule (section 2) ------------------------------------------------------

local IN_FSR, REGENERATING = ns.TRACKER_STATE.IN_FSR, ns.TRACKER_STATE.REGENERATING
local fsr = ns.FiveSecondRule

local function cast(spellId)
    HARNESS.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-" .. tostring(spellId), spellId)
    return fsr.Inspect()
end

local WAND, FIREBALL, RAGE_ONLY, ZERO_MANA = 5019, 133, 6, 7
local AURA_ABSENT, AURA_PRESENT, RAISES, SECRET_COSTS, SECRET_ENTRIES = 8, 9, 10, 11, 15
local AURA_ID_WITHHELD, HAS_AURA_WITHHELD, HAS_AURA_MISSING = 12, 13, 14

local function manaEntry(cost, aura, has)
    return { type = 0, cost = cost, costPerSec = 0, requiredAuraID = aura or 0, hasRequiredAura = has }
end
HARNESS.spellCosts[FIREBALL] = { manaEntry(50, 0, false) }
HARNESS.spellCosts[RAGE_ONLY] = { { type = 1, cost = 10, costPerSec = 0, requiredAuraID = 0 } }
HARNESS.spellCosts[ZERO_MANA] = { manaEntry(0, 0, false) }
HARNESS.spellCosts[AURA_ABSENT] = { manaEntry(30, 1234, false) }
HARNESS.spellCosts[AURA_PRESENT] = { manaEntry(30, 1234, true) }
HARNESS.spellCosts[RAISES] = "raise"
HARNESS.spellCosts[SECRET_COSTS] = HARNESS.SECRET
HARNESS.spellCosts[SECRET_ENTRIES] = HARNESS.SECRET_TABLE
HARNESS.spellCosts[AURA_ID_WITHHELD] = { manaEntry(30, HARNESS.SECRET, false) }
HARNESS.spellCosts[HAS_AURA_WITHHELD] = { manaEntry(30, 1234, HARNESS.SECRET) }
HARNESS.spellCosts[HAS_AURA_MISSING] = { manaEntry(30, 1234, nil) }

check("F0 the five-second rule is enabled", ns.Registry.State("fiveSecondRule") == "ENABLED",
    ns.Registry.State("fiveSecondRule"))

if NOCOST then
    -- F9: with no lookup at all, every cast restarts, as before Phase 20.
    local view = cast(WAND)
    check("F9 with no cost lookup a wand shot opens the window",
        view.state == IN_FSR and view.castsCostUnknown == 1, view.state)
    check("F9 and the client is recorded as unable to say",
        view.costQueryable == false and view.lastUnknownReason == "ApiMissing",
        tostring(view.costQueryable) .. "/" .. tostring(view.lastUnknownReason))
    local started = view.windowStartedAt
    HARNESS.advance(0.5)
    view = cast(FIREBALL)
    check("F9 every cast restarts it", view.windowStartedAt > started and view.castsCostUnknown == 2,
        view.windowStartedAt .. " vs " .. started)
    check("F9 no cast was called free or costing", view.castsFree == 0 and view.castsCostingMana == 0)
    local mark = chatMark()
    slash("fsr")
    check("F9 /pa fsr names the missing lookup",
        chatSince(mark):find("this client has no spell cost lookup", 1, true) ~= nil, chatSince(mark))
else
    -- F1: a wand shot with no window open.
    local view = fsr.Inspect()
    check("F1 no window before any cast", view.state == REGENERATING and view.visible == false)
    view = cast(WAND)
    check("F1 a wand shot draws no line", view.state == REGENERATING and view.visible == false
        and view.windowStartedAt == 0, view.state)
    check("F1 and is counted free", view.castsFree == 1 and view.castsCostUnknown == 0,
        view.castsFree .. "/" .. view.castsCostUnknown)

    -- F2: a 50-mana cast opens it.
    HARNESS.frame()
    view = cast(FIREBALL)
    check("F2 a mana cast opens the window", view.state == IN_FSR and view.visible == true
        and view.windowStartedAt == GetTime(), view.state)
    check("F2 counted as costing mana", view.castsCostingMana == 1)
    local started = view.windowStartedAt

    -- F3-F6: nothing free moves it.
    HARNESS.advance(0.5)
    view = cast(WAND)
    check("F3 a wand shot inside the window leaves it alone",
        view.windowStartedAt == started and view.state == IN_FSR and view.castsFree == 2,
        view.windowStartedAt .. " vs " .. started)
    view = cast(RAGE_ONLY)
    check("F4 a rage-only cost is free", view.windowStartedAt == started and view.castsFree == 3)
    view = cast(ZERO_MANA)
    check("F5 a mana entry at 0 is free", view.windowStartedAt == started and view.castsFree == 4)
    view = cast(AURA_ABSENT)
    check("F6 a mana cost whose required aura is absent is free",
        view.windowStartedAt == started and view.castsFree == 5)
    HARNESS.advance(0.5)
    view = cast(AURA_PRESENT)
    check("F6 present, it costs mana", view.windowStartedAt > started and view.castsCostingMana == 2,
        view.windowStartedAt .. " vs " .. started)

    -- F7, F8: could not tell restarts.
    HARNESS.advance(0.5)
    started = view.windowStartedAt
    view = cast(RAISES)
    check("F7 a raising lookup restarts the window",
        view.windowStartedAt > started and view.castsCostUnknown == 1, view.castsCostUnknown)
    check("F7 with its reason", view.lastUnknownReason == "CallFailed" and view.costQueryable == true,
        tostring(view.lastUnknownReason))
    HARNESS.advance(0.5)
    started = view.windowStartedAt
    view = cast(SECRET_COSTS)
    check("F8 a withheld cost table restarts it as Withheld",
        view.windowStartedAt > started and view.castsCostUnknown == 2 and view.lastUnknownReason == "Withheld",
        tostring(view.lastUnknownReason))
    HARNESS.advance(0.5)
    started = view.windowStartedAt
    view = cast(SECRET_ENTRIES)
    check("F8 a table whose contents are withheld is unreadable, and restarts",
        view.windowStartedAt > started and view.castsCostUnknown == 3
        and view.lastUnknownReason == "EntryUnreadable", tostring(view.lastUnknownReason))

    -- F11: no spell id at all.
    HARNESS.advance(0.5)
    started = view.windowStartedAt
    local withheldBefore = view.withheldSpellIds
    HARNESS.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-none", nil)
    view = fsr.Inspect()
    check("F11 a cast with no spell id restarts the window",
        view.windowStartedAt > started and view.withheldSpellIds == withheldBefore + 1,
        view.withheldSpellIds .. " vs " .. withheldBefore)
    check("F11 without reaching the cost lookup", view.castsCostUnknown == 3)

    -- F12: an aura field that does not read is "could not tell", never "free".
    local unknown = view.castsCostUnknown
    for _, spellId in ipairs({ AURA_ID_WITHHELD, HAS_AURA_WITHHELD, HAS_AURA_MISSING }) do
        HARNESS.advance(0.5)
        started = view.windowStartedAt
        view = cast(spellId)
        unknown = unknown + 1
        check("F12 spell " .. spellId .. " is EntryUnreadable and restarts",
            view.windowStartedAt > started and view.castsCostUnknown == unknown
            and view.lastUnknownReason == "EntryUnreadable",
            tostring(view.lastUnknownReason) .. " " .. view.castsCostUnknown)
    end

    -- F10: on disk.
    local saved = savedCounters("fiveSecondRule")
    check("F10 every counter is in the saved diagnostics",
        saved.castsFree == view.castsFree and saved.castsCostingMana == view.castsCostingMana
        and saved.castsCostUnknown == view.castsCostUnknown
        and saved.withheldSpellIds == view.withheldSpellIds,
        format("%s/%s/%s/%s", tostring(saved.castsFree), tostring(saved.castsCostingMana),
            tostring(saved.castsCostUnknown), tostring(saved.withheldSpellIds)))
    local mark = chatMark()
    slash("fsr")
    check("F9 (reverse) a client with the lookup is not reported as missing it",
        chatSince(mark):find("no spell cost lookup", 1, true) == nil and view.costQueryable == true,
        chatSince(mark))
end

if not NOCOST then

-- B: the damage breakdown (section 3) ------------------------------------------------------

local breakdown = ns.DamageBreakdown
local PANEL_PADDING, ROW_HEIGHT, ROW_SPACING = 6, 16, 2
local HEADER_HEIGHT = ns.BREAKDOWN_HEADER_HEIGHT
local DOT = "\194\183"
local panel = _G.PersonalAddonDamageBreakdown

check("B0 the breakdown is enabled", ns.Registry.State("damageBreakdown") == "ENABLED")

-- Rows in drawn order: the first is anchored to the panel, each next one to the row
-- above it. Pool order says nothing about screen order.
local function breakdownRows()
    local live = {}
    for _, frame in ipairs(HARNESS.createdFrames) do
        if frame.parent == panel and frame.shown and rawget(frame, "share") then
            live[#live + 1] = frame
        end
    end
    local ordered, anchor = {}, panel
    for _ = 1, #live do
        local nextRow = nil
        for _, row in ipairs(live) do
            local point = row.points[1]
            if point and point[2] == anchor then
                nextRow = row
                break
            end
        end
        if not nextRow then
            break
        end
        ordered[#ordered + 1] = nextRow
        anchor = nextRow
    end
    return ordered
end

local function sharesOf(rows)
    local shares = {}
    for index, row in ipairs(rows) do
        shares[index] = tonumber((row.share.text or ""):match("^(%d+)%%$"))
    end
    return shares
end

local function sumOf(list)
    local total = 0
    for _, value in ipairs(list) do
        total = total + (value or 0)
    end
    return total
end

local function joined(list)
    local parts = {}
    for index, value in ipairs(list) do
        parts[index] = tostring(value)
    end
    return table.concat(parts, ",")
end

local function headerRegion()
    for _, region in ipairs(panel.regions) do
        local point = region.points[1]
        if region.kind == "FontString" and point and point[1] == "TOPLEFT" and point[2] == panel
            and point[4] == PANEL_PADDING and point[5] == -PANEL_PADDING then
            return region
        end
    end
end

local function refresh()
    breakdown.Refresh()
    return breakdown.Inspect(), breakdownRows()
end

local function heightFor(rows)
    if rows == 0 then
        return PANEL_PADDING * 2 + ROW_HEIGHT
    end
    return PANEL_PADDING * 2 + HEADER_HEIGHT + ROW_SPACING + rows * ROW_HEIGHT + (rows - 1) * ROW_SPACING
end

-- B1: one total per spell.
local mergedBefore = breakdown.Inspect().mergedEntries
HARNESS.meterFight({ { 1, 300 }, { 1, 300 }, { 2, 400 } }, 10)
local view, rows = refresh()
check("B1 two entries of one spell are one row", #rows == 2 and joined(sharesOf(rows)) == "60,40",
    #rows .. " rows: " .. joined(sharesOf(rows)))
check("B1 and the merge is counted", view.lastMergedEntries == 1 and view.mergedEntries == mergedBefore + 1,
    view.lastMergedEntries .. "/" .. view.mergedEntries)

-- B2, B8, B10, B12: more spells than rows.
HARNESS.meterFight({ { 1, 600 }, { 2, 500 }, { 3, 400 }, { 4, 300 }, { 5, 200 }, { 6, 100 } }, 10)
view, rows = refresh()
local shares = sharesOf(rows)
check("B2 four spell rows and a '+2' row", #rows == 5 and rows[5].more.text == "+2"
    and rows[5].more.shown == true and rows[5].icon.shown == false,
    #rows .. " rows, last more=" .. tostring(rows[5] and rows[5].more.text))
check("B2 the drawn integers sum to 100", sumOf(shares) == 100 and view.percentsSum == 100,
    joined(shares))
check("B2 largest remainders: 29, 24, 19, 14, 14", joined(shares) == "29,24,19,14,14", joined(shares))
check("B8 rowsShown counts spell rows only", view.rowsShown == 4 and view.otherRowShown == true,
    view.rowsShown)
check("B10 the panel's height follows the row count",
    view.panelHeight == heightFor(5) and panel.height == heightFor(5),
    tostring(view.panelHeight) .. " vs " .. heightFor(5))
local firstPoint = rows[1] and rows[1].points[1] or {}
check("B12 row 1 sits a header and a gap below the top",
    firstPoint[1] == "TOPLEFT" and firstPoint[2] == panel and firstPoint[3] == "TOPLEFT"
    and firstPoint[4] == PANEL_PADDING
    and firstPoint[5] == -(PANEL_PADDING + HEADER_HEIGHT + ROW_SPACING),
    tostring(firstPoint[4]) .. "," .. tostring(firstPoint[5]))

-- B9: a pooled row is either kind.
setSetting("damageBreakdown", "maximumRows", 6)
rows = breakdownRows()
local allSpellRows = #rows == 6
for _, row in ipairs(rows) do
    if row.more.shown or row.more.text ~= "" or not row.icon.shown then
        allSpellRows = false
    end
end
check("B9 a pooled '+N' row reused as a spell row shows its icon and hides the count", allSpellRows,
    #rows .. " rows")
setSetting("damageBreakdown", "maximumRows", 2)
rows = breakdownRows()
check("B9 and a spell row reused as '+N' hides its icon and shows the count",
    #rows == 3 and rows[3].more.text == "+4" and rows[3].more.shown == true and rows[3].icon.shown == false
    and rows[1].more.shown == false and rows[1].icon.shown == true,
    #rows .. " rows, last more=" .. tostring(rows[3] and rows[3].more.text))
setSetting("damageBreakdown", "maximumRows", 4)

-- B3: three equal spells.
HARNESS.meterFight({ { 1, 100 }, { 2, 100 }, { 3, 100 } }, 10)
view, rows = refresh()
shares = sharesOf(rows)
local sorted = { shares[1], shares[2], shares[3] }
table.sort(sorted)
check("B3 three equal spells show 33, 33 and 34", joined(sorted) == "33,33,34" and sumOf(shares) == 100,
    joined(shares))

-- B4: the session's own total is not the denominator.
local mismatchBefore = breakdown.Inspect().totalMismatchReads
HARNESS.meterFight({ { 1, 600 }, { 2, 400 } }, 10, 1100)
view, rows = refresh()
check("B4 shares are of the spells' sum", joined(sharesOf(rows)) == "60,40"
    and view.sumOfSpells == 1000 and view.sourceTotal == 1100, joined(sharesOf(rows)))
check("B4 and the mismatch is counted", view.totalMismatchReads == mismatchBefore + 1,
    view.totalMismatchReads .. " vs " .. mismatchBefore)

-- B5, B6: the header.
HARNESS.meterFight({ { 1, 600 }, { 2, 400 } }, 10)
view, rows = refresh()
local header = headerRegion()
local wantedHeader = "10s " .. DOT .. " 100 dps"
check("B5 the header reads the fight's length and DPS", view.headerText == wantedHeader
    and header and header.text == wantedHeader and header.shown == true, tostring(view.headerText))
HARNESS.meterDuration = "secret"
view = refresh()
check("B6 an unreadable duration leaves DPS alone", view.headerText == "100 dps", tostring(view.headerText))
HARNESS.meterDuration = 10

-- B11: nothing to apportion.
HARNESS.meterEmpty = true
view, rows = refresh()
check("B11 no fight yet draws zero rows", view.rowsShown == 0 and #rows == 0 and view.percentsSum == 0
    and view.panelShown == false, view.rowsShown .. "/" .. view.percentsSum)
HARNESS.meterEmpty = false
HARNESS.meterOff = true
view, rows = refresh()
check("B11 the meter off draws zero rows", view.rowsShown == 0 and #rows == 0 and view.percentsSum == 0,
    view.rowsShown .. "/" .. view.percentsSum)
HARNESS.meterOff = false

-- B12: the empty panel's height, with the header hidden.
setSetting("damageBreakdown", "showWhenEmpty", true)
HARNESS.meterEmpty = true
view = refresh()
check("B12 an empty panel is two paddings and a row tall", view.panelHeight == heightFor(0)
    and panel.height == heightFor(0) and view.panelShown == true, tostring(view.panelHeight))
check("B12 with the header hidden", header and header.shown == false and view.headerText == nil)
HARNESS.meterEmpty = false
setSetting("damageBreakdown", "showWhenEmpty", false)

-- B7, B13: the preview, and closing it.
HARNESS.meterFight({ { 1, 600 }, { 2, 400 } }, 10)
refresh()
ns.Preview.SetEnabled(true)
ns.Preview.FocusFeature("damageBreakdown")
rows = breakdownRows()
check("B7 the preview draws a header", header and header.shown == true
    and header.text == "20s " .. DOT .. " 577 dps", header and tostring(header.text))
check("B7 and a '+N' row", #rows == 5 and rows[5].more.text == "+6" and sumOf(sharesOf(rows)) == 100,
    #rows .. " rows")
ns.Preview.SetEnabled(false)
view, rows = breakdown.Inspect(), breakdownRows()
check("B13 closing the preview out of combat redraws the last fight",
    view.panelShown == true and #rows == 2 and view.headerText == wantedHeader
    and header and header.text == wantedHeader, tostring(view.headerText) .. ", " .. #rows .. " rows")

-- M: the merchant visit (section 6) --------------------------------------------------------

local Toasts = ns.Toasts

local function shownChildren(parent)
    local list = {}
    for _, frame in ipairs(HARNESS.createdFrames) do
        if frame.parent == parent and frame.shown then
            list[#list + 1] = frame
        end
    end
    return list
end

local function toastFrames()
    return shownChildren(_G.PersonalAddonToasts)
end

local function labelOf(toast)
    return toast.label:GetText() or ""
end

local VISIT_LABEL = "Gained at a merchant"
local JUNK_LABELS = { ["Junk sold"] = true, ["Some junk sold"] = true, ["Junk sale not confirmed"] = true }

local function visitToasts()
    local list = {}
    for _, toast in ipairs(toastFrames()) do
        if labelOf(toast):sub(1, #VISIT_LABEL) == VISIT_LABEL then
            list[#list + 1] = toast
        end
    end
    return list
end

local function visitToast()
    return visitToasts()[1]
end

local function junkToast()
    for _, toast in ipairs(toastFrames()) do
        if JUNK_LABELS[labelOf(toast)] then
            return toast
        end
    end
end

local function counts()
    return Toasts.Inspect().counts
end

-- Sold and bought by hand are both just the balance moving.
local function arrive()
    HARNESS.merchantOpen = true
    HARNESS.fire("MERCHANT_SHOW")
    HARNESS.frame()
end

-- Long enough for at least one poll to see the merchant gone.
local function walkAway()
    HARNESS.merchantOpen = false
    HARNESS.advance(0.55)
end

local function settle()
    HARNESS.advance(1.05)
end

local function clearToasts()
    HARNESS.advance(12)
end

local function pollTimers()
    local live = 0
    for _, timer in ipairs(HARNESS.timers) do
        if not timer.cancelled and timer.interval == ns.MERCHANT_VISIT_POLL_SECONDS then
            live = live + 1
        end
    end
    return live
end

local function waitForToast(predicate, seconds)
    local waited = 0
    while waited <= seconds do
        for _, toast in ipairs(toastFrames()) do
            if predicate(toast) then
                return toast
            end
        end
        HARNESS.advance(0.25)
        waited = waited + 0.25
    end
    return nil
end

check("M0 toasts are enabled, with the merchant visit on by default",
    ns.Registry.State("toasts") == "ENABLED" and Toasts.Inspect().showMerchantGold == true)

-- M1, M12: a hand sale.
clearToasts()
HARNESS.junk = 0
local pollBaseline = pollTimers()
local before = counts()
arrive()
check("M1 a visit opens a frame after MERCHANT_SHOW", Toasts.Inspect().visitPhase == "Open",
    Toasts.Inspect().visitPhase)
HARNESS.money = HARNESS.money + 500
HARNESS.advance(1)
check("M1 nothing while still at the merchant", #visitToasts() == 0)
walkAway()
check("M1 the poll saw the merchant close, and the visit settles first",
    Toasts.Inspect().visitPhase == "Settling" and #visitToasts() == 0, Toasts.Inspect().visitPhase)
settle()
local toasts = visitToasts()
check("M1 one toast with the net gain", #toasts == 1 and toasts[1].text:GetText() == "+coins:500",
    #toasts .. " " .. tostring(toasts[1] and toasts[1].text:GetText()))
check("M1 counted", counts().merchantVisitToasts == before.merchantVisitToasts + 1
    and counts().merchantVisits == before.merchantVisits + 1)
check("M12 after a visit no ticker or timer of ours is pending",
    Toasts.Inspect().visitTimersPending == false and Toasts.Inspect().visitPhase == "Idle"
    and pollTimers() == pollBaseline, pollTimers() .. " vs " .. pollBaseline)

-- M2, M3: a junk sale inside a visit. Run twice, once with Toasts re-subscribed after
-- auto-sell, so at least one run has Toasts' deferred read AFTER the sale call in the
-- same frame -- the ordering section 6.4 has to be safe under.
local function heldJunkVisit(tag)
    clearToasts()
    HARNESS.junk = 2
    local phaseAtSale = nil
    local realSell = C_MerchantFrame.SellAllJunkItems
    C_MerchantFrame.SellAllJunkItems = function(...)
        phaseAtSale = Toasts.Inspect().visitPhase
        return realSell(...)
    end
    arrive()
    C_MerchantFrame.SellAllJunkItems = realSell
    check("M3 (" .. tag .. ") the sale and the visit's money read share a frame",
        phaseAtSale ~= nil and Toasts.Inspect().visitPhase == "Open", tostring(phaseAtSale))
    local heldBefore = counts().junkHeld
    HARNESS.completeSale()
    HARNESS.frame()
    check("M2 (" .. tag .. ") the junk sale is Held", ns.AutoSellJunk.Inspect().lastPosted == "Held"
        and counts().junkHeld == heldBefore + 1, tostring(ns.AutoSellJunk.Inspect().lastPosted))
    check("M2 (" .. tag .. ") nothing shows at the merchant", junkToast() == nil and #visitToasts() == 0)
    walkAway()
    settle()
    local shown = visitToasts()
    check("M2 (" .. tag .. ") one toast after leaving, carrying the junk",
        #shown == 1 and labelOf(shown[1]) == VISIT_LABEL .. " " .. DOT .. " 2 junk"
        and shown[1].text:GetText() == "+coins:500" and junkToast() == nil,
        #shown .. " " .. tostring(shown[1] and labelOf(shown[1])))
    check("M3 (" .. tag .. ") the visit took the pre-sale balance", Toasts.Inspect().lastVisitNet == 500,
        tostring(Toasts.Inspect().lastVisitNet))
    return phaseAtSale
end
local firstOrder = heldJunkVisit("as loaded")
slash("off toasts")
slash("on toasts")
local secondOrder = heldJunkVisit("re-subscribed")
check("M3 one run had the sale called before the visit opened",
    firstOrder == "Idle" or secondOrder == "Idle", tostring(firstOrder) .. "/" .. tostring(secondOrder))

-- M4: purchases only.
clearToasts()
HARNESS.junk = 0
before = counts()
arrive()
HARNESS.money = HARNESS.money - 300
walkAway()
settle()
check("M4 purchases only: no toast", #toastFrames() == 0, #toastFrames())
check("M4 and counted silent", counts().merchantVisitsSilent == before.merchantVisitsSilent + 1
    and Toasts.Inspect().lastVisitVerdict == "Silent", tostring(Toasts.Inspect().lastVisitVerdict))

-- M5: a confirmed junk sale outweighed by a purchase.
clearToasts()
HARNESS.junk = 2
arrive()
HARNESS.completeSale()
HARNESS.frame()
HARNESS.money = HARNESS.money - 800
walkAway()
settle()
check("M5 a confirmed sale outweighed by a purchase shows nothing",
    #toastFrames() == 0 and Toasts.Inspect().lastVisitVerdict == "Silent",
    #toastFrames() .. " " .. tostring(Toasts.Inspect().lastVisitVerdict))

-- M6: an unconfirmed sale, and no gain.
clearToasts()
HARNESS.junk = 2
arrive()
HARNESS.advance(ns.VEND_SETTLE_SECONDS + 0.2)
check("M6 the unconfirmed sale is held while the visit is open",
    ns.AutoSellJunk.Inspect().lastPosted == "Held" and junkToast() == nil,
    tostring(ns.AutoSellJunk.Inspect().lastPosted))
walkAway()
settle()
local toast = junkToast()
check("M6 the Phase 8 'not confirmed' toast shows at visit end",
    toast and labelOf(toast) == "Junk sale not confirmed" and toast.text:GetText() == "2 still in your bags"
    and #visitToasts() == 0 and Toasts.Inspect().lastVisitVerdict == "PostJunkOnly",
    toast and labelOf(toast))
HARNESS.junk = 0

-- M7: a withheld interaction read never ends a visit.
clearToasts()
arrive()
HARNESS.money = HARNESS.money + 100
HARNESS.interactionSecret = true
HARNESS.merchantOpen = false
HARNESS.advance(2)
check("M7 a withheld read keeps the visit open", Toasts.Inspect().visitPhase == "Open"
    and #visitToasts() == 0, Toasts.Inspect().visitPhase)
HARNESS.interactionSecret = false
walkAway()
settle()
toast = visitToast()
check("M7 and the answer, once it reads, ends it", toast and toast.text:GetText() == "+coins:100",
    toast and toast.text:GetText())

-- M8: the ten-minute cap.
clearToasts()
before = counts()
arrive()
HARNESS.money = HARNESS.money + 100
for _ = 1, 121 do
    HARNESS.frame(5)
end
check("M8 the cap settles a visit the client never ends",
    counts().visitPollCapped == before.visitPollCapped + 1
    and Toasts.Inspect().lastVisitVerdict == "PostVisit" and Toasts.Inspect().lastVisitNet == 100,
    counts().visitPollCapped .. " " .. tostring(Toasts.Inspect().lastVisitVerdict))
HARNESS.merchantOpen = false
HARNESS.advance(1)

-- M9: the setting off restores Phase 8's toast.
clearToasts()
slash("set toasts showMerchantGold false")
HARNESS.junk = 2
arrive()
check("M9 off: no visit opens", Toasts.Inspect().visitPhase == "Idle")
HARNESS.completeSale()
HARNESS.frame()
toast = junkToast()
check("M9 off: the junk toast shows at once", toast and labelOf(toast) == "Junk sold"
    and toast.text:GetText() == "2 for coins:500" and ns.AutoSellJunk.Inspect().lastPosted == "Shown",
    toast and toast.text:GetText())
HARNESS.merchantOpen = false
HARNESS.advance(2)
check("M9 off: and no visit toast after", #visitToasts() == 0)
slash("set toasts showMerchantGold true")

-- M9: switched off mid-visit, a held sale shows at once.
clearToasts()
HARNESS.junk = 2
arrive()
HARNESS.completeSale()
HARNESS.frame()
check("M9 a sale is held before the switch", Toasts.Inspect().visitHeldJunk == true)
slash("set toasts showMerchantGold false")
toast = junkToast()
check("M9 switching off mid-visit shows the held sale as the junk toast",
    toast and labelOf(toast) == "Junk sold" and Toasts.Inspect().visitPhase == "Idle", toast and labelOf(toast))
slash("set toasts showMerchantGold true")
HARNESS.merchantOpen = false
HARNESS.advance(2)

-- M10: Toasts disabled with a sale held.
clearToasts()
HARNESS.junk = 2
arrive()
HARNESS.completeSale()
HARNESS.frame()
local mark = chatMark()
slash("off toasts")
check("M10 Toasts disabled with a sale held puts the summary in chat",
    chatSince(mark):find("sold 2 junk item(s) for coins:500", 1, true) ~= nil, chatSince(mark))
slash("on toasts")
HARNESS.merchantOpen = false
HARNESS.advance(2)

-- M11: a new MERCHANT_SHOW while the last visit settles.
clearToasts()
HARNESS.junk = 0
arrive()
HARNESS.money = HARNESS.money + 200
walkAway()
check("M11 the first visit is settling", Toasts.Inspect().visitPhase == "Settling")
arrive()
toast = visitToast()
check("M11 the old visit is finalized first", toast and toast.text:GetText() == "+coins:200"
    and Toasts.Inspect().visitPhase == "Open", toast and toast.text:GetText())
walkAway()
settle()
check("M11 and the new one ends on its own", Toasts.Inspect().visitPhase == "Idle"
    and Toasts.Inspect().lastVisitVerdict == "Silent", tostring(Toasts.Inspect().lastVisitVerdict))
check("M12 no timer of ours outlives either visit", Toasts.Inspect().visitTimersPending == false
    and pollTimers() == pollBaseline, pollTimers() .. " vs " .. pollBaseline)

-- M13: a held sale whose toast is dropped.
clearToasts()
HARNESS.junk = 2
arrive()
HARNESS.completeSale()
HARNESS.frame()
walkAway()
for index = 1, 3 + ns.TOAST_QUEUE_CAPACITY do
    Toasts.Post({
        kind = Toasts.KIND.LOOTED_ITEM, itemId = 0, name = "Filler " .. index,
        icon = "Interface\\Icons\\INV_Misc_QuestionMark", quantity = 1, quality = 2, isQuestItem = false,
    })
end
mark = chatMark()
settle()
check("M13 a dropped visit toast writes its held sale to chat",
    Toasts.Inspect().lastVisitVerdict == "PostVisit"
    and chatSince(mark):find("sold 2 junk item(s) for coins:500", 1, true) ~= nil, chatSince(mark))
slash("off toasts")
slash("on toasts")

-- M14: money unreadable when the visit ends.
clearToasts()
HARNESS.junk = 2
before = counts()
arrive()
HARNESS.completeSale()
HARNESS.frame()
walkAway()
HARNESS.moneySecret = true
settle()
HARNESS.moneySecret = false
toast = junkToast()
check("M14 unreadable money is counted", counts().visitMoneyUnreadable == before.visitMoneyUnreadable + 1)
check("M14 and a held confirmed sale still shows as the junk toast",
    toast and labelOf(toast) == "Junk sold" and toast.text:GetText() == "2 for coins:500"
    and #visitToasts() == 0, toast and toast.text:GetText())

-- M16: four samples, three visible.
clearToasts()
local outcomes = Toasts.PostSamples()
check("M16 PostSamples returns Shown, Shown, Shown, Queued at maximumVisible 3",
    table.concat(outcomes, ", ") == "Shown, Shown, Shown, Queued", table.concat(outcomes, ", "))
clearToasts()
clearToasts()

-- M15: the test command during a visit.
HARNESS.junk = 2
arrive()
HARNESS.completeSale()
HARNESS.frame()
before = counts()
mark = chatMark()
slash("toasts test")
check("M15 /pa toasts test posts its junk sample past the hold",
    chatSince(mark):find("posted one of each toast: Shown, Shown, Shown, Queued", 1, true) ~= nil
    and counts().junkHeld == before.junkHeld, chatSince(mark))
walkAway()
settle()
toast = waitForToast(function(candidate) return candidate.text:GetText() == "+coins:500" end, 12)
check("M15 and the visit's held figures are unchanged",
    toast and labelOf(toast) == VISIT_LABEL .. " " .. DOT .. " 2 junk" and Toasts.Inspect().lastVisitNet == 500,
    toast and labelOf(toast))
clearToasts()

-- M17: a client that cannot say when you leave opens no visit.
local interactionRead = C_PlayerInteractionManager.IsInteractingWithNpcOfType
C_PlayerInteractionManager.IsInteractingWithNpcOfType = nil
HARNESS.junk = 0
mark = chatMark()
arrive()
check("M17 without the interaction read no visit opens",
    Toasts.Inspect().visitPhase == "Idle" and Toasts.Inspect().visitCapable == false,
    Toasts.Inspect().visitPhase)
check("M17 and it says so once", count(chatSince(mark), "cannot say when you leave a merchant") == 1,
    chatSince(mark))
C_PlayerInteractionManager.IsInteractingWithNpcOfType = interactionRead
HARNESS.merchantOpen = false
HARNESS.advance(1)

-- R: NPC roles (section 7) -----------------------------------------------------------------

local Bridge = ns.QuestieDBBridge

local function record(token)
    for _, plate in ipairs(ns.Nameplates.TrackedPlates()) do
        if plate.unitToken == token then
            return plate
        end
    end
end

local function labelText(token)
    local plate = record(token)
    return plate and plate.label and plate.label.text.text
end

local function plates()
    return ns.Nameplates.Inspect()
end

local INNKEEPER, WEAPONS, NO_ROLE, ROLE_RAISES, INJECTED = 3001, 3002, 3003, 3004, 3005
HARNESS.npcRoles[INNKEEPER] = "Innkeeper"
HARNESS.npcRoles[WEAPONS] = "Weapon Merchant"
HARNESS.npcRoles[INJECTED] = "|cffff0000x|r"
HARNESS.npcRoleRaises[ROLE_RAISES] = true

check("R0 roles are off by default", plates().npcRoles == false and plates().nameAlignLeft == false)
setSetting("nameplates", "npcRoles", true)

-- R1: a friendly NPC.
local innkeeper = HARNESS.addPlate20("nameplate1", { npcId = INNKEEPER, friend = true })
local plate = record("nameplate1")
check("R1 a friendly NPC with a role is labelled with it",
    plate and plate.label and plate.labelSource == "Role" and plate.label.text.text == "Innkeeper"
    and plate.label.shown == true, labelText("nameplate1"))
local point = plate and plate.label and plate.label.points[1]
check("R1 anchored TOP to the container's BOTTOM, where a guild name goes",
    point and point[1] == "TOP" and point[2] == innkeeper.UnitFrame.HealthBarsContainer
    and point[3] == "BOTTOM" and point[5] == -ns.GUILD_LABEL_GAP)

-- R2: a hostile NPC.
local skippedBefore = plates().roleSkippedNotFriendly
HARNESS.addPlate20("nameplate2", { npcId = WEAPONS, friend = false, canAttack = true })
check("R2 a hostile NPC with a role gets none", record("nameplate2").label == nil
    and plates().roleSkippedNotFriendly == skippedBefore + 1, plates().roleSkippedNotFriendly)

-- R3: a player beside it.
setSetting("nameplates", "guildNames", true)
HARNESS.addPlate20("nameplate3", { isPlayer = true, guild = "The Silver Hand", friend = true })
check("R3 a player keeps a guild label", record("nameplate3").labelSource == "Guild"
    and labelText("nameplate3") == "The Silver Hand", labelText("nameplate3"))
check("R3 while the NPC beside it shows its role", record("nameplate1").labelSource == "Role"
    and labelText("nameplate1") == "Innkeeper", labelText("nameplate1"))

-- R4, R5: each toggle releases its own kind only.
setSetting("nameplates", "npcRoles", false)
check("R4 roles off releases role labels", record("nameplate1").label == nil)
check("R4 and only those", labelText("nameplate3") == "The Silver Hand")
setSetting("nameplates", "npcRoles", true)
check("R4 roles on brings them back", labelText("nameplate1") == "Innkeeper")
setSetting("nameplates", "guildNames", false)
check("R5 guild names off releases guild labels", record("nameplate3").label == nil)
check("R5 and only those", labelText("nameplate1") == "Innkeeper")
setSetting("nameplates", "guildNames", true)
check("R5 guild names on brings them back", labelText("nameplate3") == "The Silver Hand")

-- R6: a guild update anywhere in view.
local roleLabel = record("nameplate1").label
HARNESS.fire("PLAYER_GUILD_UPDATE", "player")
HARNESS.frame()
check("R6 PLAYER_GUILD_UPDATE leaves role labels in place",
    record("nameplate1").label == roleLabel and labelText("nameplate1") == "Innkeeper",
    tostring(labelText("nameplate1")))

-- R7: a withheld GUID.
local withheldBefore = plates().roleReadsWithheld
HARNESS.addPlate20("nameplate4", { guid = HARNESS.SECRET, friend = true })
check("R7 a withheld GUID gives no label", record("nameplate4").label == nil
    and plates().roleReadsWithheld == withheldBefore + 1, plates().roleReadsWithheld)

-- R8: an injected role.
HARNESS.addPlate20("nameplate5", { npcId = INJECTED, friend = true })
check("R8 every pipe in a role is doubled", labelText("nameplate5") == "||cffff0000x||r",
    labelText("nameplate5"))

-- R9: the cache.
local calls = HARNESS.subNameCalls
local hits = Bridge.Inspect().hits
HARNESS.addPlate20("nameplate6", { npcId = INNKEEPER, spawn = 2, friend = true })
check("R9 a second plate of the same NPC is a cache hit",
    HARNESS.subNameCalls == calls and labelText("nameplate6") == "Innkeeper" and Bridge.Inspect().hits > hits,
    HARNESS.subNameCalls .. " vs " .. calls)
calls = HARNESS.subNameCalls
local noneBefore = plates().roleReadsNone
HARNESS.addPlate20("nameplate7", { npcId = NO_ROLE, friend = true })
HARNESS.addPlate20("nameplate8", { npcId = NO_ROLE, spawn = 2, friend = true })
check("R9 no role is an answer, and cached", HARNESS.subNameCalls == calls + 1
    and plates().roleReadsNone == noneBefore + 2 and record("nameplate7").label == nil,
    HARNESS.subNameCalls - calls)
calls = HARNESS.subNameCalls
local unavailableBefore = plates().roleBridgeUnavailable
HARNESS.addPlate20("nameplate9", { npcId = ROLE_RAISES, friend = true })
HARNESS.addPlate20("nameplate10", { npcId = ROLE_RAISES, spawn = 2, friend = true })
check("R9 a raising getter is not an answer, and is not cached", HARNESS.subNameCalls == calls + 2
    and plates().roleBridgeUnavailable == unavailableBefore + 2 and record("nameplate9").label == nil,
    HARNESS.subNameCalls - calls)

-- R12: the shared size.
setSetting("nameplates", "guildFontSize", 14)
local sized = record("nameplate1") and record("nameplate1").label
check("R12 guildFontSize resizes role labels", sized and sized.text.textHeight == 14 and sized.height == 16,
    sized and tostring(sized.text.textHeight))
setSetting("nameplates", "guildFontSize", ns.GUILD_FONT_DEFAULT)

-- R14: turning hostile while the plate is up.
HARNESS.units.nameplate1.canAttack = true
HARNESS.units.nameplate1.friend = false
HARNESS.fire("UNIT_FACTION", "nameplate1")
check("R14 a scope change to attackable releases the role", record("nameplate1").label == nil)
HARNESS.units.nameplate1.canAttack = false
HARNESS.units.nameplate1.friend = true
HARNESS.fire("UNIT_FACTION", "nameplate1")
check("R14 and turning friendly brings it back", labelText("nameplate1") == "Innkeeper")

-- R16: a withheld UnitIsPlayer, counted per toggle.
local view0 = plates()
HARNESS.addPlate20("nameplate11", { isPlayerSecret = true, npcId = INNKEEPER, spawn = 3, friend = true })
local view1 = plates()
check("R16 both on: a withheld UnitIsPlayer counts for both",
    view1.guildReadsWithheld == view0.guildReadsWithheld + 1
    and view1.roleReadsWithheld == view0.roleReadsWithheld + 1 and record("nameplate11").label == nil)
setSetting("nameplates", "guildNames", false)
view0 = plates()
HARNESS.addPlate20("nameplate12", { isPlayerSecret = true })
view1 = plates()
check("R16 roles only: it counts for roles only",
    view1.guildReadsWithheld == view0.guildReadsWithheld
    and view1.roleReadsWithheld == view0.roleReadsWithheld + 1)
setSetting("nameplates", "guildNames", true)
view0 = plates()
HARNESS.addPlate20("nameplate13", { npcId = INNKEEPER, spawn = 4, friend = true })
view1 = plates()
check("R16 an NPC under guild names counts as no guild",
    view1.guildReadsNoGuild == view0.guildReadsNoGuild + 1 and labelText("nameplate13") == "Innkeeper")

-- R15: both off reads nothing.
setSetting("nameplates", "guildNames", false)
setSetting("nameplates", "npcRoles", false)
local asked = { HARNESS.unitIsPlayerCalls, HARNESS.unitIsFriendCalls, HARNESS.subNameCalls }
HARNESS.addPlate20("nameplate14", { npcId = WEAPONS, friend = true })
check("R15 with both toggles off, an attach reads nothing",
    HARNESS.unitIsPlayerCalls == asked[1] and HARNESS.unitIsFriendCalls == asked[2]
    and HARNESS.subNameCalls == asked[3] and record("nameplate14").label == nil,
    format("%d/%d/%d", HARNESS.unitIsPlayerCalls - asked[1], HARNESS.unitIsFriendCalls - asked[2],
        HARNESS.subNameCalls - asked[3]))
setSetting("nameplates", "guildNames", true)
setSetting("nameplates", "npcRoles", true)

-- R13, R17: one pool of 64.
local view = plates()
check("R17 guildPoolCapacity still reads, as 64", view.guildPoolCapacity == 64
    and view.labelPoolCapacity == 64, tostring(view.guildPoolCapacity))
mark = chatMark()
slash("plates")
check("R17 /pa plates prints with guild names on",
    chatSince(mark):find("labels %d+ of 64 pooled") ~= nil
    and chatSince(mark):find("roles: on", 1, true) ~= nil, chatSince(mark))
local live = view.guildLabels + view.roleLabels
local exhaustedBefore = view.guildPoolExhausted
local extra = {}
for index = 1, 64 - live + 1 do
    local token = "poolplate" .. index
    HARNESS.addPlate20(token, { npcId = INNKEEPER, spawn = 100 + index, friend = true })
    extra[#extra + 1] = token
end
view = plates()
check("R13 the pool cap is 64", view.guildLabels + view.roleLabels == 64
    and view.guildPoolExhausted == exhaustedBefore + 1,
    (view.guildLabels + view.roleLabels) .. " labels, exhausted " .. view.guildPoolExhausted)
for _, token in ipairs(extra) do
    HARNESS.removePlate(token)
end
view = plates()
check("R13 and removing the plates returns their labels", view.guildLabels + view.roleLabels == live)

-- R10: QuestieDB missing.
HARNESS.questiePresent = false
HARNESS.buildQuestie()
Bridge.Reset()
local unavailable = plates().roleBridgeUnavailable
HARNESS.addPlate20("nameplate15", { npcId = INNKEEPER, spawn = 9, friend = true })
check("R10 QuestieDB missing: no label", record("nameplate15").label == nil
    and plates().roleBridgeUnavailable == unavailable + 1)
mark = chatMark()
slash("plates")
check("R10 and /pa plates says why", chatSince(mark):find("ProviderMissing", 1, true) ~= nil, chatSince(mark))
HARNESS.questiePresent = true
HARNESS.buildQuestie()
Bridge.Reset()
HARNESS.removePlate("nameplate15")

-- A: names at the left end of the bar (section 8) ------------------------------------------

local STYLES = NamePlateConstants.NAME_ANCHOR_STYLES

local function eligiblePlates()
    local list = {}
    for _, tracked in ipairs(ns.Nameplates.TrackedPlates()) do
        if tracked.nameRegion and not tracked.unitFrame.showOnlyName then
            list[#list + 1] = tracked
        end
    end
    return list
end

local function allRead(list, wanted)
    for _, tracked in ipairs(list) do
        if tracked.nameRegion.justifyH ~= wanted then
            return false, tracked.unitToken .. "=" .. tostring(tracked.nameRegion.justifyH)
        end
    end
    return true
end

local function skipCounts()
    local current = plates()
    return format("%d/%d/%d/%d/%d/%d", current.nameAlignSkippedStyle, current.nameAlignSkippedNameOnly,
        current.nameAlignSkippedNoRegion, current.nameAlignWrites, current.nameAlignUnchanged,
        current.nameAlignWriteFailed)
end

check("A0 off: no name was written", HARNESS.justifyWrites == 0, HARNESS.justifyWrites)
check("A0 and the probe has not run", plates().nameAlignCapability == "NotYetProbed")

-- A13, A14: on, at once.
local eligible = eligiblePlates()
setNow("nameplates", "nameAlignLeft", true)
local saved = savedCounters("nameplates")
local ok, which = allRead(eligible, "LEFT")
check("A13 turning the setting on aligns every tracked plate at once", ok and #eligible > 0, which)
check("A14 the first eligible plate is probed before any reassert",
    saved.nameAlignCapabilityVerified == 1 and plates().nameAlignCapability == "Verified"
    and (saved.nameAlignUnchanged or 0) == 0 and saved.nameAlignWrites == #eligible,
    format("verified=%s writes=%s of %d", tostring(saved.nameAlignCapabilityVerified),
        tostring(saved.nameAlignWrites), #eligible))

-- A12, A1: a plate attached after.
local enemy = HARNESS.addPlate20("nameplate20", { npcId = 3010, canAttack = true })
check("A12 a plate attached after the setting is on is aligned by the attach alone",
    enemy.UnitFrame.name.justifyH == "LEFT", enemy.UnitFrame.name.justifyH)
HARNESS.frame()
check("A1 on, AboveHealthBar: an attached plate reads LEFT", enemy.UnitFrame.name:GetJustifyH() == "LEFT")

-- A2: Blizzard's layout pass, and our post-hook.
HARNESS.layoutPass("nameplate20")
check("A2 after a layout pass, LEFT again before the call returns", enemy.UnitFrame.name.justifyH == "LEFT")

-- A3, A15: the Style.
NamePlateSetupOptions.unitNameAnchorStyle = STYLES.InsideHealthBar
local writes = HARNESS.justifyWrites
local styleSkips = plates().nameAlignSkippedStyle
HARNESS.layoutPass("nameplate20")
check("A3 InsideHealthBar is skipped with no write", enemy.UnitFrame.name.justifyH == "CENTER"
    and HARNESS.justifyWrites == writes and plates().nameAlignSkippedStyle > styleSkips,
    enemy.UnitFrame.name.justifyH)
HARNESS.advance(0.3)
check("A3 nor from the sweep", HARNESS.justifyWrites == writes)
NamePlateSetupOptions.unitNameAnchorStyle = HARNESS.SECRET
styleSkips = plates().nameAlignSkippedStyle
HARNESS.advance(0.3)
check("A15 an unreadable Style lands on the Style counter", plates().nameAlignSkippedStyle > styleSkips
    and HARNESS.justifyWrites == writes)
NamePlateSetupOptions.unitNameAnchorStyle = STYLES.AboveHealthBar
HARNESS.advance(0.3)
check("A3 back on AboveHealthBar the sweep aligns it again", enemy.UnitFrame.name.justifyH == "LEFT")

-- A4: a name-only plate.
local nameOnlySkips = plates().nameAlignSkippedNameOnly
local nameOnly = HARNESS.addPlate20("nameplate21", { npcId = 3011, friend = true, showOnlyName = true })
HARNESS.advance(0.3)
check("A4 a name-only plate is untouched", nameOnly.UnitFrame.name.justifyH == "CENTER"
    and #nameOnly.UnitFrame.name.writes == 0 and plates().nameAlignSkippedNameOnly > nameOnlySkips)

-- A5: the loop is outside the colour sweep's scope filter.
local friendly = record("nameplate1")
check("A5 the innkeeper is out of the colour sweep's scope", friendly.scope == "OutOfScope")
friendly.nameRegion.justifyH = "CENTER"
HARNESS.advance(0.3)
check("A5 a SCOPE.OUT friendly plate is aligned by the sweep", friendly.nameRegion.justifyH == "LEFT")

-- A10: the unchanged path.
HARNESS.advance(0.3)
writes = HARNESS.justifyWrites
local unchanged = plates().nameAlignUnchanged
HARNESS.advance(0.5)
check("A10 the unchanged path writes nothing", HARNESS.justifyWrites == writes
    and plates().nameAlignUnchanged > unchanged, HARNESS.justifyWrites - writes)

-- A11: a plate that turns out name-only after its attach.
local healing = HARNESS.addPlate20("nameplate22", { npcId = 3012, friend = true })
local healingRecord = record("nameplate22")
check("A11 judged eligible while showOnlyName was provisional", healingRecord.nameAligned == true
    and healing.UnitFrame.name.justifyH == "LEFT")
healing.UnitFrame.showOnlyName = true
healing.UnitFrame.name.justifyH = "CENTER"
nameOnlySkips = plates().nameAlignSkippedNameOnly
local healingWrites = #healing.UnitFrame.name.writes
HARNESS.advance(0.3)
check("A11 the next sweep heals it: mark cleared, counted, nothing written",
    healingRecord.nameAligned == false and plates().nameAlignSkippedNameOnly > nameOnlySkips
    and #healing.UnitFrame.name.writes == healingWrites and healing.UnitFrame.name.justifyH == "CENTER")

-- A15: no name region.
local noRegionSkips = plates().nameAlignSkippedNoRegion
HARNESS.addPlate20("nameplate23", { npcId = 3013, friend = true, noName = true })
check("A15 a plate with no name lands on the no-region counter",
    plates().nameAlignSkippedNoRegion == noRegionSkips + 1)

-- A6, A9, A15: off, and back on.
eligible = eligiblePlates()
setNow("nameplates", "nameAlignLeft", false)
ok, which = allRead(eligible, "CENTER")
check("A6 off restores CENTER from the option table", ok and plates().nameAlignedNow == 0, which)
local skipsOff = skipCounts()
HARNESS.advance(0.5)
check("A15 off is counted nowhere", skipCounts() == skipsOff, skipsOff .. " -> " .. skipCounts())
setNow("nameplates", "nameAlignLeft", true)
HARNESS.advance(0.3)
check("A9 the probe runs once per UI load", savedCounters("nameplates").nameAlignCapabilityVerified == 1
    and plates().nameAlignCapability == "Verified")

-- A16: the verdict on disk.
saved = savedCounters("nameplates")
local valid, why = diagnosticsValid()
check("A16 the probe's verdict is a NUMBER counter", type(saved.nameAlignCapabilityVerified) == "number"
    and saved.nameAlignCapability == nil, tostring(saved.nameAlignCapability))
check("A16 and the saved diagnostics still validate", valid, why)

-- A7: the read refused. A disable lets the probe run again (section 20, correction 3).
ns.Registry.SetEnabled("nameplates", false)
HARNESS.justifyRefuse = "read"
HARNESS.justifyWrites = 0
mark = chatMark()
ns.Registry.SetEnabled("nameplates", true)
HARNESS.advance(0.5)
check("A7 an unreadable alignment is Unverifiable", plates().nameAlignCapability == "Unverifiable",
    plates().nameAlignCapability)
check("A7 with zero writes and one log line", HARNESS.justifyWrites == 0
    and count(chatSince(mark), "will not show a nameplate name's alignment") == 1,
    HARNESS.justifyWrites .. " writes")
check("A7 counted under its own name", savedCounters("nameplates").nameAlignCapabilityUnverifiable == 1)

-- A8: the write refused.
ns.Registry.SetEnabled("nameplates", false)
HARNESS.justifyRefuse = "write"
HARNESS.justifyWrites = 0
for _, tracked in ipairs(HARNESS.plateOrder) do
    local frame = HARNESS.plates[tracked]
    if frame and frame.UnitFrame.name then
        frame.UnitFrame.name.writes = {}
    end
end
mark = chatMark()
ns.Registry.SetEnabled("nameplates", true)
local probed = nil
for _, tracked in ipairs(HARNESS.plateOrder) do
    local frame = HARNESS.plates[tracked]
    local region = frame and frame.UnitFrame.name
    if region and #region.writes > 0 then
        probed = region
    end
end
check("A8 a write that does not stick is Refused", plates().nameAlignCapability == "Refused",
    plates().nameAlignCapability)
check("A8 the original is written back", probed and joined(probed.writes) == "LEFT,CENTER"
    and HARNESS.justifyWrites == 2, probed and joined(probed.writes))
check("A8 with one log line", count(chatSince(mark), "did not keep a nameplate name's alignment") == 1)
local skipsDown = skipCounts()
HARNESS.advance(1)
HARNESS.layoutPass("nameplate20")
check("A8 and no further writes", HARNESS.justifyWrites == 2, HARNESS.justifyWrites)
check("A15 a capability that is down is counted nowhere", skipCounts() == skipsDown,
    skipsDown .. " -> " .. skipCounts())
HARNESS.justifyRefuse = nil

-- R11, last: nothing ever asked QuestieDB's faction test.
check("R11 the role path never calls friendlyToFaction", HARNESS.friendlyToFactionCalls == 0,
    HARNESS.friendlyToFactionCalls)

-- U: Core/UnitIdentity.lua (section 9) -----------------------------------------------------

local UnitIdentity = ns.UnitIdentity
local READING = UnitIdentity.READING

local function identityOf(guid)
    HARNESS.guids.identityProbe = guid
    local reading, detail = UnitIdentity.NpcIdFor("identityProbe")
    HARNESS.guids.identityProbe = nil
    return reading, detail
end

local reading, detail = identityOf("Creature-0-1-2-3-4567-0000AB")
check("U1 a Creature GUID resolves", reading == READING.RESOLVED and detail == 4567, tostring(detail))
reading, detail = identityOf("Vehicle-0-1-2-3-890-000001")
check("U1 a Vehicle GUID resolves", reading == READING.RESOLVED and detail == 890, tostring(detail))
reading, detail = identityOf("Player-1-00000001")
check("U2 a player is not an NPC, and says so", reading == READING.NOT_AN_NPC and detail == true)
reading, detail = identityOf("Pet-0-1-2-3-1234-0000000001")
check("U2 a pet is not an NPC, and is not a player", reading == READING.NOT_AN_NPC and detail == false)
reading = identityOf(HARNESS.SECRET)
check("U3 a hidden GUID is Withheld", reading == READING.WITHHELD, tostring(reading))
local touched = false
local trap = setmetatable({}, { __index = function() touched = true error("indexed") end })
reading = identityOf(trap)
check("U3 with no string operation on it", reading == READING.WITHHELD and touched == false, tostring(reading))
local realUnitGUID = UnitGUID
UnitGUID = function() return nil end
reading = UnitIdentity.NpcIdFor("nobody")
UnitGUID = realUnitGUID
check("U3 no GUID at all is Absent", reading == READING.ABSENT, tostring(reading))

end -- not NOCOST

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
