-- Features/ConsumableMacros.lua
-- Four character macros that always use the best consumable you carry: healing,
-- bandage, food and water (Architecture/20261011-Phase16.md).
--
-- The write path is the edit path (section 5): the macro body is rewritten. Spike S
-- is the gate on that choice -- if EditMacro delivers ACTIONBAR_SLOT_CHANGED inside
-- the call, the Gamepad page unit writes activeBar in our execution and pad presses
-- are refused in our name (section 2.1). Until the spike is recorded, every write
-- runs inside CallWindow.Capture and anything delivered outside WRITE_INLINE_EVENTS
-- faults the feature rather than passing quietly.
--
-- What keeps this cheap: the planned body is compared against the current one, and
-- an unchanged body is no client write at all. AutoPotion rewrote five macros after
-- every fight regardless; that is the behaviour this replaces.

local ADDON_NAME, ns = ...

local FEATURE_ID = "consumableMacros"

local format, type, pcall, tostring, pairs =
    string.format, type, pcall, tostring, pairs
local concat = table.concat
local min = math.min

local KIND = ns.MACRO_KIND
local CONSUMABLE = ns.CONSUMABLE_KIND
-- Core loads before Features, so this is resolved at file scope rather than at
-- enable: /pa consumables reads combat state and must work before a login too.
local ClientRead = ns.ClientRead

-- The events spike S measured inside a macro write (§2.9). CreateMacro delivers
-- UPDATE_MACROS alone; EditMacro on a macro that sits on an action slot adds the
-- other two, and Blizzard listens to both -- the Gamepad page unit and the edit
-- frame's page unit for the slot change, the action buttons' range-check frame for
-- the other.
--
-- They are listed as EXPECTED rather than as a fault (D16), because the event is not
-- the harm. The harm GAPBugs01 §2.9 traced is the page unit writing `activeBar` in
-- our execution, and that write is conditional: the slot-change handler reaches it
-- only `if (actionBarToActivate)` (PageUnit.lua:600). S9 measured `activeBar` still
-- secure straight after one of these writes. So the guard asks the variable
-- afterwards (activeBarTaint) instead of inferring harm from the event list.
--
-- Anything OUTSIDE this set still faults: the set is what was measured, and a new
-- arrival is exactly what the window is for.
local WRITE_INLINE_LIST = { "UPDATE_MACROS", "ACTION_RANGE_CHECK_UPDATE", "ACTIONBAR_SLOT_CHANGED" }
local WRITE_INLINE_EVENTS = {
    UPDATE_MACROS = true,
    ACTION_RANGE_CHECK_UPDATE = true,
    ACTIONBAR_SLOT_CHANGED = true,
}

local KNOWN = { KNOWN = "Known", NOT_YET = "NotYet", GAVE_UP = "GaveUp" }

local PHASE = {
    WAITING = "Waiting",
    IDLE = "Idle",
    PENDING = "Pending",
    HELD = "Held",
    RETRYING = "Retrying",
    FAULTED = "Faulted",
}

local DEFER = {
    IN_COMBAT = "InCombat",
    COMBAT_UNKNOWN = "CombatUnknown",
    LEVEL_UNKNOWN = "LevelUnknown",
    WINDOW_OPEN = "MacroWindowOpen",
    WINDOW_UNKNOWN = "MacroWindowUnknown",
}

local WRITE = {
    UNCHANGED = "Unchanged",
    WRITTEN = "Written",
    CREATED = "Created",
    RENAMED = "Renamed",
    DEFERRED = "Deferred",
    NOT_CREATED = "NotCreated",
    NOT_MAINTAINED = "NotMaintained",
    REFUSED = "Refused",
}

-- Which consumable kinds each macro draws on, and the config keys that name it.
local MACRO_SPEC = {
    [KIND.HEAL] = { toggle = "healMacro", nameKey = "healMacroName", label = "healing" },
    [KIND.BANDAGE] = { toggle = "bandageMacro", nameKey = "bandageMacroName", label = "bandage" },
    [KIND.FOOD] = { toggle = "foodMacro", nameKey = "foodMacroName", label = "food" },
    [KIND.WATER] = { toggle = "waterMacro", nameKey = "waterMacroName", label = "water" },
}

local DEFAULT_SETTINGS = {
    healMacro = true,
    bandageMacro = true,
    foodMacro = true,
    waterMacro = true,
    conjuredFirst = true,
    -- Off, because on Forever becoming well fed is what eating normally does: both
    -- foods S5 saw say so, and with this on the food macro would never pick
    -- anything (section 2.8, D15). Phase 12's decision was taken on Classic food.
    skipBuffFood = false,
    healMacroName = "PA Heal",
    bandageMacroName = "PA Bandage",
    foodMacroName = "PA Food",
    waterMacroName = "PA Water",
}

local state = {
    enabled = false,
    phase = PHASE.WAITING,
    known = KNOWN.NOT_YET,
    dirty = false,
    enteredWorldAt = nil,

    maintainedName = {},
    collidedWith = {},
    notCreatedReason = {},
    createdThisLoad = {},
    missingThisLoad = {},
    adoptedThisLoad = {},

    rebuildToken = nil,
    retryToken = nil,
    retryCount = 0,
    cooldownToken = nil,
    macrosEventToken = nil,
    knownTimerToken = nil,

    faultReason = nil,
    lastWrite = {},
    lastPlan = {},
    lastDefer = nil,
    lastInline = nil,
    couldNotTell = 0,
    tokens = {},

    references = nil,
    classifications = {},
    classificationCount = 0,

    settings = {},
}

local function counters()
    return ns.Diagnostics.CountersFor(FEATURE_ID)
end

local function bump(name, amount)
    ns.Diagnostics.Bump(counters(), name, amount)
end

local function now()
    return _G.GetTime and _G.GetTime() or 0
end

-- Reads -----------------------------------------------------------------------------

-- Lockdown, as three answers rather than two: a read we could not take is not "out
-- of combat" (README rule 10). CombatUnknown can happen out of combat, where no
-- PLAYER_REGEN_ENABLED will ever come, so it retries instead of waiting (section 5.2).
local function combatReading()
    local kind, inCombat = ClientRead.Call(_G.InCombatLockdown, "boolean")
    if kind == ClientRead.PLAIN then
        return inCombat and DEFER.IN_COMBAT or nil
    end
    if kind == ClientRead.ABSENT then
        return nil
    end
    return DEFER.COMBAT_UNKNOWN
end

-- UnitLevel carries no SecretWhen* flag on this client, so a withheld level is not
-- a path; CALL_FAILED and UNEXPECTED_TYPE are, which is what this covers. Ranking
-- against a level we could not read would name an item the character cannot use
-- (section 4.2, audit finding 12).
local function playerLevel()
    local kind, level = ClientRead.Call(_G.UnitLevel, "number", "player")
    if kind ~= ClientRead.PLAIN then
        return nil
    end
    return level
end

local function usesMana()
    local kind, power = ClientRead.Call(_G.UnitPowerType, "number", "player")
    if kind ~= ClientRead.PLAIN then
        return nil
    end
    local mana = _G.Enum and _G.Enum.PowerType and _G.Enum.PowerType.Mana or 0
    return power == mana
