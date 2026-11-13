-- Features/RareAlerts.lua
-- A toast and a sound when a rare or rare-elite mob gets a nameplate in the open
-- world, once per creature every ten minutes (Architecture/20261112-Phase21.md
-- section 8).
--
-- ITS OWN SUBSCRIPTION. QuestMarkers takes plates through Nameplates' call-outs
-- because it attaches to Nameplates' plate record. This feature attaches nothing and
-- reads only the unit, so it cannot race that record, and it works with the Nameplates
-- feature off: the plates are Blizzard's.
--
-- THE EVENT QUEUES; THE FLUSH READS. NAME_PLATE_UNIT_ADDED is a SynchronousEvent, so
-- its handler records the token and schedules a flush a frame later (README rules 1,
-- 5 and 9). The flush reads the map first and stands down in dungeons and raids, as
-- QuestMarkers does, and wherever the map cannot be read.
--
-- SUPPRESSION NEEDS A PLAIN YES. A rare is skipped as dead, tapped or unattackable
-- only when the client says so plainly. "Could not tell" announces it: a missed rare
-- is the failure this feature exists to prevent (rule 10).

local ADDON_NAME, ns = ...

local FEATURE_ID = "rareAlerts"

local format, type, ipairs, pairs, tostring = string.format, type, ipairs, pairs, tostring
local concat = table.concat

local ClientRead = ns.ClientRead
local PLAIN, WITHHELD = ClientRead.PLAIN, ClientRead.WITHHELD
local bump = ns.Diagnostics.Bump

-- Blizzard's classification strings (premise 96) and our class for each.
local RARE_CLASS = { rare = "Rare", rareelite = "RareElite" }
local CLASS_LABEL = { Rare = "rare", RareElite = "rare elite" }

-- Printed by /pa rares in this order, zero when absent (section 11).
local COUNTER_NAMES = {
    "tokensQueued", "tokensUnreadable", "pendingDropped", "flushes", "mapStoodDown",
    "mapUnreadable", "gone", "notRare", "classificationUnreadable", "notAttackable", "dead",
    "tappedByOthers", "suppressionUnreadable", "identityUnreadable", "nameUnreadable", "repeats",
    "alerts", "toastUnavailable", "soundUnavailable", "memoryEvictions", "evaluateFaults",
}

local state = {
    enabled = false,
    -- Bumped on disable and enable: a flush scheduled before either does nothing.
    generation = 0,
    tokens = {},
    pending = {},
    pendingOrder = {},
    pendingCount = 0,
    flushScheduled = false,
    -- NpcId -> when it was last announced. Per UI load (section 8.3).
    memory = {},
    memoryCount = 0,
    recent = {},
    counters = {},
    lastMap = nil,
    enemyPlates = nil,
    faultNoted = false,
    settings = {
        playSound = true,
        repeatMinutes = 10,
    },
}

local function repeatSeconds()
    return (state.settings.repeatMinutes or 10) * 60
end

-- The verdict (section 8.2) -------------------------------------------------------------

-- A sighting, or nil when the plate is skipped. Every skip counts exactly one counter.
-- The name is kept as the client gave it: it is neutralized once, where it is shown.
local function evaluatePlate(token, at)
    local counters = state.counters

    local existsKind, exists = ClientRead.Call(UnitExists, "boolean", token)
    if existsKind ~= PLAIN or exists ~= true then
        bump(counters, "gone")
        return nil
    end

    -- First, because almost every plate fails it, at one read.
    local classKind, classification = ClientRead.Call(UnitClassification, "string", token)
    if classKind ~= PLAIN then
        bump(counters, "classificationUnreadable")
        return nil
    end
    local rareClass = RARE_CLASS[classification]
    if not rareClass then
        bump(counters, "notRare")
        return nil
    end

    local attackKind, attackable = ClientRead.Call(UnitCanAttack, "boolean", "player", token)
    if attackKind == PLAIN then
        if attackable ~= true then
            bump(counters, "notAttackable")
            return nil
        end
    else
        bump(counters, "suppressionUnreadable")
    end

    local deadKind, dead = ClientRead.Call(UnitIsDead, "boolean", token)
    if deadKind == PLAIN then
        if dead == true then
            bump(counters, "dead")
            return nil
        end
    else
        bump(counters, "suppressionUnreadable")
    end

    local tapKind, tapped = ClientRead.Call(UnitIsTapDenied, "boolean", token)
    if tapKind == PLAIN then
        if tapped == true then
            bump(counters, "tappedByOthers")
            return nil
        end
    else
        bump(counters, "suppressionUnreadable")
    end

    -- Without an id there is no "once per creature".
    local identity, npcId = ns.UnitIdentity.NpcIdFor(token)
    if identity ~= ns.UnitIdentity.READING.RESOLVED then
        bump(counters, "identityUnreadable")
        return nil
    end

    local last = state.memory[npcId]
    if last and at - last < repeatSeconds() then
        bump(counters, "repeats")
        return nil
    end

    local nameKind, name = ClientRead.Call(UnitName, "string", token)
    if nameKind ~= PLAIN then
        bump(counters, "nameUnreadable")
        name = "a rare"
    end
    local levelKind, level = ClientRead.Call(UnitLevel, "number", token)
    return {
        npcId = npcId,
        name = name,
        level = levelKind == PLAIN and level or nil,
        rareClass = rareClass,
    }
