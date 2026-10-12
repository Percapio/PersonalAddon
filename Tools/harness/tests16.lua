-- Phase 16 offline checks (Architecture/20261011-Phase16.md section 12.1).
-- One session, "phase16". M1-M33 are the design's own checks; M34-M45 were added by
-- the audit and each names the finding it covers.

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

local FEATURE = "consumableMacros"

local function setSetting(key, value)
    local ok, reason = ns.ConfigStore.Set(FEATURE, key, value)
    ns.Registry.NotifyConfigChanged(FEATURE, key)
    HARNESS.frame()
    return ok, reason
end

-- A rebuild runs a frame later, on the feature's own timer, so every trigger is
-- followed by a frame.
local function rebuild()
    HARNESS.fire("BAG_UPDATE_DELAYED")
    HARNESS.frame()
    HARNESS.frame()
end

local function body(name)
    local macro = HARNESS.macroNamed(name)
    return macro and macro.body or nil
end

local function inspect()
    return ns.ConsumableMacros.Inspect()
end

local function macroView(kind)
    for _, macro in ipairs(inspect().macros) do
        if macro.kind == kind then
            return macro
        end
    end
    return nil
end

-- The bag -----------------------------------------------------------------------------

local STONE = HARNESS.addConsumable(5512, { requiredLevel = 5, itemLevel = 5, conjured = true })
local BIG_STONE = HARNESS.addConsumable(19004, { requiredLevel = 30, itemLevel = 30, conjured = true })
local POTION = HARNESS.addConsumable(929, { requiredLevel = 22, itemLevel = 22, spell = "Healing Potion" })
local FOOD = HARNESS.addConsumable(4541, { requiredLevel = 20, itemLevel = 20, spell = "Food" })
local BETTER_FOOD = HARNESS.addConsumable(4542, { requiredLevel = 35, itemLevel = 35, spell = "Food" })
local HIGH_FOOD = HARNESS.addConsumable(4544, { requiredLevel = 55, itemLevel = 55, spell = "Food" })
local BUFF_FOOD = HARNESS.addConsumable(13928, { requiredLevel = 38, itemLevel = 38, spell = "Food", wellFed = true })
local CONJURED_FOOD = HARNESS.addConsumable(8076, { requiredLevel = 25, itemLevel = 25, spell = "Food", conjured = true })
local WATER = HARNESS.addConsumable(1179, { requiredLevel = 15, itemLevel = 15, spell = "Drink" })
local CONJURED_WATER = HARNESS.addConsumable(8078, { requiredLevel = 20, itemLevel = 20, spell = "Drink", conjured = true })
local BANDAGE = HARNESS.addConsumable(3531, { subClassID = 7, requiredLevel = 25, itemLevel = 25 })
local BIG_BANDAGE = HARNESS.addConsumable(6451, { subClassID = 7, requiredLevel = 35, itemLevel = 35 })
local LATE_BANDAGE = HARNESS.addConsumable(14529, { subClassID = 7, requiredLevel = 55, itemLevel = 55 })
-- A consumable that is loaded and simply has no use spell (audit finding 13).
local SPELLLESS = HARNESS.addConsumable(2320, { spell = nil })
-- A consumable whose data has not arrived yet.
local UNLOADED = HARNESS.addConsumable(99999, { loaded = false })

HARNESS.carry(STONE, POTION, FOOD, WATER, BANDAGE)

HARNESS.fire("ADDON_LOADED", "PersonalAddon")
HARNESS.fire("PLAYER_LOGIN")
HARNESS.frame()
HARNESS.fire("PLAYER_ENTERING_WORLD")
HARNESS.frame()
HARNESS.frame()

-- M11 and the login path ----------------------------------------------------------------

check("login created the four macros", HARNESS.macroNamed("PA Heal") ~= nil
    and HARNESS.macroNamed("PA Bandage") ~= nil
    and HARNESS.macroNamed("PA Food") ~= nil
    and HARNESS.macroNamed("PA Water") ~= nil)
check("macros are known", inspect().known == "Known", inspect().known)

-- M1 -------------------------------------------------------------------------------------
check("M1 a stone and a potion give a castsequence",
    body("PA Heal") == "#showtooltip\n/castsequence reset=combat item:5512, item:929", body("PA Heal"))

-- M2: the stone on cooldown, the potion ready ---------------------------------------------
HARNESS.cooldowns[STONE] = 120
rebuild()
check("M2 the ready potion leads",
    body("PA Heal") == "#showtooltip\n/castsequence reset=combat item:929, item:5512", body("PA Heal"))

-- M45: the cooldown timer reads the plan, not the body (audit finding 4) ------------------
check("M45 a cooldown schedules a re-plan", inspect().cooldownPending == true)
HARNESS.cooldowns[STONE] = nil
HARNESS.advance(121)
HARNESS.frame()
check("M45 the timer re-sequenced on its own",
    body("PA Heal") == "#showtooltip\n/castsequence reset=combat item:5512, item:929", body("PA Heal"))

