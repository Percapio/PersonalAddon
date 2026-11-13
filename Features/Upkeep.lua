-- Features/Upkeep.lua
-- Out of combat: the buffs and weapon enchants about to run out, and your ammo or
-- soul shards (Architecture/20261112-Phase21.md sections 3-7).
--
-- HIDDEN IN COMBAT. Every aura read is secret under the combat restriction (section
-- 3.1), so a fight cannot be followed. The panel hides a frame after the pull, keeps
-- the roster it last read, and when the fight ends shows in dark red whatever ran out
-- during it (section 4.4). In combat a refresh reads supplies alone, for the
-- low-supply toast (section 5.3), and draws nothing.
--
-- EVERY HANDLER MARKS AND SCHEDULES. The work runs a frame later in our own timer,
-- never inside an event (README rules 1, 5 and 9). Every read goes through ClientRead
-- (rule 10), and each part is all-or-nothing: a partial roster would make every
-- unread buff or enchant look gone, and the tails would lie (sections 4.1 and 4.2).
--
-- The panel is ours, under UIParent, and attaches beside the damage breakdown, the
-- threat panel or the player frame (section 6.2). Nothing here writes a Blizzard frame.

local ADDON_NAME, ns = ...

local FEATURE_ID = "upkeep"
local BREAKDOWN_ID, THREAT_ID = "damageBreakdown", "threatPanel"

local format, type, pairs, ipairs, tostring = string.format, type, pairs, ipairs, tostring
local ceil, max, min, sort, concat = math.ceil, math.max, math.min, table.sort, table.concat

local ClientRead = ns.ClientRead
local PLAIN, ABSENT, WITHHELD = ClientRead.PLAIN, ClientRead.ABSENT, ClientRead.WITHHELD
local SECRET_VALUE, CALL_FAILED = ClientRead.SECRET_VALUE, ClientRead.CALL_FAILED
local UNAVAILABLE, UNEXPECTED_TYPE = ClientRead.UNAVAILABLE, ClientRead.UNEXPECTED_TYPE
local bump = ns.Diagnostics.Bump

local SOURCE = { BUFF = "Buff", ENCHANT = "Enchant" }
local SUPPLY = { AMMO = "Ammo", SHARDS = "SoulShards" }
local SUPPLY_ORDER = { SUPPLY.AMMO, SUPPLY.SHARDS }
local SUPPLY_WORDS = { Ammo = "ammo", SoulShards = "soul shards" }
local LEVEL = { PLENTY = "Plenty", LOW = "Low", CRITICAL = "Critical" }
local READING = { COUNTED = "Counted", NOT_APPLICABLE = "NotApplicable", UNREADABLE = "Unreadable" }
local CELL = { COUNTING = "Counting", EXPIRED = "Expired" }
local VISIBILITY = {
    OFF = "Off", SHOWN = "Shown", EMPTY = "Empty",
    HIDDEN_IN_COMBAT = "HiddenInCombat", PREVIEW = "Preview",
}
local ANCHOR = {
    BREAKDOWN = "DamageBreakdown", THREAT = "ThreatPanel",
    PLAYER_FRAME = "PlayerFrame", SCREEN = "Screen",
}
local ANCHOR_COUNTER = {
    DamageBreakdown = "anchorBreakdown", ThreatPanel = "anchorThreatPanel",
    PlayerFrame = "anchorPlayerFrame", Screen = "anchorScreen",
}
-- How a part's last read went, for /pa upkeep (section 11).
local READ = {
    NOT_READ = "NotRead", KNOWN = "Known", OFF = "Off", THROTTLED = "Throttled",
    API_MISSING = "ApiMissing", ENUMS_MISSING = "EnumsMissing",
    CALL_FAILED = "CallFailed", HIDDEN = "Hidden",
}

-- Printed by /pa upkeep in this order, zero when absent (section 11).
local COUNTER_NAMES = {
    "refreshes", "auraReadsPlain", "auraReadsWithheld", "auraReadsFailed",
    "auraEntriesUnreadable", "aurasPermanent", "aurasShort", "rosterTruncated", "iconsUnreadable",
    "enchantReadsPlain", "enchantReadsWithheld", "enchantReadsFailed", "enchantEntriesUnreadable",
    "chargesUnreadable", "cellsTruncated", "tailsLive", "tailsPostFight", "postFightRetries",
    "postFightGaveUp", "supplyReadsPlain", "supplyReadsWithheld", "ammoApplicabilityWithheld",
    "shardApplicabilityWithheld", "lowSupplyToasts", "lowSupplyCooled", "toastUnavailable",
    "anchorBreakdown", "anchorThreatPanel", "anchorPlayerFrame", "anchorScreen", "refreshFaults",
}

-- The defaults, here and in the registration below (section 10.2).
local DEFAULTS = {
    warningSeconds = 30,
    shortBuffSeconds = 60,
    showWeaponEnchants = true,
    showSupplies = true,
    lowSupplyToast = true,
    expiredTailSeconds = 10,
    maximumIcons = 6,
    attachToPanels = true,
    panelAlpha = 0.8,
    scale = 1.0,
    anchorOffsetX = 0,
    anchorOffsetY = 0,
    ammoAmberBelow = 200,
    ammoRedBelow = 50,
    shardAmberBelow = 3,
    shardRedBelow = 1,
}

local state = {
    enabled = false,
    inCombat = false,
    -- Bumped on every combat change and on disable, so a deferred transition, a wake
    -- or a retry that is no longer wanted does nothing when its time comes.
    generation = 0,
    panel = nil,
    chrome = nil,
    pool = nil,
    liveCells = {},
    tokens = {},
    counters = {},
    settings = {},
    -- Enum.WeaponSlot and Enum.ItemEnchantType, resolved once at enable.
    enums = nil,
    -- The roster as last read out of combat; the snapshot is that roster at the pull.
    roster = nil,
    snapshot = nil,
    fightStartedAt = nil,
    -- The post-fight comparison in progress, with its retries (section 4.4).
    postFight = nil,
    -- One map; only it draws Expired cells (section 4.4, audit finding 4).
    tails = {},
    supplies = {},
    lastCounted = {},
    lastNoticeAt = {},
    contents = nil,
    visibility = VISIBILITY.OFF,
    anchor = nil,
    anchorStale = false,
    -- Kept here rather than asked of the frame: IsShown is secret-capable.
    panelShown = false,
    panelWidth = 0,
    ticker = nil,
    wakeTimer = nil,
    wakeAt = nil,
    refreshScheduled = false,
    buffRead = READ.NOT_READ,
    enchantRead = READ.NOT_READ,
    buffHiddenAt = nil,
    buffApiMissing = false,
    enchantApiMissing = false,
    previewShown = false,
    faultNoted = false,
}

for key, value in pairs(DEFAULTS) do
    state.settings[key] = value
end

-- Raises a counter to value when value is higher: the most in any one draw.
local function raiseTo(counters, name, value)
    local current = counters[name] or 0
    if value > current then
        bump(counters, name, value - current)
    end
end

local function now()
    return GetTime()
end

-- Section 1.4: a supply's two thresholds from the flat keys (audit finding 1).
local function thresholdsFor(supply)
    local settings = state.settings
    if supply == SUPPLY.AMMO then
        return { amberBelow = settings.ammoAmberBelow, redBelow = settings.ammoRedBelow }
    end
    return { amberBelow = settings.shardAmberBelow, redBelow = settings.shardRedBelow }
end

-- Section 5.2.
local function supplyLevel(count, thresholds)
    if count < thresholds.redBelow then
        return LEVEL.CRITICAL
    end
    if count < thresholds.amberBelow then
        return LEVEL.LOW
    end
    return LEVEL.PLENTY
end

-- Section 4.3: Blizzard's own arithmetic (BuffFrame.lua:1233-1237).
local function remainingOf(expiresAt, timeMod, at)
    if timeMod and timeMod > 0 then
        return (expiresAt - at) / timeMod
    end
    return expiresAt - at
end

-- A Withheld read whose reason means "hidden", as opposed to "not that type".
local function hidden(kind, reason)
    return kind == WITHHELD and (reason == SECRET_VALUE or reason == CALL_FAILED)
end

-- A texture from a client call or field: a fileID, or a path on a client that gives
-- one. nil when it does not read Plain.
local function callTexture(clientFunction, ...)
    local kind, value = ClientRead.Call(clientFunction, "number", ...)
    if kind == PLAIN then
        return value
    end
    if kind == WITHHELD and value == UNEXPECTED_TYPE then
        local pathKind, path = ClientRead.Call(clientFunction, "string", ...)
        if pathKind == PLAIN then
            return path
        end
    end
    return nil
