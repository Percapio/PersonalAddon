-- Phase 21 offline checks (Architecture/20261112-Phase21.md section 16.1).
-- Sessions: "phase21"; "phase21-hidden", where the first aura's expiry and every tap
-- read are hidden from login (K9, R10); and "phase21-noapi", where GetUnitAuras,
-- GetWeaponEnchantInfo, UnitUsesAmmo and SOUNDKIT are missing (K10, E7, S10, R19).
-- Check names follow the design's table: K buffs, E enchants, T tails, S supplies,
-- L low-supply toast, V visibility and anchor, P preview, R rare alerts, X toasts.

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

local function setNow(feature, key, value)
    ns.ConfigStore.Set(feature, key, value)
    ns.Registry.NotifyConfigChanged(feature, key)
end

local function setSetting(feature, key, value)
    setNow(feature, key, value)
    HARNESS.frame()
end

local HIDDEN = (HARNESS_SESSION == "phase21-hidden")
local NOAPI = (HARNESS_SESSION == "phase21-noapi")

local MIDDLE_DOT = "\194\183"
local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"
local SWORD, BOW, DAGGER = 1001, 1002, 1004
local SWORD_ICON, BOW_ICON = 135327, 135490
local AMMO_ITEM, AMMO_ICON = 3001, 132382
local SHARD = 6265
local MAIN_HAND, RANGED = 0, 2

-- Before login --------------------------------------------------------------------------------

HARNESS.items[AMMO_ITEM] = { classID = 6, subClassID = 2, icon = AMMO_ICON, quality = 1 }
HARNESS.playerClassFile = "MAGE"
HARNESS.installCVars({ nameplateShowEnemies = "1" })
if HIDDEN then
    HARNESS.aurasSecret = "expiration"
    HARNESS.secretStanding = true
end
if NOAPI then
    C_UnitAuras.GetUnitAuras = nil
    C_Item.GetWeaponEnchantInfo = nil
    UnitUsesAmmo = nil
    SOUNDKIT = nil
end

HARNESS.fire("ADDON_LOADED", "PersonalAddon")
HARNESS.fire("PLAYER_LOGIN")
HARNESS.frame()
HARNESS.fire("PLAYER_ENTERING_WORLD")
HARNESS.frame()

-- Helpers ---------------------------------------------------------------------------------------

local Upkeep = ns.Upkeep
local RareAlerts = ns.RareAlerts

local function view()
    return Upkeep.Inspect()
end

local function counter(name)
    return (view().counters or {})[name] or 0
end

local function rareCounter(name)
    return (RareAlerts.Inspect().counters or {})[name] or 0
end

local function cellFrames()
    return Upkeep.CellFrames()
end

local function texts()
    local list = {}
    for index, frame in ipairs(cellFrames()) do
        list[index] = tostring(frame.text.text)
    end
    return table.concat(list, ",")
end

local function panel()
    return _G.PersonalAddonUpkeep
end

local nextInstance = 5000
local function aura(spellId, remaining, duration, fields)
    nextInstance = nextInstance + 1
    local entry = {
        auraInstanceID = nextInstance, spellId = spellId, icon = 7000 + spellId,
        duration = duration or 300, expirationTime = HARNESS.now + remaining, timeMod = 1,
    }
    for key, value in pairs(fields or {}) do
        entry[key] = value
    end
    return entry
end

local function setAuras(list)
    HARNESS.playerAuras = list or {}
    HARNESS.fire("UNIT_AURA", "player", {})
    HARNESS.frame()
end

local function enchant(seconds, fields)
    local entry = {
        hasEnchant = true, enchantType = 2, timeLeft = seconds * 1000, charges = 0,
        enchantID = 900, enchantIconID = 0,
    }
    for key, value in pairs(fields or {}) do
        entry[key] = value
    end
    return entry
end

local function setEnchants(slot, list)
    HARNESS.weaponEnchants[slot] = list
    HARNESS.fire("WEAPON_ENCHANT_CHANGED")
    HARNESS.frame()
end

local function bagsChanged()
    HARNESS.fire("BAG_UPDATE_DELAYED")
    HARNESS.frame()
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

-- A clean Upkeep: no auras, enchants or supplies, the stub weapons back, every
-- setting at its default, and the feature switched off and on so nothing carries.
local function resetUpkeep()
    HARNESS.playerAuras = {}
    HARNESS.weaponEnchants = {}
    HARNESS.usesAmmo = false
    HARNESS.playerClassFile = "MAGE"
    HARNESS.itemCounts = {}
    HARNESS.itemCountSecret = false
    HARNESS.equipped[0] = nil
    HARNESS.equipped[16], HARNESS.equipped[18] = SWORD, BOW
    HARNESS.aurasSecret = HIDDEN and "expiration" or nil
    HARNESS.enchantsSecret, HARNESS.enchantRaiseSlot = nil, nil
    for key, value in pairs({
        warningSeconds = 30, shortBuffSeconds = 60, showWeaponEnchants = true, showSupplies = true,
        lowSupplyToast = true, expiredTailSeconds = 10, maximumIcons = 6, attachToPanels = true,
        scale = 1.0, anchorOffsetX = 0, anchorOffsetY = 0, ammoAmberBelow = 200, ammoRedBelow = 50,
        shardAmberBelow = 3, shardRedBelow = 1,
    }) do
        ns.ConfigStore.Set("upkeep", key, value)
    end
    slash("off upkeep")
    slash("on upkeep")
    HARNESS.frame()
end