-- M30: everything ready, no timer ---------------------------------------------------------
check("M30 nothing on cooldown schedules no timer", inspect().cooldownPending == false)

-- M3, M4 ----------------------------------------------------------------------------------
HARNESS.carry(POTION, FOOD, WATER, BANDAGE)
rebuild()
check("M3 only a potion gives a use body",
    body("PA Heal") == "#showtooltip\n/use item:929", body("PA Heal"))

HARNESS.carry(FOOD, WATER, BANDAGE)
rebuild()
check("M4 nothing carried leaves showtooltip alone",
    body("PA Heal") == "#showtooltip", body("PA Heal"))

-- M5: conjured first ----------------------------------------------------------------------
HARNESS.carry(BETTER_FOOD, CONJURED_FOOD, WATER, BANDAGE)
rebuild()
check("M5 conjured food wins even though it is weaker",
    body("PA Food") == "#showtooltip\n/use item:8076", body("PA Food"))

setSetting("conjuredFirst", false)
rebuild()
check("M5 with conjuredFirst off the higher level wins",
    body("PA Food") == "#showtooltip\n/use item:4542", body("PA Food"))
setSetting("conjuredFirst", true)

-- M6: conjuredFirst does not reach the healing macro (section 4.3) ------------------------
HARNESS.carry(STONE, POTION, FOOD, WATER)
HARNESS.cooldowns[STONE] = 90
rebuild()
check("M6 a stone on cooldown does not lead just because it is summoned",
    body("PA Heal") == "#showtooltip\n/castsequence reset=combat item:929, item:5512", body("PA Heal"))
HARNESS.cooldowns[STONE] = nil

-- M7: skipBuffFood, and a tooltip we could not read ---------------------------------------
-- The setting ships OFF since D15, so this block switches it on for itself and puts
-- it back. Leaving it on leaked into M48 and M51, where every Forever food carries
-- Well Fed and the food macro silently went empty.
setSetting("skipBuffFood", true)
HARNESS.carry(FOOD, BUFF_FOOD, WATER, BANDAGE)
rebuild()
check("M7 Well Fed food is skipped",
    body("PA Food") == "#showtooltip\n/use item:4541", body("PA Food"))

-- A food this session has not classified yet, so the unreadable tooltip is what
-- decides rather than a cached verdict.
local UNTOLD_FOOD = HARNESS.addConsumable(21023, { requiredLevel = 30, itemLevel = 30, spell = "Food" })
HARNESS.tooltipsUnreadable = true
HARNESS.carry(UNTOLD_FOOD, WATER, BANDAGE)
rebuild()
check("M7 food whose tooltip could not be read is never chosen while skipBuffFood is on",
    body("PA Food") == "#showtooltip", body("PA Food"))
HARNESS.tooltipsUnreadable = false
setSetting("skipBuffFood", false)
rebuild()
check("M7 and it is chosen once Well Fed food is allowed",
    body("PA Food") == "#showtooltip\n/use item:21023", body("PA Food"))
-- Back to the shipped default, not to what this block wanted.
setSetting("skipBuffFood", false)

-- M8, M9, M10: bandages -------------------------------------------------------------------
HARNESS.carry(BANDAGE, BIG_BANDAGE, FOOD, WATER)
rebuild()
check("M8 the higher required level bandage is chosen",
    body("PA Bandage") == "#showtooltip\n/use [help,nodead][@player] item:6451", body("PA Bandage"))
check("M9 the bandage body carries the target conditional",
    body("PA Bandage"):find("[help,nodead][@player]", 1, true) ~= nil, body("PA Bandage"))

HARNESS.carry(LATE_BANDAGE, FOOD, WATER)
rebuild()
check("M8 a bandage above the player's level is not chosen",
    body("PA Bandage") == "#showtooltip", body("PA Bandage"))

HARNESS.carry(BANDAGE, FOOD, WATER)
rebuild()
check("M10 a bandage is classified by subclass, with no use spell",
    body("PA Bandage") == "#showtooltip\n/use [help,nodead][@player] item:3531", body("PA Bandage"))