end

-- Memory (section 8.3) ------------------------------------------------------------------

local function remember(npcId, at)
    if state.memory[npcId] == nil then
        if state.memoryCount >= ns.RARE_ALERT_MEMORY_CAPACITY then
            local window = repeatSeconds()
            for id, alertedAt in pairs(state.memory) do
                if at - alertedAt >= window then
                    state.memory[id] = nil
                    state.memoryCount = state.memoryCount - 1
                    bump(state.counters, "memoryEvictions")
                end
            end
        end
        if state.memoryCount >= ns.RARE_ALERT_MEMORY_CAPACITY then
            local oldestId, oldestAt = nil, nil
            for id, alertedAt in pairs(state.memory) do
                if oldestAt == nil or alertedAt < oldestAt then
                    oldestId, oldestAt = id, alertedAt
                end
            end
            if oldestId ~= nil then
                state.memory[oldestId] = nil
                state.memoryCount = state.memoryCount - 1
                bump(state.counters, "memoryEvictions")
            end
        end
        state.memoryCount = state.memoryCount + 1
    end
    state.memory[npcId] = at
end

-- The announcement (section 8.4) ---------------------------------------------------------

-- C_Sound.PlaySound, the documented call (premise 99); the global PlaySound is only
-- Blizzard's alias for it. True when the client took the sound.
local function playAlertSound()
    local keyKind, soundKit = ClientRead.Field(_G.SOUNDKIT, ns.RARE_ALERT_SOUND_KEY, "number")
    if keyKind ~= PLAIN then
        bump(state.counters, "soundUnavailable")
        return false
    end
    local api = _G.C_Sound
    local playKind = ClientRead.Call(type(api) == "table" and api.PlaySound or nil, "boolean", soundKit)
    if playKind == WITHHELD then
        bump(state.counters, "soundUnavailable")
        return false
    end
    return true
end

local function chatLine(sighting)
    local label = CLASS_LABEL[sighting.rareClass] or "rare"
    if type(sighting.level) == "number" then
        local level = sighting.level < 0 and "??" or tostring(sighting.level)
        return ns.EscapeGuard.Format("%s spotted: %s (level %s)", label, sighting.name, level)
    end
    return ns.EscapeGuard.Format("%s spotted: %s", label, sighting.name)
end

local function postToast(sighting)
    if not (ns.Toasts and ns.Toasts.Post) then
        return "Unavailable"
    end
    return ns.Toasts.Post({
        kind = "RareSpotted",
        name = sighting.name,
        level = sighting.level,
        rareClass = sighting.rareClass,
        atlas = ns.RARE_ALERT_ATLAS[sighting.rareClass],
    })
end

local function announce(sighting, at)
    local counters = state.counters
    bump(counters, "alerts")
    local shown = postToast(sighting)
    local chatted = false
    if shown == "Unavailable" or shown == "Dropped" then
        bump(counters, "toastUnavailable")
        ns.Log.Info(chatLine(sighting))
        chatted = true
    end
    local sounded = false
    if state.settings.playSound then
        sounded = playAlertSound()
    end
    local recent = state.recent
    recent[#recent + 1] = {
        name = sighting.name, level = sighting.level, rareClass = sighting.rareClass, at = at,
    }
    while #recent > ns.RARE_ALERT_RECENT do
        table.remove(recent, 1)
    end
    return { shown = shown, chatted = chatted, sounded = sounded }