end

local function fieldTexture(container, key)
    local kind, value = ClientRead.Field(container, key, "number")
    if kind == PLAIN then
        return value
    end
    if kind == WITHHELD and value == UNEXPECTED_TYPE then
        local pathKind, path = ClientRead.Field(container, key, "string")
        if pathKind == PLAIN then
            return path
        end
    end
    return nil
end

local function emptyRoster(at)
    return {
        buffs = {}, buffsKnown = false,
        enchants = {}, weapons = {}, enchantsKnown = false,
        readAt = at,
    }
end

-- Reads: buffs (section 4.1) --------------------------------------------------------

-- One aura entry: the TrackedBuff, or nil; and true when the whole read must be
-- Hidden because a timing field is.
local function readAuraEntry(entry, counters)
    local idKind, auraInstanceId = ClientRead.Field(entry, "auraInstanceID", "number")
    local spellKind, spellId = ClientRead.Field(entry, "spellId", "number")
    local durationKind, duration = ClientRead.Field(entry, "duration", "number")
    local expiresKind, expiresAt = ClientRead.Field(entry, "expirationTime", "number")
    local modKind, timeMod = ClientRead.Field(entry, "timeMod", "number")
    if hidden(idKind, auraInstanceId) or hidden(spellKind, spellId)
        or hidden(durationKind, duration) or hidden(expiresKind, expiresAt)
        or hidden(modKind, timeMod) then
        return nil, true
    end
    if idKind ~= PLAIN or spellKind ~= PLAIN or durationKind ~= PLAIN or expiresKind ~= PLAIN then
        bump(counters, "auraEntriesUnreadable")
        return nil, false
    end
    if duration <= 0 or expiresAt <= 0 then
        bump(counters, "aurasPermanent")
        return nil, false
    end
    -- Decision D2: "60 s or less" is ignored, so exactly 60 is.
    if duration <= state.settings.shortBuffSeconds then
        bump(counters, "aurasShort")
        return nil, false
    end
    if modKind ~= PLAIN or timeMod <= 0 then
        timeMod = 1
    end
    local icon = fieldTexture(entry, "icon")
    if icon == nil then
        bump(counters, "iconsUnreadable")
        icon = ns.UPKEEP_FALLBACK_ICON
    end
    return {
        auraInstanceId = auraInstanceId,
        spellId = spellId,
        icon = icon,
        duration = duration,
        expiresAt = expiresAt,
        timeMod = timeMod,
    }, false
end