-- M11, M12: the zero-write diff ------------------------------------------------------------
local mark = #HARNESS.macroWrites
rebuild()
check("M11 an unchanged body makes no client write", #HARNESS.writesSince(mark) == 0,
    #HARNESS.writesSince(mark))

HARNESS.carry(BANDAGE, BETTER_FOOD, WATER)
mark = #HARNESS.macroWrites
rebuild()
check("M12 a changed body writes", #HARNESS.writesSince(mark) > 0)

-- M13, M14: combat ---------------------------------------------------------------------------
HARNESS.playerLevel = 60
HARNESS.playerInCombat = true
HARNESS.carry(BANDAGE, HIGH_FOOD, WATER)
mark = #HARNESS.macroWrites
rebuild()
check("M13 nothing is written in combat", #HARNESS.writesSince(mark) == 0)
check("M13 the phase is Held", inspect().phase == "Held", inspect().phase)
check("M13 the deferral says InCombat", inspect().lastDefer == "InCombat", inspect().lastDefer)

HARNESS.playerInCombat = false
HARNESS.fire("PLAYER_REGEN_ENABLED")
HARNESS.frame()
HARNESS.frame()
check("M13 leaving combat writes the held plan",
    body("PA Food") == "#showtooltip\n/use item:4544", body("PA Food"))

-- M42: a level we could not read (audit finding 12) --------------------------------------
HARNESS.levelReadable = false
HARNESS.carry(BANDAGE, FOOD, WATER)
mark = #HARNESS.macroWrites
rebuild()
check("M42 an unreadable level writes nothing", #HARNESS.writesSince(mark) == 0)
check("M42 the deferral says LevelUnknown", inspect().lastDefer == "LevelUnknown", inspect().lastDefer)
check("M42 and it retries", inspect().phase == "Retrying", inspect().phase)
HARNESS.levelReadable = true

-- M15: the Macros window is the gate, not the event (decision D12) ------------------------
-- The first in-game run wrote nothing because Terminal registers UPDATE_MACROS for
-- the whole session. A foreign listener must no longer hold a write back.
local otherAddonFrame = CreateFrame("Frame")
otherAddonFrame:RegisterEvent("UPDATE_MACROS")
HARNESS.carry(BANDAGE, BETTER_FOOD, WATER)
mark = #HARNESS.macroWrites
rebuild()
check("M15 another addon listening for UPDATE_MACROS does not hold the write back",
    #HARNESS.writesSince(mark) > 0, #HARNESS.writesSince(mark))
check("M15 and the body is the planned one",
    body("PA Food") == "#showtooltip\n/use item:4542", body("PA Food"))
otherAddonFrame:UnregisterEvent("UPDATE_MACROS")

-- M15b: the window itself still holds it back ----------------------------------------------
HARNESS.macroWindowShown = true
HARNESS.carry(BANDAGE, HIGH_FOOD, WATER)
HARNESS.playerLevel = 60
mark = #HARNESS.macroWrites
rebuild()
check("M15b an open Macros window holds the write back", #HARNESS.writesSince(mark) == 0,
    #HARNESS.writesSince(mark))
check("M15b the deferral names the window",
    inspect().lastDefer == "MacroWindowOpen", inspect().lastDefer)
check("M15b and /pa consumables says the window is open",
    inspect().macroWindow == "open", inspect().macroWindow)
HARNESS.macroWindowShown = false
rebuild()
check("M15b closing it lets the next rebuild through",
    body("PA Food") == "#showtooltip\n/use item:4544", body("PA Food"))
HARNESS.playerLevel = 40

-- M41: a window whose shown state cannot be read counts as open ----------------------------
HARNESS.macroWindowReadable = false
HARNESS.carry(BANDAGE, FOOD, WATER)
mark = #HARNESS.macroWrites
rebuild()
check("M41 an unreadable window writes nothing", #HARNESS.writesSince(mark) == 0,
    #HARNESS.writesSince(mark))
check("M41 the deferral says MacroWindowUnknown",
    inspect().lastDefer == "MacroWindowUnknown", inspect().lastDefer)
HARNESS.macroWindowReadable = true

-- M41b: before the window's addon loads, MacroFrame is nil and writing is clear ------------
local priorWindow = MacroFrame
MacroFrame = nil
check("M41b an unloaded Macros window reads as not loaded",
    inspect().macroWindow == "not loaded", inspect().macroWindow)
HARNESS.carry(BANDAGE, BETTER_FOOD, WATER)
mark = #HARNESS.macroWrites
rebuild()
check("M41b and the write goes through", #HARNESS.writesSince(mark) > 0)
MacroFrame = priorWindow

-- M34, M35: the classification cache (audit finding 13) -----------------------------------
HARNESS.carry(SPELLLESS, FOOD, WATER, BANDAGE)
rebuild()
HARNESS.itemSpellCalls = 0
rebuild()
check("M34 a loaded consumable with no use spell is cached, so it is not asked again",
    HARNESS.itemSpellCalls == 0, HARNESS.itemSpellCalls)
check("M34 and it does not count as could-not-tell", inspect().couldNotTell == 0,
    inspect().couldNotTell)

HARNESS.carry(UNLOADED, FOOD, WATER, BANDAGE)
rebuild()
check("M35 an unloaded item counts as could not tell", inspect().couldNotTell == 1,
    inspect().couldNotTell)
HARNESS.itemInfoCalls = 0
rebuild()
check("M35 and it is asked again rather than cached", (HARNESS.itemInfoCalls or 0) > 0,
    HARNESS.itemInfoCalls)

-- M36, M37: renaming (audit finding 3) ----------------------------------------------------
HARNESS.carry(BANDAGE, FOOD, WATER)
rebuild()
local before = HARNESS.countMacrosNamed("PA Food")
setSetting("foodMacroName", "PA Chow")
rebuild()
check("M36 a rename renames the macro the client still holds",
    HARNESS.macroNamed("PA Chow") ~= nil, "PA Chow missing")
check("M36 and creates no duplicate", HARNESS.countMacrosNamed("PA Food") == before - 1,
    HARNESS.countMacrosNamed("PA Food"))
check("M36 the renamed macro kept our body",
    body("PA Chow") == "#showtooltip\n/use item:4541", body("PA Chow"))
check("M36 the view reports the new name", macroView("FoodMacro").name == "PA Chow",
    macroView("FoodMacro").name)
setSetting("foodMacroName", "PA Food")
rebuild()
check("M37 renaming back renames again rather than creating",
    HARNESS.countMacrosNamed("PA Food") == 1 and HARNESS.macroNamed("PA Chow") == nil,
    HARNESS.countMacrosNamed("PA Food"))

-- M38: two kinds sharing a name (audit finding 5) -----------------------------------------
-- distinctFrom refuses this through /pa set, so the collision is forced the way a
-- hand-edited saved file would.
check("M25 /pa set refuses a duplicate name",
    select(1, ns.ConfigStore.Set(FEATURE, "foodMacroName", "PA Heal")) == false)
local stored = ns.ConfigStore.Feature(FEATURE)
stored.settings.foodMacroName = "PA Heal"
ns.Registry.SetEnabled(FEATURE, false)
ns.Registry.SetEnabled(FEATURE, true)
HARNESS.fire("PLAYER_ENTERING_WORLD")
HARNESS.frame()
HARNESS.frame()
check("M38 the later kind is not maintained",
    macroView("FoodMacro").outcome == "NotMaintained", macroView("FoodMacro").outcome)
check("M38 and it says which kind keeps the name",
    (macroView("FoodMacro").reason or ""):find("healing", 1, true) ~= nil,
    macroView("FoodMacro").reason)
local healBody = body("PA Heal")
mark = #HARNESS.macroWrites
rebuild()
check("M38 repeated rebuilds never write for the colliding kind",
    #HARNESS.writesSince(mark) == 0 and body("PA Heal") == healBody)
stored.settings.foodMacroName = "PA Food"

-- M39: an account macro is never adopted (audit finding 9) --------------------------------
ns.Registry.SetEnabled(FEATURE, false)
HARNESS.macros = {}
HARNESS.putAccountMacro("PA Food", "-- yours")
ns.Registry.SetEnabled(FEATURE, true)
HARNESS.fire("PLAYER_ENTERING_WORLD")
HARNESS.frame()
HARNESS.frame()
check("M39 an account macro of that name is left alone",
    HARNESS.macros[1].body == "-- yours", HARNESS.macros[1].body)
check("M39 the food macro is not maintained",
    macroView("FoodMacro").outcome == "NotMaintained", macroView("FoodMacro").outcome)
check("M39 and it says the name is account-wide",
    (macroView("FoodMacro").reason or ""):find("account-wide", 1, true) ~= nil,
    macroView("FoodMacro").reason)

ns.Registry.SetEnabled(FEATURE, false)
HARNESS.macros = {}
local adopted = HARNESS.putCharacterMacro("PA Food", "-- yours")
ns.Registry.SetEnabled(FEATURE, true)
HARNESS.fire("PLAYER_ENTERING_WORLD")
HARNESS.frame()
HARNESS.frame()
check("M39 the same name as a character macro is adopted",
    HARNESS.macros[adopted].body == "#showtooltip\n/use item:4541",
    HARNESS.macros[adopted].body)

-- M40: NotCreated and NotMaintained settle in Idle (audit finding 6) ----------------------
check("M40 a settled answer leaves the machine Idle", inspect().phase == "Idle", inspect().phase)

-- M19, M20: the water macro's mana gate ----------------------------------------------------
ns.Registry.SetEnabled(FEATURE, false)
HARNESS.macros = {}
HARNESS.manaUser = false
ns.Registry.SetEnabled(FEATURE, true)
HARNESS.fire("PLAYER_ENTERING_WORLD")
HARNESS.frame()
HARNESS.frame()
check("M19 a non-mana class gets no water macro", HARNESS.macroNamed("PA Water") == nil)
check("M19 and the other three are created", HARNESS.macroNamed("PA Heal") ~= nil
    and HARNESS.macroNamed("PA Bandage") ~= nil and HARNESS.macroNamed("PA Food") ~= nil)
check("M19 /pa consumables says why",
    (macroView("WaterMacro").reason or ""):find("does not use mana", 1, true) ~= nil,
    macroView("WaterMacro").reason)

ns.Registry.SetEnabled(FEATURE, false)
HARNESS.macros = {}
HARNESS.manaUser = true
HARNESS.manaReadable = false
ns.Registry.SetEnabled(FEATURE, true)
HARNESS.fire("PLAYER_ENTERING_WORLD")
HARNESS.frame()
HARNESS.frame()
check("M20 an unreadable power type creates no water macro",
    HARNESS.macroNamed("PA Water") == nil)
check("M20 and it is not reported as an error",
    (macroView("WaterMacro").reason or ""):find("could not tell", 1, true) ~= nil,
    macroView("WaterMacro").reason)
HARNESS.manaReadable = true

-- M18: the macro cap -------------------------------------------------------------------------
ns.Registry.SetEnabled(FEATURE, false)
HARNESS.macros = {}
for index = 1, Constants.MacroConsts.MAX_CHARACTER_MACROS do
    HARNESS.putCharacterMacro("Mine " .. index)
end
ns.Registry.SetEnabled(FEATURE, true)
HARNESS.fire("PLAYER_ENTERING_WORLD")
HARNESS.frame()
HARNESS.frame()
check("M18 a full macro list creates nothing", HARNESS.macroNamed("PA Heal") == nil)
check("M18 and says the list is full",
    (macroView("HealMacro").reason or ""):find("the most the client allows", 1, true) ~= nil,
    macroView("HealMacro").reason)

-- M17: GaveUp -----------------------------------------------------------------------------
ns.Registry.SetEnabled(FEATURE, false)
HARNESS.macros = {}
local kept = HARNESS.putCharacterMacro("PA Heal", "-- old")
HARNESS.macrosReadable = false
ns.Registry.SetEnabled(FEATURE, true)
HARNESS.fire("PLAYER_ENTERING_WORLD")
HARNESS.frame()
HARNESS.advance(ns.MACROS_KNOWN_TIMEOUT + 2)
HARNESS.frame()
HARNESS.frame()
check("M17 the feature gives up", inspect().known == "GaveUp", inspect().known)
check("M17 an existing macro is still maintained",
    HARNESS.macros[kept].body ~= "-- old", HARNESS.macros[kept].body)
check("M17 and none is created", HARNESS.macroNamed("PA Food") == nil)

-- M44: GaveUp released the login subscription (audit finding 7) ---------------------------
local beforeGaveUp = #HARNESS.macroWrites
HARNESS.fire("UPDATE_MACROS")
check("M44 UPDATE_MACROS after GaveUp runs no handler of ours",
    #HARNESS.macroWrites == beforeGaveUp)
HARNESS.macrosReadable = true

-- M16: a write that delivers something unexpected ------------------------------------------
ns.Registry.SetEnabled(FEATURE, false)
HARNESS.macros = {}
-- D16 made the two action-bar events expected, so the event gate needs an
-- event spike S never measured.
HARNESS.macroInline = { { "PLAYER_ENTERING_WORLD" } }
HARNESS.expectedFaults[FEATURE] = true
ns.Registry.SetEnabled(FEATURE, true)
HARNESS.fire("PLAYER_ENTERING_WORLD")
HARNESS.frame()
HARNESS.frame()
check("M16 an unexpected inline event faults the feature",
    inspect().phase == "Faulted", inspect().phase)
check("M16 and the fault names the event",
    (inspect().faultReason or ""):find("PLAYER_ENTERING_WORLD", 1, true) ~= nil,
    inspect().faultReason)
mark = #HARNESS.macroWrites
rebuild()
check("M16 and no further write happens this UI load", #HARNESS.writesSince(mark) == 0)
HARNESS.macroInline = {}

-- M43: disable releases every timer and subscription (audit findings 7, 8) ----------------
ns.Registry.SetEnabled(FEATURE, false)
HARNESS.macros = {}
HARNESS.carry(STONE, POTION, FOOD, WATER, BANDAGE)
HARNESS.cooldowns[STONE] = 60
HARNESS.levelReadable = false
ns.Registry.SetEnabled(FEATURE, true)
HARNESS.fire("PLAYER_ENTERING_WORLD")
HARNESS.frame()
HARNESS.frame()
check("M43 a retry is outstanding", inspect().phase == "Retrying", inspect().phase)
ns.Registry.SetEnabled(FEATURE, false)
HARNESS.levelReadable = true
mark = #HARNESS.macroWrites
HARNESS.advance(ns.MACRO_RETRY_MAXIMUM_DELAY + 90)
check("M43 no timer fires into a disabled feature", #HARNESS.writesSince(mark) == 0,
    #HARNESS.writesSince(mark))
HARNESS.cooldowns[STONE] = nil

-- M21: two equal names in the saved file ----------------------------------------------------
HARNESS.macros = {}
stored = ns.ConfigStore.Feature(FEATURE)
stored.settings.healMacroName = "PA Both"
stored.settings.bandageMacroName = "PA Both"
ns.Registry.SetEnabled(FEATURE, true)
HARNESS.fire("PLAYER_ENTERING_WORLD")
HARNESS.frame()
HARNESS.frame()
check("M21 only one macro carries the shared name", HARNESS.countMacrosNamed("PA Both") == 1,
    HARNESS.countMacrosNamed("PA Both"))
check("M21 and the heal macro is the one that keeps it",
    macroView("HealMacro").outcome ~= "NotMaintained"
    and macroView("BandageMacro").outcome == "NotMaintained",
    macroView("BandageMacro").outcome)
stored.settings.healMacroName = "PA Heal"
stored.settings.bandageMacroName = "PA Bandage"

-- M22, M23, M24, M25: the text bound --------------------------------------------------------
local ok, reason = ns.ConfigStore.Set(FEATURE, "healMacroName", "PA Seventeen Char")
check("M22 a 17-character name is refused", ok == false)
check("M22 and the message names the bound",
    tostring(reason):find("at most 16 characters", 1, true) ~= nil, reason)

ok = ns.ConfigStore.Set(FEATURE, "healMacroName", "")
check("M23 an empty name is refused", ok == false)

ok = ns.ConfigStore.Set(FEATURE, "healMacroName", "PA\nHeal")
check("M24 a name holding a line break is refused", ok == false)

ok, reason = ns.ConfigStore.Set(FEATURE, "healMacroName", "pa food")
check("M25 a name differing only in case is refused", ok == false)
check("M25 and names the key it collides with",
    tostring(reason):find("foodMacroName", 1, true) ~= nil, reason)

ok = ns.ConfigStore.Set(FEATURE, "healMacroName", "PA Heal 2")
check("M26 an acceptable name is taken", ok == true)
ns.ConfigStore.Set(FEATURE, "healMacroName", "PA Heal")

check("M22 a non-string name is refused",
    select(1, ns.ConfigStore.Set(FEATURE, "healMacroName", 7)) == false)

-- M27, M28: the queue ------------------------------------------------------------------------
ns.Registry.SetEnabled(FEATURE, false)
HARNESS.macros = {}
ns.Registry.SetEnabled(FEATURE, true)
check("M27 a trigger before macros are known runs nothing",
    #HARNESS.macroWrites == #HARNESS.macroWrites)
HARNESS.fire("BAG_UPDATE_DELAYED")
HARNESS.frame()
check("M27 nothing is created while Waiting", HARNESS.macroNamed("PA Heal") == nil)
HARNESS.fire("PLAYER_ENTERING_WORLD")
HARNESS.frame()
HARNESS.frame()
check("M27 leaving Waiting runs exactly one rebuild", HARNESS.macroNamed("PA Heal") ~= nil)

mark = #HARNESS.macroWrites
HARNESS.carry(BIG_STONE, POTION, BETTER_FOOD, CONJURED_WATER, BIG_BANDAGE)
HARNESS.fire("BAG_UPDATE_DELAYED")
HARNESS.fire("BAG_UPDATE_COOLDOWN")
HARNESS.fire("PLAYER_LEVEL_UP", 41)
HARNESS.frame()
HARNESS.frame()
local writes = HARNESS.writesSince(mark)
check("M28 three triggers in one frame produce one rebuild's writes",
    #writes > 0 and #writes <= 4, #writes)

-- M31: disable deletes nothing -----------------------------------------------------------------
local healBefore = body("PA Heal")
ns.Registry.SetEnabled(FEATURE, false)
check("M31 disable leaves every macro in place",
    body("PA Heal") == healBefore and HARNESS.macroNamed("PA Water") ~= nil)
ns.Registry.SetEnabled(FEATURE, true)
HARNESS.fire("PLAYER_ENTERING_WORLD")
HARNESS.frame()
HARNESS.frame()

-- M32, M33: the cache --------------------------------------------------------------------------
for index = 1, ns.CLASSIFICATION_CACHE_CAPACITY + 8 do
    HARNESS.addConsumable(500000 + index, { spell = "Food", requiredLevel = 1, itemLevel = index })
end
local many = {}
for index = 1, ns.CLASSIFICATION_CACHE_CAPACITY + 8 do
    many[index] = 500000 + index
end
HARNESS.bags[0] = { size = #many, locked = {}, items = many }
rebuild()
check("M32 overflowing the cache does not raise and still plans a body",
    body("PA Food") ~= nil and body("PA Food") ~= "#showtooltip", body("PA Food"))

HARNESS.addConsumable(700001, { classID = 4, spell = "Food" })
HARNESS.spellCallsFor = {}
HARNESS.carry(700001, FOOD, WATER, BANDAGE)
rebuild()
check("M33 a non-consumable never reaches the spell read",
    (HARNESS.spellCallsFor[700001] or 0) == 0, HARNESS.spellCallsFor[700001])
check("M33 and it is answered from the instant read alone",
    body("PA Food") == "#showtooltip\n/use item:4541", body("PA Food"))

-- M29: one cooldown timer at a time --------------------------------------------------------------
HARNESS.carry(STONE, POTION, FOOD, WATER, BANDAGE)
HARNESS.cooldowns[STONE] = 45
rebuild()
check("M29 a cooldown schedules a timer", inspect().cooldownPending == true)
rebuild()
check("M29 a second rebuild replaces it rather than adding one",
    inspect().cooldownPending == true)
HARNESS.cooldowns[STONE] = nil
rebuild()
check("M29 and a ready plan clears it", inspect().cooldownPending == false)

-- M48-M52: Forever's food and water, as S5 actually found them (D14, §2.8) ---------------------------
-- The use spell is "Nutritious Food", not spell 433's "Food", so the subclass carries
-- the signal and the tooltip's restore line splits food from water.
local FOREVER_FOOD = HARNESS.addConsumable(2681, {
    subClassID = 5, requiredLevel = 1, itemLevel = 10,
    spell = "Nutritious Food", restores = "health", wellFed = true,
})
local FOREVER_FOOD_BETTER = HARNESS.addConsumable(6290, {
    subClassID = 5, requiredLevel = 20, itemLevel = 30,
    spell = "Nutritious Food", restores = "health", wellFed = true,
})
local FOREVER_WATER = HARNESS.addConsumable(1179, {
    subClassID = 5, requiredLevel = 5, itemLevel = 15,
    spell = "Refreshing Drink", restores = "mana",
})
local FOREVER_CONJURED_WATER = HARNESS.addConsumable(8078, {
    subClassID = 5, requiredLevel = 1, itemLevel = 5,
    spell = "Refreshing Drink", restores = "mana", conjured = true,
})
local UNTELLABLE_FOODDRINK = HARNESS.addConsumable(55555, {
    subClassID = 5, requiredLevel = 1, itemLevel = 1, spell = "Mystery Snack",
})

HARNESS.carry(FOREVER_FOOD, FOREVER_FOOD_BETTER, FOREVER_WATER, BANDAGE)
rebuild()
check("M48 food is found by subclass even though its spell is not spell 433's name",
    body("PA Food") == "#showtooltip\n/use item:6290", body("PA Food"))
check("M49 water is told from food by what it restores",
    body("PA Water") == "#showtooltip\n/use item:1179", body("PA Water"))

HARNESS.carry(FOREVER_WATER, FOREVER_CONJURED_WATER, FOREVER_FOOD, BANDAGE)
rebuild()
check("M50 conjured water still wins on conjuredFirst",
    body("PA Water") == "#showtooltip\n/use item:8078", body("PA Water"))

-- M51: skipBuffFood is off by default, because every Forever food grants Well Fed.
-- Read from the registered default, not the live store, so no earlier block can
-- make this pass or fail by what it left behind.
check("M51 skipBuffFood ships off",
    ns.Registry.Defaults(FEATURE).settings.skipBuffFood == false,
    tostring(ns.Registry.Defaults(FEATURE).settings.skipBuffFood))
HARNESS.carry(FOREVER_FOOD, FOREVER_WATER, BANDAGE)
rebuild()
check("M51 so Well Fed food is still chosen",
    body("PA Food") == "#showtooltip\n/use item:2681", body("PA Food"))
setSetting("skipBuffFood", true)
rebuild()
check("M51 and switching it on excludes it again",
    body("PA Food") == "#showtooltip", body("PA Food"))
setSetting("skipBuffFood", false)

-- M52: a subclass-5 item whose tooltip says neither is never guessed at
HARNESS.carry(UNTELLABLE_FOODDRINK, BANDAGE)
rebuild()
check("M52 an untellable food-or-drink is left out, not guessed as food",
    body("PA Food") == "#showtooltip" and body("PA Water") == "#showtooltip",
    body("PA Food"))
check("M52 and it is counted as could not tell", inspect().couldNotTell >= 1,
    inspect().couldNotTell)

-- M53-M56: a slotted macro IS rewritten, and the taint reading is the guard (D16) ------------------
-- S1 showed EditMacro on a slotted macro delivers both action-bar events. Those are
-- expected now; the fault comes from the harm, not the event.
HARNESS.carry(FOREVER_FOOD, FOREVER_WATER, BANDAGE)
rebuild()
HARNESS.placeOnBar("PA Food", 7)
HARNESS.carry(FOREVER_FOOD_BETTER, FOREVER_WATER, BANDAGE)
HARNESS.macroInline = { { "ACTIONBAR_SLOT_CHANGED", 7 }, { "ACTION_RANGE_CHECK_UPDATE", 7, true, true } }
mark = #HARNESS.macroWrites
rebuild()
check("M53 a slotted macro is rewritten when activeBar stays secure",
    body("PA Food") == "#showtooltip\n/use item:6290", body("PA Food"))
check("M53 the write happened", #HARNESS.writesSince(mark) > 0)
check("M53 and the feature did not fault over the events alone",
    inspect().phase ~= "Faulted", inspect().phase)
check("M53 /pa consumables shows which slot carries the risk",
    macroView("FoodMacro").actionSlot == 7, macroView("FoodMacro").actionSlot)
check("M53 and reports activeBar secure", inspect().activeBar == "Secure", inspect().activeBar)

-- M54: the harm itself faults, and stops further writes
HARNESS.activeBarTaintedBy = ns.ADDON_NAME
HARNESS.expectedFaults[FEATURE] = true
HARNESS.carry(FOREVER_FOOD, FOREVER_WATER, BANDAGE)
rebuild()
check("M54 activeBar tainted by us faults the feature",
    inspect().phase == "Faulted", inspect().phase)
check("M54 and the fault says a pad press may be refused",
    (inspect().faultReason or ""):find("refused in our name", 1, true) ~= nil,
    inspect().faultReason)
mark = #HARNESS.macroWrites
rebuild()
check("M54 no further macro is written this session", #HARNESS.writesSince(mark) == 0)
HARNESS.activeBarTaintedBy = nil

-- M55: someone else's taint is said once, not faulted over
ns.Registry.SetEnabled(FEATURE, false)
HARNESS.macros = {}
HARNESS.clearBars()
HARNESS.activeBarTaintedBy = "SomeOtherAddon"
ns.Registry.SetEnabled(FEATURE, true)
HARNESS.fire("PLAYER_ENTERING_WORLD")
HARNESS.frame()
HARNESS.frame()
check("M55 another addon's taint does not fault us", inspect().phase ~= "Faulted",
    inspect().phase)
check("M55 and the macros are still written", HARNESS.macroNamed("PA Food") ~= nil)
HARNESS.activeBarTaintedBy = nil

-- M56: a harm we cannot see is not a pass
ns.Registry.SetEnabled(FEATURE, false)
HARNESS.macros = {}
HARNESS.secureVariableReadable = false
HARNESS.expectedFaults[FEATURE] = true
ns.Registry.SetEnabled(FEATURE, true)
HARNESS.fire("PLAYER_ENTERING_WORLD")
HARNESS.frame()
HARNESS.frame()
check("M56 a taint reading we cannot take faults rather than continuing",
    inspect().phase == "Faulted", inspect().phase)
HARNESS.secureVariableReadable = true
HARNESS.macroInline = {}

-- M57: creation is still allowed, because CreateMacro was measured clean ----------------------------
ns.Registry.SetEnabled(FEATURE, false)
HARNESS.macros = {}
HARNESS.clearBars()
HARNESS.carry(FOREVER_FOOD, FOREVER_WATER, BANDAGE, POTION)
ns.Registry.SetEnabled(FEATURE, true)
HARNESS.fire("PLAYER_ENTERING_WORLD")
HARNESS.frame()
HARNESS.frame()
check("M57 a fresh macro is still created with its body",
    body("PA Food") == "#showtooltip\n/use item:2681", body("PA Food"))

-- /pa set with a name that has a space in it ---------------------------------------------------------
-- The macro names are the first settings whose values contain spaces, and /pa set is
-- the only way to change them, so the command has to take the whole rest of the line.
slash("set consumableMacros foodMacroName PA Rations")
check("/pa set keeps every word of a name",
    ns.ConfigStore.Get(FEATURE, "foodMacroName") == "PA Rations",
    ns.ConfigStore.Get(FEATURE, "foodMacroName"))
HARNESS.frame()
HARNESS.frame()
check("and the macro is renamed to it", HARNESS.macroNamed("PA Rations") ~= nil)

local chatMark = #HARNESS.chat
slash("set consumableMacros foodMacroName")
local saidUsage = false
for index = chatMark + 1, #HARNESS.chat do
    if tostring(HARNESS.chat[index]):find("usage: /pa set", 1, true) then saidUsage = true end
end
check("/pa set with no value says so", saidUsage)
slash("set consumableMacros foodMacroName PA Food")
HARNESS.frame()
HARNESS.frame()

-- /pa consumables (section 8) ----------------------------------------------------------------------
chatMark = #HARNESS.chat
slash("consumables")
local said, saidWhy = false, false
for index = chatMark + 1, #HARNESS.chat do
    local line = tostring(HARNESS.chat[index])
    if line:find("path=edit", 1, true) then said = true end
    if line:find("uses:", 1, true) then saidWhy = true end
end
check("the command reports the write path", said)
check("the command reports what each macro uses", saidWhy)

-- The spike's route is gone (Phase 18 section 11.4) ------------------------------------------------
-- Spike S answered every question Phase 16 section 2.6 records, so the probe and
-- its route went with the design that needed them. Checked as an absence rather
-- than deleted outright: a probe that came back would be a spike feature shipping
-- to a player, and the old block here was conditional on ns.MacroProbe, so it
-- would have gone quiet instead of failing.
check("the macro probe is gone", ns.MacroProbe == nil)
-- /pa help is the route's only advertisement, so its absence there is the check.
local helpMark = #HARNESS.chat
slash("help")
-- "/pa probe" only. The fault and failed-enable probes are substrate and stay
-- listed; it is the spike route that went.
local offeredProbe = false
for index = helpMark + 1, #HARNESS.chat do
    if tostring(HARNESS.chat[index]):find("/pa probe", 1, true) then offeredProbe = true end
end
check("and /pa help no longer offers a probe route", not offeredProbe)

-- Report --------------------------------------------------------------------------------------------
local errors = {}
for _, line in ipairs(HARNESS.chat) do
    if line:find("raised", 1, true) or (line:find("faulted", 1, true) and not HARNESS.expectedFaults[FEATURE]) then
        errors[#errors + 1] = line
    end
end
HARNESS_RESULT = { passed = passed, failures = failures, errors = errors, chat = HARNESS.chat }
