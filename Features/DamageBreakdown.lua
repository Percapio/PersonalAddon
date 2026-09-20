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

local ADDON_NAME, ns = ...

local FEATURE_ID = "damageBreakdown"

local format, pairs, pcall, type = string.format, pairs, pcall, type
local sort, floor, max = table.sort, math.floor, math.max

local SESSION_NAMES = { Current = true, Overall = true }

local state = {
    panel = nil,
    rowPool = nil,
    liveRows = {},
    tokens = {},
    enabled = false,
    inCombat = false,
    refreshTicker = nil,
    timerGeneration = 0,
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
    settings = {
        sessionType = "Current",
        maximumRows = 4,
        inCombatRefreshSeconds = 0,
        showWhenEmpty = false,
        panelAlpha = 0.8,
        anchorOffsetX = 0,
        anchorOffsetY = 8,
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
    if type(api) ~= "table" or type(api.GetCombatSessionSourceFromType) ~= "function" then
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

local function byTotalDescending(left, right)
    return (left.totalAmount or 0) > (right.totalAmount or 0)
end

-- Returns a breakdown table, or nil plus a reason. A nil session is NOT a
-- failure: it means no combat yet, or the meter switched off, which is data.
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

    local playerGuid = UnitGUID("player")
    local ok, source = pcall(api.GetCombatSessionSourceFromType,
        sessionType, meterType, playerGuid)
    if not ok then
        return nil, "the session source call was refused"
    end
    if type(source) ~= "table" or type(source.combatSpells) ~= "table" then
        return { rows = {}, totalAmount = 0, truncatedRows = 0 }
    end

    local durationSeconds = 0
    if api.GetSessionDurationSeconds then
        local durationOk, seconds = pcall(api.GetSessionDurationSeconds, sessionType)
        if durationOk and type(seconds) == "number" then
            durationSeconds = seconds
        end
    end

    local total = source.totalAmount or 0
    local ranked = {}
    for index = 1, #source.combatSpells do
        local spell = source.combatSpells[index]
        -- A spell that landed for nothing displaces a row that means something.
        if spell and (spell.totalAmount or 0) > 0 then
            ranked[#ranked + 1] = spell
        end
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
            amountPerSecond = spell.amountPerSecond or 0,
            shareOfTotal = (total > 0) and ((spell.totalAmount or 0) / total) or 0,
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
    state.panel:ClearAllPoints()
    state.panel:SetPoint(panelPoint, anchorFrame, anchorPoint,
        state.settings.anchorOffsetX, state.settings.anchorOffsetY)
end

-- Last resort: four thin edge textures we draw ourselves. Not an in-game border,
-- but it always works, and a visible edge beats none.
local function buildManualBorder(panel)
    local function edge(firstPoint, secondPoint, width, height)
        local texture = panel:CreateTexture(nil, "BORDER")
        if texture.SetColorTexture then
            texture:SetColorTexture(0.55, 0.55, 0.55, 0.9)
        else
            texture:SetTexture(0.55, 0.55, 0.55, 0.9)
        end
        texture:SetPoint(firstPoint, panel, firstPoint, 0, 0)
        texture:SetPoint(secondPoint, panel, secondPoint, 0, 0)
        if width then texture:SetWidth(width) end
        if height then texture:SetHeight(height) end
        return texture
    end

    panel.borderTop = edge("TOPLEFT", "TOPRIGHT", nil, 1)
    panel.borderBottom = edge("BOTTOMLEFT", "BOTTOMRIGHT", nil, 1)
    panel.borderLeft = edge("TOPLEFT", "BOTTOMLEFT", 1, nil)
    panel.borderRight = edge("TOPRIGHT", "BOTTOMRIGHT", 1, nil)
end

-- Revision 1 guarded this with `if panel.SetBackdrop then`, which on this client
-- is false -- so the border was skipped SILENTLY and no border appeared with no
-- message saying why. The guard was right; failing quietly was not.
--
-- SetBackdrop needs the frame to be created with BackdropTemplate on modern
-- clients, so the frame itself is created through a chain and the border through
-- a second one. Whichever works is reported by /pa dps.
local FRAME_TEMPLATES = { "BackdropTemplate" }
local BORDER_TEMPLATES = {
    "TooltipBorderedFrameTemplate",
    "DialogBorderTemplate",
    "ThinBorderTemplate",
    "InsetFrameTemplate3",
}

local function createPanelFrame()
    for index = 1, #FRAME_TEMPLATES do
        local ok, frame = pcall(CreateFrame, "Frame", "PersonalAddonDamageBreakdown",
            _G.UIParent, FRAME_TEMPLATES[index])
        if ok and frame then
            return frame, FRAME_TEMPLATES[index]
        end
    end
    return CreateFrame("Frame", "PersonalAddonDamageBreakdown", _G.UIParent), nil
end

local function applyBorder(panel)
    if panel.SetBackdrop then
        local ok = pcall(panel.SetBackdrop, panel, {
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        if ok then
            if panel.SetBackdropBorderColor then
                pcall(panel.SetBackdropBorderColor, panel, 1, 1, 1, 0.7)
            end
            return "backdrop"
        end
    end

    -- A bordered child frame stretched over the panel. This is how the client's
    -- own windows get their edges, so it is the closest thing to "any border
    -- currently in game".
    for index = 1, #BORDER_TEMPLATES do
        local ok, child = pcall(CreateFrame, "Frame", nil, panel, BORDER_TEMPLATES[index])
        if ok and child then
            local anchored = pcall(child.SetAllPoints, child, panel)
            if anchored then
                panel.borderFrame = child
                return BORDER_TEMPLATES[index]
            end
            pcall(child.Hide, child)
        end
    end

    buildManualBorder(panel)
    ns.Log.Once("dps:manualborder",
        "no in-game border template was available on this client; the breakdown panel draws a plain edge instead")
    return "manual"
end

local function ensurePanel()
    if state.panel then
        return state.panel
    end

    local panel, frameTemplate = createPanelFrame()
    panel:SetWidth(PANEL_WIDTH)
    panel:SetHeight(ROW_HEIGHT + PANEL_PADDING * 2)

    panel.background = panel:CreateTexture(nil, "BACKGROUND")
    panel.background:SetAllPoints(panel)
    if panel.background.SetColorTexture then
        panel.background:SetColorTexture(0, 0, 0, 1)
    else
        panel.background:SetTexture(0, 0, 0, 1)
    end

    state.borderStyle = applyBorder(panel)
    if frameTemplate then
        state.borderStyle = state.borderStyle .. " via " .. frameTemplate
    end

    -- Opacity applies to the background texture alone. Setting it on the frame
    -- faded the rows, icons and border with it, so a readable panel and a subtle
    -- one were the same slider and could not both be had.
    panel:SetAlpha(1)
    panel.background:SetAlpha(state.settings.panelAlpha)
    panel:Hide()

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
    panel.background:SetAlpha(state.settings.panelAlpha)
    panel:Show()
end

local function refreshNow()
    if not state.enabled then
        return false
    end

    local breakdown, reason = readOwnBreakdown()
    if not breakdown then
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

            local breakdown = readOwnBreakdown()
            if not breakdown then
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

-- Refresh timer ---------------------------------------------------------------

local function cancelRefreshTicker()
    if state.refreshTicker and state.refreshTicker.Cancel then
        state.refreshTicker:Cancel()
    end
    state.refreshTicker = nil
    state.timerGeneration = state.timerGeneration + 1
end

local function startRefreshTicker()
    cancelRefreshTicker()

    local interval = state.settings.inCombatRefreshSeconds or 0
    if interval <= 0 then
        return
    end

    local generation = state.timerGeneration
    local function fire()
        if generation ~= state.timerGeneration or not state.enabled then
            return
        end
        refreshNow()
    end

    if C_Timer and C_Timer.NewTicker then
        state.refreshTicker = C_Timer.NewTicker(interval, fire)
    end
end

-- Signals ---------------------------------------------------------------------

local function onCombatStart()
    state.inCombat = true
    -- A new fight invalidates any settle read still pending for the last one.
    cancelSettleReads()
    startRefreshTicker()
end

local function onCombatEnd()
    state.inCombat = false
    -- Cancelled on every exit from combat, not only on disable: a poller that
    -- outlives the fight it was created for keeps reading a session nobody is
    -- looking at (Phase 1 section 6.1).
    cancelRefreshTicker()
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
      lost = "the in-combat refresh will never start" },
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
    state.settings.inCombatRefreshSeconds =
        settings.inCombatRefreshSeconds or state.settings.inCombatRefreshSeconds
    state.settings.showWhenEmpty = (settings.showWhenEmpty == true)
    state.settings.panelAlpha = settings.panelAlpha or state.settings.panelAlpha
    state.settings.anchorOffsetX = settings.anchorOffsetX or state.settings.anchorOffsetX
    state.settings.anchorOffsetY = settings.anchorOffsetY or state.settings.anchorOffsetY
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
    if state.inCombat then
        startRefreshTicker()
    end

    refreshNow()
    return true
end

-- Every step guarded: disable also cleans up after a failed enable, which may not
-- have created the panel or the pool.
local function disable()
    state.enabled = false
    cancelRefreshTicker()
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

    if changedKey == "inCombatRefreshSeconds" then
        if state.inCombat then
            startRefreshTicker()
        else
            cancelRefreshTicker()
        end
        return ns.CONFIG_RESULT.APPLIED
    end

    if changedKey == "anchorOffsetX" or changedKey == "anchorOffsetY" then
        anchorPanel()
        return ns.CONFIG_RESULT.APPLIED
    end

    refreshNow()
    return ns.CONFIG_RESULT.APPLIED
end

ns.Registry.Register(FEATURE_ID, {
    enabledByDefault = true,
    label = "Damage breakdown",
    description = "Your own damage by spell, above the player frame, read from the built-in meter.",
    settings = {
        sessionType = "Current",
        maximumRows = 4,
        inCombatRefreshSeconds = 0,
        showWhenEmpty = false,
        panelAlpha = 0.8,
        anchorOffsetX = 0,
        anchorOffsetY = 8,
    },
    schema = {
        sessionType = {
            kind = ns.ConfigSchema.KIND.CHOICE, label = "Which fight",
            description = "Current shows the last fight; Overall sums your whole session.",
            choices = {
                { value = "Current", label = "Current fight" },
                { value = "Overall", label = "Whole session" },
            },
        },
        maximumRows = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Rows shown",
            description = "How many spells to list. Anything beyond this is counted, not dropped.",
            minimum = 1, maximum = 10, step = 1,
        },
        panelAlpha = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Panel opacity",
            minimum = 0.1, maximum = 1.0, step = 0.05,
        },
        anchorOffsetX = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Horizontal offset",
            minimum = -300, maximum = 300, step = 1,
        },
        anchorOffsetY = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Vertical offset",
            minimum = -300, maximum = 300, step = 1,
        },
        -- Not curated: redrawing during a fight competes for frame time in the
        -- one period it matters, and 0 is the right answer for nearly everyone.
        inCombatRefreshSeconds = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "In-combat refresh",
            minimum = 0, maximum = 10, curated = false,
        },
        showWhenEmpty = {
            kind = ns.ConfigSchema.KIND.TOGGLE, label = "Show when empty", curated = false,
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
            sessionType = state.settings.sessionType,
            maximumRows = state.settings.maximumRows,
            inCombat = state.inCombat,
            rowsShown = state.lastRowCount,
            truncatedRows = state.truncatedRows,
            panelShown = (state.panel ~= nil and state.panel:IsShown()) or false,
            iconsAvailable = state.iconLookup ~= nil,
            anchorIsPlayerFrame = state.anchorIsPlayerFrame == true,
            borderStyle = state.borderStyle,
            totalAmount = state.lastTotalAmount,
            durationSeconds = state.lastDurationSeconds,
            settlePending = state.settlePending,
            refreshTickerRunning = state.refreshTicker ~= nil,
            poolConstructed = constructed,
            poolLive = live,
            poolFree = free,
            poolCapacity = capacity,
        }
    end,
}