end

-- The trigger (section 8.1) ----------------------------------------------------------------

local function noteFault(fault)
    bump(state.counters, "evaluateFaults")
    if not state.faultNoted then
        state.faultNoted = true
        ns.Diagnostics.NoteFault(FEATURE_ID, fault)
    end
    ns.Log.OnceError("rares:fault", "a rare alert check raised and was skipped; /pa diag shows the message")
end

local function flush()
    state.flushScheduled = false
    local counters = state.counters
    bump(counters, "flushes")
    local order = state.pendingOrder
    state.pending, state.pendingOrder, state.pendingCount = {}, {}, 0

    local reading = ns.MapRestriction.Read()
    state.lastMap = reading
    if reading == ns.MapRestriction.RESTRICTED then
        bump(counters, "mapStoodDown")
        return
    end
    if reading ~= ns.MapRestriction.UNRESTRICTED then
        -- "Could not tell" stands down, as QuestMarkers does.
        bump(counters, "mapUnreadable")
        return
    end

    local at = GetTime()
    for _, token in ipairs(order) do
        local ok, sighting = ns.Isolation.Call(evaluatePlate, token, at)
        if not ok then
            noteFault(sighting)
        elseif sighting then
            remember(sighting.npcId, at)
            announce(sighting, at)
        end
    end
end

-- The flush carries the generation it was scheduled under: C_Timer.After cannot be
-- cancelled, so a disable between the schedule and the flush must make it a no-op
-- (audit finding 8).
local function scheduleFlush()
    if state.flushScheduled then
        return
    end
    state.flushScheduled = true
    local generation = state.generation
    C_Timer.After(0, function()
        if generation ~= state.generation or not state.enabled then
            return
        end
        local ok, fault = ns.Isolation.Call(flush)
        if not ok then
            state.flushScheduled = false
            noteFault(fault)
        end
    end)
end