local function visibleToasts(kind)
    local found = {}
    local container = _G.PersonalAddonToasts
    for _, frame in ipairs(HARNESS.frames) do
        if frame.parent == container and frame.shown and frame.request
            and (kind == nil or frame.request.kind == kind) then
            found[#found + 1] = frame
        end
    end
    return found
end

local function clearToasts()
    HARNESS.advance(12)
end

local function posted()
    return ns.Toasts.Inspect().counts.posted or 0
end

local rareTokens = {}
local nextPlate = 0
local function rarePlate(fields)
    nextPlate = nextPlate + 1
    local token = "nameplate" .. tostring(900 + nextPlate)
    HARNESS.addRarePlate(token, fields)
    rareTokens[#rareTokens + 1] = token
    return token
end

local function removeRarePlates()
    for _, token in ipairs(rareTokens) do
        if HARNESS.plates[token] then
            HARNESS.removePlate(token)
        end
    end
    rareTokens = {}
end

check("upkeep enabled at login", view().enabled == true, view().visibility)
check("rare alerts enabled at login", RareAlerts.Inspect().enabled == true)

-- The hidden session (K9, R10) --------------------------------------------------------------------

if HIDDEN then
    resetUpkeep()
    local before = counter("auraReadsWithheld")
    HARNESS.usesAmmo = true
    HARNESS.equipped[0] = AMMO_ITEM
    HARNESS.itemCounts[AMMO_ITEM] = 300
    HARNESS.weaponEnchants[MAIN_HAND] = { enchant(20) }
    setAuras({ aura(101, 25, 300), aura(102, 20, 300) })
    local current = view()
    check("K9 one secret expirationTime hides the whole buff read", current.buffsKnown == false
        and current.buffRead == "Hidden", tostring(current.buffRead))
    check("K9 no buff cell", #current.cells == 1 and current.cells[1].source == "Enchant",
        #current.cells)
    check("K9 counted", counter("auraReadsWithheld") - before >= 1, counter("auraReadsWithheld") - before)
    check("K9 no tail", current.tails == 0, current.tails)
    check("K9 enchants and supplies still drawn", texts() == "300,20", texts())

    -- R10: a withheld tap read suppresses nothing.
    local alerts, unreadable = rareCounter("alerts"), rareCounter("suppressionUnreadable")
    rarePlate({ npcId = 910001, name = "Hidden Tap" })
    HARNESS.frame()
    check("R10 a withheld tap read still alerts", rareCounter("alerts") - alerts == 1,
        rareCounter("alerts") - alerts)
    check("R10 counted", rareCounter("suppressionUnreadable") - unreadable == 1,
        rareCounter("suppressionUnreadable") - unreadable)
end

-- The no-API session (K10, E7, S10, R19) ------------------------------------------------------------

if NOAPI then
    local login = table.concat(HARNESS.chat, "\n")
    HARNESS.playerClassFile = "WARLOCK"
    HARNESS.itemCounts[SHARD] = 5
    HARNESS.weaponEnchants[MAIN_HAND] = { enchant(20) }
    setAuras({ aura(101, 25, 300) })
    bagsChanged()
    local current = view()
    check("K10 one line names the missing aura call",
        select(2, login:gsub("no C_UnitAuras.GetUnitAuras", "")) == 1, login)
    check("K10 the buff section is off", current.buffRead == "ApiMissing", tostring(current.buffRead))
    check("K10 the panel still draws supplies", texts() == "5" and current.panelShown == true, texts())
    check("E7 the enchant section is off, with one line", current.enchantRead == "ApiMissing"
        and select(2, login:gsub("cannot report weapon enchants", "")) == 1, tostring(current.enchantRead))
    check("S10 no ammo cell", current.supplies[1].supply == "Ammo"
        and current.supplies[1].state == "Unreadable", current.supplies[1].state)
    check("S10 counted", counter("ammoApplicabilityWithheld") >= 1, counter("ammoApplicabilityWithheld"))

    -- R19: no SOUNDKIT: a toast, no sound.
    local before, sounds, toastsBefore = rareCounter("soundUnavailable"), #HARNESS.sounds, posted()
    rarePlate({ npcId = 920001, name = "Silent Rare" })
    HARNESS.frame()
    check("R19 a toast", posted() - toastsBefore == 1, posted() - toastsBefore)
    check("R19 no sound", #HARNESS.sounds == sounds, #HARNESS.sounds - sounds)
    check("R19 counted", rareCounter("soundUnavailable") - before == 1, rareCounter("soundUnavailable") - before)
end

if not HIDDEN and not NOAPI then

-- K: buffs (section 4.1) ------------------------------------------------------------------------------

resetUpkeep()
setAuras({ aura(101, 25, 300) })
check("K1 one Counting cell", #view().cells == 1 and view().cells[1].kind == "Counting", #view().cells)
check("K1 it reads 25", texts() == "25", texts())
check("K1 the panel is shown", view().panelShown == true and panel().shown == true)

local short = counter("aurasShort")
setAuras({ aura(102, 25, 60) })
check("K2 a buff of exactly 60 s never draws", #view().cells == 0, #view().cells)
check("K2 counted", counter("aurasShort") - short == 1, counter("aurasShort") - short)

local permanent = counter("aurasPermanent")
setAuras({ aura(103, 0, 0, { expirationTime = 0 }) })
check("K3 a permanent buff never draws", #view().cells == 0, #view().cells)
check("K3 counted", counter("aurasPermanent") - permanent == 1, counter("aurasPermanent") - permanent)

setAuras({ aura(104, 40, 300) })
check("K4 40 s left draws nothing", #view().cells == 0, #view().cells)
check("K4 a wake timer is armed", view().wakeIn ~= nil and math.abs(view().wakeIn - 10) < 0.1,
    tostring(view().wakeIn))
local calls = HARNESS.auraCalls
HARNESS.advance(10.1)
check("K4 after 10.1 s it reads 30", texts() == "30", texts())
check("K4 with no client read in between", HARNESS.auraCalls == calls, HARNESS.auraCalls - calls)

setAuras({ aura(105, 28, 300), aura(106, 5, 300), aura(107, 20, 300) })
check("K5 soonest first, outward from the anchor", texts() == "5,20,28", texts())
local first = cellFrames()[1]
check("K5 the soonest sits at the anchored edge", first.points[1] and first.points[1][1] == "TOPRIGHT"
    and first.points[1][4] == -ns.UPKEEP_PADDING, first.points[1] and first.points[1][4])

setSetting("upkeep", "maximumIcons", 2)
check("K6 two cells at maximumIcons 2", #view().cells == 2 and texts() == "5,20", texts())
check("K6 truncation counted", counter("cellsTruncated") >= 1, counter("cellsTruncated"))
setSetting("upkeep", "maximumIcons", 6)

setAuras({ aura(108, 40, 300, { timeMod = 2 }) })
check("K7 timeMod 2 halves the countdown", texts() == "20", texts())

setAuras({ aura(109, 40, 300) })
check("K8 40 s left is outside the 30 s window", #view().cells == 0, #view().cells)
setSetting("upkeep", "warningSeconds", 60)
check("K8 a 60 s window draws it at once", texts() == "40", texts())
setSetting("upkeep", "warningSeconds", 30)

local many = {}
for index = 1, 41 do
    many[index] = aura(200 + index, 200, 300)
end
local truncated = counter("rosterTruncated")
setAuras(many)
check("K11 the roster stops at 40", view().rosterBuffs == 40, view().rosterBuffs)
check("K11 truncation counted", counter("rosterTruncated") - truncated == 1, counter("rosterTruncated") - truncated)

local icons = counter("iconsUnreadable")
HARNESS.aurasSecret = "icon"
setAuras({ aura(110, 25, 300) })
HARNESS.aurasSecret = nil
check("K12 a hidden icon is not a hidden read", view().buffsKnown == true, view().buffRead)
check("K12 the buff draws with the fallback icon", texts() == "25"
    and cellFrames()[1].icon.texture == QUESTION, cellFrames()[1] and cellFrames()[1].icon.texture)
check("K12 counted", counter("iconsUnreadable") - icons == 1, counter("iconsUnreadable") - icons)

-- E: enchants (section 4.2) -----------------------------------------------------------------------------

resetUpkeep()
setEnchants(MAIN_HAND, { enchant(20) })
check("E1 a main-hand enchant with 20000 ms reads 20", texts() == "20", texts())
check("E1 with the weapon's own icon", cellFrames()[1].icon.texture == SWORD_ICON,
    cellFrames()[1] and cellFrames()[1].icon.texture)

-- Each check starts clean: an enchant that goes from one check to the next is "gone on
-- the same weapon", and T4 shows that draws a tail.
resetUpkeep()
setEnchants(MAIN_HAND, { enchant(20, { enchantType = 1 }), enchant(20, { enchantType = 0 }) })
check("E2 Permanent and None never draw", #view().cells == 0, #view().cells)

resetUpkeep()
setEnchants(MAIN_HAND, { enchant(20, { charges = 12 }) })
check("E3 charges show", cellFrames()[1] and cellFrames()[1].charges.text == "12",
    cellFrames()[1] and cellFrames()[1].charges.text)

resetUpkeep()
setEnchants(RANGED, { enchant(15) })
check("E4 the Ranged slot reads inventory slot 18", texts() == "15"
    and cellFrames()[1].icon.texture == BOW_ICON, cellFrames()[1] and cellFrames()[1].icon.texture)

resetUpkeep()
setEnchants(MAIN_HAND, { enchant(20, { hasEnchant = false }) })
check("E5 hasEnchant false never draws", #view().cells == 0, #view().cells)

resetUpkeep()
HARNESS.weaponEnchants[MAIN_HAND] = { enchant(20) }
setSetting("upkeep", "showWeaponEnchants", false)
local enchantCalls = HARNESS.enchantCalls
setAuras({})
check("E6 off draws none", #view().cells == 0, #view().cells)
check("E6 and reads none", HARNESS.enchantCalls == enchantCalls, HARNESS.enchantCalls - enchantCalls)
check("E6 off is not Known", view().enchantsKnown == false and view().enchantRead == "Off", view().enchantRead)
setSetting("upkeep", "showWeaponEnchants", true)

-- T: tails (section 4.4) -----------------------------------------------------------------------------------

resetUpkeep()
setAuras({ aura(301, 2, 300) })
check("T1 counting first", texts() == "2", texts())
HARNESS.advance(2.25)
local tail = cellFrames()[1]
check("T1 at 0 s still listed it turns Expired", #view().cells == 1 and view().cells[1].kind == "Expired",
    view().cells[1] and view().cells[1].kind)
check("T1 desaturated", tail and tail.icon.desaturated == true)
check("T1 tinted dark red", tail and tail.icon.vertexColor[1] == ns.UPKEEP_EXPIRED_TINT[1]
    and tail.icon.vertexColor[2] == ns.UPKEEP_EXPIRED_TINT[2], tail and tail.icon.vertexColor[1])
check("T1 no text", tail and tail.text.text == "", tail and tail.text.text)
local tailsLive = counter("tailsLive")
setAuras({})
check("T1 the refresh that confirms its removal keeps the same tail", view().tails == 1
    and #view().cells == 1 and counter("tailsLive") == tailsLive, view().tails)
HARNESS.advance(10)
check("T1 gone 10 s after its expiry", #view().cells == 0 and view().tails == 0, #view().cells)

resetUpkeep()
setAuras({ aura(302, 1, 300) })
HARNESS.advance(1.25)
check("T2 expired", view().cells[1] and view().cells[1].kind == "Expired")
setAuras({ aura(302, 200, 300) })
check("T2 a renewal cancels the tail", view().tails == 0 and #view().cells == 0, view().tails)

resetUpkeep()
setAuras({ aura(303, 200, 300) })
setAuras({})
check("T3 a buff removed early gets no tail", view().tails == 0 and #view().cells == 0, view().tails)

resetUpkeep()
setEnchants(MAIN_HAND, { enchant(100) })
setEnchants(MAIN_HAND, {})
check("T4 an enchant gone on the same weapon gets a tail", view().tails == 1
    and view().cells[1] and view().cells[1].kind == "Expired", view().tails)

resetUpkeep()
setEnchants(MAIN_HAND, { enchant(100) })
HARNESS.equipped[16] = DAGGER
HARNESS.weaponEnchants[MAIN_HAND] = {}
HARNESS.fire("PLAYER_EQUIPMENT_CHANGED", 16, true)
HARNESS.frame()
check("T5 an enchant gone with its weapon gets none", view().tails == 0, view().tails)

resetUpkeep()
setAuras({ aura(306, 20, 300) })
startCombat()
check("T6 hidden in combat", view().visibility == "HiddenInCombat" and panel().shown == false,
    view().visibility)
HARNESS.advance(20.5)
HARNESS.playerAuras = {}
HARNESS.fire("UNIT_AURA", "player", {})
HARNESS.advance(39)
local postFight = counter("tailsPostFight")
endCombat()
local endedAt = HARNESS.now
check("T6 the post-fight tail shows", view().cells[1] and view().cells[1].kind == "Expired"
    and counter("tailsPostFight") - postFight == 1, view().cells[1] and view().cells[1].kind)
check("T6 it lasts until fightEndedAt + 10", view().cells[1]
    and math.abs(view().cells[1].endsAt - (endedAt + 10)) < 0.001, view().cells[1] and view().cells[1].endsAt)
HARNESS.advance(9.5)
check("T6 still there before its end", #view().cells == 1, #view().cells)
HARNESS.advance(1)
check("T6 gone after", #view().cells == 0, #view().cells)

resetUpkeep()
setAuras({ aura(307, 20, 300) })
startCombat()
HARNESS.advance(10)
HARNESS.playerAuras = { aura(307, 200, 300) }
HARNESS.advance(20)
endCombat()
check("T7 a buff recast mid-fight gets no post-fight tail", view().tails == 0, view().tails)

resetUpkeep()
setAuras({ aura(308, 20, 300), aura(309, 250, 300) })
startCombat()
HARNESS.advance(30)
HARNESS.playerAuras = { aura(309, 220, 300) }
HARNESS.aurasSecret = "expiration"
local retries = counter("postFightRetries")
endCombat()
local endedAt8 = HARNESS.now
check("T8 the first post-fight read is hidden", view().buffsKnown == false and view().tails == 0,
    view().buffRead)
HARNESS.aurasSecret = nil
HARNESS.advance(0.6)
check("T8 the retry reads plain and draws the tail", view().tails == 1
    and view().cells[1] and view().cells[1].kind == "Expired", view().tails)
check("T8 against the original fightEndedAt", view().cells[1]
    and math.abs(view().cells[1].endsAt - (endedAt8 + 10)) < 0.001, view().cells[1] and view().cells[1].endsAt)
check("T8 one retry", counter("postFightRetries") - retries == 1, counter("postFightRetries") - retries)

resetUpkeep()
setAuras({ aura(310, 20, 300), aura(311, 250, 300) })
setEnchants(MAIN_HAND, { enchant(200) })
startCombat()
HARNESS.advance(30)
HARNESS.playerAuras = { aura(311, 220, 300) }
HARNESS.weaponEnchants[MAIN_HAND] = {}
HARNESS.aurasSecret = "expiration"
retries = counter("postFightRetries")
local gaveUp = counter("postFightGaveUp")
endCombat()
HARNESS.advance(0.6)
HARNESS.advance(0.6)
HARNESS.advance(0.6)
HARNESS.aurasSecret = nil
check("T9 three retries", counter("postFightRetries") - retries == 3, counter("postFightRetries") - retries)
check("T9 then it gives up", counter("postFightGaveUp") - gaveUp == 1, counter("postFightGaveUp") - gaveUp)
local enchantTail = false
for _, cell in ipairs(view().cells) do
    if cell.kind == "Expired" and cell.source == "Enchant" then
        enchantTail = true
    end
    check("T9 no buff tail", not (cell.kind == "Expired" and cell.source == "Buff"))
end
check("T9 the enchant tail is still drawn", enchantTail)

resetUpkeep()
setSetting("upkeep", "expiredTailSeconds", 0)
setAuras({ aura(312, 1, 300) })
HARNESS.advance(1.5)
check("T10 tails off: nothing drawn at 0 s", #view().cells == 0 and view().tails == 0, #view().cells)
check("T15 and no zero-second wake re-arms", view().wakeIn == nil and view().ticker == false,
    tostring(view().wakeIn))
local timersBefore = #HARNESS.timers
HARNESS.advance(0.5)
check("T15 a few frames later still no wake loop", view().wakeIn == nil and #HARNESS.timers <= timersBefore,
    #HARNESS.timers - timersBefore)
setSetting("upkeep", "expiredTailSeconds", 10)

-- T11: a cell repainted in place after showing a tail is neither grey nor red. Tail A
-- ends while countdown B runs on, so the pool releases cell 2 and cell 1, which drew
-- the tail, is repainted with B on a tick: no release in between.
resetUpkeep()
local countdown = aura(314, 25, 300)
setAuras({ aura(313, 1, 300), countdown })
HARNESS.advance(1.25)
check("T11 a tail then a countdown", view().cells[1] and view().cells[1].kind == "Expired"
    and view().cells[2] and view().cells[2].kind == "Counting")
local reused = cellFrames()[1]
check("T11 the tail's cell is tinted first", reused.icon.desaturated == true)
HARNESS.advance(10)
check("T11 the same cell now counts", #cellFrames() == 1 and cellFrames()[1] == reused
    and texts() == tostring(math.ceil(countdown.expirationTime - HARNESS.now)), texts())
check("T11 not desaturated", reused.icon.desaturated == false)
check("T11 white", reused.icon.vertexColor[1] == 1 and reused.icon.vertexColor[2] == 1
    and reused.icon.vertexColor[3] == 1, reused.icon.vertexColor[2])

resetUpkeep()
setAuras({ aura(316, 1, 300) })
HARNESS.advance(1.25)
startCombat()
HARNESS.playerAuras = {}
HARNESS.advance(5)
endCombat()
check("T12 a snapshot buff that ran out before the pull gets no post-fight tail", view().tails == 0,
    view().tails)

resetUpkeep()
setEnchants(MAIN_HAND, { enchant(20) })
setEnchants(RANGED, { enchant(25) })
check("T13 two enchants drawn", #view().cells == 2, #view().cells)
local failed = counter("enchantReadsFailed")
HARNESS.enchantRaiseSlot = RANGED
setEnchants(RANGED, { enchant(25) })
HARNESS.enchantRaiseSlot = nil
check("T13 one raising slot fails the whole enchant read", view().enchantsKnown == false
    and view().enchantRead == "CallFailed", view().enchantRead)
check("T13 no enchant cell and no enchant tail", #view().cells == 0 and view().tails == 0, #view().cells)
check("T13 counted", counter("enchantReadsFailed") - failed == 1, counter("enchantReadsFailed") - failed)

resetUpkeep()
setAuras({ aura(317, 2, 300) })
HARNESS.advance(2.5)
setAuras({})
check("T14 the removed buff's tail shows", view().tails == 1, view().tails)
setAuras({ aura(317, 250, 300) })
check("T14 renewing it removes the tail at the next refresh", view().tails == 0 and #view().cells == 0,
    view().tails)

resetUpkeep()
HARNESS.usesAmmo = true
HARNESS.equipped[0] = AMMO_ITEM
HARNESS.itemCounts[AMMO_ITEM] = 300
setAuras({ aura(318, 200, 300) })
startCombat()
local snapshotBuffs = view().snapshotBuffs
local auraCalls, enchantCalls, countCalls = HARNESS.auraCalls, HARNESS.enchantCalls, HARNESS.itemCountCalls
HARNESS.itemCounts[AMMO_ITEM] = 299
bagsChanged()
check("T16 a refresh in combat reads supplies", HARNESS.itemCountCalls > countCalls,
    HARNESS.itemCountCalls - countCalls)
check("T16 and nothing else", HARNESS.auraCalls == auraCalls and HARNESS.enchantCalls == enchantCalls,
    (HARNESS.auraCalls - auraCalls) .. "/" .. (HARNESS.enchantCalls - enchantCalls))
check("T16 the snapshot is untouched", view().snapshotBuffs == snapshotBuffs and snapshotBuffs == 1,
    tostring(view().snapshotBuffs))
check("T16 nothing drawn", panel().shown == false and view().panelShown == false)
endCombat()

-- S: supplies (section 5) ---------------------------------------------------------------------------------

resetUpkeep()
HARNESS.usesAmmo = true
HARNESS.equipped[0] = AMMO_ITEM
HARNESS.itemCounts[AMMO_ITEM] = 300
bagsChanged()
local supply = cellFrames()[1]
check("S1 a hunter with 300 ammo draws 300", texts() == "300", texts())
check("S1 white", supply and supply.text.textColor[1] == 1 and supply.text.textColor[2] == 1)
check("S1 with the ammo's icon", supply and supply.icon.texture == AMMO_ICON, supply and supply.icon.texture)
HARNESS.itemCounts[AMMO_ITEM] = 150
bagsChanged()
check("S2 150 is amber", cellFrames()[1].text.textColor[2] == ns.UPKEEP_AMBER[2], cellFrames()[1].text.textColor[2])
HARNESS.itemCounts[AMMO_ITEM] = 40
bagsChanged()
check("S3 40 is red", cellFrames()[1].text.textColor[2] == ns.UPKEEP_RED[2], cellFrames()[1].text.textColor[2])
HARNESS.equipped[0] = nil
bagsChanged()
check("S4 an empty ammo slot reads a red 0", texts() == "0"
    and cellFrames()[1].text.textColor[2] == ns.UPKEEP_RED[2], texts())
HARNESS.usesAmmo = false
bagsChanged()
check("S5 no ammo used, no ammo cell", #cellFrames() == 0, texts())

HARNESS.playerClassFile = "WARLOCK"
HARNESS.itemCounts[SHARD] = 2
bagsChanged()
check("S6 a warlock with 2 shards is amber", texts() == "2"
    and cellFrames()[1].text.textColor[2] == ns.UPKEEP_AMBER[2], texts())
HARNESS.itemCounts[SHARD] = 0
bagsChanged()
check("S6 0 shards is red", texts() == "0" and cellFrames()[1].text.textColor[2] == ns.UPKEEP_RED[2], texts())
HARNESS.playerClassFile = "MAGE"
bagsChanged()
check("S7 a non-warlock draws no shard cell", #cellFrames() == 0, texts())

HARNESS.usesAmmo = true
HARNESS.equipped[0] = AMMO_ITEM
HARNESS.itemCounts[AMMO_ITEM] = 300
setSetting("upkeep", "showSupplies", false)
local usesCalls = HARNESS.usesAmmoCalls
bagsChanged()
check("S8 off draws none", #cellFrames() == 0, texts())
check("S8 and reads none", HARNESS.usesAmmoCalls == usesCalls, HARNESS.usesAmmoCalls - usesCalls)
setSetting("upkeep", "showSupplies", true)

setNow("upkeep", "ammoRedBelow", 300)
HARNESS.itemCounts[AMMO_ITEM] = 150
bagsChanged()
check("S9 red at or above amber leaves amber unreachable", cellFrames()[1].text.textColor[2] == ns.UPKEEP_RED[2],
    cellFrames()[1].text.textColor[2])
setNow("upkeep", "ammoRedBelow", 50)

-- L: the low-supply toast (sections 5.3 and 5.4) --------------------------------------------------------

resetUpkeep()
clearToasts()
HARNESS.usesAmmo = true
HARNESS.equipped[0] = AMMO_ITEM
HARNESS.itemCounts[AMMO_ITEM] = 60
bagsChanged()
startCombat()
local toasts = counter("lowSupplyToasts")
local playerPoints = #PlayerFrame.points
local createdInCombat = HARNESS.framesCreatedInCombat
HARNESS.itemCounts[AMMO_ITEM] = 45
local countCallsBefore = HARNESS.itemCountCalls
HARNESS.fire("BAG_UPDATE_DELAYED")
check("L7 the handler reads nothing", HARNESS.itemCountCalls == countCallsBefore,
    HARNESS.itemCountCalls - countCallsBefore)
HARNESS.frame()
check("L7 the read comes a frame later", HARNESS.itemCountCalls > countCallsBefore)
check("L1 crossing into red in combat posts one toast", counter("lowSupplyToasts") - toasts == 1,
    counter("lowSupplyToasts") - toasts)
local low = visibleToasts("SupplyLow")[1]
check("L1 it reads 45 left", low and low.text.text == "45 left" and low.label.text == "Low on ammo",
    low and low.text.text)
check("L1 the panel stays hidden", panel().shown == false)
check("L8 no Blizzard frame is written", #PlayerFrame.points == playerPoints, #PlayerFrame.points - playerPoints)
check("L8 no frame is created in combat", HARNESS.framesCreatedInCombat == createdInCombat,
    HARNESS.framesCreatedInCombat - createdInCombat)
HARNESS.itemCounts[AMMO_ITEM] = 44
bagsChanged()
check("L3 45 to 44 posts nothing", counter("lowSupplyToasts") - toasts == 1, counter("lowSupplyToasts") - toasts)
endCombat()

local cooled = counter("lowSupplyCooled")
HARNESS.itemCounts[AMMO_ITEM] = 200
bagsChanged()
HARNESS.itemCounts[AMMO_ITEM] = 49
bagsChanged()
check("L4 a second crossing within 60 s is held back", counter("lowSupplyToasts") - toasts == 1
    and counter("lowSupplyCooled") - cooled == 1, counter("lowSupplyCooled") - cooled)
HARNESS.now = HARNESS.now + 61
HARNESS.itemCounts[AMMO_ITEM] = 200
bagsChanged()
HARNESS.itemCounts[AMMO_ITEM] = 49
bagsChanged()
check("L4 after 60 s it posts", counter("lowSupplyToasts") - toasts == 2, counter("lowSupplyToasts") - toasts)

HARNESS.itemCounts[AMMO_ITEM] = 45
resetUpkeep()
HARNESS.usesAmmo = true
HARNESS.equipped[0] = AMMO_ITEM
HARNESS.itemCounts[AMMO_ITEM] = 45
local beforeFirst = counter("lowSupplyToasts")
bagsChanged()
check("L2 the first reading after enable never toasts", counter("lowSupplyToasts") == beforeFirst,
    counter("lowSupplyToasts") - beforeFirst)

HARNESS.itemCounts[AMMO_ITEM] = 100
bagsChanged()
setSetting("upkeep", "lowSupplyToast", false)
HARNESS.now = HARNESS.now + 61
HARNESS.itemCounts[AMMO_ITEM] = 10
bagsChanged()
check("L5 off posts nothing", counter("lowSupplyToasts") == beforeFirst, counter("lowSupplyToasts") - beforeFirst)
setSetting("upkeep", "lowSupplyToast", true)

HARNESS.itemCounts[AMMO_ITEM] = 100
bagsChanged()
HARNESS.itemCountSecret = true
HARNESS.now = HARNESS.now + 61
bagsChanged()
HARNESS.itemCountSecret = false
check("L9 an unreadable reading never toasts", counter("lowSupplyToasts") == beforeFirst,
    counter("lowSupplyToasts") - beforeFirst)

slash("off toasts")
local unavailable = counter("toastUnavailable")
local mark = chatMark()
HARNESS.itemCounts[AMMO_ITEM] = 40
bagsChanged()
check("L6 Toasts off: one chat line", chatSince(mark):find("low on ammo: 40 left", 1, true) ~= nil,
    chatSince(mark))
check("L6 counted", counter("toastUnavailable") - unavailable == 1, counter("toastUnavailable") - unavailable)
slash("on toasts")
HARNESS.frame()

-- V: visibility and anchor (section 6) -------------------------------------------------------------------

resetUpkeep()
setAuras({ aura(401, 25, 300) })
startCombat()
check("V1 combat hides the panel a frame later", panel().shown == false
    and view().visibility == "HiddenInCombat", view().visibility)
check("V1 no ticker or wake timer", view().ticker == false and view().wakeIn == nil)
endCombat()
check("V2 the fight's end redraws", panel().shown == true
    and texts() == tostring(math.ceil(HARNESS.playerAuras[1].expirationTime - HARNESS.now)), texts())

local function point()
    return panel().points[1] or {}
end
local breakdownAnchors = counter("anchorBreakdown")
HARNESS.fire("PLAYER_ENTERING_WORLD")
HARNESS.frame()
check("V3 attached to the breakdown", point()[1] == "BOTTOMRIGHT" and point()[2] == _G.PersonalAddonDamageBreakdown
    and point()[3] == "BOTTOMLEFT" and point()[4] == -4 and point()[5] == 0,
    tostring(point()[1]) .. " " .. tostring(point()[3]) .. " " .. tostring(point()[4]))
check("V3 counted", counter("anchorBreakdown") - breakdownAnchors >= 1)
check("V3 the view says so", view().anchor == "DamageBreakdown", view().anchor)

slash("off damageBreakdown")
HARNESS.fire("PLAYER_ENTERING_WORLD")
HARNESS.frame()
check("V4 breakdown off: the threat panel", point()[2] == _G.PersonalAddonThreatPanel
    and view().anchor == "ThreatPanel", view().anchor)

slash("off threatPanel")
HARNESS.fire("PLAYER_ENTERING_WORLD")
HARNESS.frame()
check("V5 both off: the player frame", point()[2] == PlayerFrame and point()[3] == "TOPLEFT"
    and point()[4] == -4 and point()[5] == 8, tostring(point()[4]) .. "," .. tostring(point()[5]))

local savedPlayerFrame = _G.PlayerFrame
_G.PlayerFrame = nil
mark = chatMark()
HARNESS.fire("PLAYER_ENTERING_WORLD")
HARNESS.frame()
check("V6 no PlayerFrame: the middle of the screen", point()[2] == UIParent and point()[3] == "CENTER"
    and view().anchor == "Screen", view().anchor)
check("V6 one line", chatSince(mark):find("PlayerFrame was not found", 1, true) ~= nil, chatSince(mark))
_G.PlayerFrame = savedPlayerFrame

slash("on threatPanel")
HARNESS.fire("PLAYER_ENTERING_WORLD")
HARNESS.frame()
check("V11 breakdown still off: the threat panel", view().anchor == "ThreatPanel", view().anchor)
slash("on damageBreakdown")
startCombat()
endCombat()
check("V11 the breakdown switched on mid-session is picked up at the fight's end",
    view().anchor == "DamageBreakdown", view().anchor)

setSetting("upkeep", "attachToPanels", false)
check("V7 attach off: the player frame", point()[2] == PlayerFrame and view().anchor == "PlayerFrame",
    view().anchor)
setSetting("upkeep", "scale", 2)
check("V8 scale 2 halves the offsets", point()[4] == -2 and point()[5] == 4,
    tostring(point()[4]) .. "," .. tostring(point()[5]))
setSetting("upkeep", "scale", 1)
setSetting("upkeep", "attachToPanels", true)

resetUpkeep()
check("V9 nothing to draw: hidden", panel().shown == false and view().visibility == "Empty", view().visibility)
HARNESS.usesAmmo = true
HARNESS.equipped[0] = AMMO_ITEM
HARNESS.itemCounts[AMMO_ITEM] = 300
bagsChanged()
check("V9 a hunter with nothing expiring: one cell, shown", panel().shown == true and #cellFrames() == 1,
    #cellFrames())

setAuras({ aura(402, 25, 300) })
startCombat()
slash("off upkeep")
slash("on upkeep")
HARNESS.frame()
check("V10 enabled in combat: hidden", view().visibility == "HiddenInCombat" and panel().shown == false,
    view().visibility)
endCombat()
check("V10 drawn when the fight ends, with no snapshot tails", panel().shown == true and view().tails == 0,
    view().tails)

-- P: preview (section 6.3) --------------------------------------------------------------------------------

resetUpkeep()
local beforeCalls = { HARNESS.auraCalls, HARNESS.enchantCalls, HARNESS.itemCountCalls, HARNESS.usesAmmoCalls }
ns.Preview.SetEnabled(true)
local kinds = {}
for _, window in ipairs(ns.Preview.Inspect().windows) do
    kinds[window.panelId] = window.kind
end
check("P1 Upkeep's samples and the threat panel's at once", kinds.Upkeep == "Shown"
    and kinds.ThreatPanel == "Shown", tostring(kinds.Upkeep) .. "/" .. tostring(kinds.ThreatPanel))
check("P1 one supply sample and four expiry samples", #cellFrames() == 5 and view().visibility == "Preview",
    #cellFrames())
check("P2 the samples read no client value", HARNESS.auraCalls == beforeCalls[1]
    and HARNESS.enchantCalls == beforeCalls[2] and HARNESS.itemCountCalls == beforeCalls[3]
    and HARNESS.usesAmmoCalls == beforeCalls[4])
check("P4 five windows", #ns.Preview.Inspect().windows == 5, #ns.Preview.Inspect().windows)
setSetting("upkeep", "maximumIcons", 2)
check("P1 maximumIcons cuts the expiry samples only", #cellFrames() == 3, #cellFrames())
setSetting("upkeep", "maximumIcons", 6)
startCombat()
check("P3 a fight ends the preview", ns.Preview.IsEnabled() == false)
check("P3 and Upkeep hides", panel().shown == false and view().visibility == "HiddenInCombat",
    view().visibility)
endCombat()

setAuras({ aura(501, 25, 300) })
ns.Preview.SetEnabled(true)
check("P5 samples while on", #cellFrames() == 5)
ns.Preview.SetEnabled(false)
check("P5 the preview's end redraws the real cells", texts() == "25" and view().visibility == "Shown",
    texts())

-- R: rare alerts (section 8) ------------------------------------------------------------------------------

clearToasts()
local alerts = rareCounter("alerts")
local sounds = #HARNESS.sounds
rarePlate({ npcId = 900001, name = "Sample Rare", level = 34 })
check("R13 the event only queues", RareAlerts.Inspect().pending == 1 and rareCounter("alerts") == alerts)
HARNESS.frame()
local rare = visibleToasts("RareSpotted")[1]
check("R1 one alert", rareCounter("alerts") - alerts == 1, rareCounter("alerts") - alerts)
check("R1 labelled Rare", rare and rare.label.text == "Rare", rare and rare.label.text)
check("R1 name and level", rare and rare.text.text == "Sample Rare " .. MIDDLE_DOT .. " level 34",
    rare and rare.text.text)
check("X1 the plate's own art, by SetAtlas", rare and rare.icon.atlas == ns.RARE_ALERT_ATLAS.Rare,
    rare and rare.icon.atlas)
check("R1 the raid warning sound", #HARNESS.sounds - sounds == 1 and HARNESS.sounds[#HARNESS.sounds] == 8959,
    tostring(HARNESS.sounds[#HARNESS.sounds]))

-- X2: the same pooled toast, next painted as loot, has its coordinates back.
clearToasts()
ns.Toasts.Post({ kind = ns.Toasts.KIND.LOOTED_ITEM, itemId = 2001, name = "Boots", icon = 132539,
    quantity = 1, quality = 2, isQuestItem = false })
local loot = visibleToasts("LootedItem")[1]
check("X2 the loot toast reuses the rare's frame", loot == rare)
check("X2 its coordinates are reset", loot and loot.icon.texCoord[1] == 0 and loot.icon.texCoord[2] == 1
    and loot.icon.texCoord[3] == 0 and loot.icon.texCoord[4] == 1, loot and tostring(loot.icon.texCoord[1]))
clearToasts()

rarePlate({ npcId = 900002, name = "Silver One", classification = "rareelite" })
HARNESS.frame()
local elite = visibleToasts("RareSpotted")[1]
check("R2 rare elite", elite and elite.label.text == "Rare elite"
    and elite.icon.atlas == ns.RARE_ALERT_ATLAS.RareElite, elite and elite.label.text)
clearToasts()

alerts = rareCounter("alerts")
rarePlate({ npcId = 900003, classification = "elite" })
rarePlate({ npcId = 900004, classification = "normal" })
rarePlate({ npcId = 900005, classification = "worldboss" })
HARNESS.frame()
check("R3 elite, normal and worldboss post nothing", rareCounter("alerts") == alerts,
    rareCounter("alerts") - alerts)

local repeats = rareCounter("repeats")
HARNESS.now = HARNESS.now + 300
rarePlate({ npcId = 900001, name = "Sample Rare" })
HARNESS.frame()
check("R4 the same creature 5 min later: nothing", rareCounter("alerts") == alerts
    and rareCounter("repeats") - repeats == 1, rareCounter("repeats") - repeats)
HARNESS.now = HARNESS.now + 360
rarePlate({ npcId = 900001, name = "Sample Rare" })
HARNESS.frame()
check("R4 11 min later: a toast", rareCounter("alerts") - alerts == 1, rareCounter("alerts") - alerts)
clearToasts()

alerts = rareCounter("alerts")
rarePlate({ npcId = 900006, dead = true })
rarePlate({ npcId = 900007, tapDenied = true })
HARNESS.frame()
check("R5 dead: nothing", rareCounter("dead") >= 1)
check("R6 tapped: nothing", rareCounter("tappedByOthers") >= 1)
check("R5 R6 no alert", rareCounter("alerts") == alerts, rareCounter("alerts") - alerts)

HARNESS.restrictedMap = true
local stood, gone, notRare = rareCounter("mapStoodDown"), rareCounter("gone"), rareCounter("notRare")
rarePlate({ npcId = 900008 })
HARNESS.frame()
check("R7 a restricted map: nothing", rareCounter("alerts") == alerts and rareCounter("mapStoodDown") - stood == 1)
check("R7 and no unit read", rareCounter("gone") == gone and rareCounter("notRare") == notRare)
HARNESS.restrictedMap = false

local token = rarePlate({ npcId = 900009 })
HARNESS.guids[token] = HARNESS.SECRET
HARNESS.frame()
check("R8 a withheld GUID: IdentityUnreadable", rareCounter("identityUnreadable") >= 1
    and rareCounter("alerts") == alerts)

local unit = HARNESS.units[rarePlate({ npcId = 900010 })]
unit.classification = HARNESS.SECRET
HARNESS.frame()
check("R9 a withheld classification: nothing", rareCounter("classificationUnreadable") >= 1
    and rareCounter("alerts") == alerts)

setSetting("rareAlerts", "playSound", false)
sounds = #HARNESS.sounds
rarePlate({ npcId = 900011 })
HARNESS.frame()
check("R11 sound off: a toast, no sound", rareCounter("alerts") - alerts == 1 and #HARNESS.sounds == sounds)
setSetting("rareAlerts", "playSound", true)
clearToasts()

slash("off toasts")
mark = chatMark()
rarePlate({ npcId = 900012, name = "Pipe|Name" })
HARNESS.frame()
check("R12 Toasts off: one neutralized chat line", chatSince(mark):find("rare spotted: Pipe||Name (level 34)", 1, true)
    ~= nil, chatSince(mark))
slash("on toasts")
HARNESS.frame()

rarePlate({ npcId = 900013, name = "|cffff0000x|r" })
HARNESS.frame()
local piped = visibleToasts("RareSpotted")[1]
check("R16 every pipe doubled", piped and piped.text.text:find("||cffff0000x||r", 1, true) == 1,
    piped and piped.text.text)
clearToasts()

local dropped, goneBefore = rareCounter("pendingDropped"), rareCounter("gone")
for index = 1, 129 do
    HARNESS.fire("NAME_PLATE_UNIT_ADDED", "ghost" .. index)
end
HARNESS.frame()
check("R14 129 plates in one frame: one dropped", rareCounter("pendingDropped") - dropped == 1,
    rareCounter("pendingDropped") - dropped)
check("R14 128 evaluated", rareCounter("gone") - goneBefore == 128, rareCounter("gone") - goneBefore)

setSetting("rareAlerts", "playSound", false)
local evictions = rareCounter("memoryEvictions")
for index = 1, 65 do
    rarePlate({ npcId = 950000 + index })
end
HARNESS.frame()
clearToasts()
check("R15 a 65th creature evicts the oldest", rareCounter("memoryEvictions") - evictions >= 1
    and RareAlerts.Inspect().remembered == ns.RARE_ALERT_MEMORY_CAPACITY,
    RareAlerts.Inspect().remembered)
setSetting("rareAlerts", "playSound", true)
removeRarePlates()

alerts = rareCounter("alerts")
slash("off rareAlerts")
rarePlate({ npcId = 960001, name = "Already Here" })
slash("on rareAlerts")
HARNESS.frame()
check("R17 enabling beside a rare alerts once", rareCounter("alerts") - alerts == 1,
    rareCounter("alerts") - alerts)
removeRarePlates()
clearToasts()

HARNESS.cvars.nameplateShowEnemies = "0"
mark = chatMark()
slash("off rareAlerts")
slash("on rareAlerts")
HARNESS.frame()
check("R18 enemy plates off: one hint line", chatSince(mark):find("enemy nameplates are off", 1, true) ~= nil,
    chatSince(mark))
HARNESS.cvars.nameplateShowEnemies = "1"

alerts = rareCounter("alerts")
local flushes = rareCounter("flushes")
rarePlate({ npcId = 970001 })
slash("off rareAlerts")
HARNESS.frame()
check("R20 a disable while a flush is pending: nothing posted", rareCounter("alerts") == alerts
    and rareCounter("flushes") == flushes, rareCounter("flushes") - flushes)
check("R20 the pending set is empty", RareAlerts.Inspect().pending == 0)
removeRarePlates()
slash("on rareAlerts")
HARNESS.frame()

-- X: toasts (section 9) -----------------------------------------------------------------------------------

clearToasts()
ns.Toasts.Post({ kind = ns.Toasts.KIND.SUPPLY_LOW, supply = "Ammo", count = 0, icon = AMMO_ICON })
local out = visibleToasts("SupplyLow")[1]
check("X3 SupplyLow at 0 reads Out of ammo", out and out.label.text == "Out of ammo" and out.text.text == "0 left",
    out and out.label.text)
clearToasts()

HARNESS.missingAtlases[ns.RARE_ALERT_ATLAS.Rare] = true
ns.Toasts.Post({ kind = ns.Toasts.KIND.RARE_SPOTTED, name = "No Art", level = 20, rareClass = "Rare",
    atlas = ns.RARE_ALERT_ATLAS.Rare })
local noArt = visibleToasts("RareSpotted")[1]
check("X4 an atlas the client does not know: the question mark", noArt and noArt.icon.texture == QUESTION,
    noArt and tostring(noArt.icon.texture))
HARNESS.missingAtlases[ns.RARE_ALERT_ATLAS.Rare] = nil
clearToasts()
HARNESS.atlasRaise = true
ns.Toasts.Post({ kind = ns.Toasts.KIND.RARE_SPOTTED, name = "Raises", level = 20, rareClass = "Rare",
    atlas = ns.RARE_ALERT_ATLAS.Rare })
local raised = visibleToasts("RareSpotted")[1]
check("X4 SetAtlas raising: the question mark", raised and raised.icon.texture == QUESTION,
    raised and tostring(raised.icon.texture))
HARNESS.atlasRaise = false
clearToasts()

HARNESS.badTextures[AMMO_ICON] = true
ns.Toasts.Post({ kind = ns.Toasts.KIND.SUPPLY_LOW, supply = "Ammo", count = 12, icon = AMMO_ICON })
local badIcon = visibleToasts("SupplyLow")[1]
check("X6 a SupplyLow icon that fails falls back to the question mark, not the coin",
    badIcon and badIcon.icon.texture == QUESTION, badIcon and tostring(badIcon.icon.texture))
HARNESS.badTextures[AMMO_ICON] = nil
clearToasts()

local outcomes = ns.Toasts.PostSamples()
check("X5 PostSamples returns Shown, Shown, Shown, Queued, Queued, Queued",
    table.concat(outcomes, ", ") == "Shown, Shown, Shown, Queued, Queued, Queued", table.concat(outcomes, ", "))
clearToasts()
clearToasts()

-- Commands and saved diagnostics ----------------------------------------------------------------------------

mark = chatMark()
slash("upkeep")
check("/pa upkeep reports", chatSince(mark):find("visibility=", 1, true) ~= nil, chatSince(mark))
mark = chatMark()
slash("rares")
check("/pa rares reports", chatSince(mark):find("remembered=", 1, true) ~= nil, chatSince(mark))
mark = chatMark()
slash("help")
check("/pa help lists both", chatSince(mark):find("/pa upkeep", 1, true) ~= nil
    and chatSince(mark):find("/pa rares", 1, true) ~= nil)

end -- the main session

-- Every saved counter is a number (Phase 20 section 11's lesson).
local function diagnosticsValid()
    local log = PersonalAddonDiagnostics
    if type(log) ~= "table" or type(log.sessions) ~= "table" then
        return false, "no saved log"
    end
    for _, record in ipairs(log.sessions) do
        for featureId, counters in pairs(record.counters or {}) do
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