end

-- The localized names the classifier compares against, read once per UI load. Only
-- the spell IDs are ours; every string comes from the client, so this works in any
-- locale (section 4.1).
local function referenceNames()
    if state.references then
        return state.references
    end
    local references = {}
    local getName = _G.C_Spell and _G.C_Spell.GetSpellName
    for field, spellId in pairs(ns.CONSUMABLE_REFERENCE_SPELLS) do
        local kind, name = ClientRead.Call(getName, "string", spellId)
        if kind == ClientRead.PLAIN and name ~= "" then
            references[field] = name
        end
    end
    local kind, conjured = ClientRead.Classify(_G.ITEM_CONJURED, "string")
    if kind == ClientRead.PLAIN and conjured ~= "" then
        references.conjured = conjured
    end
    -- The words for what a consumable restores, which is how food is told from water
    -- (D14). Blizzard uses both as labels on its own character pane
    -- (Camelot/PaperDollFrame.lua:617, :665), so they are the client's words in the
    -- client's locale, not strings of ours.
    for field, global in pairs({ health = _G.HEALTH, mana = _G.MANA }) do
        local wordKind, word = ClientRead.Classify(global, "string")
        if wordKind == ClientRead.PLAIN and word ~= "" then
            references[field] = word:lower()
        end
    end
    for field in pairs(ns.CONSUMABLE_REFERENCE_SPELLS) do
        if not references[field] then
            ns.Log.Once("consumables:reference:" .. field, format(
                "consumable macros cannot read the client's name for %s, so what needs it is left alone",
                field))
        end
    end
    state.references = references
    return references
end

