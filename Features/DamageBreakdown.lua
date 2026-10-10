-- Features/DamageBreakdown.lua
-- A small panel above the player frame listing your own damage by spell: icon,
-- DPS, and share of your own total (Phase 4).
--
-- This feature aggregates nothing. The client ships an accurate damage meter and
-- a sanctioned API, C_DamageMeter, which already returns per-spell totals and
-- per-second rates -- more accurately than we could compute them, since it
-- divides by a fractional session duration it does not otherwise expose. If this
-- file is ever seen summing damage, something has gone wrong.
--
-- It is also the first feature in this addon that owns its widgets, because there
-- is no Blizzard widget to restyle. That makes it FramePool's first real
-- consumer, two phases after the pool was built.
--
-- Phase 9 (Architecture/20261002-Phase09.md section 5.1): the in-combat refresh is
-- gone. The session source is SecretWhenInCombat, so during a fight it could never
-- draw, and its comparisons would have raised on every tick. What remains reads
-- through ClientRead, and a withheld read keeps the last render: the settle reads
-- after combat retry it.
--
-- Phase 11 (Architecture/20261005-Phase11.md section 6): with hideInCombat, on by
-- default, the panel hides for the length of a fight, when it can only show the
-- last one, and the threat panel takes its place.

local ADDON_NAME, ns = ...

local FEATURE_ID = "damageBreakdown"

local format, pairs, pcall, type = string.format, pairs, pcall, type
local sort, floor, max = table.sort, math.floor, math.max

local ClientRead = ns.ClientRead
local PLAIN, ABSENT, WITHHELD = ClientRead.PLAIN, ClientRead.ABSENT, ClientRead.WITHHELD
local bump = ns.Diagnostics.Bump

-- The reason readOwnBreakdown gives when the client withheld a figure.
local READ_WITHHELD = "the client withheld a figure"

local SESSION_NAMES = { Current = true, Overall = true }

local state = {
    panel = nil,
    chrome = nil,
    rowPool = nil,
    liveRows = {},
    tokens = {},
    enabled = false,
    inCombat = false,
    settleGeneration = 0,
    settlePending = 0,
    settleBaselineTotal = nil,
    lastTotalAmount = 0,
    lastDurationSeconds = 0,
    borderStyle = "none",
    iconLookup = nil,
    iconLookupResolved = false,
    anchorIsPlayerFrame = false,
    lastRowCount = 0,
    truncatedRows = 0,
    -- This UI load's diagnostics table, bound at enable (Phase 9 section 5.1).
    counters = {},
    settings = {
        sessionType = "Current",
        maximumRows = 4,
        showWhenEmpty = false,
        panelAlpha = 0.8,
        scale = 1.0,
        anchorOffsetX = 0,
        anchorOffsetY = 8,
        hideInCombat = true,
    },
}

-- Combat end is not session end. PLAYER_REGEN_ENABLED fires the moment the
-- player leaves combat, while the client may still be recording a final tick, a
-- pending swing, or overkill resolution. Reading only at that instant produces a
-- total that is sometimes short of what the built-in meter settles on.
--
-- So the panel renders immediately -- something should appear at once -- and then
-- re-reads at these offsets and keeps whichever is latest.
local SETTLE_DELAYS = { 0.6, 2.0 }

local ROW_HEIGHT = 16
local ROW_SPACING = 2
local PANEL_WIDTH = 132
local PANEL_PADDING = 6
local ICON_SIZE = 14

-- API -------------------------------------------------------------------------

local function meterApi()
    local api = C_DamageMeter
    if type(api) ~= "table" or not ClientRead.Available(api.GetCombatSessionSourceFromType) then
        return nil
    end
    return api
end

local function sessionTypeValue(name)
    local enum = Enum and Enum.DamageMeterSessionType
    if type(enum) ~= "table" then
        return nil
    end
    return enum[name]
end

local function damageDoneValue()
    local enum = Enum and Enum.DamageMeterType
    if type(enum) ~= "table" then
        return nil
    end
    return enum.DamageDone
