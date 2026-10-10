-- Phase 13 offline checks (Architecture/20261009-Phase13.md section 11.1).
-- Sessions: "phase13" (P1-P30) and "phase13-norefuse"... no: "phase13-refused",
-- where the settings API refuses the preview setting and SetFrameStrata raises.

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

local PANEL = ns.PREVIEW_PANEL
local GROUP = ns.PREVIEW_GROUP
local OUTCOME = ns.Preview.OUTCOME

local function outcomeFor(panelId)
    for _, window in ipairs(ns.Preview.Inspect().windows) do
        if window.panelId == panelId then
            return window
        end
    end
    return nil
end

local function kindFor(panelId)
    local window = outcomeFor(panelId)
    return window and window.kind or nil
end

-- Session variants, set before login ----------------------------------------------
local REFUSED = (HARNESS_SESSION == "phase13-refused")
if REFUSED then
    -- The settings API will not take the preview setting, and raising a window's
    -- strata raises. Neither may take the rest of the phase down.
    local realRegister = Settings.RegisterAddOnSetting
    Settings.RegisterAddOnSetting = function(category, variable, key, tbl, varType, label, default)
        if variable == "PersonalAddon_preview_showAll" then
            error("the harness refuses the preview setting")
        end
        return realRegister(category, variable, key, tbl, varType, label, default)
    end
end

HARNESS.fire("ADDON_LOADED", "PersonalAddon")
HARNESS.fire("PLAYER_LOGIN")
HARNESS.frame()

-- P1: the toggle is a PAGE-level control, parented to no switch -------------------
-- Phase 12's A5 skips it for exactly this reason, so the exception is asserted
-- here rather than merely excused there.
local previewInitializer = nil
for _, category in ipairs(HARNESS.settingsCategories) do
    for _, initializer in ipairs(category.layout.initializers) do
        if initializer.setting ~= nil
            and initializer.setting.variable == "PersonalAddon_preview_showAll" then
            previewInitializer = initializer
        end
    end
end

if REFUSED then
    check("P1 refused toggle is absent", previewInitializer == nil)
    check("P2 refusal noted for /pa panel",
        ns.SettingsPanel.Inspect().previewToggleBuilt == false,
        tostring(ns.SettingsPanel.Inspect().previewToggleBuilt))
    local others = 0
    for _, category in ipairs(HARNESS.settingsCategories) do
        others = others + #category.layout.initializers
    end
    check("P3 the rest of the page still built", others > 10, others)
else
    check("P1 toggle is top-level", previewInitializer ~= nil
        and previewInitializer.parentInitializer == nil)
    check("P2 toggle is a checkbox", previewInitializer ~= nil
        and previewInitializer.kind == "checkbox", previewInitializer and previewInitializer.kind)
    check("P3 toggle defaults off", previewInitializer ~= nil
        and previewInitializer.setting.defaultValue == false)
end

-- P3a: one window that cannot be raised does not take the others down ---------------
if REFUSED then
    local threatFrame = HARNESS.frameByName("PersonalAddonThreatPanel")
    threatFrame.SetFrameStrata = function() error("the harness refuses this strata") end
    ns.Preview.SetEnabled(true)
    check("P3a the refused window is skipped with a reason",
        kindFor(PANEL.THREAT_PANEL) == OUTCOME.SKIPPED
        and tostring(outcomeFor(PANEL.THREAT_PANEL).detail):find("refused", 1, true) ~= nil,
        tostring(kindFor(PANEL.THREAT_PANEL)) .. "/"
            .. tostring(outcomeFor(PANEL.THREAT_PANEL).detail))
    check("P3b the others still show",
        kindFor(PANEL.EQUIPPED_SKILLS) == OUTCOME.SHOWN
        and kindFor(PANEL.TOASTS) == OUTCOME.SHOWN,
        tostring(kindFor(PANEL.EQUIPPED_SKILLS)) .. "/" .. tostring(kindFor(PANEL.TOASTS)))
    ns.Preview.SetEnabled(false)
    threatFrame.SetFrameStrata = nil
