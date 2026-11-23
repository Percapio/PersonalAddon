-- Features/EquippedSkills.lua
-- A small panel at the left edge of the bags while they are open: your primary
-- professions, the skill of each weapon you have equipped, and Defense, each as an
-- icon and "rank / maximum" (Phase 8 section 5).
--
-- Read-only by construction. It subscribes to no client event: it reads one frame
-- after the bag opens and polls while the bag is shown. Both events that would
-- announce a change are synchronous, and the Skills tab raises SKILL_LINES_CHANGED
-- inside controller clicks (section 3). Every skill is read by ID, so whatever the
-- Skills tab has collapsed never matters, and nothing here expands or selects one:
-- that would be a write, with Blizzard's listeners running inside it.
--
-- The panel is anchored to the bag, never parented to it. SmartNavigation rebuilds a
-- panel's navigation state when a frame is created under it (Patch 01 section 0.2),
-- and every frame here is created at enable, under UIParent.

local ADDON_NAME, ns = ...

local FEATURE_ID = "equippedSkills"

local format, pcall, pairs, type, tostring = string.format, pcall, pairs, type, tostring
local concat, max, min = table.concat, math.max, math.min

local ROW_HEIGHT = 16
local ROW_SPACING = 2
-- The width is settings.panelWidth, defaulting to 96. Phase 13 section 6.2
-- resizes the panel and every row in the pool when it changes.
local PANEL_PADDING = 6
local ICON_SIZE = 14
-- The gap between the icon and the rank text, which the text's width is derived
-- from. Named because the width floor is computed from it.
local ICON_TEXT_GAP = 4

-- Patch 03 sections 6.2 and 8.1: the role box under the panel. Tank and DPS share the
-- first row, Auto takes the second; layout values, in pixels, not settings.
local ROLE_BOX_GAP = 2
local ROLE_BOX_PADDING = 4
local ROLE_BUTTON_HEIGHT = 16
local ROLE_BUTTON_GAP = 2
local ROLE_BOX_HEIGHT = ROLE_BOX_PADDING * 2 + ROLE_BUTTON_HEIGHT * 2 + ROLE_BUTTON_GAP
-- The chosen button and the others: background and text.
local ROLE_LIT = { background = { 0.22, 0.42, 0.80, 0.95 }, text = { 1, 1, 1 } }
local ROLE_DIM = { background = { 0.12, 0.12, 0.12, 0.70 }, text = { 0.62, 0.62, 0.62 } }
local ROLE_LABELS = { Tank = "Tank", Dps = "DPS", Auto = "Auto" }
local AUTO_LABELS = { Tank = "Auto: Tank", NotTank = "Auto: DPS", Unread = "Auto: ?" }

local CAPABILITY = {
    NOT_YET_READ = "NotYetRead",
    READABLE = "Readable",
    WITHHELD = "Withheld",
}

local SOURCE = {
    PROFESSION = "PrimaryProfession",
    FISHING = "Fishing",
    WEAPON = "WeaponSkill",
    DEFENSE = "Defense",
}

-- Blizzard's live list (Camelot/SkillsFrame.lua:10-27), keyed by the NAME of each
-- Enum.ItemWeaponSubclass value, so the numbers come from the client. Fist weapons
-- carry two candidates because Blizzard's two tables disagree (section 5.2); the
-- live one sets the order.
local WEAPON_SKILL_CANDIDATES = {
    Axe1H = { 44 },
    Axe2H = { 172 },
    Mace1H = { 54 },
    Mace2H = { 160 },
    Sword1H = { 43 },
    Sword2H = { 55 },
    Polearm = { 229 },
    Staff = { 136 },
    Dagger = { 173 },
    Bows = { 45 },
    Guns = { 46 },
    Crossbow = { 226 },
    Thrown = { 176 },
    Wand = { 228 },
    Unarmed = { 162, 473 },
}
local UNARMED_SUBCLASS_NAME = "Unarmed"
local FISHING_SUBCLASS_NAME = "Fishingpole"

local state = {
    enabled = false,
    chrome = nil,
    panel = nil,
    rowPool = nil,
    liveRows = {},
    tokens = {},
    capability = CAPABILITY.NOT_YET_READ,
    capabilityReason = nil,
    weaponClass = nil,
    candidatesBySubclass = {},
    subclassNames = {},
    unarmedSubclass = nil,
    fishingSubclass = nil,
    slots = {},
    mainHandSlot = nil,
    shown = false,
    poll = nil,
    lastSignature = nil,
    lastSnapshot = nil,
    resolvedLines = {},
    withheldReads = 0,
    iconFailures = 0,
    reads = 0,
    -- Patch 03 section 6: { chrome, frame, buttons } once built at enable; the choice
    -- and Auto reading the last relight showed.
    roleBox = nil,
    roleShownChoice = nil,
    roleShownAuto = nil,
    settings = {
        anchorOffsetX = -4,
        anchorOffsetY = 0,
        panelWidth = 96,
        panelAlpha = 0.8,
        pollSeconds = 1,
        roleChoice = true,
    },
}

-- Values ------------------------------------------------------------------------