end

-- Named constants only. An integer literal here would be a value brute-forced
-- from a probe, which a patch could renumber without telling us; the client's own
-- name survives renumbering.
local function enumsPresent()
    return sessionTypeValue("Current") ~= nil
        and sessionTypeValue("Overall") ~= nil
        and damageDoneValue() ~= nil
end

-- This client has already proved C_Spell is only partially populated -- Phase 1
-- reports GetSpellPowerCost missing from both the namespace and the globals -- so
-- the icon lookup is a chain resolved once, not an assumption.
local function resolveIconLookup()
    if state.iconLookupResolved then
        return state.iconLookup
    end
    state.iconLookupResolved = true

    local candidates = {
        function(spellId)
            if C_Spell and C_Spell.GetSpellTexture then
                return C_Spell.GetSpellTexture(spellId)
            end
        end,
        function(spellId)
            if _G.GetSpellTexture then
                return _G.GetSpellTexture(spellId)
            end
        end,
        function(spellId)
            if C_Spell and C_Spell.GetSpellInfo then
                local info = C_Spell.GetSpellInfo(spellId)
                return info and info.iconID
            end
        end,
        function(spellId)
            if _G.GetSpellInfo then
                return select(3, _G.GetSpellInfo(spellId))
            end
        end,
    }

    -- Probed with a spell id we know exists on this character, taken from the
    -- session itself where possible. 1 is a safe fallback probe value: a nil
    -- result from a real candidate still tells us the function is callable.
    for index = 1, #candidates do
        local ok, texture = pcall(candidates[index], 1)
        if ok and texture ~= nil then
            state.iconLookup = candidates[index]
            return state.iconLookup
        end
    end

    ns.Log.Once("dps:noiconapi",
        "no spell icon lookup on this client; the breakdown will show DPS and share without icons")
    state.iconLookup = nil
    return nil
end

-- Read ------------------------------------------------------------------------

-- Sorts our own copies of the spells, never the client's tables, so every value
-- compared here was already classified Plain.
local function byTotalDescending(left, right)
    return left.totalAmount > right.totalAmount
end

-- The spells worth a row, as plain copies. Returns nil when any figure was
-- withheld, so a half-read session never renders as if it were whole.
local function rankedSpells(spells)
    local ranked = {}
    for index = 1, #spells do
        local entryKind, spell = ClientRead.Field(spells, index, "table")
        if entryKind == WITHHELD then
            return nil
        end
        if entryKind == PLAIN then
            local amountKind, amount = ClientRead.Field(spell, "totalAmount", "number")
            local rateKind, rate = ClientRead.Field(spell, "amountPerSecond", "number")
            local idKind, spellId = ClientRead.Field(spell, "spellID", "number")
            if amountKind == WITHHELD or rateKind == WITHHELD or idKind == WITHHELD then
                return nil
            end
            amount = (amountKind == PLAIN) and amount or 0
            -- A spell that landed for nothing displaces a row that means something.
            if amount > 0 then
                ranked[#ranked + 1] = {
                    spellID = spellId,
                    totalAmount = amount,
                    amountPerSecond = (rateKind == PLAIN) and rate or 0,
                }
            end
        end
    end
    return ranked
end

