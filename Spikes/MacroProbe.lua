-- Spikes/MacroProbe.lua
-- Spike S: does writing a macro taint the Gamepad action bar?
--
-- TEMPORARY. Deleted with its `/pa probe macros` and `/pa probe consumables`
-- routes once Phase 16 section 2.6 records the answers, as Phase 15's
-- GuildNameProbe and Phase 14's BarHeightProbe were. An internal feature, off by
-- default, that switches itself on at the first command and calls nothing until
-- then.
--
-- WHY A PROBE, AND WHY NOW. The edit path of Phase 16 section 5 rewrites a macro
-- body. If EditMacro delivers ACTIONBAR_SLOT_CHANGED before it returns, the
-- Gamepad page unit chooses its active bar again and writes `activeBar` in OUR
-- execution (PageUnit.lua:248 -> :528). That field is read at :546-547, and
-- GAPBugs01 section 2.9 traced refused pad jumps to exactly that read. So a pad
-- press after one of our writes would be refused in PersonalAddon's name.
--
-- Phase 12 section 9.5 proposed answering this passively, from DrinkBot's and
-- AutoPotion's sessions. That route produced no evidence (Phase 16 section 1.5):
-- no taint.log was written at all, and both addons are now disabled, so nothing
-- is left rewriting macros after every fight. This probe is the remaining way.
--
-- THREE INSTRUMENTS, BECAUSE THEY ANSWER DIFFERENT THINGS.
--
-- 1. CallWindow.Capture says WHICH events arrived inside the call (S1, S3) and
--    which frames listen for them (S2). Phase 16 section 5.4's listener check
--    depends on that list, so nothing else can replace it.
-- 2. issecurevariable(GamepadMainActionBarFramePageUnit, "activeBar") says
--    whether the carrier is NOW TAINTED and who the client blames (S9). Taint
--    attaches to the variable, so the question has a real answer whether or not
--    the field holds a value today -- which is the mistake /pa taint's first
--    suspect list made (Core/Debug.lua:485-490).
-- 3. A refused pad press says the taint reached a protected path. That needs a
--    person with a controller, and BugGrabber hides the dialog, so it is the
--    confirmation rather than the measurement.
--
-- 1 and 2 together are deterministic and cost one command. This probe runs both
-- around every write and prints them side by side.
--
-- WHAT IT DOES NOT DO. It installs no hook, keeps no timer past its own report,
-- and makes no client call until one of its commands is typed.

local ADDON_NAME, ns = ...

local FEATURE_ID = "macroProbe"

local format, type, tostring, pairs, ipairs =
    string.format, type, tostring, pairs, ipairs
local concat = table.concat
local ClientRead = ns.ClientRead

local PROBE_MACRO = "PA Probe"
local PROBE_MACRO_OFF_SLOT = "PA Probe2"

-- Every probe macro's name starts with this, so `clean` can find them all and
-- nothing of the player's is ever matched.
local PROBE_PREFIX = "PA Probe"