-- A secret value must be checked before anything compares it: testing a secret is
-- itself an error for insecure code (Phase 7 section 5.2).
local function isPlain(value, expectedType)
    local isSecret = _G.issecretvalue
    if type(isSecret) == "function" then
        local ok, secret = pcall(isSecret, value)
        if not ok or secret then
            return false
        end
    end
    return type(value) == expectedType
end

-- nil stays nil. Anything else is returned only when it is a plain value of the
-- expected type; otherwise it is counted as withheld and read as absent, the
-- direction that claims nothing.
local function plainOrAbsent(value, expectedType)
    if value == nil then
        return nil
    end
    if isPlain(value, expectedType) then
        return value
    end
    state.withheldReads = state.withheldReads + 1
    ns.Log.Once("skills:withheldread",
        "the client withheld a skill value; that row is left out of the skills window")
    return nil
end

local function plainIcon(value)
    if value == nil then
        return nil
    end
    if isPlain(value, "number") or isPlain(value, "string") then
        return value
    end
    return nil
end

-- Gateway (section 5.3) -----------------------------------------------------------
-- The seam the offline harness stubs. Every call is a read.

local gateway = {}

function gateway.professionSlots()
    if type(_G.GetProfessions) ~= "function" then
        return nil
    end
    local ok, first, second, _, fishing = pcall(_G.GetProfessions)
    if not ok then
        return nil
    end
    local primary = {}
    first = plainOrAbsent(first, "number")
    second = plainOrAbsent(second, "number")
    if first then primary[#primary + 1] = first end
    if second then primary[#primary + 1] = second end
    return { primary = primary, fishing = plainOrAbsent(fishing, "number") }
end

function gateway.profession(index)
    if type(_G.GetProfessionInfo) ~= "function" then
        return nil
    end
    local ok, name, texture, rank, maxRank = pcall(_G.GetProfessionInfo, index)
    if not ok then
        return nil
    end
    rank = plainOrAbsent(rank, "number")
    maxRank = plainOrAbsent(maxRank, "number")
    if rank == nil or maxRank == nil then
        return nil
    end
    return {
        name = isPlain(name, "string") and name or nil,
        icon = plainIcon(texture),
        rank = rank,
        maximum = maxRank,
    }
end

function gateway.skillLine(id)
    local api = _G.C_SkillInfo and _G.C_SkillInfo.GetSkillLineInfoByID
    if type(api) ~= "function" then
        return nil
    end
    local ok, attributes = pcall(api, id)
    if not ok or attributes == nil then
        return nil
    end
    if not isPlain(attributes, "table") then
        plainOrAbsent(attributes, "table")
        return nil
    end
    local rank = plainOrAbsent(attributes.rank, "number")
    local maximum = plainOrAbsent(attributes.maxRank, "number")
    if rank == nil or maximum == nil then
        return nil
    end
    return {
        name = isPlain(attributes.name, "string") and attributes.name or nil,
        rank = rank,
        maximum = maximum,
    }
end

function gateway.equippedItem(slot)
    if type(_G.GetInventoryItemID) ~= "function" then
        return nil
    end
    local ok, itemId = pcall(_G.GetInventoryItemID, "player", slot)
    if not ok then
        return nil
    end
    return plainOrAbsent(itemId, "number")
end

function gateway.equippedIcon(slot)
    if type(_G.GetInventoryItemTexture) ~= "function" then
        return nil
    end
    local ok, icon = pcall(_G.GetInventoryItemTexture, "player", slot)
    if not ok then
        return nil
    end
    return plainIcon(icon)
end

-- The empty slot's own art, as the paper doll shows it.
function gateway.emptySlotIcon(slot)
    local api = _G.C_PaperDollInfo and _G.C_PaperDollInfo.GetInventorySlotInfoForInvSlot
    if type(api) ~= "function" then
        return nil
    end
    local ok, _, texture = pcall(api, slot)
    if not ok then
        return nil
    end
    return plainIcon(texture)
end

-- The subclass of a weapon, or nil for anything that is not one (a shield, a held
-- item, a relic) and for anything unreadable.
function gateway.weaponSubclass(itemId)
    local instant = (_G.C_Item and _G.C_Item.GetItemInfoInstant) or _G.GetItemInfoInstant
    if type(instant) ~= "function" or state.weaponClass == nil then
        return nil
    end
    local ok, _, _, _, _, _, classId, subclassId = pcall(instant, itemId)
    if not ok then
        return nil
    end
    classId = plainOrAbsent(classId, "number")
    subclassId = plainOrAbsent(subclassId, "number")
    if classId ~= state.weaponClass then
        return nil
    end
    return subclassId
end

-- Blizzard's bag frame, whose Shown aspect can be secret: read through ClientRead
-- (Phase 9 section 5.2). Withheld reads as not shown, which hides the window.
function gateway.combinedBagShown()
    local bag = _G.ContainerFrameCombinedBags
    if not bag then
        return false
    end
    local kind, shown = ns.ClientRead.Call(bag.IsShown, "boolean", bag)
    if kind == ns.ClientRead.WITHHELD then
        ns.Diagnostics.Bump(ns.Diagnostics.CountersFor(FEATURE_ID), "bagReadsWithheld")
    end
    return kind == ns.ClientRead.PLAIN and shown == true
end

-- Reads (section 5.3) -------------------------------------------------------------

local function resolveWeaponSkill(subclass)
    local candidates = state.candidatesBySubclass[subclass]
    if not candidates then
        return nil, nil
    end
    for index = 1, #candidates do
        local reading = gateway.skillLine(candidates[index])
        if reading then
            state.resolvedLines[subclass] = candidates[index]
            return candidates[index], reading
        end
    end
    return nil, nil
end

local function readSkills()
    state.reads = state.reads + 1
    local rows, unresolved, seenLines = {}, {}, {}
    local seenFishing = false

    local slots = gateway.professionSlots()
    if slots then
        for index = 1, #slots.primary do
            local profession = gateway.profession(slots.primary[index])
            if profession then
                rows[#rows + 1] = {
                    source = SOURCE.PROFESSION,
                    label = profession.name,
                    icon = profession.icon,
                    rank = profession.rank,
                    maximum = profession.maximum,
                }
            end
        end
    end

    if state.capability ~= CAPABILITY.READABLE then
        return { rows = rows, unresolved = unresolved }
    end

    for index = 1, #state.slots do
        local slot = state.slots[index]
        local itemId = gateway.equippedItem(slot)
        local subclass
        if itemId == nil then
            -- An empty main hand is the Unarmed subclass, decided without a client
            -- call. An empty off hand or ranged slot is simply no row.
            if slot == state.mainHandSlot then
                subclass = state.unarmedSubclass
            end
        else
            subclass = gateway.weaponSubclass(itemId)
        end

        if subclass ~= nil and subclass == state.fishingSubclass then
            local fishing = slots and slots.fishing and gateway.profession(slots.fishing)
            if fishing and not seenFishing then
                seenFishing = true
                rows[#rows + 1] = {
                    source = SOURCE.FISHING,
                    label = fishing.name,
                    icon = gateway.equippedIcon(slot) or fishing.icon,
                    rank = fishing.rank,
                    maximum = fishing.maximum,
                }
            end
        elseif subclass ~= nil then
            local skillLine, reading = resolveWeaponSkill(subclass)
            if skillLine then
                if not seenLines[skillLine] then
                    seenLines[skillLine] = true
                    local icon
                    if itemId ~= nil then
                        icon = gateway.equippedIcon(slot)
                    else
                        icon = gateway.emptySlotIcon(slot)
                    end
                    rows[#rows + 1] = {
                        source = SOURCE.WEAPON,
                        slot = slot,
                        skillLine = skillLine,
                        label = reading.name,
                        icon = icon,
                        rank = reading.rank,
                        maximum = reading.maximum,
                    }
                end
            elseif itemId ~= nil then
                unresolved[#unresolved + 1] = { slot = slot, subclass = subclass }
            end
        end
    end

    local defense = gateway.skillLine(ns.DEFENSE_SKILL_LINE)
    if defense then
        rows[#rows + 1] = {
            source = SOURCE.DEFENSE,
            skillLine = ns.DEFENSE_SKILL_LINE,
            label = defense.name,
            icon = ns.DEFENSE_ICON,
            rank = defense.rank,
            maximum = defense.maximum,
        }
    end

    return { rows = rows, unresolved = unresolved }
end

-- Checks, once per session, that the skill reads return plain values (section 5.4).
local function checkCapability()
    local api = _G.C_SkillInfo and _G.C_SkillInfo.GetSkillLineInfoByID
    if type(api) ~= "function" then
        return CAPABILITY.WITHHELD, "C_SkillInfo.GetSkillLineInfoByID is absent"
    end
    local ok, attributes = pcall(api, ns.DEFENSE_SKILL_LINE)
    if not ok then
        return CAPABILITY.WITHHELD, "reading Defense raised"
    end
    if attributes == nil then
        return CAPABILITY.READABLE
    end
    if not isPlain(attributes, "table") then
        return CAPABILITY.WITHHELD, "the skill record came back secret"
    end
    local rank, maximum = attributes.rank, attributes.maxRank
    if (rank ~= nil and not isPlain(rank, "number"))
        or (maximum ~= nil and not isPlain(maximum, "number")) then
        return CAPABILITY.WITHHELD, "skill ranks came back secret"
    end
    return CAPABILITY.READABLE
end

-- Named constants only (Phase 4 section 4.3): the numbers come from the client, so a
-- patch that renumbers an enum cannot silently shift a row.
local function resolveTables()
    local classEnum = _G.Enum and _G.Enum.ItemClass
    local subclassEnum = _G.Enum and _G.Enum.ItemWeaponSubclass
    state.weaponClass = type(classEnum) == "table" and classEnum.Weapon or nil
    state.candidatesBySubclass = {}
    state.subclassNames = {}
    state.unarmedSubclass = nil
    state.fishingSubclass = nil

    if type(subclassEnum) == "table" then
        for name, candidates in pairs(WEAPON_SKILL_CANDIDATES) do
            local value = subclassEnum[name]
            if value ~= nil then
                state.candidatesBySubclass[value] = candidates
            end
        end
        for name, value in pairs(subclassEnum) do
            state.subclassNames[value] = name
        end
        state.unarmedSubclass = subclassEnum[UNARMED_SUBCLASS_NAME]
        state.fishingSubclass = subclassEnum[FISHING_SUBCLASS_NAME]
    end
    if state.weaponClass == nil or type(subclassEnum) ~= "table" then
        ns.Log.Once("skills:noweaponenums",
            "this client lacks Enum.ItemClass or Enum.ItemWeaponSubclass, so the skills window shows no weapon rows")
    end

    state.slots = {}
    state.mainHandSlot = _G.INVSLOT_MAINHAND
    local candidates = { _G.INVSLOT_MAINHAND, _G.INVSLOT_OFFHAND, _G.INVSLOT_RANGED }
    for index = 1, 3 do
        if type(candidates[index]) == "number" then
            state.slots[#state.slots + 1] = candidates[index]
        end
    end
    if #state.slots < 3 then
        ns.Log.Once("skills:noslots",
            "this client lacks one of the INVSLOT constants for the weapon slots; those slots have no row")
    end
end

-- Panel ---------------------------------------------------------------------------

-- Geometry derived from the width, never read back off a frame.

local function rowWidthFor(panelWidth)
    return panelWidth - PANEL_PADDING * 2
end

-- The rank text is the only flexible column; the icon is fixed.
local function textWidthFor(panelWidth)
    return rowWidthFor(panelWidth) - ICON_SIZE - ICON_TEXT_GAP
end

local function createRow()
    local row = CreateFrame("Frame", nil, state.panel)
    row:SetHeight(ROW_HEIGHT)
    row:SetWidth(rowWidthFor(state.settings.panelWidth))
    row:EnableMouse(false)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetWidth(ICON_SIZE)
    row.icon:SetHeight(ICON_SIZE)
    row.icon:SetPoint("LEFT", row, "LEFT", 0, 0)

    row.level = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.level:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.level:SetJustifyH("RIGHT")
    row.level:SetWidth(textWidthFor(state.settings.panelWidth))

    return row
end

local function resetRow(row)
    row:Hide()
    row:ClearAllPoints()
    row.icon:SetTexture(nil)
    row.icon:Hide()
    row.level:SetText("")
end

local function releaseRows()
    for index = #state.liveRows, 1, -1 do
        ns.FramePool.Release(state.rowPool, state.liveRows[index])
        state.liveRows[index] = nil
    end
end

local function anchorPanel()
    local bag = _G.ContainerFrameCombinedBags
    if not state.panel or not bag then
        return
    end
    state.panel:ClearAllPoints()
    state.panel:SetPoint("TOPRIGHT", bag, "TOPLEFT",
        state.settings.anchorOffsetX, state.settings.anchorOffsetY)
end

-- Every frame the window will ever use is made here, at enable (section 3).
local function ensurePanel()
    if state.panel then
        return
    end
    local chrome = ns.PanelChrome.Build({
        frameName = "PersonalAddonEquippedSkills",
        width = state.settings.panelWidth,
        height = ROW_HEIGHT + PANEL_PADDING * 2,
        alpha = state.settings.panelAlpha,
        strata = "MEDIUM",
        ownerKey = "skills",
        ownerLabel = "the skills window",
    })
    state.chrome = chrome
    state.panel = chrome.frame
    state.panel:SetClampedToScreen(true)

    state.rowPool = ns.FramePool.Create({
        poolName = "equippedSkillRows",
        capacity = ns.SKILL_ROW_CAPACITY,
        dropPolicy = ns.DROP_POLICY.SURFACE_AND_FAIL,
        factory = createRow,
        reset = resetRow,
    })
    ns.FramePool.Prewarm(state.rowPool)
end

-- Role box (Patch 03 section 6) ---------------------------------------------------
--
-- Tank, DPS and Auto under the panel, clicked with the mouse. A child of the panel,
-- which is ours (rule 6), so it shows and hides with it. The pad cannot reach it, and
-- must not: SmartNavigation collects buttons only from the panel it tracks, and a
-- pad-reachable addon button is GAPBugs01 G1's carrier (section 6.3). So the buttons
-- carry an OnClick and nothing else: no OnEnter, no OnLeave, no tooltip.

local function lightRoleButton(button, lit)
    local look = lit and ROLE_LIT or ROLE_DIM
    local background = look.background
    if button.background.SetColorTexture then
        button.background:SetColorTexture(background[1], background[2], background[3], background[4])
    else
        button.background:SetTexture(background[1], background[2], background[3], background[4])
    end
    button.label:SetTextColor(look.text[1], look.text[2], look.text[3])
end

-- The chosen button lit and the others dimmed; under Auto, the Auto label shows what
-- the game's test answers now (section 6.5). Runs only while the feature is enabled
-- and the box exists (audit finding 5). Reads our own store, and under Auto the test,
-- once, counted in this feature's table.
local function relightRoleBox()
    local box = state.roleBox
    if not (state.enabled and box) then
        return
    end
    local Threat = ns.Threat
    local stored = ns.ConfigStore.Feature(Threat.ROLE_FEATURE_ID)
    local choice = Threat.RoleChoiceFrom(stored and stored.settings)
    local auto = Threat.AUTO_READING.NOT_ASKED
    if choice == Threat.ROLE_CHOICE.AUTO then
        local _
        _, auto = Threat.ResolveRole(choice, ns.Diagnostics.CountersFor(FEATURE_ID))
    end
    for buttonChoice, button in pairs(box.buttons) do
        lightRoleButton(button, buttonChoice == choice)
    end
    box.buttons[Threat.ROLE_CHOICE.AUTO].label:SetText(
        AUTO_LABELS[auto] or ROLE_LABELS[Threat.ROLE_CHOICE.AUTO])
    state.roleShownChoice = choice
    state.roleShownAuto = auto
end

-- A click writes through the one write path, shared with /pa role (section 6.4), and
-- relights only when the write landed.
local function onRoleClicked(button)
    if ns.Threat.WriteRoleChoice(button.choice) == ns.Threat.ROLE_WRITE.WRITTEN then
        relightRoleBox()
    end
end

-- The engine's dispatch of a click to our own button. Isolated like a handler: an
-- error faults the feature instead of reaching the client's error window.
local function onRoleButtonClick(button)
    local ok, err = ns.Isolation.Call(onRoleClicked, button)
    if not ok then
        ns.Registry.Fault(FEATURE_ID, "raised handling a role box click", err)
    end
end

local function createRoleButton(parent, choice)
    local button = CreateFrame("Button", nil, parent)
    button:SetHeight(ROLE_BUTTON_HEIGHT)
    button:EnableMouse(true)
    button:RegisterForClicks("LeftButtonUp")
    button.choice = choice
    button.background = button:CreateTexture(nil, "BACKGROUND")
    button.background:SetAllPoints(button)
    button.label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    button.label:SetPoint("CENTER", button, "CENTER", 0, 0)
    button.label:SetText(ROLE_LABELS[choice])
    button:SetScript("OnClick", onRoleButtonClick)
    button:Show()
    return button
end

-- Made once, at enable, beside the panel: nothing is created while a bag is open
-- (Patch 01 section 0.2). Tank and DPS meet at the box's top centre, so they split any
-- width in two without code in applyWidth (audit finding 9); Auto spans them both.
local function ensureRoleBox()
    if state.roleBox or not state.panel then
        return
    end
    local ROLE_CHOICE = ns.Threat.ROLE_CHOICE
    local chrome = ns.PanelChrome.Build({
        parent = state.panel,
        width = state.settings.panelWidth,
        height = ROLE_BOX_HEIGHT,
        alpha = state.settings.panelAlpha,
        ownerKey = "rolebox",
        ownerLabel = "the role box",
    })
    local frame = chrome.frame
    frame:SetPoint("TOPLEFT", state.panel, "BOTTOMLEFT", 0, -ROLE_BOX_GAP)
    frame:SetPoint("TOPRIGHT", state.panel, "BOTTOMRIGHT", 0, -ROLE_BOX_GAP)

    local halfGap = ROLE_BUTTON_GAP / 2
    local tank = createRoleButton(frame, ROLE_CHOICE.TANK)
    tank:SetPoint("TOPLEFT", frame, "TOPLEFT", ROLE_BOX_PADDING, -ROLE_BOX_PADDING)
    tank:SetPoint("TOPRIGHT", frame, "TOP", -halfGap, -ROLE_BOX_PADDING)
    local dps = createRoleButton(frame, ROLE_CHOICE.DPS)
    dps:SetPoint("TOPLEFT", frame, "TOP", halfGap, -ROLE_BOX_PADDING)
    dps:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -ROLE_BOX_PADDING, -ROLE_BOX_PADDING)
    local auto = createRoleButton(frame, ROLE_CHOICE.AUTO)
    auto:SetPoint("TOPLEFT", tank, "BOTTOMLEFT", 0, -ROLE_BUTTON_GAP)
    auto:SetPoint("TOPRIGHT", dps, "BOTTOMRIGHT", 0, -ROLE_BUTTON_GAP)

    state.roleBox = {
        chrome = chrome,
        frame = frame,
        buttons = {
            [ROLE_CHOICE.TANK] = tank,
            [ROLE_CHOICE.DPS] = dps,
            [ROLE_CHOICE.AUTO] = auto,
        },
    }
end

-- Shown with the panel while roleChoice is on (section 6.2). With it off, the stored
-- choice still applies.
local function applyRoleBoxWanted()
    local box = state.roleBox
    if not box then
        return
    end
    if state.settings.roleChoice then
        box.frame:Show()
    else
        box.frame:Hide()
    end
end

-- The box keeps its own chrome: PanelChrome holds a frame at alpha 1 and fades the
-- background alone, so a child does not follow the panel's opacity (audit finding 1).
-- Called wherever the panel's background opacity is set.
local function applyRoleBoxAlpha()
    if state.roleBox then
        ns.PanelChrome.SetAlpha(state.roleBox.chrome, state.settings.panelAlpha)
    end
end

local function signatureOf(snapshot)
    local parts = {}
    for index = 1, #snapshot.rows do
        local row = snapshot.rows[index]
        parts[#parts + 1] = format("%s:%s:%d:%d", tostring(row.source),
            tostring(row.icon), row.rank, row.maximum)
    end
    return concat(parts, "|")
end

local function setIcon(texture, icon)
    if icon == nil then
        texture:Hide()
        return
    end
    -- SetTexture reports whether the texture loaded. Only an explicit false is a
    -- failure: a client that returns nothing has set it.
    if texture:SetTexture(icon) == false then
        state.iconFailures = state.iconFailures + 1
        ns.Log.Once("skills:iconfailed:" .. tostring(icon), format(
            "the skills window could not load the icon %s; that row shows its numbers alone",
            ns.EscapeGuard.Neutralize(tostring(icon))))
        texture:Hide()
        return
    end
    texture:Show()
end

local function render(snapshot)
    local signature = signatureOf(snapshot)
    if signature == state.lastSignature then
        return false
    end
    state.lastSignature = signature
    releaseRows()

    local rows = snapshot.rows
    if #rows == 0 then
        state.panel:Hide()
        return true
    end

    local previous = nil
    for index = 1, #rows do
        local row, poolError = ns.FramePool.Acquire(state.rowPool)
        if not row then
            ns.Log.OnceError("skills:poolexhausted", format(
                "the skills window row pool was exhausted (%s)", tostring(poolError)))
            break
        end
        local entry = rows[index]
        setIcon(row.icon, entry.icon)
        row.level:SetText(format("%d / %d", entry.rank, entry.maximum))
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
    applyRoleBoxAlpha()
    state.panel:Show()
    return true
end

-- Width (section 6.2) ------------------------------------------------------------

-- Every row in the POOL, not just the live ones: a row resized only while live
-- would come back at the old width the next time it is acquired.
local function applyWidth()
    if not state.panel then
        return
    end
    local width = state.settings.panelWidth
    state.panel:SetWidth(width)
    local rowWidth, textWidth = rowWidthFor(width), textWidthFor(width)
    ns.FramePool.ForEach(state.rowPool, function(row)
        row:SetWidth(rowWidth)
        row.level:SetWidth(textWidth)
    end)
end

-- Preview (section 5.4) ----------------------------------------------------------

-- A fixed six rows, which is the normal case: two professions, three weapon
-- slots and Defense. The live count is what you have equipped, behind reads that
-- can be withheld, so the previewed HEIGHT can differ from the live one; width
-- is what this phase adjusts and it is unaffected. Reads no skill value.
local PREVIEW_LABELS = {
    "Sample 1", "Sample 2", "Sample 3", "Sample 4", "Sample 5", "Sample 6",
    "Sample 7", "Sample 8",
}

local function showPlaceholders()
    if not state.panel then
        return 0
    end
    releaseRows()
    -- The live render short-circuits on an unchanged signature, so the preview
    -- clears it: the next real render must redraw rather than believe the sample
    -- rows are its own.
    state.lastSignature = nil

    local drawCount = min(ns.PREVIEW_SKILL_ROWS, ns.SKILL_ROW_CAPACITY)
    local previous = nil
    for index = 1, drawCount do
        local row, poolError = ns.FramePool.Acquire(state.rowPool)
        if not row then
            ns.Log.OnceError("skills:previewpool", format(
                "the skills window row pool was exhausted drawing a preview (%s)",
                tostring(poolError)))
            break
        end
        row.icon:SetTexture(ns.DEFENSE_ICON)
        row.icon:Show()
        row.level:SetText(PREVIEW_LABELS[index] or "Sample")
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
    applyRoleBoxAlpha()
    state.panel:Show()
    -- Patch 03 section 6.5: no poll runs in the preview, so the box is lit here.
    relightRoleBox()
    return shown
end

local function clearPlaceholders()
    if state.rowPool then
        releaseRows()
    end
    state.lastSignature = nil
    if state.panel then
        state.panel:Hide()
    end
end

local function registerPreview()
    ns.Preview.Register({
        panelId = ns.PREVIEW_PANEL.EQUIPPED_SKILLS,
        raiseTarget = state.panel,
        baseStrata = state.chrome and state.chrome.baseStrata or nil,
        show = showPlaceholders,
        clear = clearPlaceholders,
    })
end

-- Visibility and refresh (section 5.5) -------------------------------------------

local function stopPoll()
    if state.poll and state.poll.Cancel then
        state.poll:Cancel()
    end
    state.poll = nil
end

local function hideWindow()
    state.shown = false
    stopPoll()
    if state.rowPool then
        releaseRows()
    end
    if state.panel then
        state.panel:Hide()
    end
    state.lastSignature = nil
end

local function refresh()
    -- The preview owns the panel while it is on, and the poll ticker runs
    -- whenever the bags are open, so opening them during a preview would
    -- otherwise overwrite the sample rows (section 5.7).
    if ns.Preview.IsEnabled() then
        return
    end
    local snapshot = readSkills()
    state.lastSnapshot = snapshot
    render(snapshot)
end

local startPoll

-- A tick runs from the timer, outside Dispatch, so it takes the same protection a
-- handler gets: an error faults the feature instead of reaching the client.
local function pollTick()
    if not state.enabled or not state.shown then
        stopPoll()
        return
    end
    local ok, err = ns.Isolation.Call(function()
        -- The bag's OnHide always announces a close; this only catches the case
        -- where that announcement never arrived.
        if not gateway.combinedBagShown() then
            hideWindow()
            return
        end
        refresh()
        -- Patch 03 section 6.5: an outside change, or Auto's answer, within one poll.
        relightRoleBox()
    end)
    if not ok then
        ns.Registry.Fault(FEATURE_ID, "raised while refreshing the skills window", err)
    end
end

startPoll = function()
    stopPoll()
    if C_Timer and C_Timer.NewTicker then
        state.poll = C_Timer.NewTicker(state.settings.pollSeconds, pollTick)
    end
end

local function showWindow()
    state.shown = true
    state.lastSignature = nil
    refresh()
    relightRoleBox()
    startPoll()
end

-- Both bag callbacks arrive here, a frame after Blizzard's OnShow or OnHide
-- (Dispatch section 4.1). Level-triggered: what counts is whether the bag is on
-- screen now, not which event arrived, so an open and a close in one frame resolve
-- to what the player sees.
local function onBagSignal()
    if not state.enabled then
        return
    end
    local bagShown = gateway.combinedBagShown()
    if bagShown and not state.shown then
        showWindow()
    elseif not bagShown and state.shown then
        hideWindow()
    end
end

-- Lifecycle -----------------------------------------------------------------------

local function readSettings(config)
    local settings = config and config.settings
    if not settings then
        return
    end
    state.settings.panelWidth = settings.panelWidth or state.settings.panelWidth
    state.settings.anchorOffsetX = settings.anchorOffsetX or state.settings.anchorOffsetX
    state.settings.anchorOffsetY = settings.anchorOffsetY or state.settings.anchorOffsetY
    state.settings.panelAlpha = settings.panelAlpha or state.settings.panelAlpha
    state.settings.pollSeconds = settings.pollSeconds or state.settings.pollSeconds
    state.settings.roleChoice = (settings.roleChoice ~= false)
end

local BAG_EVENTS = { "ContainerFrame.OpenBag", "ContainerFrame.CloseBag" }

local function enable(config)
    readSettings(config)

    if not _G.ContainerFrameCombinedBags then
        return nil, "this client has no combined bag frame (ContainerFrameCombinedBags), so there is nothing to sit beside"
    end
    if not (_G.C_SkillInfo and type(_G.C_SkillInfo.GetSkillLineInfoByID) == "function") then
        return nil, "this client has no C_SkillInfo.GetSkillLineInfoByID, so skill levels cannot be read by ID"
    end

    resolveTables()
    if state.capability == CAPABILITY.NOT_YET_READ then
        state.capability, state.capabilityReason = checkCapability()
        if state.capability == CAPABILITY.WITHHELD then
            ns.Log.Once("skills:withheld", format(
                "the client withholds skill levels (%s); the skills window shows professions only",
                tostring(state.capabilityReason)))
        end
    end

    ensurePanel()
    applyWidth()
    anchorPanel()
    -- Patch 03 section 6.2: the role box, made here with the panel, never at a bag open.
    ensureRoleBox()
    applyRoleBoxWanted()
    registerPreview()

    for index = 1, #BAG_EVENTS do
        local token, reason = ns.Dispatch.SubscribeCallback(FEATURE_ID, BAG_EVENTS[index], onBagSignal)
        if not token then
            return nil, format("cannot follow %s (%s)", BAG_EVENTS[index], tostring(reason))
        end
        state.tokens[#state.tokens + 1] = token
    end

    state.enabled = true
    -- The bag may already be open: enabling from the settings panel or /pa on.
    onBagSignal()
    return true
end

-- Tolerates a partial enable (Phase 1 section 6.1).
local function disable()
    state.enabled = false
    ns.Preview.Unregister(ns.PREVIEW_PANEL.EQUIPPED_SKILLS)
    hideWindow()
    for index = #state.tokens, 1, -1 do
        ns.Dispatch.Unsubscribe(state.tokens[index])
        state.tokens[index] = nil
    end
end

local function onConfigChanged(config, changedKey)
    readSettings(config)
    if changedKey == "anchorOffsetX" or changedKey == "anchorOffsetY" then
        anchorPanel()
    elseif changedKey == "panelWidth" then
        applyWidth()
        if ns.Preview.IsEnabled() then
            showPlaceholders()
        end
    elseif changedKey == "panelAlpha" then
        ns.PanelChrome.SetAlpha(state.chrome, state.settings.panelAlpha)
        applyRoleBoxAlpha()
    elseif changedKey == "roleChoice" then
        -- Patch 03 section 6.5 (audit finding 5): lit at once when it turns on.
        applyRoleBoxWanted()
        if state.settings.roleChoice then
            relightRoleBox()
        end
    elseif changedKey == "pollSeconds" then
        if state.poll then
            startPoll()
        end
    end
    return ns.CONFIG_RESULT.APPLIED
end

ns.Registry.Register(FEATURE_ID, {
    enabledByDefault = true,
    label = "Equipped skills",
    description = "Your professions, the skills of your equipped weapons, and Defense, beside the bags while they are open.",
    settingsPage = ns.SETTINGS_PAGE.BAGS_AND_LOOT,
    settingsOrder = 10,
    settings = {
        anchorOffsetX = -4,
        anchorOffsetY = 0,
        panelWidth = 96,
        panelAlpha = 0.8,
        pollSeconds = 1,
        -- Patch 03 section 8.2.
        roleChoice = true,
    },
    schema = {
        -- Phase 13: the minimum is padding, icon, gap and the least the rank
        -- text can have (Core/Constants.lua).
        panelWidth = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Window width", order = 0,
            unit = ns.ConfigSchema.UNIT.PIXELS,
            minimum = ns.SKILL_PANEL_MINIMUM_WIDTH,
            maximum = ns.SKILL_PANEL_MAXIMUM_WIDTH, step = 1,
        },
        anchorOffsetX = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Horizontal offset", order = 1,
            unit = ns.ConfigSchema.UNIT.PIXELS,
            minimum = -300, maximum = 300, step = 1,
        },
        anchorOffsetY = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Vertical offset", order = 2,
            unit = ns.ConfigSchema.UNIT.PIXELS,
            minimum = -300, maximum = 300, step = 1,
        },
        panelAlpha = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Panel opacity", order = 3,
            unit = ns.ConfigSchema.UNIT.FRACTION,
            minimum = 0.1, maximum = 1.0, step = 0.05,
        },
        -- Patch 03 section 8.2.
        roleChoice = {
            kind = ns.ConfigSchema.KIND.TOGGLE, label = "Show the Tank / DPS / Auto choice", order = 4,
            description = "A Tank / DPS / Auto switch under this window, clicked with the mouse. Tank: a mob you hold turns green, one about to change hands orange, one on your group red, on nameplates and the threat panel. Auto: Tank whenever the game counts you as tanking.",
        },
        pollSeconds = {
            kind = ns.ConfigSchema.KIND.NUMBER, label = "Refresh interval while open",
            minimum = 0.5, maximum = 5, step = 0.5, curated = false,
        },
    },
}, {
    enable = enable,
    disable = disable,
    onConfigChanged = onConfigChanged,
})