end

-- P3c: the CONTROL turns the preview on, not just the API -----------------------------
-- The user clicks a checkbox; they do not call Preview.SetEnabled. Driving the
-- registered setting the way Blizzard does goes through onPanelValueChanged,
-- scheduleApply and flushPendingApplies, and it is that last step which dropped
-- the apply in game while every direct-call check passed (section 16, item 7).
if not REFUSED then
    local setting = HARNESS.settingsByVariable["PersonalAddon_preview_showAll"]
    check("P3c the toggle is registered", setting ~= nil)
    if setting then
        setting:SetValue(true)
        HARNESS.frame()
        check("P3d the control turned the preview on", ns.Preview.IsEnabled() == true)
        setting:SetValue(false)
        HARNESS.frame()
        check("P3e the control turned it off again", ns.Preview.IsEnabled() == false)
    end
end

-- P4: nothing is persisted ---------------------------------------------------------
check("P4 the toggle reaches no config key",
    ns.ConfigStore.Get("preview", "showAll") == nil)

-- P5: every window registered at login --------------------------------------------
check("P5 four windows known", #ns.Preview.Inspect().windows == 4,
    #ns.Preview.Inspect().windows)
check("P6 preview starts off", ns.Preview.IsEnabled() == false)
check("P7 initial focus is the threat panel",
    ns.Preview.Inspect().focus[GROUP.PLAYER_FRAME] == PANEL.THREAT_PANEL,
    tostring(ns.Preview.Inspect().focus[GROUP.PLAYER_FRAME]))

-- P8: on, with everything enabled --------------------------------------------------
local counterNamesBefore = {}
local threatBefore = ns.ThreatPanel.Inspect()
for key, value in pairs(threatBefore.counters or {}) do
    counterNamesBefore[key] = value
end

ns.Preview.SetEnabled(true)
check("P8 preview on", ns.Preview.IsEnabled() == true)
check("P9 threat panel shown", kindFor(PANEL.THREAT_PANEL) == OUTCOME.SHOWN,
    tostring(kindFor(PANEL.THREAT_PANEL)))
check("P10 breakdown deferred", kindFor(PANEL.DAMAGE_BREAKDOWN) == OUTCOME.DEFERRED,
    tostring(kindFor(PANEL.DAMAGE_BREAKDOWN)))
check("P11 deferred names the subject",
    outcomeFor(PANEL.DAMAGE_BREAKDOWN).detail == PANEL.THREAT_PANEL,
    tostring(outcomeFor(PANEL.DAMAGE_BREAKDOWN).detail))
check("P12 skills shown", kindFor(PANEL.EQUIPPED_SKILLS) == OUTCOME.SHOWN,
    tostring(kindFor(PANEL.EQUIPPED_SKILLS)))
check("P13 toasts shown", kindFor(PANEL.TOASTS) == OUTCOME.SHOWN,
    tostring(kindFor(PANEL.TOASTS)))

-- P14: raised above HIGH ------------------------------------------------------------
check("P14 threat panel raised to DIALOG",
    ns.ThreatPanel.Inspect().panelShown == true
    and HARNESS.frameByName("PersonalAddonThreatPanel"):GetFrameStrata() == "DIALOG",
    HARNESS.frameByName("PersonalAddonThreatPanel"):GetFrameStrata())

-- P15: the sample rows read nothing and move no counter ----------------------------
local threatAfter = ns.ThreatPanel.Inspect()
local moved = {}
for key, value in pairs(threatAfter.counters or {}) do
    if (counterNamesBefore[key] or 0) ~= value then
        moved[#moved + 1] = key
    end
end
check("P15 no threat counter moved by a preview", #moved == 0, table.concat(moved, ", "))
check("P16 /pa threat reports preview", threatAfter.preview == true)
check("P17 /pa dps reports preview", ns.DamageBreakdown.Inspect().preview == true)
check("P18 /pa skills reports preview", ns.EquippedSkills.Inspect().preview == true)
check("P19 /pa toasts reports preview", ns.Toasts.Inspect().preview == true)

-- P20: two toast samples, with a slot left free -------------------------------------
check("P20 two samples held", ns.Toasts.Inspect().previewSamples == 2,
    ns.Toasts.Inspect().previewSamples)
check("P21 a slot is still free",
    ns.Toasts.Inspect().visible < ns.Toasts.Inspect().maximumVisible,
    ns.Toasts.Inspect().visible .. "/" .. ns.Toasts.Inspect().maximumVisible)

-- P22: idempotent ---------------------------------------------------------------------
local before = kindFor(PANEL.THREAT_PANEL)
ns.Preview.SetEnabled(true)
check("P22 SetEnabled(true) twice is idempotent", kindFor(PANEL.THREAT_PANEL) == before)

-- P23: focus follows what is adjusted ------------------------------------------------
ns.Preview.FocusFeature("damageBreakdown")
check("P23 focus moved to the breakdown",
    ns.Preview.Inspect().focus[GROUP.PLAYER_FRAME] == PANEL.DAMAGE_BREAKDOWN)
check("P24 breakdown shown, threat panel deferred",
    kindFor(PANEL.DAMAGE_BREAKDOWN) == OUTCOME.SHOWN
    and kindFor(PANEL.THREAT_PANEL) == OUTCOME.DEFERRED,
    tostring(kindFor(PANEL.DAMAGE_BREAKDOWN)) .. "/" .. tostring(kindFor(PANEL.THREAT_PANEL)))
check("P25 the deferred panel was restored",
    HARNESS.frameByName("PersonalAddonThreatPanel"):GetFrameStrata() ~= "DIALOG",
    HARNESS.frameByName("PersonalAddonThreatPanel"):GetFrameStrata())

-- P25a: every sample icon is a real texture path -----------------------------------------
-- A literal written through a shell heredoc can lose its doubled backslashes, which
-- leaves a path with one separator character where Lua needs two, so it reads as
-- "InterfaceIconsX": a path the client cannot load and
-- no stub rejects. Asserted because it happened (section 16, item 6). Runs HERE, after
-- both player-frame panels have been the subject, because a deferred panel has drawn
-- nothing and a check that inspects nothing passes for the wrong reason.
local iconsSeen, badIcons = 0, {}
for _, frame in ipairs(HARNESS.frames) do
    local region = rawget(frame, "icon")
    local texture = region and rawget(region, "texture")
    if type(texture) == "string" and texture:find("Interface", 1, true) then
        iconsSeen = iconsSeen + 1
        if not texture:find("\\", 1, true) then
            badIcons[#badIcons + 1] = texture
        end
    end
end
check("P25a sample icons were found to check", iconsSeen >= 3, iconsSeen)
check("P25b sample icon paths keep their separators", #badIcons == 0,
    table.concat(badIcons, ", "))

ns.Preview.FocusFeature("nameplates")
check("P26 a feature owning no window does not move any focus",
    ns.Preview.Inspect().focus[GROUP.PLAYER_FRAME] == PANEL.DAMAGE_BREAKDOWN)

ns.Preview.Focus(PANEL.THREAT_PANEL)

-- P27: the fallback when the focused feature is off -----------------------------------
ns.Registry.SetEnabled("threatPanel", false)
HARNESS.frame()
check("P27 the focused panel is skipped with its state",
    kindFor(PANEL.THREAT_PANEL) == OUTCOME.SKIPPED
    and outcomeFor(PANEL.THREAT_PANEL).detail == "DISABLED",
    tostring(kindFor(PANEL.THREAT_PANEL)) .. "/"
        .. tostring(outcomeFor(PANEL.THREAT_PANEL).detail))
check("P28 the sibling stands in",
    kindFor(PANEL.DAMAGE_BREAKDOWN) == OUTCOME.SHOWN,
    tostring(kindFor(PANEL.DAMAGE_BREAKDOWN)))
check("P29 the fallback does not move the focus",
    ns.Preview.Inspect().focus[GROUP.PLAYER_FRAME] == PANEL.THREAT_PANEL,
    tostring(ns.Preview.Inspect().focus[GROUP.PLAYER_FRAME]))
check("P30 the subject differs from the focus",
    ns.Preview.Inspect().subject[GROUP.PLAYER_FRAME] == PANEL.DAMAGE_BREAKDOWN,
    tostring(ns.Preview.Inspect().subject[GROUP.PLAYER_FRAME]))

-- P31: re-enabling takes the subject back in the Register call ------------------------
ns.Registry.SetEnabled("threatPanel", true)
HARNESS.frame()
check("P31 re-enabling restores the subject",
    kindFor(PANEL.THREAT_PANEL) == OUTCOME.SHOWN
    and kindFor(PANEL.DAMAGE_BREAKDOWN) == OUTCOME.DEFERRED,
    tostring(kindFor(PANEL.THREAT_PANEL)) .. "/" .. tostring(kindFor(PANEL.DAMAGE_BREAKDOWN)))

-- P32: both of the group off --------------------------------------------------------
ns.Registry.SetEnabled("threatPanel", false)
ns.Registry.SetEnabled("damageBreakdown", false)
HARNESS.frame()
check("P32 the group shows nothing",
    ns.Preview.Inspect().subject[GROUP.PLAYER_FRAME] == nil,
    tostring(ns.Preview.Inspect().subject[GROUP.PLAYER_FRAME]))
check("P33 the other windows are unaffected",
    kindFor(PANEL.EQUIPPED_SKILLS) == OUTCOME.SHOWN
    and kindFor(PANEL.TOASTS) == OUTCOME.SHOWN)
ns.Registry.SetEnabled("threatPanel", true)
ns.Registry.SetEnabled("damageBreakdown", true)
HARNESS.frame()

-- P34: a real toast evicts a sample --------------------------------------------------
ns.ConfigStore.Set("toasts", "maximumVisible", 2)
ns.Registry.NotifyConfigChanged("toasts", "maximumVisible")
HARNESS.frame()
ns.Preview.SetEnabled(false)
ns.Preview.SetEnabled(true)
check("P34 samples fit the lowered cap", ns.Toasts.Inspect().previewSamples <= 2,
    ns.Toasts.Inspect().previewSamples)

local chatMark = #HARNESS.chat
ns.Toasts.Post({ kind = ns.Toasts.KIND.LOOTED_MONEY, amount = 999 })
HARNESS.frame()
local poolWarned = false
for index = chatMark + 1, #HARNESS.chat do
    if tostring(HARNESS.chat[index]):find("the cap is wrong", 1, true) then
        poolWarned = true
    end
end
check("P35 no false pool-exhausted notice", poolWarned == false)
check("P36 the real toast is on screen", ns.Toasts.Inspect().counts.shown > 0,
    ns.Toasts.Inspect().counts.shown)
ns.ConfigStore.Set("toasts", "maximumVisible", 3)
ns.Registry.NotifyConfigChanged("toasts", "maximumVisible")
HARNESS.frame()

-- P37: combat ends the preview, and the toggle is told --------------------------------
local chatBeforeCombat = #HARNESS.chat
HARNESS.fire("PLAYER_REGEN_DISABLED")
HARNESS.frame()
check("P37 combat ended the preview", ns.Preview.IsEnabled() == false)
local said = false
for index = chatBeforeCombat + 1, #HARNESS.chat do
    if tostring(HARNESS.chat[index]):find("a fight started", 1, true) then
        said = true
    end
end
check("P38 one line says why", said)
check("P39 every window was restored",
    HARNESS.frameByName("PersonalAddonThreatPanel"):GetFrameStrata() ~= "DIALOG",
    HARNESS.frameByName("PersonalAddonThreatPanel"):GetFrameStrata())
if not REFUSED then
    check("P40 the toggle agrees with the state",
        HARNESS.settingValue("PersonalAddon_preview_showAll") == false,
        tostring(HARNESS.settingValue("PersonalAddon_preview_showAll")))
end

HARNESS.fire("PLAYER_REGEN_ENABLED")
HARNESS.frame()

-- P41: the live paths come back ---------------------------------------------------------
check("P41 the breakdown refreshes again", ns.DamageBreakdown.Refresh() ~= false)

-- P42: width floors --------------------------------------------------------------------
check("P42 the threat floor is 10% under the player bar",
    ns.THREAT_PANEL_MINIMUM_WIDTH == 112, ns.THREAT_PANEL_MINIMUM_WIDTH)
local accepted, violation = ns.ConfigSchema.Validate("threatPanel", "panelWidth", 111)
check("P43 111 is refused", accepted == nil
    and violation == ns.ConfigSchema.VIOLATION.BELOW_MINIMUM, tostring(violation))
accepted, violation = ns.ConfigSchema.Validate("threatPanel", "panelWidth", 401)
check("P44 401 is refused", accepted == nil
    and violation == ns.ConfigSchema.VIOLATION.ABOVE_MAXIMUM, tostring(violation))
check("P45 112 is accepted",
    ns.ConfigSchema.Validate("threatPanel", "panelWidth", 112) == 112)
accepted, violation = ns.ConfigSchema.Validate("equippedSkills", "panelWidth", 73)
check("P46 the skills floor is 74", accepted == nil
    and violation == ns.ConfigSchema.VIOLATION.BELOW_MINIMUM, tostring(violation))

-- P47: applying a width reaches the panel and every POOLED row ---------------------------
ns.ConfigStore.Set("threatPanel", "panelWidth", 112)
ns.Registry.NotifyConfigChanged("threatPanel", "panelWidth")
HARNESS.frame()
local panel = HARNESS.frameByName("PersonalAddonThreatPanel")
check("P47 the panel narrowed", panel:GetWidth() == 112, panel:GetWidth())

local wrongWidth = 0
for _, frame in ipairs(HARNESS.frames) do
    if frame.parent == panel and frame.width ~= nil and frame.width ~= 100 then
        wrongWidth = wrongWidth + 1
    end
end
check("P48 every pooled row narrowed too", wrongWidth == 0, wrongWidth)

local view = ns.ThreatPanel.Inspect()
check("P49 the bar is 22 at the floor with the tag on", view.barWidth == 22, view.barWidth)

-- P50: the name hides under the threshold ------------------------------------------------
check("P50 the name is hidden at a 22px bar", view.barWidth < ns.THREAT_NAME_MINIMUM_BAR)
ns.ConfigStore.Set("threatPanel", "showLevel", false)
ns.Registry.NotifyConfigChanged("threatPanel", "showLevel")
HARNESS.frame()
check("P51 the tag's space goes to the bar",
    ns.ThreatPanel.Inspect().barWidth == 55, ns.ThreatPanel.Inspect().barWidth)
check("P52 and the name comes back",
    ns.ThreatPanel.Inspect().barWidth >= ns.THREAT_NAME_MINIMUM_BAR)
ns.ConfigStore.Set("threatPanel", "showLevel", true)
ns.Registry.NotifyConfigChanged("threatPanel", "showLevel")
HARNESS.frame()

-- P53: a row released and re-acquired keeps the new width ---------------------------------
ns.Preview.SetEnabled(true)
ns.Preview.SetEnabled(false)
ns.Preview.SetEnabled(true)
wrongWidth = 0
for _, frame in ipairs(HARNESS.frames) do
    if frame.parent == panel and frame.width ~= nil and frame.width ~= 100 then
        wrongWidth = wrongWidth + 1
    end
end
check("P53 recycled rows keep the width", wrongWidth == 0, wrongWidth)
ns.Preview.SetEnabled(false)
ns.ConfigStore.Set("threatPanel", "panelWidth", 200)
ns.Registry.NotifyConfigChanged("threatPanel", "panelWidth")
HARNESS.frame()

-- P53a: the width SLIDER narrows the panel, and focus follows the control ------------------
-- Same lesson as P3c: drive what the user drives. These go through
-- onPanelValueChanged -> ConfigStore.Set -> scheduleApply -> flushPendingApplies
-- -> applyBinding -> Preview.Focus + applyKey.
ns.Preview.SetEnabled(true)
local widthSetting = HARNESS.settingsByVariable["PersonalAddon_threatPanel_panelWidth"]
check("P53a the width slider is registered", widthSetting ~= nil)
if widthSetting then
    widthSetting:SetValue(140)
    HARNESS.frame()
    check("P53b the slider narrowed the panel", panel:GetWidth() == 140, panel:GetWidth())
    check("P53c and the store took it",
        ns.ConfigStore.Get("threatPanel", "panelWidth") == 140,
        ns.ConfigStore.Get("threatPanel", "panelWidth"))
    check("P53d adjusting the threat panel focuses it",
        ns.Preview.Inspect().focus[GROUP.PLAYER_FRAME] == PANEL.THREAT_PANEL,
        tostring(ns.Preview.Inspect().focus[GROUP.PLAYER_FRAME]))
end

local breakdownSetting = HARNESS.settingsByVariable["PersonalAddon_damageBreakdown_anchorOffsetY"]
if breakdownSetting then
    breakdownSetting:SetValue(12)
    HARNESS.frame()
    check("P53e adjusting the breakdown focuses the breakdown",
        ns.Preview.Inspect().focus[GROUP.PLAYER_FRAME] == PANEL.DAMAGE_BREAKDOWN,
        tostring(ns.Preview.Inspect().focus[GROUP.PLAYER_FRAME]))
    check("P53f and it is the one shown",
        kindFor(PANEL.DAMAGE_BREAKDOWN) == OUTCOME.SHOWN,
        tostring(kindFor(PANEL.DAMAGE_BREAKDOWN)))
end
ns.Preview.Focus(PANEL.THREAT_PANEL)
ns.Preview.SetEnabled(false)
widthSetting:SetValue(200)
HARNESS.frame()

-- P54: the observer ------------------------------------------------------------------------
local seen = {}
ns.Preview.SetStateObserver(function(newState) seen[#seen + 1] = newState end)
ns.Preview.SetEnabled(true)
ns.Preview.SetEnabled(false)
check("P54 the observer saw both transitions",
    #seen == 2 and seen[1] == "On" and seen[2] == "Off",
    table.concat(seen, ","))
ns.Preview.SetStateObserver(nil)
ns.Preview.SetEnabled(true)
check("P55 no observer is not an error", ns.Preview.IsEnabled() == true)
ns.Preview.SetEnabled(false)

-- P56: unknown windows are refused, not crashed ---------------------------------------------
ns.Preview.Register({ panelId = "NoSuchWindow", show = function() return 0 end,
    clear = function() end })
check("P56 an unknown window is ignored", #ns.Preview.Inspect().windows == 4)
ns.Preview.Focus("NoSuchWindow")
check("P57 focusing an unknown window is ignored",
    ns.Preview.Inspect().focus[GROUP.PLAYER_FRAME] == PANEL.THREAT_PANEL)

-- P58: /pa preview ---------------------------------------------------------------------------
local mark = #HARNESS.chat
slash("preview on")
HARNESS.frame()
check("P58 /pa preview on turns it on", ns.Preview.IsEnabled() == true)
slash("preview")
local printed = false
for index = mark + 1, #HARNESS.chat do
    if tostring(HARNESS.chat[index]):find("preview=On", 1, true) then
        printed = true
    end
end
check("P59 /pa preview reports the state", printed)
slash("preview off")
HARNESS.frame()
check("P60 /pa preview off turns it off", ns.Preview.IsEnabled() == false)

-- Report ---------------------------------------------------------------------------------
local errors = {}
for _, line in ipairs(HARNESS.chat) do
    if line:find("raised", 1, true) or line:find("faulted", 1, true) then
        errors[#errors + 1] = line
    end
end
HARNESS_RESULT = { passed = passed, failures = failures, errors = errors, chat = HARNESS.chat }