local function queueToken(token)
    if not state.pending[token] then
        if state.pendingCount >= ns.RARE_ALERT_PENDING_CAPACITY then
            bump(state.counters, "pendingDropped")
            return
        end
        state.pending[token] = true
        state.pendingCount = state.pendingCount + 1
        state.pendingOrder[#state.pendingOrder + 1] = token
        bump(state.counters, "tokensQueued")
    end
    scheduleFlush()
end

-- Nothing is read here: the token is classified and queued.
local function onPlateAdded(unitToken)
    if not state.enabled then
        return
    end
    local kind, token = ClientRead.Classify(unitToken, "string")
    if kind ~= PLAIN then
        bump(state.counters, "tokensUnreadable")
        return
    end
    queueToken(token)
end

-- Read once at enable. The option is the user's, never changed here.
local function checkEnemyPlates()
    local api = _G.C_CVar
    local kind, value = ClientRead.Call(type(api) == "table" and api.GetCVar or nil, "string", "nameplateShowEnemies")
    if kind ~= PLAIN then
        state.enemyPlates = nil
        return
    end
    state.enemyPlates = value
    if value == "0" then
        ns.Log.Once("rares:enemyplatesoff",
            "enemy nameplates are off, so no rare can be noticed; turn them on to use rare alerts")
    end
end

-- The plates already on screen, read as the threat panel reads them, so a reload
-- beside a rare still alerts.
local function queuePlatesOnScreen()
    local api = _G.C_NamePlate
    local listKind, list = ClientRead.Call(type(api) == "table" and api.GetNamePlates or nil, "table")
    if listKind ~= PLAIN then
        return
    end
    local index = 1
    while true do
        local entryKind, frame = ClientRead.Field(list, index, "table")
        if entryKind ~= PLAIN then
            break
        end
        local tokenKind, token = ClientRead.Field(frame, "unitToken", "string")
        if tokenKind == PLAIN then
            queueToken(token)
        end
        index = index + 1
    end
end

-- Lifecycle ---------------------------------------------------------------------------------

local function readSettings(config)
    local settings = config and config.settings or {}
    local own = state.settings
    own.playSound = (settings.playSound ~= false)
    if type(settings.repeatMinutes) == "number" then
        own.repeatMinutes = settings.repeatMinutes
    end
end

local function enable(config)
    readSettings(config)
    local timer = _G.C_Timer
    if not (type(timer) == "table" and ClientRead.Available(timer.After)) then
        return nil, "this client has no C_Timer.After, so rare alerts cannot check plates outside Blizzard's call"
    end
    if not ClientRead.Available(_G.UnitClassification) then
        return nil, "UnitClassification is missing from this client, so no rare can be recognised"
    end
    state.counters = ns.Diagnostics.CountersFor(FEATURE_ID)
    local token = ns.Dispatch.Subscribe(FEATURE_ID, "NAME_PLATE_UNIT_ADDED", onPlateAdded)
    if not token then
        return nil, "this client does not deliver NAME_PLATE_UNIT_ADDED, so no plate can be checked"
    end
    state.tokens[#state.tokens + 1] = token
    state.enabled = true
    state.generation = state.generation + 1
    checkEnemyPlates()
    queuePlatesOnScreen()
    return true
end

-- Leaves nothing to flush: the pending set is emptied and any scheduled flush is stale.
local function disable()
    state.enabled = false
    state.generation = state.generation + 1
    state.flushScheduled = false
    state.pending, state.pendingOrder, state.pendingCount = {}, {}, 0
    for index = #state.tokens, 1, -1 do
        ns.Dispatch.Unsubscribe(state.tokens[index])
        state.tokens[index] = nil
    end
end

local function onConfigChanged(config)
    readSettings(config)
    return ns.CONFIG_RESULT.APPLIED
end

ns.Registry.Register(FEATURE_ID, {
    enabledByDefault = true,
    label = "Rare alerts",
    description = "A toast and a sound when a rare or rare-elite mob gets a nameplate in the open world, once per creature every 10 minutes. Skips dead ones and ones another player has tagged. Needs enemy nameplates; nothing in dungeons and raids.",
    settingsPage = ns.SETTINGS_PAGE.NAMEPLATES,
    settingsOrder = 20,
    settings = {
        playSound = true,
        repeatMinutes = 10,
    },
    schema = {
        playSound = {
            kind = ns.ConfigSchema.KIND.TOGGLE, label = "Play a sound", order = 1,
        },
        repeatMinutes = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Alert again after (minutes)", order = 2,
            unit = ns.ConfigSchema.UNIT.PLAIN,
            minimum = 1, maximum = 60, step = 1,
        },
    },
}, {
    enable = enable,
    disable = disable,
    onConfigChanged = onConfigChanged,
})

-- The view /pa rares prints and the harness reads (section 11) ----------------------------

ns.RareAlerts = {
    COUNTER_NAMES = COUNTER_NAMES,

    -- /pa rares test: one sample toast, and the sound when it is on. Counts nothing
    -- and remembers nothing.
    PostSample = function()
        local sighting = { npcId = 0, name = "A rare", level = 34, rareClass = "Rare" }
        local shown = postToast(sighting)
        local sounded = false
        if state.settings.playSound then
            local keyKind, soundKit = ClientRead.Field(_G.SOUNDKIT, ns.RARE_ALERT_SOUND_KEY, "number")
            local api = _G.C_Sound
            if keyKind == PLAIN then
                sounded = ClientRead.Call(type(api) == "table" and api.PlaySound or nil, "boolean", soundKit) ~= WITHHELD
            end
        end
        return shown, sounded
    end,

    Inspect = function()
        local recent = {}
        for index, entry in ipairs(state.recent) do
            recent[index] = {
                name = entry.name, level = entry.level, rareClass = entry.rareClass, at = entry.at,
            }
        end
        return {
            enabled = state.enabled,
            map = state.lastMap,
            enemyPlates = state.enemyPlates,
            remembered = state.memoryCount,
            capacity = ns.RARE_ALERT_MEMORY_CAPACITY,
            pending = state.pendingCount,
            flushScheduled = state.flushScheduled,
            recent = recent,
            playSound = state.settings.playSound,
            repeatMinutes = state.settings.repeatMinutes,
            counters = state.counters,
        }
    end,

    CounterLine = function(counters)
        local parts = {}
        for _, name in ipairs(COUNTER_NAMES) do
            parts[#parts + 1] = format("%s=%d", name, (counters or {})[name] or 0)
        end
        return concat(parts, " ")
    end,
}