-- The player's timed buffs that Upkeep may draw. Returns the list, or nil and a READ.
local function readBuffs()
    local counters = state.counters
    local api = _G.C_UnitAuras
    if not (type(api) == "table" and ClientRead.Available(api.GetUnitAuras)) then
        return nil, READ.API_MISSING
    end
    local capacity = ns.UPKEEP_AURA_READ_CAPACITY
    local listKind, list = ClientRead.Call(api.GetUnitAuras, "table", "player", "HELPFUL", capacity + 1)
    if listKind == WITHHELD then
        if list == CALL_FAILED or list == UNAVAILABLE then
            bump(counters, "auraReadsFailed")
            return nil, READ.CALL_FAILED
        end
        bump(counters, "auraReadsWithheld")
        return nil, READ.HIDDEN
    end
    local buffs = {}
    if listKind == PLAIN then
        for index = 1, capacity + 1 do
            local entryKind, entry = ClientRead.Field(list, index, "table")
            if entryKind == ABSENT then
                break
            end
            if hidden(entryKind, entry) then
                bump(counters, "auraReadsWithheld")
                return nil, READ.HIDDEN
            end
            if index > capacity then
                bump(counters, "rosterTruncated")
                break
            end
            if entryKind ~= PLAIN then
                bump(counters, "auraEntriesUnreadable")
            else
                local buff, mustHide = readAuraEntry(entry, counters)
                if mustHide then
                    bump(counters, "auraReadsWithheld")
                    return nil, READ.HIDDEN
                end
                if buff then
                    buffs[#buffs + 1] = buff
                end
            end
        end
    end
    bump(counters, "auraReadsPlain")
    return buffs
end

-- Reads: enchants (section 4.2) -----------------------------------------------------

-- The two enums, through ClientRead, once at enable. nil when either is missing.
local function resolveEnums()
    local enumKind, enum = ClientRead.Field(_G.Enum, "WeaponSlot", "table")
    local typeKind, types = ClientRead.Field(_G.Enum, "ItemEnchantType", "table")
    if enumKind ~= PLAIN or typeKind ~= PLAIN then
        return nil
    end
    local slots = {}
    for index, name in ipairs({ "MainHand", "OffHand", "Ranged" }) do
        local kind, value = ClientRead.Field(enum, name, "number")
        if kind ~= PLAIN then
            return nil
        end
        slots[index] = value
    end
    local temporaryKind, temporary = ClientRead.Field(types, "Temporary", "number")
    local imbueKind, imbue = ClientRead.Field(types, "Imbue", "number")
    if temporaryKind ~= PLAIN or imbueKind ~= PLAIN then
        return nil
    end
    return { slots = slots, temporary = temporary, imbue = imbue }
end

-- One WeaponEnchantInfo: the TrackedEnchant, or nil; and true when the whole read
-- must be Hidden.
local function readEnchantEntry(entry, slotIndex, weapon, at, counters)
    local enums = state.enums
    local hasKind, hasEnchant = ClientRead.Field(entry, "hasEnchant", "boolean")
    local typeKind, enchantType = ClientRead.Field(entry, "enchantType", "number")
    local timeKind, timeLeft = ClientRead.Field(entry, "timeLeft", "number")
    local idKind, enchantId = ClientRead.Field(entry, "enchantID", "number")
    if hidden(hasKind, hasEnchant) or hidden(typeKind, enchantType)
        or hidden(timeKind, timeLeft) or hidden(idKind, enchantId) then
        return nil, true
    end
    if hasKind == PLAIN and hasEnchant ~= true then
        return nil, false
    end
    if hasKind ~= PLAIN or typeKind ~= PLAIN or timeKind ~= PLAIN or idKind ~= PLAIN then
        bump(counters, "enchantEntriesUnreadable")
        return nil, false
    end
    if (enchantType ~= enums.temporary and enchantType ~= enums.imbue) or timeLeft <= 0 then
        return nil, false
    end
    if weapon == nil then
        return nil, false
    end
    local charges = 0
    local chargeKind, chargeValue = ClientRead.Field(entry, "charges", "number")
    if chargeKind == PLAIN then
        charges = max(0, chargeValue)
    elseif chargeKind == WITHHELD then
        bump(counters, "chargesUnreadable")
    end
    local icon = callTexture(_G.GetInventoryItemTexture, "player", ns.UPKEEP_WEAPON_INVENTORY_SLOTS[slotIndex])
    if icon == nil then
        bump(counters, "iconsUnreadable")
        icon = ns.UPKEEP_FALLBACK_ICON
    end
    return {
        slot = slotIndex,
        enchantId = enchantId,
        icon = icon,
        charges = charges,
        -- Milliseconds (premise 92; BuffFrame.lua:775).
        expiresAt = at + timeLeft / 1000,
        timeMod = 1,
    }, false
end

-- Every weapon slot's temporary enchants, all-or-nothing (audit finding 3). Returns
-- { enchants, weapons }, or nil and a READ.
local function readEnchants(at)
    local counters = state.counters
    local api = _G.C_Item
    if not (type(api) == "table" and ClientRead.Available(api.GetWeaponEnchantInfo)) then
        return nil, READ.API_MISSING
    end
    if not state.enums then
        return nil, READ.ENUMS_MISSING
    end
    local reading = { enchants = {}, weapons = {} }
    -- Each slot's list is read to a fixed bound, keeping at most the per-slot cap.
    local scanBound = ns.UPKEEP_ENCHANTS_PER_SLOT * 4
    for slotIndex = 1, #ns.UPKEEP_WEAPON_INVENTORY_SLOTS do
        local inventorySlot = ns.UPKEEP_WEAPON_INVENTORY_SLOTS[slotIndex]
        local weaponKind, weaponId = ClientRead.Call(_G.GetInventoryItemID, "number", "player", inventorySlot)
        local weapon = nil
        if weaponKind == PLAIN then
            weapon = weaponId
        end
        reading.weapons[slotIndex] = weapon
        local listKind, list = ClientRead.Call(api.GetWeaponEnchantInfo, "table", state.enums.slots[slotIndex])
        if listKind == WITHHELD then
            if list == CALL_FAILED or list == UNAVAILABLE then
                bump(counters, "enchantReadsFailed")
                return nil, READ.CALL_FAILED
            end
            bump(counters, "enchantReadsWithheld")
            return nil, READ.HIDDEN
        end
        if listKind == PLAIN then
            local kept = 0
            for entryIndex = 1, scanBound do
                if kept >= ns.UPKEEP_ENCHANTS_PER_SLOT then
                    break
                end
                local entryKind, entry = ClientRead.Field(list, entryIndex, "table")
                if entryKind == ABSENT then
                    break
                end
                if hidden(entryKind, entry) then
                    bump(counters, "enchantReadsWithheld")
                    return nil, READ.HIDDEN
                end
                if entryKind ~= PLAIN then
                    bump(counters, "enchantEntriesUnreadable")
                else
                    local enchant, mustHide = readEnchantEntry(entry, slotIndex, weapon, at, counters)
                    if mustHide then
                        bump(counters, "enchantReadsWithheld")
                        return nil, READ.HIDDEN
                    end
                    if enchant then
                        kept = kept + 1
                        reading.enchants[#reading.enchants + 1] = enchant
                    end
                end
            end
        end
    end
    bump(counters, "enchantReadsPlain")
    return reading
end

-- The roster: buffs and enchants, each Known or not, with why (section 4).
-- force skips the Hidden throttle, for the post-fight retries.
local function readRoster(at, force)
    local roster = emptyRoster(at)
    local settings = state.settings

    if state.buffApiMissing then
        state.buffRead = READ.API_MISSING
    elseif not force and state.buffHiddenAt
        and at - state.buffHiddenAt < ns.UPKEEP_WITHHELD_RETRY_SECONDS then
        state.buffRead = READ.THROTTLED
    else
        local buffs, failure = readBuffs()
        if buffs then
            roster.buffs, roster.buffsKnown = buffs, true
            state.buffHiddenAt = nil
            state.buffRead = READ.KNOWN
        else
            state.buffRead = failure
            if failure == READ.API_MISSING then
                state.buffApiMissing = true
                ns.Log.Once("upkeep:noauras",
                    "this client has no C_UnitAuras.GetUnitAuras, so Upkeep shows no buffs; enchants and counts still show")
            elseif failure == READ.HIDDEN then
                state.buffHiddenAt = at
            end
        end
    end

    if not settings.showWeaponEnchants then
        -- Off is not Known: a part switched off must never read as "everything gone".
        state.enchantRead = READ.OFF
    elseif state.enchantApiMissing then
        state.enchantRead = READ.API_MISSING
    else
        local reading, failure = readEnchants(at)
        if reading then
            roster.enchants, roster.weapons = reading.enchants, reading.weapons
            roster.enchantsKnown = true
            state.enchantRead = READ.KNOWN
        else
            state.enchantRead = failure
            if failure == READ.API_MISSING or failure == READ.ENUMS_MISSING then
                state.enchantApiMissing = true
                ns.Log.Once("upkeep:noenchants", format(
                    "this client cannot report weapon enchants (%s), so Upkeep shows none; buffs and counts still show",
                    failure == READ.API_MISSING and "no C_Item.GetWeaponEnchantInfo" or "no WeaponSlot or ItemEnchantType enum"))
            end
        end
    end
    return roster
end

-- Reads: supplies (section 5.1) -------------------------------------------------------

local function unreadable(supply, reason)
    return { supply = supply, state = READING.UNREADABLE, reason = tostring(reason) }
end

local function notApplicable(supply)
    return { supply = supply, state = READING.NOT_APPLICABLE }
end

local function counted(supply, count, icon, counters)
    bump(counters, "supplyReadsPlain")
    return { supply = supply, state = READING.COUNTED, count = count, icon = icon or ns.UPKEEP_FALLBACK_ICON }
end

local function itemCount(itemId)
    local api = _G.C_Item
    return ClientRead.Call(type(api) == "table" and api.GetItemCount or nil, "number", itemId)
end

-- Ammo is decided by the client's own predicate, the one the character pane's ammo
-- slot follows (premise 89). No class list.
local function readAmmo(counters)
    local usesKind, uses = ClientRead.Call(_G.UnitUsesAmmo, "boolean", "player")
    if usesKind ~= PLAIN then
        bump(counters, "ammoApplicabilityWithheld")
        if uses == UNAVAILABLE then
            ns.Log.Once("upkeep:nousesammo", "this client has no UnitUsesAmmo, so Upkeep shows no ammo count")
        end
        return unreadable(SUPPLY.AMMO, uses)
    end
    if uses ~= true then
        return notApplicable(SUPPLY.AMMO)
    end
    local idKind, itemId = ClientRead.Call(_G.GetInventoryItemID, "number", "player", ns.UPKEEP_AMMO_SLOT)
    if idKind == ABSENT then
        -- Uses ammo and has none: the case the counter exists for.
        return counted(SUPPLY.AMMO, 0, ns.UPKEEP_FALLBACK_ICON, counters)
    end
    if idKind ~= PLAIN then
        bump(counters, "supplyReadsWithheld")
        return unreadable(SUPPLY.AMMO, itemId)
    end
    local countKind, count = itemCount(itemId)
    if countKind ~= PLAIN then
        bump(counters, "supplyReadsWithheld")
        return unreadable(SUPPLY.AMMO, count)
    end
    local icon = callTexture(_G.GetInventoryItemTexture, "player", ns.UPKEEP_AMMO_SLOT)
    if icon == nil then
        bump(counters, "iconsUnreadable")
    end
    return counted(SUPPLY.AMMO, count, icon, counters)
end

-- Soul shards are an item on this client (premise 95; decision D11).
local function readShards(counters)
    local classKind, classFile = ClientRead.CallNth(_G.UnitClass, 2, "string", "player")
    if classKind ~= PLAIN then
        bump(counters, "shardApplicabilityWithheld")
        return unreadable(SUPPLY.SHARDS, classFile)
    end
    if classFile ~= "WARLOCK" then
        return notApplicable(SUPPLY.SHARDS)
    end
    local countKind, count = itemCount(ns.SOUL_SHARD_ITEM_ID)
    if countKind ~= PLAIN then
        bump(counters, "supplyReadsWithheld")
        return unreadable(SUPPLY.SHARDS, count)
    end
    local api = _G.C_Item
    local icon = callTexture(type(api) == "table" and api.GetItemIconByID or nil, ns.SOUL_SHARD_ITEM_ID)
    if icon == nil then
        bump(counters, "iconsUnreadable")
    end
    return counted(SUPPLY.SHARDS, count, icon, counters)
end

local function readSupplies()
    local counters = state.counters
    if not state.settings.showSupplies then
        state.supplies[SUPPLY.AMMO] = notApplicable(SUPPLY.AMMO)
        state.supplies[SUPPLY.SHARDS] = notApplicable(SUPPLY.SHARDS)
        return
    end
    state.supplies[SUPPLY.AMMO] = readAmmo(counters)
    state.supplies[SUPPLY.SHARDS] = readShards(counters)
end

-- The low-supply toast (section 5.3) --------------------------------------------------

local function lowSupplyNotice(supply, reading, at)
    if reading.state ~= READING.COUNTED then
        return nil
    end
    local previous = state.lastCounted[supply]
    if previous == nil then
        return nil
    end
    local redBelow = thresholdsFor(supply).redBelow
    if not (previous >= redBelow and reading.count < redBelow) then
        return nil
    end
    if not state.settings.lowSupplyToast then
        return nil
    end
    local last = state.lastNoticeAt[supply]
    if last and at - last < ns.UPKEEP_LOW_SUPPLY_COOLDOWN_SECONDS then
        bump(state.counters, "lowSupplyCooled")
        return nil
    end
    return { supply = supply, count = reading.count, icon = reading.icon }
end

local function postLowSupply(notice, at)
    local counters = state.counters
    bump(counters, "lowSupplyToasts")
    state.lastNoticeAt[notice.supply] = at
    local outcome = "Unavailable"
    if ns.Toasts and ns.Toasts.Post then
        outcome = ns.Toasts.Post({
            kind = "SupplyLow", supply = notice.supply, count = notice.count, icon = notice.icon,
        })
    end
    if outcome == "Unavailable" or outcome == "Dropped" then
        bump(counters, "toastUnavailable")
        ns.Log.Info(format("%s %s: %d left", notice.count <= 0 and "out of" or "low on",
            SUPPLY_WORDS[notice.supply] or "supplies", notice.count))
    end
    return outcome
end

-- Every supply's crossing, then the readings kept for the next comparison. An
-- Unreadable reading keeps the last Counted one; a NotApplicable one drops it, so a
-- supply that comes back starts from a fresh baseline and never toasts on return.
local function checkCrossings(at)
    for _, supply in ipairs(SUPPLY_ORDER) do
        local reading = state.supplies[supply]
        if reading then
            local notice = lowSupplyNotice(supply, reading, at)
            if reading.state == READING.COUNTED then
                state.lastCounted[supply] = reading.count
            elseif reading.state == READING.NOT_APPLICABLE then
                state.lastCounted[supply] = nil
            end
            if notice then
                postLowSupply(notice, at)
            end
        end
    end
end

-- Tails (section 4.4) -----------------------------------------------------------------

local function buffKey(spellId)
    return "B:" .. tostring(spellId)
end

local function enchantKey(slot)
    return "E:" .. tostring(slot)
end

-- Every insertion is refused when tails are off or the tail would already be over.
-- An existing key keeps the later end. The map holds at most maximumIcons tails; the
-- one ending soonest goes first.
local function insertTail(key, source, icon, endsAt, at)
    local seconds = state.settings.expiredTailSeconds
    if not seconds or seconds <= 0 or endsAt <= at then
        return false
    end
    local existing = state.tails[key]
    if existing then
        if endsAt > existing.endsAt then
            existing.endsAt = endsAt
        end
        return false
    end
    local count, oldestKey, oldestEnds = 0, nil, nil
    for tailKey, tail in pairs(state.tails) do
        count = count + 1
        if oldestEnds == nil or tail.endsAt < oldestEnds then
            oldestKey, oldestEnds = tailKey, tail.endsAt
        end
    end
    if count >= max(1, state.settings.maximumIcons) then
        if oldestEnds and endsAt <= oldestEnds then
            return false
        end
        state.tails[oldestKey] = nil
    end
    state.tails[key] = { key = key, source = source, icon = icon, endsAt = endsAt }
    return true
end

local function spellsIn(roster)
    local present = {}
    for _, buff in ipairs(roster.buffs) do
        present[buff.spellId] = true
    end
    return present
end

local function enchantedSlotsIn(roster)
    local present = {}
    for _, enchant in ipairs(roster.enchants) do
        present[enchant.slot] = true
    end
    return present
end

-- The weapon read Plain on both sides and unchanged (audit finding 3).
local function sameWeapon(before, after, slot)
    local weaponBefore, weaponAfter = before.weapons[slot], after.weapons[slot]
    return weaponBefore ~= nil and weaponAfter ~= nil and weaponBefore == weaponAfter
end

-- Between two out-of-combat reads.
local function liveTails(previous, current, at)
    if not previous then
        return
    end
    local counters = state.counters
    local seconds = state.settings.expiredTailSeconds
    if previous.buffsKnown and current.buffsKnown then
        local present = spellsIn(current)
        for _, buff in ipairs(previous.buffs) do
            if not present[buff.spellId] and buff.expiresAt <= at + ns.UPKEEP_EXPIRY_TOLERANCE_SECONDS then
                if insertTail(buffKey(buff.spellId), SOURCE.BUFF, buff.icon, buff.expiresAt + seconds, at) then
                    bump(counters, "tailsLive")
                end
            end
        end
    end
    if previous.enchantsKnown and current.enchantsKnown then
        local present = enchantedSlotsIn(current)
        for _, enchant in ipairs(previous.enchants) do
            local slot = enchant.slot
            if not present[slot] and sameWeapon(previous, current, slot) then
                if insertTail(enchantKey(slot), SOURCE.ENCHANT, enchant.icon, at + seconds, at) then
                    bump(counters, "tailsLive")
                end
            end
        end
    end
end

-- What ran out during the fight; every tail ends a full tail after the fight does.
local function postFightTails(postFight, current, at)
    local snapshot = postFight.snapshot
    local counters = state.counters
    local endsAt = postFight.endedAt + state.settings.expiredTailSeconds
    if not postFight.buffsDone then
        if not snapshot.buffsKnown then
            postFight.buffsDone = true
        elseif current.buffsKnown then
            local present = spellsIn(current)
            for _, buff in ipairs(snapshot.buffs) do
                if postFight.startedAt < buff.expiresAt
                    and buff.expiresAt <= postFight.endedAt + ns.UPKEEP_EXPIRY_TOLERANCE_SECONDS
                    and not present[buff.spellId] then
                    if insertTail(buffKey(buff.spellId), SOURCE.BUFF, buff.icon, endsAt, at) then
                        bump(counters, "tailsPostFight")
                    end
                end
            end
            postFight.buffsDone = true
        end
    end
    if not postFight.enchantsDone then
        if not snapshot.enchantsKnown then
            postFight.enchantsDone = true
        elseif current.enchantsKnown then
            local present = enchantedSlotsIn(current)
            for _, enchant in ipairs(snapshot.enchants) do
                local slot = enchant.slot
                if not present[slot] and sameWeapon(snapshot, current, slot) then
                    if insertTail(enchantKey(slot), SOURCE.ENCHANT, enchant.icon, endsAt, at) then
                        bump(counters, "tailsPostFight")
                    end
                end
            end
            postFight.enchantsDone = true
        end
    end
end

-- A drawn entry at zero while the client still lists it: the server's removal lags
-- our clock. It joins the map, so it is drawn once (audit finding 4).
local function tickTails(at)
    local roster = state.roster
    if not roster then
        return
    end
    local counters = state.counters
    local seconds = state.settings.expiredTailSeconds
    if roster.buffsKnown then
        for _, buff in ipairs(roster.buffs) do
            if remainingOf(buff.expiresAt, buff.timeMod, at) <= 0 then
                if insertTail(buffKey(buff.spellId), SOURCE.BUFF, buff.icon, buff.expiresAt + seconds, at) then
                    bump(counters, "tailsLive")
                end
            end
        end
    end
    if roster.enchantsKnown then
        for _, enchant in ipairs(roster.enchants) do
            if enchant.expiresAt - at <= 0 then
                if insertTail(enchantKey(enchant.slot), SOURCE.ENCHANT, enchant.icon, enchant.expiresAt + seconds, at) then
                    bump(counters, "tailsLive")
                end
            end
        end
    end
end

-- Removes ended tails, and any whose buff or enchant is back with time on it: a
-- renewal ends its tail at once (T2, T14).
local function reconcileTails(at)
    local roster = state.roster
    local renewedSpells, renewedSlots = {}, {}
    if roster and roster.buffsKnown then
        for _, buff in ipairs(roster.buffs) do
            if remainingOf(buff.expiresAt, buff.timeMod, at) > 0 then
                renewedSpells[buffKey(buff.spellId)] = true
            end
        end
    end
    if roster and roster.enchantsKnown then
        for _, enchant in ipairs(roster.enchants) do
            if enchant.expiresAt - at > 0 then
                renewedSlots[enchantKey(enchant.slot)] = true
            end
        end
    end
    for key, tail in pairs(state.tails) do
        if tail.endsAt <= at or renewedSpells[key] or renewedSlots[key] then
            state.tails[key] = nil
        end
    end
end

local function clearTails()
    for key in pairs(state.tails) do
        state.tails[key] = nil
    end
end

-- Cells (section 4.5) -------------------------------------------------------------------

local function buildContents(at)
    local settings = state.settings
    local supplies = {}
    for _, supply in ipairs(SUPPLY_ORDER) do
        local reading = state.supplies[supply]
        if reading and reading.state == READING.COUNTED then
            supplies[#supplies + 1] = reading
        end
    end

    local expired, counting = {}, {}
    for _, tail in pairs(state.tails) do
        if tail.endsAt > at then
            expired[#expired + 1] = {
                kind = CELL.EXPIRED, source = tail.source, icon = tail.icon,
                endsAt = tail.endsAt, key = tail.key, charges = 0,
            }
        end
    end
    local roster = state.roster
    if roster then
        local warning = settings.warningSeconds
        if roster.enchantsKnown then
            for _, enchant in ipairs(roster.enchants) do
                local remaining = enchant.expiresAt - at
                if remaining > 0 and remaining <= warning then
                    counting[#counting + 1] = {
                        kind = CELL.COUNTING, source = SOURCE.ENCHANT, icon = enchant.icon,
                        remaining = remaining, charges = enchant.charges, order = enchant.slot,
                    }
                end
            end
        end
        if roster.buffsKnown then
            for _, buff in ipairs(roster.buffs) do
                local remaining = remainingOf(buff.expiresAt, buff.timeMod, at)
                if remaining > 0 and remaining <= warning then
                    counting[#counting + 1] = {
                        kind = CELL.COUNTING, source = SOURCE.BUFF, icon = buff.icon,
                        remaining = remaining, charges = 0, order = buff.auraInstanceId,
                    }
                end
            end
        end
    end

    sort(expired, function(left, right)
        if left.endsAt ~= right.endsAt then
            return left.endsAt > right.endsAt
        end
        return left.key < right.key
    end)
    sort(counting, function(left, right)
        if left.remaining ~= right.remaining then
            return left.remaining < right.remaining
        end
        if left.source ~= right.source then
            return left.source == SOURCE.ENCHANT
        end
        return left.order < right.order
    end)

    local cells = {}
    for index = 1, #expired do
        cells[#cells + 1] = expired[index]
    end
    for index = 1, #counting do
        cells[#cells + 1] = counting[index]
    end
    local limit = max(1, settings.maximumIcons)
    local truncated = 0
    if #cells > limit then
        truncated = #cells - limit
        for index = #cells, limit + 1, -1 do
            cells[index] = nil
        end
    end
    raiseTo(state.counters, "cellsTruncated", truncated)
    return { supplies = supplies, cells = cells, truncated = truncated }
end

-- Drawing (section 6.1) ------------------------------------------------------------------

local function countdownText(remaining)
    if remaining >= 60 then
        return format("%dm", ceil(remaining / 60))
    end
    return format("%d", ceil(remaining))
end

local function setCellIcon(texture, icon)
    if icon == nil or texture:SetTexture(icon) == false then
        texture:SetTexture(ns.UPKEEP_FALLBACK_ICON)
    end
end

local function createCell()
    local cell = CreateFrame("Frame", nil, state.panel)
    cell:SetWidth(ns.UPKEEP_CELL_WIDTH)
    cell:SetHeight(ns.UPKEEP_CELL_HEIGHT)
    cell:EnableMouse(false)

    cell.icon = cell:CreateTexture(nil, "ARTWORK")
    cell.icon:SetWidth(ns.UPKEEP_ICON_SIZE)
    cell.icon:SetHeight(ns.UPKEEP_ICON_SIZE)
    cell.icon:SetPoint("TOP", cell, "TOP", 0, 0)

    cell.text = cell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cell.text:SetPoint("TOP", cell.icon, "BOTTOM", 0, -2)
    cell.text:SetWidth(ns.UPKEEP_CELL_WIDTH)
    cell.text:SetJustifyH("CENTER")
    cell.text:SetWordWrap(false)

    cell.charges = cell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cell.charges:SetPoint("BOTTOMRIGHT", cell.icon, "BOTTOMRIGHT", 1, 1)
    cell.charges:SetJustifyH("RIGHT")
    return cell
end

-- Everything a cell shows, emptied: a reused cell is never red or grey by accident.
local function resetCell(cell)
    cell:Hide()
    cell:ClearAllPoints()
    cell.icon:SetTexture(nil)
    cell.icon:SetTexCoord(0, 1, 0, 1)
    cell.icon:SetDesaturated(false)
    cell.icon:SetVertexColor(1, 1, 1)
    cell.text:SetText("")
    cell.text:SetTextColor(1, 1, 1)
    cell.charges:SetText("")
    cell.entry = nil
end

local function paintCell(cell, entry)
    cell.entry = entry
    cell.icon:SetDesaturated(false)
    cell.icon:SetVertexColor(1, 1, 1)
    cell.charges:SetText("")
    setCellIcon(cell.icon, entry.icon)
    if entry.state == READING.COUNTED then
        local level = supplyLevel(entry.count, thresholdsFor(entry.supply))
        local colour = level == LEVEL.CRITICAL and ns.UPKEEP_RED
            or level == LEVEL.LOW and ns.UPKEEP_AMBER or nil
        cell.text:SetText(tostring(entry.count))
        if colour then
            cell.text:SetTextColor(colour[1], colour[2], colour[3])
        else
            cell.text:SetTextColor(1, 1, 1)
        end
        return
    end
    if entry.kind == CELL.EXPIRED then
        local tint = ns.UPKEEP_EXPIRED_TINT
        cell.icon:SetDesaturated(true)
        cell.icon:SetVertexColor(tint[1], tint[2], tint[3])
        cell.text:SetText("")
        cell.text:SetTextColor(1, 1, 1)
        return
    end
    cell.text:SetText(countdownText(entry.remaining))
    cell.text:SetTextColor(1, 1, 1)
    if (entry.charges or 0) > 0 then
        cell.charges:SetText(tostring(entry.charges))
    end
end

local function anchorCell(cell, index)
    cell:ClearAllPoints()
    cell:SetPoint("TOPRIGHT", state.panel, "TOPRIGHT",
        -(ns.UPKEEP_PADDING + (index - 1) * (ns.UPKEEP_CELL_WIDTH + ns.UPKEEP_CELL_SPACING)),
        -ns.UPKEEP_PADDING)
end

local function releaseCells()
    local live = state.liveCells
    for index = #live, 1, -1 do
        ns.FramePool.Release(state.pool, live[index])
        live[index] = nil
    end
end

local function hidePanel(visibility)
    releaseCells()
    if state.panel then
        state.panel:Hide()
    end
    state.panelShown = false
    state.visibility = visibility
end

-- Supplies first, then expiry cells, right to left from the anchored edge. Returns
-- how many cells were drawn.
local function drawContents(contents, visibility)
    if not state.panel then
        return 0
    end
    local entries = {}
    for index = 1, #contents.supplies do
        entries[#entries + 1] = contents.supplies[index]
    end
    for index = 1, #contents.cells do
        entries[#entries + 1] = contents.cells[index]
    end

    local live = state.liveCells
    while #live > #entries do
        ns.FramePool.Release(state.pool, live[#live])
        live[#live] = nil
    end
    while #live < #entries do
        local cell, poolError = ns.FramePool.Acquire(state.pool)
        if not cell then
            ns.Log.OnceError("upkeep:poolexhausted", format(
                "Upkeep's cell pool was exhausted (%s)", tostring(poolError)))
            break
        end
        live[#live + 1] = cell
        anchorCell(cell, #live)
        cell:Show()
    end

    local total = #live
    for index = 1, total do
        paintCell(live[index], entries[index])
    end
    if total == 0 then
        state.panel:Hide()
        state.panelShown = false
        state.visibility = VISIBILITY.EMPTY
        return 0
    end
    local width = ns.UPKEEP_PADDING * 2 + total * ns.UPKEEP_CELL_WIDTH
        + (total - 1) * ns.UPKEEP_CELL_SPACING
    state.panelWidth = width
    state.panel:SetWidth(width)
    state.panel:SetHeight(ns.UPKEEP_PADDING * 2 + ns.UPKEEP_CELL_HEIGHT)
    ns.PanelChrome.SetAlpha(state.chrome, state.settings.panelAlpha)
    state.panel:Show()
    state.panelShown = true
    state.visibility = visibility or VISIBILITY.SHOWN
    return total
end

-- Placement (section 6.2) ------------------------------------------------------------------

-- A panel of ours to attach to: its feature ENABLED and its frame built.
local function panelOf(featureId, api)
    if type(api) ~= "table" or type(api.Frame) ~= "function" then
        return nil
    end
    if ns.Registry.State(featureId) ~= ns.FEATURE_STATE.ENABLED then
        return nil
    end
    return api.Frame()
end

local function resolveAnchor()
    local gap = ns.UPKEEP_ATTACH_GAP
    if state.settings.attachToPanels then
        local frame = panelOf(BREAKDOWN_ID, ns.DamageBreakdown)
        if frame then
            return ANCHOR.BREAKDOWN, frame, "BOTTOMRIGHT", "BOTTOMLEFT", -gap, 0
        end
        frame = panelOf(THREAT_ID, ns.ThreatPanel)
        if frame then
            return ANCHOR.THREAT, frame, "BOTTOMRIGHT", "BOTTOMLEFT", -gap, 0
        end
    end
    if _G.PlayerFrame then
        return ANCHOR.PLAYER_FRAME, _G.PlayerFrame, "BOTTOMRIGHT", "TOPLEFT", -gap, ns.UPKEEP_DETACHED_BASE_Y
    end
    ns.Log.Once("upkeep:noplayerframe",
        "PlayerFrame was not found; Upkeep is anchored to the middle of the screen instead")
    return ANCHOR.SCREEN, _G.UIParent, "BOTTOMRIGHT", "CENTER", 0, 0
end

local function anchorPanel()
    if not state.panel then
        return
    end
    local target, frame, panelPoint, targetPoint, baseX, baseY = resolveAnchor()
    if not frame then
        ns.Log.OnceError("upkeep:noanchor", "neither PlayerFrame nor UIParent exists; Upkeep cannot be anchored")
        return
    end
    state.anchor = target
    state.anchorStale = false
    bump(state.counters, ANCHOR_COUNTER[target])
    local settings = state.settings
    ns.PanelChrome.Place(state.panel, frame, panelPoint, targetPoint, {
        scale = settings.scale,
        offsetX = baseX + settings.anchorOffsetX,
        offsetY = baseY + settings.anchorOffsetY,
    })
end

-- Scheduling (section 6.4) ------------------------------------------------------------------

local guardedTick

local function stopTicker()
    if state.ticker and state.ticker.Cancel then
        state.ticker:Cancel()
    end
    state.ticker = nil
end

local function cancelWake()
    if state.wakeTimer and state.wakeTimer.Cancel then
        state.wakeTimer:Cancel()
    end
    state.wakeTimer = nil
    state.wakeAt = nil
end

-- Only thresholds still ahead count (audit finding 6): an entry past its threshold
-- and not drawn waits for the next signal instead of re-arming every frame.
local function nextWake(at)
    local roster = state.roster
    if not roster then
        return nil
    end
    local warning = state.settings.warningSeconds
    local best = nil
    if roster.buffsKnown then
        for _, buff in ipairs(roster.buffs) do
            local wakeAt = buff.expiresAt - warning * buff.timeMod
            if wakeAt > at and (best == nil or wakeAt < best) then
                best = wakeAt
            end
        end
    end
    if roster.enchantsKnown then
        for _, enchant in ipairs(roster.enchants) do
            local wakeAt = enchant.expiresAt - warning
            if wakeAt > at and (best == nil or wakeAt < best) then
                best = wakeAt
            end
        end
    end
    if best == nil then
        return nil
    end
    return min(max(best, at + ns.UPKEEP_TICK_SECONDS), at + ns.UPKEEP_MAXIMUM_WAKE_SECONDS)
end

local function scheduleTiming(contents, at)
    if #contents.cells > 0 then
        cancelWake()
        if not state.ticker then
            state.ticker = C_Timer.NewTicker(ns.UPKEEP_TICK_SECONDS, function()
                guardedTick()
            end)
        end
        return
    end
    stopTicker()
    local wakeAt = nextWake(at)
    if wakeAt ~= nil and wakeAt == state.wakeAt and state.wakeTimer then
        return
    end
    cancelWake()
    if wakeAt == nil then
        return
    end
    state.wakeAt = wakeAt
    local generation = state.generation
    state.wakeTimer = C_Timer.NewTimer(wakeAt - at, function()
        state.wakeTimer = nil
        state.wakeAt = nil
        if generation == state.generation and state.enabled and not state.inCombat then
            guardedTick()
        end
    end)
end

local function previewOwnsPanel()
    return state.previewShown and ns.Preview.IsEnabled()
end

-- No client read: countdowns move, items enter the window, tails begin and end.
local function tick()
    if not state.enabled or state.inCombat or previewOwnsPanel() then
        stopTicker()
        return
    end
    local at = now()
    tickTails(at)
    reconcileTails(at)
    local contents = buildContents(at)
    state.contents = contents
    drawContents(contents)
    scheduleTiming(contents, at)
end

local function noteFault(fault)
    bump(state.counters, "refreshFaults")
    if not state.faultNoted then
        state.faultNoted = true
        ns.Diagnostics.NoteFault(FEATURE_ID, fault)
    end
    ns.Log.OnceError("upkeep:fault", "an Upkeep update raised and was skipped; /pa diag shows the message")
end

guardedTick = function()
    local ok, fault = ns.Isolation.Call(tick)
    if not ok then
        noteFault(fault)
    end
end

-- Refreshes (sections 4, 5.3, 6.4) ----------------------------------------------------------

local requestRefresh

-- While hidden in combat: supplies only (audit finding 2). The roster, the snapshot,
-- the tails and the panel are left exactly as they are.
local function refreshInCombat(at)
    readSupplies()
    checkCrossings(at)
end

-- The post-fight comparison, then a retry while buffs are still hidden (section 4.4).
local function applyPostFight(postFight, current, at)
    postFightTails(postFight, current, at)
    if postFight.buffsDone and postFight.enchantsDone then
        state.postFight = nil
        return
    end
    if postFight.retryPending then
        return
    end
    if postFight.attempts >= ns.UPKEEP_POST_FIGHT_RETRIES then
        if not postFight.buffsDone then
            bump(state.counters, "postFightGaveUp")
        end
        state.postFight = nil
        return
    end
    postFight.attempts = postFight.attempts + 1
    postFight.retryPending = true
    bump(state.counters, "postFightRetries")
    local generation = state.generation
    C_Timer.After(ns.UPKEEP_POST_FIGHT_RETRY_SECONDS, function()
        postFight.retryPending = false
        if generation == state.generation and state.enabled and state.postFight == postFight then
            requestRefresh()
        end
    end)
end

local function refreshNow()
    state.refreshScheduled = false
    if not state.enabled then
        return
    end
    local at = now()
    if state.inCombat then
        refreshInCombat(at)
        return
    end
    -- The fight has ended and its transition has not run yet: it refreshes itself.
    if state.snapshot then
        return
    end
    if previewOwnsPanel() then
        return
    end
    bump(state.counters, "refreshes")
    if state.anchorStale then
        anchorPanel()
    end
    local postFight = state.postFight
    local current = readRoster(at, postFight ~= nil)
    readSupplies()
    checkCrossings(at)
    local previous = state.roster
    state.roster = current
    if postFight then
        applyPostFight(postFight, current, at)
    else
        liveTails(previous, current, at)
    end
    tickTails(at)
    reconcileTails(at)
    local contents = buildContents(at)
    state.contents = contents
    drawContents(contents)
    scheduleTiming(contents, at)
end

local function guardedRefresh()
    local ok, fault = ns.Isolation.Call(refreshNow)
    if not ok then
        state.refreshScheduled = false
        noteFault(fault)
    end
end

requestRefresh = function()
    if state.refreshScheduled or not state.enabled then
        return
    end
    state.refreshScheduled = true
    C_Timer.After(0, function()
        if state.enabled then
            guardedRefresh()
        else
            state.refreshScheduled = false
        end
    end)
end

-- Preview (section 6.3) ---------------------------------------------------------------------

-- Reads no client value and moves no counter beyond the draw itself.
local function previewContents()
    local fallback = ns.UPKEEP_FALLBACK_ICON
    local supplies = {
        { supply = SUPPLY.AMMO, state = READING.COUNTED, count = 180, icon = fallback },
    }
    local samples = {
        { kind = CELL.EXPIRED, source = SOURCE.BUFF, icon = fallback, endsAt = 0, key = "sample", charges = 0 },
        { kind = CELL.COUNTING, source = SOURCE.BUFF, icon = fallback, remaining = 7, charges = 0 },
        { kind = CELL.COUNTING, source = SOURCE.ENCHANT, icon = fallback, remaining = 18, charges = 12 },
        { kind = CELL.COUNTING, source = SOURCE.BUFF, icon = fallback, remaining = 24, charges = 0 },
    }
    -- Only the expiry samples are cut, as in the real panel (audit finding 5).
    local cells = {}
    local limit = max(1, state.settings.maximumIcons)
    for index = 1, min(limit, #samples) do
        cells[index] = samples[index]
    end
    return { supplies = supplies, cells = cells, truncated = #samples - #cells }
end

local function showSamples()
    if not state.panel then
        return 0
    end
    stopTicker()
    cancelWake()
    state.previewShown = true
    anchorPanel()
    releaseCells()
    return drawContents(previewContents(), VISIBILITY.PREVIEW)
end

local function clearSamples()
    local wasShown = state.previewShown
    state.previewShown = false
    if wasShown then
        hidePanel(state.inCombat and VISIBILITY.HIDDEN_IN_COMBAT or VISIBILITY.EMPTY)
    end
    -- The preview's end redraws the real state at once (Phase 20 section 3.5's lesson).
    if state.enabled and not state.inCombat then
        guardedRefresh()
    end
end

local function registerPreview()
    ns.Preview.Register({
        panelId = ns.PREVIEW_PANEL.UPKEEP,
        raiseTarget = state.panel,
        baseStrata = state.chrome and state.chrome.baseStrata or nil,
        show = showSamples,
        clear = clearSamples,
    })
end

-- Combat (section 6.4) ------------------------------------------------------------------------

-- Runs action a frame later, unless a later combat change or a disable came first.
local function scheduleTransition(action)
    state.generation = state.generation + 1
    local generation = state.generation
    C_Timer.After(0, function()
        if generation == state.generation and state.enabled then
            local ok, fault = ns.Isolation.Call(action)
            if not ok then
                noteFault(fault)
            end
        end
    end)
end

local function enterCombat()
    state.fightStartedAt = now()
    state.snapshot = state.roster
    state.postFight = nil
    clearTails()
    stopTicker()
    cancelWake()
    hidePanel(VISIBILITY.HIDDEN_IN_COMBAT)
end

local function leaveCombat()
    local at = now()
    if state.snapshot and state.fightStartedAt then
        state.postFight = {
            snapshot = state.snapshot, startedAt = state.fightStartedAt, endedAt = at,
            attempts = 0, buffsDone = false, enchantsDone = false, retryPending = false,
        }
    end
    state.snapshot = nil
    state.fightStartedAt = nil
    state.anchorStale = true
    state.visibility = VISIBILITY.EMPTY
    refreshNow()
end

-- Signals (section 3.3): every handler marks and schedules; none reads the client.

local function onCombatStart()
    state.inCombat = true
    scheduleTransition(enterCombat)
end

local function onCombatEnd()
    state.inCombat = false
    scheduleTransition(leaveCombat)
end

-- Ignored in combat. Otherwise only the player's auras, and a unit that cannot be
-- read, which may be the player.
local function onAuraSignal(unitTarget)
    if state.inCombat then
        return
    end
    local kind, unit = ClientRead.Classify(unitTarget, "string")
    if kind == ABSENT or (kind == PLAIN and unit ~= "player") then
        return
    end
    requestRefresh()
end

local function onEnchantSignal()
    if state.inCombat then
        return
    end
    requestRefresh()
end

local function onSuppliesSignal()
    requestRefresh()
end

local function onEnteringWorld()
    state.anchorStale = true
    requestRefresh()
end

local SIGNALS = {
    { event = "PLAYER_REGEN_DISABLED", handler = onCombatStart, required = true,
      lost = "Upkeep cannot tell when a fight starts, so it cannot hide in combat" },
    { event = "PLAYER_REGEN_ENABLED", handler = onCombatEnd, required = true,
      lost = "Upkeep cannot tell when a fight ends" },
    { event = "UNIT_AURA", handler = onAuraSignal, required = false,
      lost = "buffs update only when equipment, bags or a fight change" },
    { event = "WEAPON_ENCHANT_CHANGED", handler = onEnchantSignal, required = false,
      lost = "a new weapon enchant shows at the next other change" },
    { event = "PLAYER_EQUIPMENT_CHANGED", handler = onSuppliesSignal, required = false,
      lost = "a weapon or ammo change shows at the next other change" },
    { event = "BAG_UPDATE_DELAYED", handler = onSuppliesSignal, required = false,
      lost = "ammo and shard counts update only when buffs or equipment change, and the low-supply toast cannot fire in combat" },
    { event = "PLAYER_ENTERING_WORLD", handler = onEnteringWorld, required = false,
      lost = "the panel keeps the anchor it found at login" },
}

-- Lifecycle (section 7) ------------------------------------------------------------------------

local function readSettings(config)
    local stored = config and config.settings or {}
    local own = state.settings
    for key, default in pairs(DEFAULTS) do
        local value = stored[key]
        if type(value) == type(default) then
            own[key] = value
        else
            own[key] = default
        end
    end
end

local function ensurePanel()
    if state.panel then
        return
    end
    local chrome = ns.PanelChrome.Build({
        frameName = "PersonalAddonUpkeep",
        width = ns.UPKEEP_PADDING * 2 + ns.UPKEEP_CELL_WIDTH,
        height = ns.UPKEEP_PADDING * 2 + ns.UPKEEP_CELL_HEIGHT,
        alpha = state.settings.panelAlpha,
        ownerKey = "upkeep",
        ownerLabel = "the upkeep panel",
    })
    state.chrome = chrome
    state.panel = chrome.frame
    state.pool = ns.FramePool.Create({
        poolName = "upkeepCells",
        capacity = ns.UPKEEP_CELL_CAPACITY,
        dropPolicy = ns.DROP_POLICY.SURFACE_AND_FAIL,
        factory = createCell,
        reset = resetCell,
    })
    ns.FramePool.Prewarm(state.pool)
end

local function enable(config)
    readSettings(config)
    local timer = _G.C_Timer
    if not (type(timer) == "table" and ClientRead.Available(timer.After)
        and ClientRead.Available(timer.NewTicker) and ClientRead.Available(timer.NewTimer)) then
        return nil, "this client has no C_Timer, so Upkeep cannot do its work outside Blizzard's calls"
    end
    state.counters = ns.Diagnostics.CountersFor(FEATURE_ID)
    state.enums = resolveEnums()
    ensurePanel()
    anchorPanel()
    registerPreview()

    for index = 1, #SIGNALS do
        local signal = SIGNALS[index]
        local token = ns.Dispatch.Subscribe(FEATURE_ID, signal.event, signal.handler)
        if token then
            state.tokens[#state.tokens + 1] = token
        elseif signal.required then
            return nil, format("this client does not deliver %s, so %s", signal.event, signal.lost)
        else
            ns.Log.Once("upkeep:no" .. signal.event, format(
                "this client does not deliver %s, so %s", signal.event, signal.lost))
        end
    end

    state.enabled = true
    state.generation = state.generation + 1
    state.roster = nil
    state.snapshot = nil
    state.postFight = nil
    clearTails()

    -- Enabled during a fight: hidden until it ends, with no snapshot to compare.
    local combatKind, inCombat = ClientRead.Call(UnitAffectingCombat, "boolean", "player")
    state.inCombat = (combatKind == PLAIN and inCombat == true)
    state.visibility = state.inCombat and VISIBILITY.HIDDEN_IN_COMBAT or VISIBILITY.EMPTY
    requestRefresh()
    return true
end

-- Every step guarded: disable also cleans up after a failed enable.
local function disable()
    state.enabled = false
    state.inCombat = false
    state.generation = state.generation + 1
    state.refreshScheduled = false
    state.previewShown = false
    ns.Preview.Unregister(ns.PREVIEW_PANEL.UPKEEP)
    stopTicker()
    cancelWake()
    if state.pool then
        releaseCells()
    end
    if state.panel then
        state.panel:Hide()
    end
    state.panelShown = false
    state.visibility = VISIBILITY.OFF
    state.roster = nil
    state.snapshot = nil
    state.fightStartedAt = nil
    state.postFight = nil
    state.contents = nil
    clearTails()
    state.supplies = {}
    state.lastCounted = {}
    state.lastNoticeAt = {}
    state.buffHiddenAt = nil
    for index = #state.tokens, 1, -1 do
        ns.Dispatch.Unsubscribe(state.tokens[index])
        state.tokens[index] = nil
    end
end

-- Redraws from the roster without a read, as a tick does.
local function redraw()
    if state.enabled and not state.inCombat and not previewOwnsPanel() then
        guardedTick()
    end
end

local function onConfigChanged(config, changedKey)
    readSettings(config)
    if changedKey == "anchorOffsetX" or changedKey == "anchorOffsetY" or changedKey == "scale"
        or changedKey == "attachToPanels" then
        anchorPanel()
    elseif changedKey == "panelAlpha" then
        ns.PanelChrome.SetAlpha(state.chrome, state.settings.panelAlpha)
    elseif changedKey == "shortBuffSeconds" or changedKey == "showWeaponEnchants"
        or changedKey == "showSupplies" then
        requestRefresh()
    else
        redraw()
    end
    if previewOwnsPanel() then
        showSamples()
    end
    return ns.CONFIG_RESULT.APPLIED
end

ns.Registry.Register(FEATURE_ID, {
    enabledByDefault = true,
    label = "Upkeep",
    description = "Out of combat: buffs and weapon enchants about to run out, and your ammo or soul shards. Hidden in combat; what ran out during a fight shows in dark red when it ends.",
    settingsPage = ns.SETTINGS_PAGE.COMBAT,
    settingsOrder = 40,
    settings = {
        warningSeconds = DEFAULTS.warningSeconds,
        shortBuffSeconds = DEFAULTS.shortBuffSeconds,
        showWeaponEnchants = DEFAULTS.showWeaponEnchants,
        showSupplies = DEFAULTS.showSupplies,
        lowSupplyToast = DEFAULTS.lowSupplyToast,
        expiredTailSeconds = DEFAULTS.expiredTailSeconds,
        maximumIcons = DEFAULTS.maximumIcons,
        attachToPanels = DEFAULTS.attachToPanels,
        panelAlpha = DEFAULTS.panelAlpha,
        scale = DEFAULTS.scale,
        anchorOffsetX = DEFAULTS.anchorOffsetX,
        anchorOffsetY = DEFAULTS.anchorOffsetY,
        ammoAmberBelow = DEFAULTS.ammoAmberBelow,
        ammoRedBelow = DEFAULTS.ammoRedBelow,
        shardAmberBelow = DEFAULTS.shardAmberBelow,
        shardRedBelow = DEFAULTS.shardRedBelow,
    },
    schema = {
        warningSeconds = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Warn with this much time left", order = 1,
            unit = ns.ConfigSchema.UNIT.SECONDS,
            minimum = 5, maximum = 300, step = 5,
        },
        shortBuffSeconds = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Ignore buffs this short or shorter", order = 2,
            unit = ns.ConfigSchema.UNIT.SECONDS,
            description = "By the duration the game reports for each buff. 0 keeps every timed buff.",
            minimum = 0, maximum = 600, step = 10,
        },
        showWeaponEnchants = {
            kind = ns.ConfigSchema.KIND.TOGGLE, label = "Weapon enchants", order = 3,
        },
        showSupplies = {
            kind = ns.ConfigSchema.KIND.TOGGLE, label = "Ammo and soul shard counts", order = 4,
        },
        lowSupplyToast = {
            kind = ns.ConfigSchema.KIND.TOGGLE, label = "Toast when ammo or shards run low", order = 5,
            description = "One toast when a count drops into red, in combat too.",
        },
        expiredTailSeconds = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Show what ran out for", order = 6,
            unit = ns.ConfigSchema.UNIT.SECONDS,
            minimum = 0, maximum = 30, step = 1,
        },
        maximumIcons = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Most timers shown", order = 7,
            unit = ns.ConfigSchema.UNIT.COUNT,
            minimum = 1, maximum = 10, step = 1,
        },
        attachToPanels = {
            kind = ns.ConfigSchema.KIND.TOGGLE, label = "Attach to the damage and threat panels", order = 8,
        },
        panelAlpha = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Panel opacity", order = 9,
            unit = ns.ConfigSchema.UNIT.FRACTION,
            minimum = 0.1, maximum = 1.0, step = 0.05,
        },
        scale = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Scale", order = 10,
            unit = ns.ConfigSchema.UNIT.FRACTION,
            minimum = 0.5, maximum = 2.0, step = 0.05,
        },
        anchorOffsetX = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Horizontal offset", order = 11,
            unit = ns.ConfigSchema.UNIT.PIXELS,
            minimum = -1200, maximum = 1200, step = 1,
        },
        anchorOffsetY = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Vertical offset", order = 12,
            unit = ns.ConfigSchema.UNIT.PIXELS,
            minimum = -800, maximum = 800, step = 1,
        },
        -- Not curated: the user took the defaults (decision D9); /pa set changes them.
        ammoAmberBelow = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Ammo turns amber below",
            unit = ns.ConfigSchema.UNIT.COUNT, minimum = 0, maximum = 2000, step = 1, curated = false,
        },
        ammoRedBelow = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Ammo turns red below",
            unit = ns.ConfigSchema.UNIT.COUNT, minimum = 0, maximum = 2000, step = 1, curated = false,
        },
        shardAmberBelow = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Shards turn amber below",
            unit = ns.ConfigSchema.UNIT.COUNT, minimum = 0, maximum = 40, step = 1, curated = false,
        },
        shardRedBelow = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Shards turn red below",
            unit = ns.ConfigSchema.UNIT.COUNT, minimum = 0, maximum = 40, step = 1, curated = false,
        },
    },
}, {
    enable = enable,
    disable = disable,
    onConfigChanged = onConfigChanged,
})

-- The view /pa upkeep prints and the harness reads (section 11) -----------------------------

local function inspectCells()
    local cells = {}
    local contents = state.contents
    if not contents then
        return cells
    end
    for _, cell in ipairs(contents.cells) do
        cells[#cells + 1] = {
            kind = cell.kind, source = cell.source, remaining = cell.remaining,
            endsAt = cell.endsAt, charges = cell.charges or 0,
        }
    end
    return cells
end

local function inspectSupplies()
    local supplies = {}
    for _, supply in ipairs(SUPPLY_ORDER) do
        local reading = state.supplies[supply]
        if reading then
            local level = nil
            if reading.state == READING.COUNTED then
                level = supplyLevel(reading.count, thresholdsFor(supply))
            end
            supplies[#supplies + 1] = {
                supply = supply, state = reading.state, count = reading.count,
                level = level, reason = reading.reason,
            }
        end
    end
    return supplies
end

local function inspectEnchants(at)
    local enchants = {}
    local roster = state.roster
    if roster and roster.enchantsKnown then
        for _, enchant in ipairs(roster.enchants) do
            enchants[#enchants + 1] = {
                slot = enchant.slot, enchantId = enchant.enchantId,
                remaining = enchant.expiresAt - at, charges = enchant.charges,
            }
        end
    end
    return enchants
end

local function tailCount()
    local count = 0
    for _ in pairs(state.tails) do
        count = count + 1
    end
    return count
end

ns.Upkeep = {
    COUNTER_NAMES = COUNTER_NAMES,
    VISIBILITY = VISIBILITY,

    -- /pa upkeep test: one sample low-supply toast. Counts nothing.
    PostSample = function()
        if not (ns.Toasts and ns.Toasts.Post) then
            return "Unavailable"
        end
        return ns.Toasts.Post({
            kind = "SupplyLow", supply = SUPPLY.AMMO, count = 45, icon = ns.UPKEEP_FALLBACK_ICON,
        })
    end,

    Inspect = function()
        local at = now()
        local roster = state.roster
        local snapshot = state.snapshot
        local live, free, capacity = 0, 0, 0
        if state.pool then
            local _
            _, live, free, capacity = ns.FramePool.Stats(state.pool)
        end
        local wakeIn = nil
        if state.wakeAt then
            wakeIn = state.wakeAt - at
        end
        return {
            enabled = state.enabled,
            -- The defence against reading sample cells as real (Phase 13 section 5.1).
            preview = previewOwnsPanel(),
            visibility = state.visibility,
            inCombat = state.inCombat,
            anchor = state.anchor,
            buffsKnown = roster ~= nil and roster.buffsKnown or false,
            buffRead = state.buffRead,
            rosterBuffs = roster and #roster.buffs or 0,
            enchantsKnown = roster ~= nil and roster.enchantsKnown or false,
            enchantRead = state.enchantRead,
            enchants = inspectEnchants(at),
            supplies = inspectSupplies(),
            cells = inspectCells(),
            tails = tailCount(),
            snapshotBuffs = snapshot and #snapshot.buffs or nil,
            postFightPending = state.postFight ~= nil,
            ticker = state.ticker ~= nil,
            wakeIn = wakeIn,
            panelShown = state.panelShown,
            panelWidth = state.panelWidth,
            liveCells = #state.liveCells,
            counters = state.counters,
            poolLive = live,
            poolFree = free,
            poolCapacity = capacity,
        }
    end,

    -- The drawn cells, in order: for /pa upkeep and the harness.
    CellFrames = function()
        local frames = {}
        for index = 1, #state.liveCells do
            frames[index] = state.liveCells[index]
        end
        return frames
    end,

    CounterLine = function(counters)
        local parts = {}
        for _, name in ipairs(COUNTER_NAMES) do
            parts[#parts + 1] = format("%s=%d", name, (counters or {})[name] or 0)
        end
        return concat(parts, " ")
    end,
}