-- Tooltip lines for one item. TOOLTIP_DATA_UPDATE is a UniqueEvent, so it cannot
-- arrive inside this call; the window is kept anyway so that a third event is
-- caught once rather than tainting quietly (section 4.1, premise 44).
local function tooltipLines(itemId)
    local getter = _G.C_TooltipInfo and _G.C_TooltipInfo.GetItemByID
    if type(getter) ~= "function" then
        return nil
    end
    local data
    local names, ok = ns.CallWindow.Capture(function()
        data = getter(itemId)
    end)
    if not ok or type(data) ~= "table" then
        return nil
    end
    local unexpected = ns.CallWindow.Unexpected(names, WRITE_INLINE_EVENTS)
    if #unexpected > 0 then
        ns.Log.Once("consumables:tooltipinline:" .. concat(unexpected, ","), format(
            "reading an item tooltip delivered %s inside the call, which the design did not expect",
            concat(unexpected, ", ")))
    end
    local kind, lines = ClientRead.Field(data, "lines", "table")
    if kind ~= ClientRead.PLAIN then
        return nil
    end
    local texts = {}
    for index = 1, #lines do
        local line = lines[index]
        if type(line) == "table" then
            local textKind, text = ClientRead.Field(line, "leftText", "string")
            if textKind == ClientRead.PLAIN then
                texts[#texts + 1] = text
            end
        end
    end
    return texts
end

-- Classification (section 4.1) -------------------------------------------------------

local function cacheClassification(itemId, classification)
    if state.classificationCount >= ns.CLASSIFICATION_CACHE_CAPACITY then
        state.classifications = {}
        state.classificationCount = 0
    end
    if state.classifications[itemId] == nil then
        state.classificationCount = state.classificationCount + 1
    end
    state.classifications[itemId] = classification
    return classification
end

local NOT_CONSUMABLE = { kind = nil }

-- What one item is. The class check comes first and answers from the client's own
-- item data, which requests nothing; the subclass arrives in the same return, so the
-- bandage kind costs nothing extra (section 4.1).
--
-- Audit finding 13: an item that is loaded but simply has no use spell is cached as
-- not a consumable. Only an item that is NOT LOADED YET stays uncached, so a
-- spell-less consumable is asked once per UI load rather than once per rebuild.
local function classify(itemId)
    local cached = state.classifications[itemId]
    if cached ~= nil then
        return cached
    end

    local instant = _G.C_Item and _G.C_Item.GetItemInfoInstant
    if type(instant) ~= "function" then
        return NOT_CONSUMABLE
    end
    local ok, _, _, _, _, _, classID, subClassID = pcall(instant, itemId)
    if not ok then
        return NOT_CONSUMABLE
    end
    local consumableClass = _G.Enum and _G.Enum.ItemClass and _G.Enum.ItemClass.Consumable or 0
    if ClientRead.Classify(classID, "number") ~= ClientRead.PLAIN or classID ~= consumableClass then
        return NOT_CONSUMABLE
    end

    local references = referenceNames()
    local subclasses = _G.Enum and _G.Enum.ItemConsumableSubclass
    local bandageSubclass = subclasses and subclasses.Bandage or 7
    local foodDrinkSubclass = subclasses and subclasses.Fooddrink or 5

    local kind, needsRestoreSplit
    if ns.HEALTHSTONE_ITEMS[itemId] then
        kind = CONSUMABLE.HEALTHSTONE
    elseif subClassID == bandageSubclass then
        kind = CONSUMABLE.BANDAGE
    elseif subClassID == foodDrinkSubclass then
        -- Subclass 5 is one subclass for both food and water, so it says "one of the
        -- two" and the tooltip's restore line says which (D14, section 2.8). The
        -- use-spell name cannot: Forever's food uses "Nutritious Food", not spell
        -- 433's "Food", which is why the first in-game run found no food at all.
        needsRestoreSplit = true
    end

    local requiredLevel, itemLevel
    local info = _G.C_Item and _G.C_Item.GetItemInfo
    local loaded = false
    if type(info) == "function" then
        local infoOk, _, _, _, level, required = pcall(info, itemId)
        if infoOk and level ~= nil then
            loaded = true
            if ClientRead.Classify(level, "number") == ClientRead.PLAIN then
                itemLevel = level
            end
            if ClientRead.Classify(required, "number") == ClientRead.PLAIN then
                requiredLevel = required
            end
        end
    end
    if not loaded then
        -- Not loaded yet: ask again next scan, and do not cache (audit finding 13).
        return nil
    end

    if not kind and not needsRestoreSplit then
        local spell = _G.C_Item and _G.C_Item.GetItemSpell
        local spellName
        if type(spell) == "function" then
            local spellOk, name = pcall(spell, itemId)
            if spellOk and ClientRead.Classify(name, "string") == ClientRead.PLAIN then
                spellName = name
            end
        end
        if spellName == nil then
            -- Loaded, and no use spell: this is an answer, so cache it.
            return cacheClassification(itemId, NOT_CONSUMABLE)
        end
        -- The use-spell name still identifies a healing potion, which S5 confirmed:
        -- item 929 and item 858 both answer spell 439's name. Food and drink are
        -- kept here as a fallback for an item that is NOT subclass 5 but does carry
        -- the generic spell -- the subclass is the primary signal now.
        if spellName == references.healingPotion then
            kind = CONSUMABLE.HEALING_POTION
        elseif spellName == references.food then
            kind = CONSUMABLE.FOOD
        elseif spellName == references.drink then
            kind = CONSUMABLE.DRINK
        end
    end

    if not kind and not needsRestoreSplit then
        return cacheClassification(itemId, NOT_CONSUMABLE)
    end

    -- One tooltip read answers everything left: conjured, Well Fed, and for a
    -- subclass-5 item which of food or water it is. A bandage needs none of them.
    local conjured, buffFood = "No", "No"
    if kind ~= CONSUMABLE.BANDAGE then
        conjured, buffFood = "CouldNotTell", "CouldNotTell"
        local lines = tooltipLines(itemId)
        if lines then
            conjured, buffFood = "No", "No"
            local restores
            for index = 1, #lines do
                local text = lines[index]
                local folded = text:lower()
                if references.conjured and text == references.conjured then
                    conjured = "Yes"
                end
                if references.wellFed and folded:find(references.wellFed:lower(), 1, true) then
                    buffFood = "Yes"
                end
                if needsRestoreSplit and not restores then
                    -- Health before mana: an item that restores both is food, which
                    -- is the reading that puts it in the macro you press out of
                    -- combat either way.
                    if references.health and folded:find(references.health, 1, true) then
                        restores = CONSUMABLE.FOOD
                    elseif references.mana and folded:find(references.mana, 1, true) then
                        restores = CONSUMABLE.DRINK
                    end
                end
            end
            kind = kind or restores
        end
        -- A subclass-5 item whose tooltip would not read is "could not tell", not a
        -- guess at food (rule 10). It is left out of the scan and counted.
        if not kind then
            return nil
        end
    end

    return cacheClassification(itemId, {
        kind = kind,
        requiredLevel = requiredLevel or 1,
        itemLevel = itemLevel or 0,
        conjured = conjured,
        buffFood = buffFood,
    })
end

-- The bags (section 4.2) -------------------------------------------------------------

local function bagRange()
    local inventory = _G.Constants and _G.Constants.InventoryConstants
    return (inventory and inventory.NumBagSlots or _G.NUM_BAG_SLOTS or 4)
end

local function readyInSeconds(itemId)
    local container = _G.C_Container
    local getter = container and container.GetItemCooldown
    if type(getter) ~= "function" then
        return 0
    end
    local ok, startedAt, duration = pcall(getter, itemId)
    if not ok then
        return 0
    end
    if ClientRead.Classify(startedAt, "number") ~= ClientRead.PLAIN
        or ClientRead.Classify(duration, "number") ~= ClientRead.PLAIN then
        return 0
    end
    if startedAt == 0 or duration == 0 then
        return 0
    end
    local remaining = (startedAt + duration) - now()
    return remaining > 0 and remaining or 0
end

-- One Candidate per classified item ID, counts summed. An item that could not be
-- told is counted and left out -- never guessed in (README rule 10).
local function scanBags()
    local candidates = { byKind = {}, couldNotTell = 0 }
    local container = _G.C_Container
    if type(container) ~= "table" or type(container.GetContainerNumSlots) ~= "function"
        or type(container.GetContainerItemID) ~= "function" then
        return candidates
    end
    local byItem = {}
    for bag = 0, bagRange() do
        local ok, slots = pcall(container.GetContainerNumSlots, bag)
        if ok and type(slots) == "number" then
            for slot = 1, slots do
                local idOk, itemId = pcall(container.GetContainerItemID, bag, slot)
                if idOk and ClientRead.Classify(itemId, "number") == ClientRead.PLAIN then
                    local existing = byItem[itemId]
                    if existing then
                        existing.count = existing.count + 1
                    else
                        local classification = classify(itemId)
                        if classification == nil then
                            candidates.couldNotTell = candidates.couldNotTell + 1
                        elseif classification.kind then
                            byItem[itemId] = {
                                itemId = itemId,
                                kind = classification.kind,
                                count = 1,
                                requiredLevel = classification.requiredLevel,
                                itemLevel = classification.itemLevel,
                                conjured = classification.conjured,
                                buffFood = classification.buffFood,
                                readyInSeconds = readyInSeconds(itemId),
                            }
                        end
                    end
                end
            end
        end
    end
    for _, candidate in pairs(byItem) do
        local list = candidates.byKind[candidate.kind]
        if not list then
            list = {}
            candidates.byKind[candidate.kind] = list
        end
        list[#list + 1] = candidate
    end
    state.couldNotTell = candidates.couldNotTell
    if candidates.couldNotTell > 0 then
        bump("couldNotTell", candidates.couldNotTell)
    end
    return candidates
end

-- Ranking (section 4.5). Required level is the measure, with the cost accepted
-- (D9): on Forever a lower-tier item can restore more, and this will sometimes
-- pick the weaker one. /pa consumables prints both levels so the choice is visible.
--
-- conjuredFirst reaches food and water only. A healthstone is summoned, so letting
-- it win here unconditionally would stall the castsequence on a stone that is on
-- cooldown -- the AutoPotion defect this feature replaces (section 4.3).
local function bestOf(consumableKind, candidates, level, settings)
    local list = candidates.byKind[consumableKind]
    if not list then
        return nil
    end
    local conjuredCounts = settings.conjuredFirst
        and (consumableKind == CONSUMABLE.FOOD or consumableKind == CONSUMABLE.DRINK)
    local best
    for index = 1, #list do
        local candidate = list[index]
        local eligible = candidate.requiredLevel <= level
        if eligible and consumableKind == CONSUMABLE.FOOD and settings.skipBuffFood then
            -- "Could not tell" never eats the food you are saving.
            eligible = candidate.buffFood == "No"
        end
        if eligible then
            if not best then
                best = candidate
            else
                local betterConjured = conjuredCounts
                    and candidate.conjured == "Yes" and best.conjured ~= "Yes"
                local worseConjured = conjuredCounts
                    and best.conjured == "Yes" and candidate.conjured ~= "Yes"
                if betterConjured then
                    best = candidate
                elseif not worseConjured then
                    if candidate.requiredLevel > best.requiredLevel
                        or (candidate.requiredLevel == best.requiredLevel
                            and (candidate.itemLevel > best.itemLevel
                                or (candidate.itemLevel == best.itemLevel
                                    and candidate.itemId > best.itemId))) then
                        best = candidate
                    end
                end
            end
        end
    end
    return best
end

-- Bodies (section 4.4) ---------------------------------------------------------------

local function nameFor(macroKind, settings)
    return settings[MACRO_SPEC[macroKind].nameKey] or DEFAULT_SETTINGS[MACRO_SPEC[macroKind].nameKey]
end

-- The plan carries the candidates it was planned from, because the cooldown timer
-- needs their remaining time and a macro body cannot be parsed back into item IDs
-- (audit finding 4).
local function planMacro(macroKind, candidates, level, settings)
    local plan = {
        kind = macroKind,
        name = nameFor(macroKind, settings),
        body = "#showtooltip",
        chosen = {},
    }
    if macroKind == KIND.HEAL then
        local stone = bestOf(CONSUMABLE.HEALTHSTONE, candidates, level, settings)
        local potion = bestOf(CONSUMABLE.HEALING_POTION, candidates, level, settings)
        if stone and potion then
            -- Less cooldown left leads; on a tie the healthstone (section 4.3).
            local first, second = stone, potion
            if potion.readyInSeconds < stone.readyInSeconds then
                first, second = potion, stone
            end
            plan.chosen = { first, second }
            plan.body = format("#showtooltip\n/castsequence reset=combat item:%d, item:%d",
                first.itemId, second.itemId)
        elseif stone or potion then
            local only = stone or potion
            plan.chosen = { only }
            plan.body = format("#showtooltip\n/use item:%d", only.itemId)
        end
    elseif macroKind == KIND.BANDAGE then
        local bandage = bestOf(CONSUMABLE.BANDAGE, candidates, level, settings)
        if bandage then
            plan.chosen = { bandage }
            -- SecureCmdOptionParse resolves the target at press time: a living
            -- friendly target, otherwise the player (premise 46).
            plan.body = format("#showtooltip\n/use [help,nodead][@player] item:%d", bandage.itemId)
        end
    else
        local consumableKind = macroKind == KIND.FOOD and CONSUMABLE.FOOD or CONSUMABLE.DRINK
        local item = bestOf(consumableKind, candidates, level, settings)
        if item then
            plan.chosen = { item }
            plan.body = format("#showtooltip\n/use item:%d", item.itemId)
        end
    end
    if #plan.body > ns.MACRO_BODY_MAXIMUM then
        plan.body = plan.body:sub(1, ns.MACRO_BODY_MAXIMUM)
    end
    return plan
end

-- The macro list (section 5.4, 5.5) --------------------------------------------------

local function maxAccountMacros()
    local macroConsts = _G.Constants and _G.Constants.MacroConsts
    return macroConsts and macroConsts.MAX_ACCOUNT_MACROS or 120
end

local function maxCharacterMacros()
    local macroConsts = _G.Constants and _G.Constants.MacroConsts
    return macroConsts and macroConsts.MAX_CHARACTER_MACROS or 30
end

-- Which action slot holds this macro, if any. Diagnostics only since D16: a slotted
-- macro IS rewritten now, and the taint reading decides whether that did harm. This
-- says which macros carry the risk, so /pa consumables can show it.
--
-- Section 2.9, spike S1's answer.
--
-- S1 came back dirty on 2026-10-11: EditMacro on a macro that sits on a pad action
-- slot delivered ACTION_RANGE_CHECK_UPDATE and ACTIONBAR_SLOT_CHANGED inside the
-- call. Both are SynchronousEvent and both have Blizzard listeners -- the page unit
-- re-picks its active bar and writes activeBar (PageUnit.lua:248 -> :528), and the
-- action buttons run their range check. So that write taints the Gamepad action bar
-- in our execution, which is the refusal GAPBugs01 section 2.9 traced.
--
-- A macro on NO slot raises no slot change, so editing that one is still safe. This
-- is the question that tells the two apart, and it is why the feature now refuses
-- rather than faults.
--
-- GetActionInfo is undocumented, like the rest of the macro API, so it carries no
-- flag to reason from and every return goes through ClientRead. Nil means "could not
-- tell", which is treated as occupied.
local function macroActionSlot(index)
    local getter = _G.GetActionInfo
    if type(getter) ~= "function" then
        return nil
    end
    for slot = 1, ns.ACTION_SLOT_MAXIMUM do
        local ok, actionType, actionId = pcall(getter, slot)
        if ok
            and ClientRead.Classify(actionType, "string") == ClientRead.PLAIN
            and actionType == "macro"
            and ClientRead.Classify(actionId, "number") == ClientRead.PLAIN
            and actionId == index then
            return slot
        end
    end
    return false
end

local function indexByName(name)
    local kind, index = ClientRead.Call(_G.GetMacroIndexByName, "number", name)
    if kind ~= ClientRead.PLAIN or index == 0 then
        return nil
    end
    return index
end

local function bodyAt(index)
    local getter = _G.GetMacroInfo
    if type(getter) ~= "function" then
        return nil
    end
    local ok, macroName, _, body = pcall(getter, index)
    if not ok then
        return nil
    end
    if ClientRead.Classify(body, "string") ~= ClientRead.PLAIN then
        return nil
    end
    local resolvedName
    if ClientRead.Classify(macroName, "string") == ClientRead.PLAIN then
        resolvedName = macroName
    end
    return body, resolvedName
end

-- Which macro this kind already owns, and under which name. The fallback to the
-- name of our last successful write is what makes a rename a rename: after
-- /pa set changes the key, the client's macro still carries the old name, so a
-- lookup by the new one misses and an unguarded write would create a duplicate
-- (audit finding 3).
--
-- An account macro is never adopted: one body shared by every character on the
-- account cannot name the right item for each of them (audit finding 9).
local function resolveMacro(plan)
    local index = indexByName(plan.name)
    local currentName = plan.name
    if not index then
        local previous = state.maintainedName[plan.kind]
        if previous and previous ~= plan.name then
            index = indexByName(previous)
            currentName = previous
        end
    end
    if not index then
        return nil
    end
    if index <= maxAccountMacros() then
        return nil, index
    end
    return index, nil, currentName
end

local function characterMacroCount()
    local kind, _, character = ClientRead.CallMany(_G.GetNumMacros, 2, "number")
    if kind ~= ClientRead.PLAIN then
        return nil
    end
    return character
end

-- Whether a missing macro may be created now (section 5.5).
local function mayCreate(macroKind, settings)
    if state.known == KNOWN.GAVE_UP then
        return false, "the client never reported this character's macros"
    end
    if not settings[MACRO_SPEC[macroKind].toggle] then
        return false, "that macro is switched off"
    end
    if state.collidedWith[macroKind] then
        return false, format("'%s' is already kept for the %s macro",
            nameFor(macroKind, settings), MACRO_SPEC[state.collidedWith[macroKind]].label)
    end
    if state.createdThisLoad[macroKind] or state.missingThisLoad[macroKind] then
        return false, "already tried this session"
    end
    local count = characterMacroCount()
    if count == nil then
        return false, "the client would not say how many macros this character has"
    end
    if count >= maxCharacterMacros() then
        return false, format("this character already has %d macros, the most the client allows", count)
    end
    if macroKind == KIND.WATER then
        local mana = usesMana()
        if mana == nil then
            return false, "could not tell whether this character uses mana"
        end
        if not mana then
            return false, "this character does not use mana"
        end
    end
    return true
end

-- The write (section 5.4) ------------------------------------------------------------

local function fault(reason)
    state.phase = PHASE.FAULTED
    state.faultReason = state.faultReason or reason
    bump("rebuildFaults")
    ns.Registry.Fault(FEATURE_ID, reason)
end

-- Whether the Gamepad action bar's `activeBar` is tainted, and who the client
-- blames (D16). This is the harm GAPBugs01 §2.9 traced a refused pad press to, so
-- it is the thing worth asking about rather than the event that might cause it.
--
-- Taint attaches to the variable, so the question has an answer whether or not the
-- field holds a value right now -- the mistake /pa taint's first suspect list made
-- (Core/Debug.lua:485-490).
--
-- NotApplicable is not the same as "could not tell". With no Gamepad page unit there
-- is no Gamepad action bar to taint and nothing to guard; with a page unit but no
-- issecurevariable, we cannot see the harm and must not write again.
local function activeBarTaint()
    local pageUnit = _G.GamepadMainActionBarFramePageUnit
    if type(pageUnit) ~= "table" then
        return "NotApplicable"
    end
    local reader = _G.issecurevariable
    if type(reader) ~= "function" then
        return "Unreadable", "this client does not expose issecurevariable"
    end
    local ok, isSecure, blamed = pcall(reader, pageUnit, "activeBar")
    if not ok then
        return "Unreadable", "issecurevariable raised"
    end
    if isSecure then
        return "Secure"
    end
    return "Tainted", tostring(blamed or "unnamed")
end

-- Runs one macro call inside the window, then asks whether the write did the harm.
--
-- Two gates, and they ask different questions (section 2.9, D16):
--   * the event list catches an event spike S never measured, which is the window's
--     original job and still is;
--   * the taint reading catches the documented harm, whichever event caused it.
-- A write that delivers the measured events and leaves activeBar secure did no harm,
-- and that is the case the first in-game run faulted on.
local function captureWrite(describe, call)
    local names, ok, err = ns.CallWindow.Capture(call)
    state.lastInline = names
    if not ok then
        fault(format("%s raised: %s", describe, ns.EscapeGuard.Neutralize(tostring(err))))
        return false
    end
    local unexpected = ns.CallWindow.Unexpected(names, WRITE_INLINE_EVENTS)
    if #unexpected > 0 then
        fault(format(
            "%s delivered %s inside the call, which spike S did not measure; /reload to discard anything those handlers wrote",
            describe, concat(unexpected, ", ")))
        return false
    end

    local verdict, detail = activeBarTaint()
    state.lastActiveBar = verdict
    bump("activeBarChecks")
    if verdict == "Tainted" then
        bump("activeBarTainted")
        if detail == ns.ADDON_NAME then
            fault(format(
                "%s tainted the Gamepad action bar's activeBar, so a pad press may be refused in our name; /reload clears it, and no further macro is written this session",
                describe))
            return false
        end
        -- Someone else got there first. Not ours to fault over, and writing again
        -- cannot make it worse, but it is worth saying once.
        ns.Log.Once("consumables:activebar:" .. tostring(detail), format(
            "the Gamepad action bar's activeBar was already tainted by %s before our macro write",
            ns.EscapeGuard.Neutralize(tostring(detail))))
    elseif verdict == "Unreadable" then
        fault(format(
            "%s cannot be checked for action-bar taint (%s), so no further macro is written this session",
            describe, tostring(detail)))
        return false
    end
    return true
end

local function recordDefer(reason)
    state.lastDefer = reason
    if reason == DEFER.IN_COMBAT then
        bump("deferredInCombat")
    elseif reason == DEFER.COMBAT_UNKNOWN then
        bump("deferredCombatUnknown")
    elseif reason == DEFER.LEVEL_UNKNOWN then
        bump("deferredLevelUnknown")
    elseif reason == DEFER.WINDOW_OPEN then
        bump("deferredWindowOpen")
    elseif reason == DEFER.WINDOW_UNKNOWN then
        bump("deferredWindowUnknown")
    end
    return WRITE.DEFERRED, reason
end

-- Whether the Macros window is in the way (section 5.4, decision D12).
--
-- This WAS a check for any frame registered to UPDATE_MACROS that is not ours. It
-- could never open: Terminal's macro provider registers that event at load, for the
-- whole session (Terminal/Providers/Macros.lua:50 through Core/Core.lua:179), so the
-- first in-game run made four rebuilds, sixteen ListenerPresent deferrals and wrote
-- nothing at all. Premise 40 anticipated it in as many words.
--
-- The generic check was guarding two different things, and only one of them is about
-- a listener:
--   * Blizzard's code running inside our call (rules 1 and 9). Another ADDON's
--     handler is not that. Terminal's reads GetNumMacros and GetMacroInfo and marks
--     itself dirty; it writes nothing of Blizzard's, so our taint reaches nothing of
--     Blizzard's through it. Both of us are insecure either way.
--   * The Macros window's save-on-hide overwriting our body, or ours overwriting an
--     edit in progress (Blizzard_MacroUI.lua:119-122, premise 41). That is the real
--     hazard, and it is about one named window, not about who listens.
--
-- So the question asked is the narrower, answerable one. MacroFrame is a named
-- global in a LoadOnDemand addon (Blizzard_MacroUI.xml:25), so it is nil until the
-- player first opens the window -- the common case costs one global read. A read we
-- cannot take counts as open, never as closed (rule 10).
--
-- Every write still runs inside CallWindow.Capture, so an unexpected inline event
-- faults the feature exactly as before. What changed is which deferral is asked for,
-- not whether the write is watched.
local function macroWindowInTheWay()
    local window = _G.MacroFrame
    if window == nil then
        return nil
    end
    if type(window) ~= "table" then
        return DEFER.WINDOW_UNKNOWN
    end
    local kind, shown = ClientRead.Call(window.IsShown, "boolean", window)
    if kind == ClientRead.PLAIN then
        return shown and DEFER.WINDOW_OPEN or nil
    end
    if kind == ClientRead.ABSENT then
        return nil
    end
    return DEFER.WINDOW_UNKNOWN
end

local function writeIsClear()
    local blocked = macroWindowInTheWay()
    if blocked == DEFER.WINDOW_OPEN then
        ns.Log.Once("consumables:windowopen",
            "consumable macros are waiting while the Macros window is open, so neither of us overwrites the other")
        return false, blocked
    end
    if blocked == DEFER.WINDOW_UNKNOWN then
        ns.Log.Once("consumables:windowunknown",
            "consumable macros cannot tell whether the Macros window is open, so nothing is written")
        return false, blocked
    end
    return true
end

local function writeMacro(plan, settings)
    -- A colliding kind is refused before any client read: may_create gates creation
    -- only, so without this both kinds would edit the one macro on every rebuild,
    -- each overwriting the other (audit finding 5).
    local collided = state.collidedWith[plan.kind]
    if collided then
        bump("notMaintained")
        return WRITE.NOT_MAINTAINED, format("'%s' is already kept for the %s macro",
            plan.name, MACRO_SPEC[collided].label)
    end

    local index, accountIndex, currentName = resolveMacro(plan)

    if accountIndex then
        bump("notMaintained")
        bump("accountMacrosRefused")
        local reason = format("a macro named '%s' is account-wide, and this macro is per character",
            plan.name)
        state.notCreatedReason[plan.kind] = reason
        ns.Log.Once("consumables:account:" .. plan.kind, format(
            "the %s macro is not maintained: %s", MACRO_SPEC[plan.kind].label, reason))
        return WRITE.NOT_MAINTAINED, reason
    end

    if not index then
        local allowed, reason = mayCreate(plan.kind, settings)
        if not allowed then
            state.missingThisLoad[plan.kind] = true
            state.notCreatedReason[plan.kind] = reason
            bump("notCreated")
            return WRITE.NOT_CREATED, reason
        end
        local clear, blocked = writeIsClear()
        if not clear then
            return recordDefer(blocked)
        end
        local created
        if not captureWrite("CreateMacro", function()
            created = _G.CreateMacro(plan.name, ns.MACRO_DEFAULT_ICON, plan.body, true)
        end) then
            return WRITE.REFUSED, state.faultReason
        end
        state.createdThisLoad[plan.kind] = true
        state.maintainedName[plan.kind] = plan.name
        state.notCreatedReason[plan.kind] = nil
        bump("created")
        bump("writes")
        return WRITE.CREATED, created
    end

    local currentBody, heldName = bodyAt(index)
    local needsRename = (currentName ~= plan.name)
        or (heldName ~= nil and heldName ~= plan.name)

    if not needsRename and currentBody == plan.body then
        state.maintainedName[plan.kind] = plan.name
        state.notCreatedReason[plan.kind] = nil
        bump("unchanged")
        return WRITE.UNCHANGED
    end

    local clear, blocked = writeIsClear()
    if not clear then
        return recordDefer(blocked)
    end

    if needsRename then
        local previousName = currentName
        if not captureWrite("EditMacro", function()
            _G.EditMacro(index, plan.name)
        end) then
            return WRITE.REFUSED, state.faultReason
        end
        state.maintainedName[plan.kind] = plan.name
        bump("renamed")
        bump("writes")
        if currentBody ~= plan.body then
            if not captureWrite("EditMacro", function()
                _G.EditMacro(index, nil, nil, plan.body)
            end) then
                return WRITE.REFUSED, state.faultReason
            end
            bump("writes")
        end
        return WRITE.RENAMED, previousName
    end

    -- A body edit passes no name and no icon, as the Macros window does
    -- (Blizzard_MacroUI.lua:364).
    if not captureWrite("EditMacro", function()
        _G.EditMacro(index, nil, nil, plan.body)
    end) then
        return WRITE.REFUSED, state.faultReason
    end
    -- Counted, not announced. enable clears maintainedName, so this cannot tell a
    -- macro we created last session from one of the player's -- which meant four
    -- "adopted your macro" lines in chat at most logins, about our own macros.
    -- /pa consumables shows what is maintained, and asking is better than being told.
    if not state.maintainedName[plan.kind] and not state.adoptedThisLoad[plan.kind] then
        state.adoptedThisLoad[plan.kind] = true
        bump("adopted")
    end
    state.maintainedName[plan.kind] = plan.name
    state.notCreatedReason[plan.kind] = nil
    bump("written")
    bump("writes")
    return WRITE.WRITTEN, index
end

-- The cooldown timer (section 5.7) ---------------------------------------------------

local function cancelToken(field)
    local timer = state[field]
    if timer then
        if type(timer) == "table" and type(timer.Cancel) == "function" then
            pcall(timer.Cancel, timer)
        end
        state[field] = nil
    end
end

local scheduleRebuild

-- Only the healing macro needs this: food, water and bandages are ordered by level,
-- not by cooldown, so their bodies do not change when one ends. The cooldowns come
-- from plan.chosen, never from the body text (audit finding 4).
local function scheduleCooldownReplan(plans)
    cancelToken("cooldownToken")
    local soonest
    for index = 1, #plans do
        local plan = plans[index]
        if plan.kind == KIND.HEAL then
            for position = 1, #plan.chosen do
                local remaining = plan.chosen[position].readyInSeconds
                if remaining > 0 and (not soonest or remaining < soonest) then
                    soonest = remaining
                end
            end
        end
    end
    if not soonest then
        return "NotNeeded"
    end
    local delay = soonest + ns.COOLDOWN_TIMER_SLACK
    state.cooldownToken = _G.C_Timer and _G.C_Timer.NewTimer
        and _G.C_Timer.NewTimer(delay, function()
            state.cooldownToken = nil
            bump("cooldownReplans")
            scheduleRebuild()
        end) or nil
    return "Scheduled", delay
end

-- The rebuild (section 5.2) ----------------------------------------------------------

local function scheduleRetry()
    cancelToken("retryToken")
    if state.retryCount >= ns.MACRO_RETRY_LIMIT then
        bump("retriesExhausted")
        state.phase = PHASE.IDLE
        state.retryCount = 0
        return
    end
    local delay = min(ns.MACRO_RETRY_FIRST_DELAY * (2 ^ state.retryCount),
        ns.MACRO_RETRY_MAXIMUM_DELAY)
    state.retryCount = state.retryCount + 1
    state.phase = PHASE.RETRYING
    state.retryToken = _G.C_Timer and _G.C_Timer.NewTimer
        and _G.C_Timer.NewTimer(delay, function()
            state.retryToken = nil
            scheduleRebuild()
        end) or nil
end

local function rebuild()
    state.rebuildToken = nil
    if not state.enabled or state.phase == PHASE.FAULTED then
        return
    end

    local combat = combatReading()
    if combat == DEFER.IN_COMBAT then
        state.phase = PHASE.HELD
        recordDefer(DEFER.IN_COMBAT)
        return
    end
    if combat == DEFER.COMBAT_UNKNOWN then
        recordDefer(DEFER.COMBAT_UNKNOWN)
        scheduleRetry()
        return
    end

    local level = playerLevel()
    if level == nil then
        recordDefer(DEFER.LEVEL_UNKNOWN)
        scheduleRetry()
        return
    end

    bump("rebuilds")
    local settings = state.settings
    local candidates = scanBags()
    local plans, deferred = {}, nil

    for index = 1, #ns.MACRO_KIND_ORDER do
        local macroKind = ns.MACRO_KIND_ORDER[index]
        if settings[MACRO_SPEC[macroKind].toggle] then
            local plan = planMacro(macroKind, candidates, level, settings)
            plans[#plans + 1] = plan
            state.lastPlan[macroKind] = plan
            local outcome, detail = writeMacro(plan, settings)
            state.lastWrite[macroKind] = { outcome = outcome, detail = detail }
            if outcome == WRITE.REFUSED then
                return
            end
            -- The Macros window closing raises no event we subscribe to, and an
            -- unreadable read will not announce itself either, so both retry.
            if outcome == WRITE.DEFERRED
                and (detail == DEFER.WINDOW_OPEN or detail == DEFER.WINDOW_UNKNOWN) then
                deferred = detail
            end
        else
            state.lastWrite[macroKind] = { outcome = "Off" }
        end
    end

    scheduleCooldownReplan(plans)

    if deferred then
        scheduleRetry()
        return
    end
    -- NotCreated and NotMaintained are settled answers, not deferrals: nothing will
    -- change until a setting or the macro list does (audit finding 6).
    state.phase = PHASE.IDLE
    state.retryCount = 0
end

function scheduleRebuild()
    if not state.enabled then
        return
    end
    if state.phase == PHASE.WAITING then
        state.dirty = true
        return
    end
    if state.phase == PHASE.FAULTED then
        return
    end
    if state.rebuildToken then
        return
    end
    state.phase = PHASE.PENDING
    -- Rule 5: a frame later, on our own timer, from a queue we own.
    state.rebuildToken = _G.C_Timer and _G.C_Timer.NewTimer
        and _G.C_Timer.NewTimer(0, rebuild) or nil
end

-- Login (section 5.3) ----------------------------------------------------------------

local function releaseMacrosSubscription()
    -- Released at the first delivery, at GaveUp, or at disable, whichever comes
    -- first. A handler left registered would run inside Blizzard's call the next
    -- time the player edits a macro by hand, which is the rule 1 breach the
    -- subscription exists to avoid (audit finding 7).
    if state.macrosEventToken then
        ns.Dispatch.Unsubscribe(state.macrosEventToken)
        state.macrosEventToken = nil
    end
end

local function leaveWaiting(known)
    state.known = known
    releaseMacrosSubscription()
    cancelToken("knownTimerToken")
    if state.phase == PHASE.WAITING then
        state.phase = PHASE.IDLE
        -- Leaving Waiting always schedules one rebuild, so nothing that happened
        -- while waiting is lost (section 5.2).
        scheduleRebuild()
    end
end

local function macrosReadable()
    local count = characterMacroCount()
    return count ~= nil
end

local function onMacrosEvent()
    if state.known == KNOWN.NOT_YET and macrosReadable() then
        leaveWaiting(KNOWN.KNOWN)
    end
end

local function onEnteringWorld()
    state.enteredWorldAt = now()
    -- S4's first candidate: the macros are readable one frame after entering the
    -- world. Checked on our own timer, never inline.
    if _G.C_Timer and _G.C_Timer.NewTimer then
        _G.C_Timer.NewTimer(0, function()
            if not state.enabled then
                return
            end
            if state.known == KNOWN.NOT_YET and macrosReadable() then
                leaveWaiting(KNOWN.KNOWN)
            end
        end)
        cancelToken("knownTimerToken")
        state.knownTimerToken = _G.C_Timer.NewTimer(ns.MACROS_KNOWN_TIMEOUT, function()
            state.knownTimerToken = nil
            if state.enabled and state.known == KNOWN.NOT_YET then
                ns.Log.Once("consumables:gaveup",
                    "the client never reported this character's macros, so consumable macros will maintain the ones it finds by name and create none")
                leaveWaiting(KNOWN.GAVE_UP)
            end
        end)
    end
end

-- Name collisions (section 5.5) ------------------------------------------------------

-- Settled once, at enable. A hand-edited saved file can hold two equal names
-- despite the schema's distinctFrom, so the first kind in MACRO_KIND_ORDER that
-- holds a name keeps it and every later kind is recorded here.
local function settleCollisions(settings)
    state.collidedWith = {}
    local owner = {}
    for index = 1, #ns.MACRO_KIND_ORDER do
        local macroKind = ns.MACRO_KIND_ORDER[index]
        local name = (nameFor(macroKind, settings) or ""):lower()
        if owner[name] then
            state.collidedWith[macroKind] = owner[name]
            ns.Log.Once("consumables:collide:" .. macroKind, format(
                "the %s and %s macros are both named '%s', so only the %s one is kept",
                MACRO_SPEC[owner[name]].label, MACRO_SPEC[macroKind].label,
                ns.EscapeGuard.Neutralize(nameFor(macroKind, settings)),
                MACRO_SPEC[owner[name]].label))
        else
            owner[name] = macroKind
        end
    end
end

-- Lifecycle ---------------------------------------------------------------------------

local function readSettings(config)
    local settings = config and config.settings
    for key, value in pairs(DEFAULT_SETTINGS) do
        state.settings[key] = value
    end
    if settings then
        for key in pairs(DEFAULT_SETTINGS) do
            if settings[key] ~= nil then
                state.settings[key] = settings[key]
            end
        end
    end
end

local function enable(config)
    readSettings(config)
    if type(_G.EditMacro) ~= "function" or type(_G.GetMacroIndexByName) ~= "function"
        or type(_G.GetMacroInfo) ~= "function" then
        return nil, "this client does not expose the macro API"
    end

    settleCollisions(state.settings)
    state.phase = PHASE.WAITING
    state.known = KNOWN.NOT_YET
    state.dirty = false
    state.enabled = true

    -- "Earlier in this UI load" exists to stop a refused creation being retried on
    -- every rebuild. An enable is not a rebuild: it is the player switching the
    -- feature on, or a login, and either is a reason to try again -- otherwise
    -- freeing a macro slot and toggling the feature would still create nothing.
    -- The fault is cleared with them, so a re-enable is a fresh start.
    state.createdThisLoad = {}
    state.missingThisLoad = {}
    state.adoptedThisLoad = {}
    state.notCreatedReason = {}
    state.maintainedName = {}
    state.faultReason = nil
    state.lastDefer = nil
    state.retryCount = 0

    local triggers = {
        "BAG_UPDATE_DELAYED", "BAG_UPDATE_COOLDOWN", "PLAYER_LEVEL_UP",
        "PLAYER_REGEN_ENABLED", "PLAYER_ENTERING_WORLD",
    }
    for index = 1, #triggers do
        local eventName = triggers[index]
        local handler = eventName == "PLAYER_ENTERING_WORLD" and function()
            onEnteringWorld()
            scheduleRebuild()
        end or function()
            if eventName == "PLAYER_REGEN_ENABLED" and state.phase == PHASE.HELD then
                state.phase = PHASE.IDLE
            end
            scheduleRebuild()
        end
        local token, reason = ns.Dispatch.Subscribe(FEATURE_ID, eventName, handler)
        if not token then
            return nil, format("cannot follow %s (%s)", eventName, tostring(reason))
        end
        state.tokens[#state.tokens + 1] = token
    end

    -- S4's second candidate. Subscribed from enable and released at the first
    -- delivery, at GaveUp, or at disable (audit finding 7).
    local macroToken = ns.Dispatch.Subscribe(FEATURE_ID, "UPDATE_MACROS", onMacrosEvent)
    state.macrosEventToken = macroToken

    -- A /reload raises no PLAYER_ENTERING_WORLD before enable on every path, so the
    -- login clock starts here too.
    onEnteringWorld()
    return true
end

-- Tolerates a partial enable (Phase 1 section 6.1). Every timer and subscription
-- this feature took out is released here: a retry timer left running would rebuild
-- a feature that is off (audit finding 8).
local function disable()
    state.enabled = false
    -- A fault runs through Registry.Fault, which disables the feature, so this must
    -- not wipe the mark that says why: /pa consumables has to still report Faulted.
    -- enable clears it, so a deliberate re-enable is a fresh start.
    if state.phase ~= PHASE.FAULTED then
        state.phase = PHASE.WAITING
    end
    cancelToken("rebuildToken")
    cancelToken("retryToken")
    cancelToken("cooldownToken")
    cancelToken("knownTimerToken")
    releaseMacrosSubscription()
    state.retryCount = 0
    for index = #state.tokens, 1, -1 do
        ns.Dispatch.Unsubscribe(state.tokens[index])
        state.tokens[index] = nil
    end
    -- Nothing is deleted: deleting a macro clears its slot on the bar
    -- (ActionBarEditFrame.lua:783-785).
end

local function onConfigChanged(config)
    readSettings(config)
    settleCollisions(state.settings)
    for index = 1, #ns.MACRO_KIND_ORDER do
        local macroKind = ns.MACRO_KIND_ORDER[index]
        if not state.settings[MACRO_SPEC[macroKind].toggle] then
            -- A kind turned off is no longer tracked, so a macro the player then
            -- renames by hand is not recaptured (section 5.4).
            state.maintainedName[macroKind] = nil
        end
        state.missingThisLoad[macroKind] = nil
    end
    scheduleRebuild()
    return ns.CONFIG_RESULT.APPLIED
end

ns.Registry.Register(FEATURE_ID, {
    enabledByDefault = true,
    label = "Consumable macros",
    description = "Keeps character macros that use the best food, water, bandage and healing item you carry. They change only out of combat. Put them on your bar with the action bar editor.",
    settingsPage = ns.SETTINGS_PAGE.CONSUMABLES,
    settingsOrder = 10,
    settings = DEFAULT_SETTINGS,
    schema = {
        healMacro = {
            kind = ns.ConfigSchema.KIND.TOGGLE, label = "Healing macro", order = 1,
            description = "A healthstone, then a healing potion on the next press. Restarts when combat ends",
        },
        bandageMacro = {
            kind = ns.ConfigSchema.KIND.TOGGLE, label = "Bandage macro", order = 2,
            description = "Bandages a living friendly target, or you",
        },
        foodMacro = {
            kind = ns.ConfigSchema.KIND.TOGGLE, label = "Food macro", order = 3,
        },
        waterMacro = {
            kind = ns.ConfigSchema.KIND.TOGGLE, label = "Water macro", order = 4,
            description = "Only on characters that use mana",
        },
        conjuredFirst = {
            kind = ns.ConfigSchema.KIND.TOGGLE, label = "Conjured food and water first", order = 5,
            description = "Even when weaker than what you carry",
        },
        skipBuffFood = {
            kind = ns.ConfigSchema.KIND.TOGGLE, label = "Never use Well Fed food", order = 6,
            description = "Off by default: on this client almost all food grants Well Fed",
        },
        healMacroName = {
            kind = ns.ConfigSchema.KIND.TEXT, label = "Healing macro name", order = 7,
            maximumLength = ns.MACRO_NAME_MAXIMUM, curated = false,
            distinctFrom = { "bandageMacroName", "foodMacroName", "waterMacroName" },
        },
        bandageMacroName = {
            kind = ns.ConfigSchema.KIND.TEXT, label = "Bandage macro name", order = 8,
            maximumLength = ns.MACRO_NAME_MAXIMUM, curated = false,
            distinctFrom = { "healMacroName", "foodMacroName", "waterMacroName" },
        },
        foodMacroName = {
            kind = ns.ConfigSchema.KIND.TEXT, label = "Food macro name", order = 9,
            maximumLength = ns.MACRO_NAME_MAXIMUM, curated = false,
            distinctFrom = { "healMacroName", "bandageMacroName", "waterMacroName" },
        },
        waterMacroName = {
            kind = ns.ConfigSchema.KIND.TEXT, label = "Water macro name", order = 10,
            maximumLength = ns.MACRO_NAME_MAXIMUM, curated = false,
            distinctFrom = { "healMacroName", "bandageMacroName", "foodMacroName" },
        },
    },
}, {
    enable = enable,
    disable = disable,
    onConfigChanged = onConfigChanged,
})

-- /pa consumables (section 8) -----------------------------------------------------------

ns.ConsumableMacros = {
    Inspect = function()
        local macros = {}
        for index = 1, #ns.MACRO_KIND_ORDER do
            local macroKind = ns.MACRO_KIND_ORDER[index]
            local plan = state.lastPlan[macroKind]
            local write = state.lastWrite[macroKind] or {}
            local held = state.maintainedName[macroKind]
            macros[#macros + 1] = {
                kind = macroKind,
                label = MACRO_SPEC[macroKind].label,
                on = state.settings[MACRO_SPEC[macroKind].toggle] == true,
                name = nameFor(macroKind, state.settings),
                heldAs = held,
                exists = held ~= nil and indexByName(held) ~= nil,
                -- Which slot, if any: a macro on a bar is the one whose rewrite can
                -- reach Blizzard's page unit (section 2.9).
                actionSlot = (function()
                    if held == nil then
                        return nil
                    end
                    local index = indexByName(held)
                    if index == nil then
                        return nil
                    end
                    local slot = macroActionSlot(index)
                    return slot == nil and "unreadable" or slot or nil
                end)(),
                plannedBody = plan and plan.body or nil,
                chosen = plan and (function()
                    local parts = {}
                    for position = 1, #plan.chosen do
                        local candidate = plan.chosen[position]
                        parts[#parts + 1] = format("item:%d (required %d, item level %d%s)",
                            candidate.itemId, candidate.requiredLevel, candidate.itemLevel,
                            candidate.conjured == "Yes" and ", conjured" or "")
                    end
                    return #parts > 0 and concat(parts, " then ") or "nothing carried"
                end)() or nil,
                outcome = write.outcome,
                -- Why, in words, for a kind that is not being maintained
                -- (audit finding 14).
                reason = state.notCreatedReason[macroKind]
                    or (state.collidedWith[macroKind] and format("'%s' is kept for the %s macro",
                        nameFor(macroKind, state.settings),
                        MACRO_SPEC[state.collidedWith[macroKind]].label))
                    or (type(write.detail) == "string" and write.detail or nil),
            }
        end
        return {
            enabled = state.enabled,
            writePath = "edit",
            phase = state.phase,
            known = state.known,
            inCombat = combatReading(),
            lastDefer = state.lastDefer,
            -- Not the gate any more (D12), but still worth seeing: it is what made
            -- the first in-game run write nothing.
            macroWindow = (function()
                local window = _G.MacroFrame
                if window == nil then
                    return "not loaded"
                end
                local blocked = macroWindowInTheWay()
                return blocked == DEFER.WINDOW_OPEN and "open"
                    or blocked == DEFER.WINDOW_UNKNOWN and "unreadable" or "closed"
            end)(),
            lastInline = state.lastInline and concat(state.lastInline, ", ") or nil,
            retryCount = state.retryCount,
            cooldownPending = state.cooldownToken ~= nil,
            activeBar = state.lastActiveBar or select(1, activeBarTaint()),
            couldNotTell = state.couldNotTell,
            faultReason = state.faultReason,
            macros = macros,
            listenersNow = (function()
                local listeners = ns.CallWindow.Listeners(WRITE_INLINE_LIST)
                return listeners and ns.CallWindow.Describe(listeners) or "unreadable"
            end)(),
        }
    end,
}