-- Returns a breakdown table, or nil plus a reason. A nil session is NOT a
-- failure: it means no combat yet, or the meter switched off, which is data.
-- READ_WITHHELD means the client withheld a figure, which is transient.
local function readOwnBreakdown()
    local api = meterApi()
    if not api then
        return nil, "C_DamageMeter is unavailable"
    end

    local sessionType = sessionTypeValue(state.settings.sessionType)
    local meterType = damageDoneValue()
    if sessionType == nil or meterType == nil then
        return nil, "the damage meter enums are unavailable"
    end

    local available = true
    if api.IsDamageMeterAvailable then
        local ok, result = pcall(api.IsDamageMeterAvailable)
        available = ok and result == true
    end
    if not available then
        ns.Log.Once("dps:meteroff",
            "the built-in damage meter is switched off, so the breakdown panel has nothing to show")
        return { rows = {}, totalAmount = 0, truncatedRows = 0, meterOff = true }
    end

    local guidKind, playerGuid = ClientRead.Call(UnitGUID, "string", "player")
    if guidKind ~= PLAIN then
        return nil, READ_WITHHELD
    end
    local sourceKind, source = ClientRead.Call(api.GetCombatSessionSourceFromType, "table",
        sessionType, meterType, playerGuid)
    if sourceKind == ABSENT then
        return { rows = {}, totalAmount = 0, truncatedRows = 0 }
    end
    if sourceKind ~= PLAIN then
        if source == ClientRead.CALL_FAILED then
            return nil, "the session source call was refused"
        end
        return nil, READ_WITHHELD
    end
    local spellsKind, spells = ClientRead.Field(source, "combatSpells", "table")
    if spellsKind == ABSENT then
        return { rows = {}, totalAmount = 0, truncatedRows = 0 }
    end
    local totalKind, total = ClientRead.Field(source, "totalAmount", "number")
    if spellsKind ~= PLAIN or totalKind == WITHHELD then
        return nil, READ_WITHHELD
    end
    total = (totalKind == PLAIN) and total or 0

    local durationSeconds = 0
    if api.GetSessionDurationSeconds then
        local durationKind, seconds = ClientRead.Call(api.GetSessionDurationSeconds, "number", sessionType)
        if durationKind == PLAIN then
            durationSeconds = seconds
        end
    end

    local ranked = rankedSpells(spells)
    if not ranked then
        return nil, READ_WITHHELD
    end
    sort(ranked, byTotalDescending)

    local lookup = resolveIconLookup()
    local limit = max(1, state.settings.maximumRows)
    local rows = {}
    for index = 1, math.min(#ranked, limit) do
        local spell = ranked[index]
        local icon = nil
        if lookup then
            local iconOk, texture = pcall(lookup, spell.spellID)
            if iconOk then
                icon = texture
            end
        end
        rows[index] = {
            spellId = spell.spellID,
            iconTexture = icon,
            amountPerSecond = spell.amountPerSecond,
            shareOfTotal = (total > 0) and (spell.totalAmount / total) or 0,
        }
    end

    return {
        rows = rows,
        totalAmount = total,
        durationSeconds = durationSeconds,
        truncatedRows = max(0, #ranked - #rows),
    }
end

-- Panel -----------------------------------------------------------------------

-- PlayerFrame is not guaranteed to exist: a total-conversion UI may remove it,
-- and anchoring to nil raises. UIParent always exists, and a panel in a slightly
-- wrong place beats a feature that faulted over someone else's UI.
-- BOTTOMLEFT to the frame's TOPLEFT, so the panel sits directly above the
-- player's name and shares its left edge. Offsets nudge it from there.
local function resolvePanelAnchor()
    if _G.PlayerFrame then
        return _G.PlayerFrame, "BOTTOMLEFT", "TOPLEFT", true
    end
    ns.Log.Once("dps:noplayerframe",
        "PlayerFrame was not found; the breakdown panel is anchored to the screen instead")
    return _G.UIParent, "BOTTOMLEFT", "BOTTOMLEFT", false
end

local function createRow()
    local row = CreateFrame("Frame", nil, state.panel)
    row:SetHeight(ROW_HEIGHT)
    row:SetWidth(PANEL_WIDTH - PANEL_PADDING * 2)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetWidth(ICON_SIZE)
    row.icon:SetHeight(ICON_SIZE)
    row.icon:SetPoint("LEFT", row, "LEFT", 0, 0)

    row.rate = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.rate:SetPoint("LEFT", row, "LEFT", ICON_SIZE + 8, 0)
    row.rate:SetJustifyH("RIGHT")
    row.rate:SetWidth(48)

    row.share = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.share:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.share:SetJustifyH("RIGHT")
    row.share:SetWidth(36)

    return row
end

local function resetRow(row)
    row:Hide()
    row:ClearAllPoints()
    row.icon:SetTexture(nil)
    row.icon:Hide()
    row.rate:SetText("")
    row.share:SetText("")
end

-- Re-resolved on every enable, not once at creation: a UI that builds PlayerFrame
-- late would otherwise be stuck with the UIParent fallback for the session.
local function anchorPanel()
    if not state.panel then
        return
    end
    local anchorFrame, panelPoint, anchorPoint, usedPlayerFrame = resolvePanelAnchor()
    if not anchorFrame then
        -- Neither candidate exists. Leave the panel where it is rather than
        -- anchoring to nil, which raises.
        ns.Log.OnceError("dps:noanchor",
            "neither PlayerFrame nor UIParent exists; the breakdown panel cannot be anchored")
        state.anchorIsPlayerFrame = false
        return
    end
    state.anchorIsPlayerFrame = usedPlayerFrame
    ns.PanelChrome.Place(state.panel, anchorFrame, panelPoint, anchorPoint, {
        scale = state.settings.scale,
        offsetX = state.settings.anchorOffsetX,
        offsetY = state.settings.anchorOffsetY,
    })
end

-- The frame, border chain and background live in Core/PanelChrome.lua since Phase 8,
-- which the skills window shares so that the two panels cannot drift apart.
local function ensurePanel()
    if state.panel then
        return state.panel
    end

    local chrome = ns.PanelChrome.Build({
        frameName = "PersonalAddonDamageBreakdown",
        width = PANEL_WIDTH,
        height = ROW_HEIGHT + PANEL_PADDING * 2,
        alpha = state.settings.panelAlpha,
        ownerKey = "dps",
        ownerLabel = "the breakdown panel",
    })
    local panel = chrome.frame
    state.chrome = chrome
    state.borderStyle = chrome.borderStyle

    state.panel = panel
    anchorPanel()
    state.rowPool = ns.FramePool.Create({
        poolName = "damageBreakdownRows",
        -- Headroom over maximumRows so a raised setting does not exhaust the pool
        -- the moment it is changed. Exhaustion surfaces rather than growing.
        capacity = 16,
        dropPolicy = ns.DROP_POLICY.SURFACE_AND_FAIL,
        factory = createRow,
        reset = resetRow,
    })
    return panel
end

local function releaseRows()
    for index = #state.liveRows, 1, -1 do
        ns.FramePool.Release(state.rowPool, state.liveRows[index])
        state.liveRows[index] = nil
    end
end

local function formatRate(rate)
    return format("%d", floor((rate or 0) + 0.5))
end

local function formatShare(share)
    return format("%d%%", floor((share or 0) * 100 + 0.5))
end

-- During a fight the panel can only show the last one (Phase 11 section 6).
local function hiddenForCombat()
    return state.inCombat and state.settings.hideInCombat
end

local function renderBreakdown(breakdown)
    local panel = ensurePanel()
    releaseRows()

    local rows = breakdown and breakdown.rows or {}
    state.lastRowCount = #rows
    state.truncatedRows = breakdown and breakdown.truncatedRows or 0
    state.lastTotalAmount = breakdown and breakdown.totalAmount or 0
    state.lastDurationSeconds = breakdown and breakdown.durationSeconds or 0

    if #rows == 0 and not state.settings.showWhenEmpty then
        panel:Hide()
        return
    end

    local previous = nil
    for index = 1, #rows do
        local row, poolError = ns.FramePool.Acquire(state.rowPool)
        if not row then
            -- maximumRows exceeds the pool cap: a configuration error, surfaced
            -- rather than silently truncated.
            ns.Log.OnceError("dps:poolexhausted", format(
                "the breakdown row pool was exhausted (%s); lower maximumRows",
                tostring(poolError)))
            break
        end

        local entry = rows[index]
        if entry.iconTexture then
            row.icon:SetTexture(entry.iconTexture)
            row.icon:Show()
        else
            row.icon:Hide()
        end
        row.rate:SetText(formatRate(entry.amountPerSecond))
        row.share:SetText(formatShare(entry.shareOfTotal))

        row:ClearAllPoints()
        if previous then
            row:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -ROW_SPACING)
        else
            row:SetPoint("TOPLEFT", panel, "TOPLEFT", PANEL_PADDING, -PANEL_PADDING)
        end
        row:Show()

        state.liveRows[#state.liveRows + 1] = row
        previous = row
    end

    local shown = #state.liveRows
    local height = PANEL_PADDING * 2 + max(1, shown) * ROW_HEIGHT
        + max(0, shown - 1) * ROW_SPACING
    panel:SetHeight(height)
    ns.PanelChrome.SetAlpha(state.chrome, state.settings.panelAlpha)
    if hiddenForCombat() then
        panel:Hide()
        return
    end
    panel:Show()
end

-- Preview (section 5.3) --------------------------------------------------------

-- Sample rows, drawn by a path that is not the refresh: no C_DamageMeter call
-- and no counter moved. The row carries no name string -- the icon is the
-- identifier -- so there is nothing inside a row to mark as a sample, and
-- /pa dps reporting preview: on is the whole signal. The figures are plainly
-- round.
local PREVIEW_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local PREVIEW_RATES = { 184.0, 121.5, 96.0, 62.5, 41.0, 27.5, 18.0, 12.5, 8.0, 5.5 }

local function showPlaceholders()
    if not state.panel then
        return 0
    end
    releaseRows()

    local drawCount = max(1, math.min(state.settings.maximumRows, #PREVIEW_RATES))

    local total = 0
    for index = 1, drawCount do
        total = total + PREVIEW_RATES[index]
    end

    local previous = nil
    for index = 1, drawCount do
        local row, poolError = ns.FramePool.Acquire(state.rowPool)
        if not row then
            ns.Log.OnceError("dps:previewpool", format(
                "the breakdown row pool was exhausted drawing a preview (%s)",
                tostring(poolError)))
            break
        end
        row.icon:SetTexture(PREVIEW_ICON)
        row.icon:Show()
        row.rate:SetText(formatRate(PREVIEW_RATES[index]))
        row.share:SetText(formatShare(PREVIEW_RATES[index] / total))

        row:ClearAllPoints()
        if previous then
            row:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -ROW_SPACING)
        else
            row:SetPoint("TOPLEFT", state.panel, "TOPLEFT", PANEL_PADDING, -PANEL_PADDING)
        end
        row:Show()
        state.liveRows[#state.liveRows + 1] = row
        previous = row
    end

    local shown = #state.liveRows
    state.panel:SetHeight(PANEL_PADDING * 2 + max(1, shown) * ROW_HEIGHT
        + max(0, shown - 1) * ROW_SPACING)
    ns.PanelChrome.SetAlpha(state.chrome, state.settings.panelAlpha)
    state.panel:Show()
    return shown
end

local function clearPlaceholders()
    if state.rowPool then
        releaseRows()
    end
    if state.panel then
        state.panel:Hide()
    end
end

local function registerPreview()
    ns.Preview.Register({
        panelId = ns.PREVIEW_PANEL.DAMAGE_BREAKDOWN,
        raiseTarget = state.panel,
        baseStrata = state.chrome and state.chrome.baseStrata or nil,
        show = showPlaceholders,
        clear = clearPlaceholders,
    })
end

local function refreshNow()
    if not state.enabled then
        return false
    end
    -- The preview owns the panel while it is on. Unlike the threat panel's
    -- sweep, this path DOES fire out of combat -- the refresh and both settle
    -- reads -- which is exactly when the preview runs (section 5.7).
    if ns.Preview.IsEnabled() then
        return false
    end

    local breakdown, reason = readOwnBreakdown()
    if not breakdown then
        if reason == READ_WITHHELD then
            -- The figures exist; the client will not show them yet. Keep what is on
            -- screen: the settle reads after combat retry it.
            bump(state.counters, "withheldReads")
            ns.Log.Once("dps:withheld",
                "the damage meter's figures were withheld; the panel keeps its last figures until the next read")
            return false
        end
        -- A refusal AFTER enabling is transient, not a capability failure: the
        -- panel empties and says so once, rather than faulting the feature.
        ns.Log.Once("dps:readrefused", format(
            "the damage meter refused a read (%s); the panel will retry after the next fight",
            tostring(reason)))
        renderBreakdown(nil)
        return false
    end

    renderBreakdown(breakdown)
    return true
end

-- Settle reads ----------------------------------------------------------------

local function cancelSettleReads()
    state.settleGeneration = state.settleGeneration + 1
    state.settlePending = 0
    state.settleBaselineTotal = nil
end

local function scheduleSettleReads()
    cancelSettleReads()
    if not (C_Timer and C_Timer.After) then
        return
    end

    local generation = state.settleGeneration
    state.settleBaselineTotal = state.lastTotalAmount
    state.settlePending = #SETTLE_DELAYS

    for index = 1, #SETTLE_DELAYS do
        C_Timer.After(SETTLE_DELAYS[index], function()
            if generation ~= state.settleGeneration or not state.enabled then
                return
            end
            state.settlePending = max(0, state.settlePending - 1)

            local breakdown, reason = readOwnBreakdown()
            if not breakdown then
                if reason == READ_WITHHELD then
                    bump(state.counters, "withheldReads")
                end
                return
            end
            renderBreakdown(breakdown)

            -- Self-reporting: if a later read is higher, the immediate read at
            -- combat end really was short, which is the hypothesis this exists
            -- to test. Said once, not per fight.
            local baseline = state.settleBaselineTotal
            if baseline and breakdown.totalAmount > baseline then
                ns.Log.Once("dps:settled", format(
                    "the damage meter was still finalising when combat ended (%d -> %d); the panel now re-reads after a moment",
                    baseline, breakdown.totalAmount))
            end
        end)
    end
end

-- Signals ---------------------------------------------------------------------

local function onCombatStart()
    state.inCombat = true
    -- A new fight invalidates any settle read still pending for the last one.
    cancelSettleReads()
    -- Our own frame, hidden; the end-of-combat refresh and settle reads draw it again.
    if state.settings.hideInCombat and state.panel then
        state.panel:Hide()
    end
end

local function onCombatEnd()
    state.inCombat = false
    -- Render at once so something appears, then correct it once the client has
    -- finished recording the fight.
    refreshNow()
    scheduleSettleReads()
end

-- Re-resolves the anchor once the UI has settled. Idempotent: anchorPanel clears
-- and re-sets its point, so running it again costs one SetPoint and nothing else.
-- Announced only on an upgrade from the fallback, because that is the case where
-- the panel visibly moves and the user would otherwise wonder why.
local function onEnteringWorld()
    if not state.enabled or not state.panel then
        return
    end
    local wasOnScreenFallback = (state.anchorIsPlayerFrame == false)
    anchorPanel()
    if wasOnScreenFallback and state.anchorIsPlayerFrame then
        ns.Log.Once("dps:anchorrecovered",
            "the breakdown panel found PlayerFrame after the loading screen and moved to it")
    end
end

local SIGNALS = {
    { event = "PLAYER_ENTERING_WORLD", handler = onEnteringWorld, required = false,
      lost = "the panel keeps whatever anchor it resolved at login; /pa dps reports which" },
    { event = "PLAYER_REGEN_DISABLED", handler = onCombatStart, required = false,
      lost = "a settle read left over from one fight may redraw the panel during the next" },
    { event = "PLAYER_REGEN_ENABLED", handler = onCombatEnd, required = false,
      lost = "the panel will not update when a fight ends; use /pa dps by hand" },
}

-- Lifecycle -------------------------------------------------------------------

local function readSettings(config)
    local settings = config and config.settings
    if not settings then
        return
    end

    local wanted = settings.sessionType
    if type(wanted) == "string" and SESSION_NAMES[wanted] then
        state.settings.sessionType = wanted
    elseif wanted ~= nil then
        ns.Log.Once("dps:badsession", format(
            "sessionType '%s' is not Current or Overall; keeping %s",
            tostring(wanted), state.settings.sessionType))
    end

    state.settings.maximumRows = settings.maximumRows or state.settings.maximumRows
    state.settings.showWhenEmpty = (settings.showWhenEmpty == true)
    state.settings.panelAlpha = settings.panelAlpha or state.settings.panelAlpha
    state.settings.scale = settings.scale or state.settings.scale
    state.settings.anchorOffsetX = settings.anchorOffsetX or state.settings.anchorOffsetX
    state.settings.anchorOffsetY = settings.anchorOffsetY or state.settings.anchorOffsetY
    state.settings.hideInCombat = (settings.hideInCombat ~= false)
end

local function enable(config)
    readSettings(config)

    -- A capability check at enable, where a refusal IS a fault. Compare
    -- refreshNow, where the same refusal is transient data.
    if not meterApi() then
        return nil, "this client has no C_DamageMeter API, so there is no damage data to read"
    end
    if not enumsPresent() then
        return nil, "the damage meter enums are missing, and an integer literal here would be a guess"
    end

    ensurePanel()
    anchorPanel()
    registerPreview()
    state.counters = ns.Diagnostics.CountersFor(FEATURE_ID)

    local tokens = state.tokens
    for index = 1, #SIGNALS do
        local signal = SIGNALS[index]
        local token = ns.Dispatch.Subscribe(FEATURE_ID, signal.event, signal.handler)
        if token then
            tokens[#tokens + 1] = token
        elseif signal.required then
            return nil, format("this client does not deliver %s, so %s",
                signal.event, signal.lost)
        else
            ns.Log.Once("dps:missing:" .. signal.event, format(
                "%s is unavailable on this client; %s", signal.event, signal.lost))
        end
    end

    state.enabled = true

    -- Enabling mid-fight is routine, not an edge case: a /reload during combat
    -- means PLAYER_REGEN_DISABLED already happened and will not be seen.
    local inCombatOk, inCombat = pcall(UnitAffectingCombat, "player")
    state.inCombat = (inCombatOk and inCombat == true) or false

    refreshNow()
    return true
end

-- Every step guarded: disable also cleans up after a failed enable, which may not
-- have created the panel or the pool.
local function disable()
    state.enabled = false
    ns.Preview.Unregister(ns.PREVIEW_PANEL.DAMAGE_BREAKDOWN)
    cancelSettleReads()

    if state.rowPool then
        releaseRows()
    end
    if state.panel then
        state.panel:Hide()
    end

    for index = #state.tokens, 1, -1 do
        ns.Dispatch.Unsubscribe(state.tokens[index])
        state.tokens[index] = nil
    end

    state.inCombat = false
    state.lastRowCount = 0
    state.truncatedRows = 0
end

local function onConfigChanged(config, changedKey)
    readSettings(config)

    if changedKey == "anchorOffsetX" or changedKey == "anchorOffsetY" or changedKey == "scale" then
        anchorPanel()
        return ns.CONFIG_RESULT.APPLIED
    end

    -- In a fight a re-read is withheld, so the last render is hidden or shown as it
    -- stands rather than redrawn.
    if changedKey == "hideInCombat" and state.inCombat then
        if state.panel and hiddenForCombat() then
            state.panel:Hide()
        elseif state.panel and (state.lastRowCount > 0 or state.settings.showWhenEmpty) then
            state.panel:Show()
        end
        return ns.CONFIG_RESULT.APPLIED
    end

    refreshNow()
    return ns.CONFIG_RESULT.APPLIED
end

ns.Registry.Register(FEATURE_ID, {
    enabledByDefault = true,
    label = "Damage breakdown",
    description = "Your own damage by spell, above the player frame, read from the built-in meter.",
    settingsPage = ns.SETTINGS_PAGE.COMBAT,
    settingsOrder = 20,
    -- inCombatRefreshSeconds went in Phase 9. ConfigStore prunes a saved key the
    -- feature no longer declares, so no migration step is needed; it gives a new key,
    -- such as Phase 11's hideInCombat or Phase 12's scale, its default.
    settings = {
        sessionType = "Current",
        maximumRows = 4,
        showWhenEmpty = false,
        panelAlpha = 0.8,
        scale = 1.0,
        anchorOffsetX = 0,
        anchorOffsetY = 8,
        hideInCombat = true,
    },
    schema = {
        sessionType = {
            kind = ns.ConfigSchema.KIND.CHOICE, label = "Which fight", order = 1,
            description = "Current shows the last fight; Overall sums your whole session.",
            choices = {
                { value = "Current", label = "Current fight" },
                { value = "Overall", label = "Whole session" },
            },
        },
        maximumRows = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Rows shown", order = 2,
            unit = ns.ConfigSchema.UNIT.COUNT,
            description = "How many spells to list. Anything beyond this is counted, not dropped.",
            minimum = 1, maximum = 10, step = 1,
        },
        panelAlpha = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Panel opacity", order = 3,
            unit = ns.ConfigSchema.UNIT.FRACTION,
            minimum = 0.1, maximum = 1.0, step = 0.05,
        },
        scale = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Scale", order = 4,
            unit = ns.ConfigSchema.UNIT.FRACTION,
            description = "The panel's size. Offsets stay in screen pixels at any scale.",
            minimum = 0.5, maximum = 2.0, step = 0.05,
        },
        -- Phase 12: wide enough to reach across the screen from the player frame.
        anchorOffsetX = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Horizontal offset", order = 5,
            unit = ns.ConfigSchema.UNIT.PIXELS,
            minimum = -1200, maximum = 1200, step = 1,
        },
        anchorOffsetY = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Vertical offset", order = 6,
            unit = ns.ConfigSchema.UNIT.PIXELS,
            minimum = -800, maximum = 800, step = 1,
        },
        showWhenEmpty = {
            kind = ns.ConfigSchema.KIND.TOGGLE, label = "Show when empty", curated = false,
        },
        hideInCombat = {
            kind = ns.ConfigSchema.KIND.TOGGLE, label = "Hide during combat", order = 7,
            description = "During a fight the panel still shows the last fight's figures; hiding it leaves room for the threat panel",
        },
    },
}, {
    enable = enable,
    disable = disable,
    onConfigChanged = onConfigChanged,
})

ns.DamageBreakdown = {
    Refresh = refreshNow,
    Inspect = function()
        local constructed, live, free, capacity = 0, 0, 0, 0
        if state.rowPool then
            constructed, live, free, capacity = ns.FramePool.Stats(state.rowPool)
        end
        return {
            -- First: the defence against reading sample figures as real
            -- (section 5.1).
            preview = ns.Preview.IsEnabled(),
            sessionType = state.settings.sessionType,
            maximumRows = state.settings.maximumRows,
            inCombat = state.inCombat,
            hideInCombat = state.settings.hideInCombat,
            rowsShown = state.lastRowCount,
            truncatedRows = state.truncatedRows,
            panelShown = (state.panel ~= nil and state.panel:IsShown()) or false,
            iconsAvailable = state.iconLookup ~= nil,
            anchorIsPlayerFrame = state.anchorIsPlayerFrame == true,
            borderStyle = state.borderStyle,
            totalAmount = state.lastTotalAmount,
            durationSeconds = state.lastDurationSeconds,
            settlePending = state.settlePending,
            withheldReads = state.counters.withheldReads or 0,
            poolConstructed = constructed,
            poolLive = live,
            poolFree = free,
            poolCapacity = capacity,
        }
    end,
}