-- /pa skills ---------------------------------------------------------------------

local function slotLabel(slot)
    if slot == _G.INVSLOT_MAINHAND then return "main hand" end
    if slot == _G.INVSLOT_OFFHAND then return "off hand" end
    if slot == _G.INVSLOT_RANGED then return "ranged" end
    return "slot " .. tostring(slot)
end

-- Whether one of our own frames is shown, read through ClientRead as the secret-read
-- lint asks of every secret-capable method (README rule 10), as the bag's read is.
local function ownFrameShown(frame)
    if not frame then
        return false
    end
    local kind, shown = ns.ClientRead.Call(frame.IsShown, "boolean", frame)
    return kind == ns.ClientRead.PLAIN and shown == true
end

-- The role box is on screen when it is shown and so is its parent panel.
local function roleBoxShown()
    return state.roleBox ~= nil and ownFrameShown(state.roleBox.frame) and ownFrameShown(state.panel)
end

ns.EquippedSkills = {
    Refresh = function()
        if state.enabled and state.shown then
            state.lastSignature = nil
            refresh()
        end
    end,
    -- Patch 03 section 9: the role box for /pa role, with no skill read.
    RoleBoxState = function()
        return {
            enabled = state.enabled,
            created = state.roleBox ~= nil,
            wanted = state.settings.roleChoice,
            shown = roleBoxShown(),
        }
    end,
    Inspect = function()
        local snapshot = state.lastSnapshot
        if state.enabled and not state.shown then
            -- Read on demand so /pa skills answers with the bags closed too. Reads
            -- only; nothing is drawn.
            snapshot = readSkills()
        end
        local rows, unresolved = {}, {}
        if snapshot then
            for index = 1, #snapshot.rows do
                local row = snapshot.rows[index]
                rows[#rows + 1] = {
                    source = row.source,
                    label = row.label,
                    slot = row.slot and slotLabel(row.slot) or nil,
                    skillLine = row.skillLine,
                    rank = row.rank,
                    maximum = row.maximum,
                    hasIcon = row.icon ~= nil,
                }
            end
            for index = 1, #snapshot.unresolved do
                local entry = snapshot.unresolved[index]
                unresolved[#unresolved + 1] = format("%s (%s)", slotLabel(entry.slot),
                    tostring(state.subclassNames[entry.subclass] or entry.subclass))
            end
        end
        local constructed, live, free, capacity = 0, 0, 0, 0
        if state.rowPool then
            constructed, live, free, capacity = ns.FramePool.Stats(state.rowPool)
        end
        local fistLine = state.unarmedSubclass and state.resolvedLines[state.unarmedSubclass]
        return {
            -- First: the defence against reading sample rows as real
            -- (section 5.1).
            preview = ns.Preview.IsEnabled(),
            panelWidth = state.settings.panelWidth,
            enabled = state.enabled,
            capability = state.capability,
            capabilityReason = state.capabilityReason,
            shown = state.shown,
            bagShown = gateway.combinedBagShown(),
            panelShown = (state.panel ~= nil and state.panel:IsShown()) or false,
            pollRunning = state.poll ~= nil,
            pollSeconds = state.settings.pollSeconds,
            rows = rows,
            unresolved = unresolved,
            fistLine = fistLine,
            withheldReads = state.withheldReads,
            iconFailures = state.iconFailures,
            reads = state.reads,
            borderStyle = state.chrome and state.chrome.borderStyle or "none",
            -- Patch 03 section 9: the role box, as the last relight showed it.
            roleBox = {
                created = state.roleBox ~= nil,
                wanted = state.settings.roleChoice,
                shown = roleBoxShown(),
                choice = state.roleShownChoice,
                auto = state.roleShownAuto,
                frame = state.roleBox and state.roleBox.frame or nil,
                buttons = state.roleBox and state.roleBox.buttons or nil,
            },
            poolConstructed = constructed,
            poolLive = live,
            poolFree = free,
            poolCapacity = capacity,
        }
    end,
}