-- The name-length test needs a name no earlier run can already hold. The first run
-- of this probe reported "SHORTENED to 'PA Probe'" for an 18-character name that was
-- in fact stored in full, twice: a leftover macro of that name made the
-- already-exists branch fire, and the fallback then prefix-searched its way onto an
-- unrelated macro. The length is what is being measured, so it is built rather than
-- written out, and the answer is read back from the macro itself.
local LONG_NAME_LENGTH = 24
local function longName()
    local stamp = tostring((_G.time and _G.time() or 0) % 100000)
    local base = PROBE_PREFIX .. " L" .. stamp
    return base .. string.rep("x", LONG_NAME_LENGTH - #base)
end

local state = {
    enabled = false,
    tokens = {},
    loginWatch = false,
    enteringWorldAt = nil,
    macrosSeen = {},
}

-- Chat is not a record. The first run of this probe printed its whole report to
-- chat and none of it survived: BetterForeverChat persists only the General tab's
-- own lines, so S1, S2 and S9's readings were gone by the time anyone looked. Phase
-- 15's probe had already solved this with PersonalAddonSpikeLog, and this is the
-- same thing -- every line goes to chat AND to a saved variable, so the report can
-- be read off disk after the client quits.
local function spikeLog()
    if type(_G.PersonalAddonSpikeLog) ~= "table" then
        _G.PersonalAddonSpikeLog = { spike = "S", lines = {} }
    end
    local log = _G.PersonalAddonSpikeLog
    if type(log.lines) ~= "table" then
        log.lines = {}
    end
    return log
end

local function say(text)
    ns.Log.Info("[spike S] " .. text)
    local log = spikeLog()
    log.lines[#log.lines + 1] = format("%s %s",
        _G.date and _G.date("%H:%M:%S") or "", tostring(text))
    log.build = _G.GetBuildInfo and select(2, _G.GetBuildInfo()) or nil
    log.addonVersion = ns.VERSION
end

-- A warning or an error is still part of the report, so it lands in the log too.
local function sayWarn(text)
    ns.Log.Warn("[spike S] " .. text)
    local log = spikeLog()
    log.lines[#log.lines + 1] = format("%s WARN %s",
        _G.date and _G.date("%H:%M:%S") or "", tostring(text))
end

local function sayError(text)
    ns.Log.Error("[spike S] " .. text)
    local log = spikeLog()
    log.lines[#log.lines + 1] = format("%s ERROR %s",
        _G.date and _G.date("%H:%M:%S") or "", tostring(text))
end

-- S9's instrument. The page unit is a named global: MainActionBarFrame.xml:12
-- declares <Frame name="$parentPageUnit" parentKey="PageUnit"> under
-- GamepadMainActionBarFrame (premise 47).
local function activeBarTaint()
    local reader = _G.issecurevariable
    if type(reader) ~= "function" then
        return "Unavailable", "this client does not expose issecurevariable"
    end
    local pageUnit = _G.GamepadMainActionBarFramePageUnit
    if type(pageUnit) ~= "table" then
        return "Unavailable", "GamepadMainActionBarFramePageUnit is not a table on this client"
    end
    local ok, isSecure, blamed = pcall(reader, pageUnit, "activeBar")
    if not ok then
        return "Unavailable", "issecurevariable raised"
    end
    if isSecure then
        return "Secure"
    end
    return "Tainted", tostring(blamed or "unnamed")
end

local function reportTaint(label)
    local verdict, detail = activeBarTaint()
    if verdict == "Secure" then
        say(format("  S9 %s: activeBar secure", label))
    elseif verdict == "Tainted" then
        if detail == ns.ADDON_NAME then
            sayError(format("  S9 %s: activeBar TAINTED BY US", label))
        else
            sayWarn(format("  S9 %s: activeBar tainted by %s", label,
                ns.EscapeGuard.Neutralize(detail)))
        end
    else
        sayWarn(format("  S9 %s: could not be checked -- %s", label,
            ns.EscapeGuard.Neutralize(tostring(detail))))
    end
    return verdict, detail
end

-- Who is registered for an event, so S2 names the frames rather than a count.
local function describeListeners(names)
    local listeners = ns.CallWindow.Listeners(names)
    if not listeners then
        return "unreadable (no GetFramesRegisteredForEvent)"
    end
    return ns.CallWindow.Describe(listeners)
end

-- Runs one macro call inside the window and prints S1/S2/S3 for it.
local function probeWrite(label, call)
    reportTaint("before " .. label)
    local names, ok, err = ns.CallWindow.Capture(call)
    if not ok then
        sayError(format("%s raised: %s", label,
            ns.EscapeGuard.Neutralize(tostring(err))))
        return nil
    end
    if #names == 0 then
        say(format("  %s delivered NOTHING inside the call", label))
    else
        say(format("  %s delivered: %s", label, concat(names, ", ")))
        say("  registered for those now: " .. ns.EscapeGuard.Neutralize(describeListeners(names)))
    end
    reportTaint("after " .. label)
    return names
end

local function macroIndex(name)
    local kind, index = ClientRead.Call(_G.GetMacroIndexByName, "number", name)
    if kind ~= ClientRead.PLAIN or index == 0 then
        return nil
    end
    return index
end

local function macroCounts()
    local kind, account, character = ClientRead.CallMany(_G.GetNumMacros, 2, "number")
    if kind ~= ClientRead.PLAIN then
        return nil
    end
    return account, character
end

-- S3, S7: create ----------------------------------------------------------------------

-- What the client stored for a macro we just made, read back from the index
-- CreateMacro returned rather than searched for by name. Searching by name cannot
-- tell "stored in full" from "stored shortened" when any other macro shares a
-- prefix, which is how the first run misreported S7.
local function storedName(index)
    if type(index) ~= "number" then
        return nil, "CreateMacro returned no index"
    end
    local kind, name = ClientRead.Call(_G.GetMacroInfo, "string", index)
    if kind ~= ClientRead.PLAIN then
        return nil, "the stored name could not be read (" .. tostring(kind) .. ")"
    end
    return name
end

local function commandCreate()
    say("S3, S7: CreateMacro")
    local account, character = macroCounts()
    say(format("  macros now: %s account, %s character",
        tostring(account), tostring(character)))

    -- S3 needs a name no earlier run can hold, or the whole question is skipped --
    -- which is what happened on 2026-10-11: "'PA Probe' already exists" and S3 went
    -- unanswered while the report looked complete.
    local freshName = PROBE_PREFIX .. " S" .. tostring((_G.time and _G.time() or 0) % 100000)
    local createdIndex
    probeWrite("CreateMacro", function()
        createdIndex = _G.CreateMacro(freshName, ns.MACRO_DEFAULT_ICON, "#showtooltip", true)
    end)
    say(format("  created '%s' at index %s (account macros end at %d, so %s)",
        freshName, tostring(createdIndex), 120,
        type(createdIndex) == "number" and createdIndex > 120
            and "this is a character macro" or "THIS IS NOT A CHARACTER MACRO"))

    -- S7: the name length the client will take. Built to an exact length and read
    -- back from its own index, so the answer is a measurement, not an inference.
    local long = longName()
    say(format("S7: a %d-character name", #long))
    local longIndex
    probeWrite(format("CreateMacro(%d chars)", #long), function()
        longIndex = _G.CreateMacro(long, ns.MACRO_DEFAULT_ICON, "#showtooltip", true)
    end)
    local held, why = storedName(longIndex)
    if held == nil then
        say(format("  REFUSED or unreadable: %s", tostring(why)))
    elseif held == long then
        say(format("  ACCEPTED IN FULL at %d characters, stored as '%s'", #held,
            ns.EscapeGuard.Neutralize(held)))
    else
        say(format("  SHORTENED from %d to %d characters: '%s'", #long, #held,
            ns.EscapeGuard.Neutralize(held)))
    end
    say("  whatever this says is the bound; section 7's 16 is our own choice (D13)")

    if not macroIndex(PROBE_MACRO) then
        probeWrite("CreateMacro(the one for the slot test)", function()
            _G.CreateMacro(PROBE_MACRO, ns.MACRO_DEFAULT_ICON, "#showtooltip", true)
        end)
    end
    say("now /reload, then put '" .. PROBE_MACRO .. "' on a pad action slot and run /pa probe macros edit")
    say("when the spike is done, /pa probe macros clean deletes every " .. PROBE_PREFIX .. "* macro")
end

-- Every probe macro this spike left behind. Deleting a macro clears its slot on the
-- bar, which is why nothing else in this addon ever deletes one -- here it is the
-- point, and the prefix keeps it off the player's own macros.
local function commandClean()
    local deleter = _G.DeleteMacro
    if type(deleter) ~= "function" then
        sayError("this client has no DeleteMacro")
        return
    end
    local removed = 0
    -- Deleting renumbers what follows, so the list is re-read each time rather than
    -- walked once.
    for _ = 1, 32 do
        local found
        local kind, account, character = ClientRead.CallMany(_G.GetNumMacros, 2, "number")
        if kind ~= ClientRead.PLAIN then
            break
        end
        for index = 1, account + character + 120 do
            local nameKind, name = ClientRead.Call(_G.GetMacroInfo, "string", index)
            if nameKind == ClientRead.PLAIN and name:sub(1, #PROBE_PREFIX) == PROBE_PREFIX then
                found = index
                break
            end
        end
        if not found then
            break
        end
        local names, ok = ns.CallWindow.Capture(function() deleter(found) end)
        if not ok then
            sayError("DeleteMacro raised")
            break
        end
        removed = removed + 1
        if #names > 0 then
            say(format("  DeleteMacro delivered: %s", concat(names, ", ")))
        end
    end
    say(format("deleted %d macro(s) named %s*", removed, PROBE_PREFIX))
    reportTaint("after cleaning up")
end

-- S1, S2: edit ---------------------------------------------------------------------------

local function commandEdit()
    say("S1, S2: EditMacro")
    local onSlot = macroIndex(PROBE_MACRO)
    if not onSlot then
        sayError("'" .. PROBE_MACRO .. "' does not exist; run /pa probe macros create first")
        return
    end

    say("  the macro that IS on a pad action slot:")
    say("  (if it is not on one, put it there with the action bar editor first -- a macro")
    say("   on no slot raises no slot change, and the test is then vacuous)")
    probeWrite("EditMacro(on a slot)", function()
        _G.EditMacro(onSlot, nil, nil, "#showtooltip\n/use item:159")
    end)

    if not macroIndex(PROBE_MACRO_OFF_SLOT) then
        probeWrite("CreateMacro(second, for the off-slot case)", function()
            _G.CreateMacro(PROBE_MACRO_OFF_SLOT, ns.MACRO_DEFAULT_ICON, "#showtooltip", true)
        end)
    end
    local offSlot = macroIndex(PROBE_MACRO_OFF_SLOT)
    if offSlot then
        say("  the macro that is on NO slot:")
        probeWrite("EditMacro(off any slot)", function()
            _G.EditMacro(offSlot, nil, nil, "#showtooltip\n/use item:1179")
        end)
    end

    say("The decision rule (Phase 16 section 2.5):")
    say("  nothing delivered, activeBar still secure -> the edit path ships")
    say("  UPDATE_MACROS only, no frame listed with the Macros window closed -> edit path")
    say("  ACTIONBAR_SLOT_CHANGED, or activeBar tainted by us -> the click path instead")
    say("now /reload")
end

-- S4: when are macros readable? -------------------------------------------------------------

local function commandLogin()
    state.loginWatch = true
    state.macrosSeen = {}
    say("S4: watching when this character's macros become readable.")
    say("  Now log out and back in, then /reload once. The report prints five")
    say("  seconds after each entry into the world.")
end

local function noteReadable(moment)
    local account, character = macroCounts()
    state.macrosSeen[#state.macrosSeen + 1] = format("%s: %s account, %s character",
        moment, tostring(account), tostring(character))
end

local function onLoginEvent(eventName)
    if not state.loginWatch then
        return
    end
    if eventName == "PLAYER_LOGIN" then
        noteReadable("at PLAYER_LOGIN")
    elseif eventName == "PLAYER_ENTERING_WORLD" then
        state.enteringWorldAt = _G.GetTime and _G.GetTime() or 0
        noteReadable("at PLAYER_ENTERING_WORLD")
        if _G.C_Timer and _G.C_Timer.After then
            _G.C_Timer.After(0, function()
                noteReadable("one frame after PLAYER_ENTERING_WORLD")
            end)
            _G.C_Timer.After(5, function()
                noteReadable("five seconds after PLAYER_ENTERING_WORLD")
                say("S4 report:")
                for _, line in ipairs(state.macrosSeen) do
                    say("  " .. line)
                end
                say("  the first reading that is not nil or secret picks section 5.3's rule")
            end)
        end
    elseif eventName == "UPDATE_MACROS" then
        -- S4's third candidate, and the one that decides whether a subscription is
        -- needed at all: does it arrive with no Lua caller on its stack?
        local inline = ns.CallWindow.Describe and "" or ""
        noteReadable("at the first UPDATE_MACROS" .. inline)
    end
end

-- S5: classification ------------------------------------------------------------------------

local function commandConsumables()
    say("S5: every consumable in your bags, as the classifier sees it")
    local names = {}
    local getName = _G.C_Spell and _G.C_Spell.GetSpellName
    for field, spellId in pairs(ns.CONSUMABLE_REFERENCE_SPELLS) do
        local kind, name = ClientRead.Call(getName, "string", spellId)
        names[#names + 1] = format("%s(%d)=%s", field, spellId,
            kind == ClientRead.PLAIN and ns.EscapeGuard.Neutralize(name) or "<" .. kind .. ">")
    end
    local conjuredKind, conjured = ClientRead.Classify(_G.ITEM_CONJURED, "string")
    names[#names + 1] = "ITEM_CONJURED=" .. (conjuredKind == ClientRead.PLAIN
        and ns.EscapeGuard.Neutralize(conjured) or "<" .. conjuredKind .. ">")
    -- D14's two words: how a subclass-5 item is told to be food or water.
    local healthKind, healthWord = ClientRead.Classify(_G.HEALTH, "string")
    local manaKind, manaWord = ClientRead.Classify(_G.MANA, "string")
    names[#names + 1] = "HEALTH=" .. (healthKind == ClientRead.PLAIN
        and ns.EscapeGuard.Neutralize(healthWord) or "<" .. healthKind .. ">")
    names[#names + 1] = "MANA=" .. (manaKind == ClientRead.PLAIN
        and ns.EscapeGuard.Neutralize(manaWord) or "<" .. manaKind .. ">")
    say("  references: " .. concat(names, " "))

    local container = _G.C_Container
    if type(container) ~= "table" or type(container.GetContainerItemID) ~= "function" then
        sayError("this client has no C_Container.GetContainerItemID")
        return
    end
    local bandageSubclass = _G.Enum and _G.Enum.ItemConsumableSubclass
        and _G.Enum.ItemConsumableSubclass.Bandage or 7
    local consumableClass = _G.Enum and _G.Enum.ItemClass and _G.Enum.ItemClass.Consumable or 0
    local seen, rows = {}, 0
    for bag = 0, 4 do
        local ok, slots = pcall(container.GetContainerNumSlots, bag)
        if ok and type(slots) == "number" then
            for slot = 1, slots do
                local idOk, itemId = pcall(container.GetContainerItemID, bag, slot)
                if idOk and ClientRead.Classify(itemId, "number") == ClientRead.PLAIN
                    and not seen[itemId] then
                    seen[itemId] = true
                    local instant = _G.C_Item and _G.C_Item.GetItemInfoInstant
                    local instantOk, _, _, _, _, _, classID, subClassID = pcall(instant, itemId)
                    if instantOk and classID == consumableClass then
                        rows = rows + 1
                        local infoOk, itemName, _, _, itemLevel, requiredLevel =
                            pcall(_G.C_Item.GetItemInfo, itemId)
                        local spellOk, spellName = pcall(_G.C_Item.GetItemSpell, itemId)
                        local cooldownOk, startedAt, duration =
                            pcall(container.GetItemCooldown, itemId)
                        say(format("  %d %s: subclass=%s%s required=%s itemLevel=%s spell=%s cooldown=%s",
                            itemId,
                            infoOk and ClientRead.Classify(itemName, "string") == ClientRead.PLAIN
                                and ns.EscapeGuard.Neutralize(itemName) or "<unreadable>",
                            tostring(subClassID),
                            subClassID == bandageSubclass and " (BANDAGE)" or "",
                            tostring(infoOk and requiredLevel or "?"),
                            tostring(infoOk and itemLevel or "?"),
                            spellOk and ClientRead.Classify(spellName, "string") == ClientRead.PLAIN
                                and ns.EscapeGuard.Neutralize(spellName) or "<none>",
                            cooldownOk and format("%s/%s", tostring(startedAt), tostring(duration))
                                or "<unreadable>"))
                        if ns.HEALTHSTONE_ITEMS[itemId] then
                            say("    in the healthstone list")
                        end
                        -- S5's second half: is anything delivered while a tooltip
                        -- is read? TOOLTIP_DATA_UPDATE is a UniqueEvent, so the
                        -- expected answer is nothing (premise 44).
                        local lines
                        local delivered = ns.CallWindow.Capture(function()
                            lines = _G.C_TooltipInfo and _G.C_TooltipInfo.GetItemByID(itemId)
                        end)
                        if #delivered > 0 then
                            sayWarn(format("    reading its tooltip delivered: %s",
                                concat(delivered, ", ")))
                        end
                        local lineKind, lineList = ClientRead.Field(lines or {}, "lines", "table")
                        if lineKind == ClientRead.PLAIN then
                            -- The verdict the classifier would reach for a
                            -- subclass-5 item, printed beside its evidence, so the
                            -- food/water split can be judged rather than assumed
                            -- (D14). Run this carrying water AND food.
                            local sawConjured, sawWellFed, restores = false, false, nil
                            for index = 1, #lineList do
                                local textKind, text =
                                    ClientRead.Field(lineList[index], "leftText", "string")
                                if textKind == ClientRead.PLAIN then
                                    local folded = text:lower()
                                    if conjuredKind == ClientRead.PLAIN and text == conjured then
                                        sawConjured = true
                                    end
                                    if folded:find("well fed", 1, true) then
                                        sawWellFed = true
                                    end
                                    if not restores then
                                        if healthKind == ClientRead.PLAIN
                                            and folded:find(healthWord:lower(), 1, true) then
                                            restores = "health -> Food"
                                        elseif manaKind == ClientRead.PLAIN
                                            and folded:find(manaWord:lower(), 1, true) then
                                            restores = "mana -> Drink"
                                        end
                                    end
                                    if sawConjured or sawWellFed or restores then
                                        say("    tooltip: " .. ns.EscapeGuard.Neutralize(text))
                                    end
                                end
                            end
                            if subClassID == 5 then
                                say(format("    SUBCLASS 5 verdict: %s%s%s",
                                    restores or "COULD NOT TELL -- left out of the scan",
                                    sawConjured and "; conjured" or "",
                                    sawWellFed and "; Well Fed" or ""))
                            end
                        else
                            say("    tooltip could not be read")
                        end
                    end
                end
            end
        end
    end
    if rows == 0 then
        say("  no consumables in your bags")
    end
    say("  compare this with what you are actually carrying (section 2.5): a disagreement")
    say("  changes the reference IDs or the healthstone list before anything is built")
end

-- S6, S8: the click path ------------------------------------------------------------------------
--
-- S1 ruled out the edit path (section 2.9), so section 6 is what is left: a macro
-- whose body never changes after creation, pointing at a hidden secure button of
-- ours that we re-point instead.
--
-- The question S6 really asks is narrower than "does /click work". Blizzard's
-- SECURE_ACTIONS.item sends an `item` attribute to SecureCmdUseItem, which is the
-- same path /use takes and carries no restriction. But SECURE_ACTIONS.macro sends a
-- `macrotext` attribute to C_Macro.RunMacroText, and that one is
-- HasRestrictions = true (UIMacrosDocumentation.lua:41-44): a restricted function
-- reading a value WE wrote. The healing macro's castsequence and the bandage's
-- [help,nodead][@player] can only be expressed as macrotext, so if that is refused,
-- two of the four kinds have no path at all and the click path only half works.
--
-- So the probe builds both kinds of button and asks you to press each one.

local probeButtons = {}

local function ensureButtons()
    if probeButtons.item then
        return true
    end
    if type(_G.CreateFrame) ~= "function" then
        return false
    end
    -- Rule 6: ours, parented to UIParent, never to a Blizzard frame.
    local ok, itemButton = pcall(_G.CreateFrame, "Button", "PersonalAddonProbeItemButton",
        _G.UIParent, "SecureActionButtonTemplate")
    if not ok or not itemButton then
        sayError("this client would not create a SecureActionButtonTemplate button")
        return false
    end
    local macroOk, macroButton = pcall(_G.CreateFrame, "Button", "PersonalAddonProbeMacroButton",
        _G.UIParent, "SecureActionButtonTemplate")
    if not macroOk or not macroButton then
        sayError("the second secure button could not be created")
        return false
    end
    for _, button in ipairs({ itemButton, macroButton }) do
        pcall(button.Hide, button)
        pcall(button.SetSize, button, 1, 1)
        pcall(button.SetPoint, button, "CENTER", _G.UIParent, "CENTER", 0, 0)
    end
    probeButtons.item, probeButtons.macro = itemButton, macroButton
    return true
end

local function commandClick()
    if not ensureButtons() then
        return
    end
    say("S6: the click path's two button kinds")

    -- Something cheap and stackable to point at, so a press is unmistakable.
    local itemId = 159
    local names = ns.CallWindow.Capture(function()
        probeButtons.item:SetAttribute("type", "item")
        probeButtons.item:SetAttribute("item", "item:" .. itemId)
    end)
    say(format("  item button pointed at item:%d; SetAttribute delivered: %s", itemId,
        #names > 0 and concat(names, ", ") or "nothing"))
    reportTaint("after pointing the item button")

    names = ns.CallWindow.Capture(function()
        probeButtons.macro:SetAttribute("type", "macro")
        probeButtons.macro:SetAttribute("macrotext",
            "/use [help,nodead][@player] item:" .. itemId)
    end)
    say(format("  macro button given macrotext; SetAttribute delivered: %s",
        #names > 0 and concat(names, ", ") or "nothing"))
    reportTaint("after pointing the macro button")

    say("  Now make two macros by hand in the Macros window and put them on pad slots:")
    say("    /click PersonalAddonProbeItemButton     -- expect: uses item:" .. itemId)
    say("    /click PersonalAddonProbeMacroButton    -- expect: the same, via macrotext")
    say("  Press each. Then /pa probe macros taint, and read BugGrabber.")
    say("  The macrotext one is the question that matters: C_Macro.RunMacroText is")
    say("  HasRestrictions, so a refusal there means heal and bandage have no click path.")
    say("  A refusal names PersonalAddon in /pa blocked; silence is the pass.")

    -- S8: does the icon follow the item, so #showtooltip is worth having?
    local setter = _G.SetMacroItem
    if type(setter) ~= "function" then
        say("S8: SetMacroItem is absent on this client, so a /click macro keeps the question mark")
        return
    end
    local index = macroIndex(PROBE_MACRO)
    if not index then
        say("S8: '" .. PROBE_MACRO .. "' does not exist, so the icon test is skipped")
        return
    end
    local iconNames, iconOk = ns.CallWindow.Capture(function()
        setter(index, "item:" .. itemId)
    end)
    if not iconOk then
        sayError("SetMacroItem raised")
    else
        say(format("S8: SetMacroItem delivered: %s",
            #iconNames > 0 and concat(iconNames, ", ") or "nothing"))
        reportTaint("after SetMacroItem")
        say("  look at '" .. PROBE_MACRO .. "' on your bar: if its icon is the item's, the")
        say("  click path keeps #showtooltip's icon and count; if it is a question mark, it does not")
    end
end

-- Lifecycle ------------------------------------------------------------------------------------

local function enable()
    for _, eventName in ipairs({ "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "UPDATE_MACROS" }) do
        local token = ns.Dispatch.Subscribe(FEATURE_ID, eventName, function()
            onLoginEvent(eventName)
        end)
        if token then
            state.tokens[#state.tokens + 1] = token
        end
    end
    state.enabled = true
    return true
end

local function disable()
    state.enabled = false
    state.loginWatch = false
    for index = #state.tokens, 1, -1 do
        ns.Dispatch.Unsubscribe(state.tokens[index])
        state.tokens[index] = nil
    end
end

ns.Registry.Register(FEATURE_ID, {
    enabledByDefault = false,
    internal = true,
    label = "Macro probe (spike S)",
    description = "Temporary. Answers spike S before Phase 16's write path is built.",
    settings = {},
}, {
    enable = enable,
    disable = disable,
})

-- /pa probe macros | /pa probe consumables --------------------------------------------------------

ns.MacroProbe = {
    -- Switches itself on at the first command, so nothing of it runs on a normal
    -- login (Phase 8's probe did the same).
    Run = function(subject)
        if not state.enabled then
            local ok, reason = ns.Registry.SetEnabled(FEATURE_ID, true)
            if not ok then
                ns.Log.Error("[spike S] could not enable the probe: " .. tostring(reason))
                return
            end
        end
        subject = (subject or ""):lower()
        if subject == "clear" then
            _G.PersonalAddonSpikeLog = { spike = "S", lines = {} }
            ns.Log.Info("[spike S] the saved report is empty again")
            return
        end
        if subject == "show" then
            local log = spikeLog()
            ns.Log.Info(format("[spike S] %d line(s) saved; they survive a /reload and a quit",
                #log.lines))
            for index = 1, #log.lines do
                ns.Log.Info("  " .. tostring(log.lines[index]))
            end
            return
        end
        if subject == "clean" then
            commandClean()
        elseif subject == "click" then
            commandClick()
        elseif subject == "create" then
            commandCreate()
        elseif subject == "edit" then
            commandEdit()
        elseif subject == "login" then
            commandLogin()
        elseif subject == "taint" then
            say("S9: the baseline reading, before anything is written")
            reportTaint("baseline")
            say("  a reading that is already Tainted means something else got there first:")
            say("  /reload and start the procedure again (section 2.4 step 2)")
        else
            ns.Log.Info("Every line below is also saved to PersonalAddonSpikeLog, so the")
            ns.Log.Info("report can be read off disk after you quit -- no chat copying.")
            ns.Log.Info("/pa probe macros taint    S9: is activeBar tainted right now?")
            ns.Log.Info("/pa probe macros create   S3, S7: CreateMacro, and a 17-character name")
            ns.Log.Info("/pa probe macros edit     S1, S2: EditMacro on a pad slot and off it")
            ns.Log.Info("/pa probe macros login    S4: when this character's macros become readable")
            ns.Log.Info("/pa probe macros click    S6, S8: the click path's buttons (the way forward)")
            ns.Log.Info("/pa probe consumables     S5: every consumable in your bags, as classified")
            ns.Log.Info("/pa probe macros show     print the saved report")
            ns.Log.Info("/pa probe macros clear    empty it before a fresh run")
            ns.Log.Info("/pa probe macros clean    delete every " .. PROBE_PREFIX .. "* macro afterwards")
        end
    end,

    Consumables = function()
        if not state.enabled then
            ns.Registry.SetEnabled(FEATURE_ID, true)
        end
        commandConsumables()
    end,
}
