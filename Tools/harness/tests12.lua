-- Phase 12 Part A offline checks (Architecture/20261006-Phase12.md section 14.1).
-- Sessions: "phase12" (A1-A10, A12, A14, A15) and "phase12-nopages" (A11: a client
-- without settings subcategories).

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

local function chatSince(mark)
    local lines = {}
    for index = mark + 1, #HARNESS.chat do
        lines[#lines + 1] = HARNESS.chat[index]
    end
    return table.concat(lines, "\n")
end

local function count(text, needle)
    return select(2, text:gsub(needle:gsub("%p", "%%%0"), ""))
end

-- Session variants, set before login ----------------------------------------------------
if HARNESS_SESSION == "phase12-nopages" then
    Settings.RegisterVerticalLayoutSubcategory = nil
end

-- A public feature that names no page goes on the parent page, after the placed ones.
ns.Registry.Register("phase12Unplaced", {
    enabledByDefault = false,
    label = "Unplaced test feature",
    settings = {},
    schema = {},
}, {
    enable = function() return true end,
    disable = function() end,
    onConfigChanged = function() return ns.CONFIG_RESULT.APPLIED end,
})

HARNESS.fire("ADDON_LOADED", "PersonalAddon")
HARNESS.fire("PLAYER_LOGIN")
HARNESS.frame()
check("settings panel enabled", ns.Registry.State("settingsPanel") == "ENABLED", ns.Registry.State("settingsPanel"))

local parent = HARNESS.addOnCategories[1]

local function isSwitch(initializer)
    return initializer.kind == "checkbox" and initializer.setting ~= nil
        and initializer.setting.variable:find("_enabled$") ~= nil
end

local function switchNames(category)
    local names = {}
    for _, initializer in ipairs(category.layout.initializers) do
        if isSwitch(initializer) then
            names[#names + 1] = initializer.name
        end
    end
    return table.concat(names, ",")
end

local function headerNames(category)
    local names = {}
    for _, initializer in ipairs(category.layout.initializers) do
        if initializer.kind == "header" then
            names[#names + 1] = initializer.name
        end
    end
    return table.concat(names, ",")
end

local function pageNamed(name)
    for _, page in ipairs(HARNESS.settingsPages) do
        if page.name == name then
            return page
        end
    end
end

if HARNESS_SESSION == "phase12" then
    -- A1: one parent, three pages in order (no feature is on Consumables yet).
    local pageList = {}
    for _, page in ipairs(HARNESS.settingsPages) do
        pageList[#pageList + 1] = page.name
    end
    check("A1 one parent in the AddOns list", #HARNESS.addOnCategories == 1 and parent.name == "PersonalAddon",
        #HARNESS.addOnCategories)
    check("A1 pages in order", table.concat(pageList, ",") == "Combat,Nameplates,Bags & loot",
        table.concat(pageList, ","))
    check("A1 pages under the parent", #parent.subcategories == 3, #parent.subcategories)

    -- A2: every feature on its page, in its declared order.
    local combat, plates, bags = pageNamed("Combat"), pageNamed("Nameplates"), pageNamed("Bags & loot")
    check("A2 combat", switchNames(combat) == "Five-second rule indicator,Damage breakdown,Threat panel",
        switchNames(combat))
    check("A2 nameplates", switchNames(plates) == "Nameplates", switchNames(plates))
    check("A2 bags and loot",
        switchNames(bags) == "Equipped skills,Toasts,Tidy bags when closed,Sell junk automatically",
        switchNames(bags))
    check("A2 parent, unplaced last", switchNames(parent) == "Reload command,Unplaced test feature",
        switchNames(parent))
    local page, position = ns.Registry.PlacementOf("phase12Unplaced")
    check("A2 unplaced placement", page == ns.SETTINGS_PAGE.GENERAL and position > ns.SETTINGS_UNPLACED_ORDER,
        tostring(page) .. " " .. tostring(position))

    -- A3: headers. A page with two or more features heads each one; the intro heads
    -- the parent; the colours get one group header, right before the first colour.
    check("A3 combat headed", headerNames(combat) == "Five-second rule indicator,Damage breakdown,Threat panel",
        headerNames(combat))
    for index, initializer in ipairs(combat.layout.initializers) do
        if initializer.kind == "header" then
            local nextOne = combat.layout.initializers[index + 1]
            check("A3 header before its switch: " .. initializer.name,
                nextOne ~= nil and isSwitch(nextOne) and nextOne.name == initializer.name,
                nextOne and nextOne.name)
        end
    end
    check("A3 nameplates: only the group header", headerNames(plates) == "Colours, highest priority first",
        headerNames(plates))
    local groupHeader, afterGroup
    for index, initializer in ipairs(plates.layout.initializers) do
        if initializer.kind == "header" then
            groupHeader, afterGroup = initializer, plates.layout.initializers[index + 1]
        end
    end
    check("A3 group header before the first colour", afterGroup ~= nil and afterGroup.kind == "swatch"
        and afterGroup.name == "It is attacking you", afterGroup and afterGroup.name)
    check("A3 group header tooltip", groupHeader ~= nil
        and groupHeader.tooltip == "The threat panel's bars use these colours too.",
        groupHeader and groupHeader.tooltip)
    local intro = parent.layout.initializers[1]
    check("A3 intro header", intro ~= nil and intro.kind == "header"
        and intro.name == "PersonalAddon " .. ns.VERSION and intro.tooltip == "/pa help lists every command.",
        intro and intro.name)

    -- A4: the colours in verdict priority (Phase 11 section 2.3).
    local swatches = {}
    for _, initializer in ipairs(plates.layout.initializers) do
        if initializer.kind == "swatch" then
            swatches[#swatches + 1] = initializer.name
        end
    end
    check("A4 colour order", table.concat(swatches, "|") == table.concat({
        "It is attacking you", "You are about to pull it", "Tagged by a player outside your group",
        "It is attacking your group or pet", "Neutral, and on neither you nor your group",
        "Hostile, and attacking neither" }, "|"), table.concat(swatches, "|"))

    -- A5: every option indented under its own feature's switch, with no predicate.
    local linked, wrong = 0, {}
    for _, category in ipairs(HARNESS.settingsCategories) do
        local currentSwitch = nil
        for _, initializer in ipairs(category.layout.initializers) do
            if initializer.kind ~= "header" then
                if isSwitch(initializer) then
                    currentSwitch = initializer
                    if initializer.parentInitializer ~= nil then
                        wrong[#wrong + 1] = initializer.name .. " (a switch with a parent)"
                    end
                elseif initializer.parentInitializer == currentSwitch and currentSwitch ~= nil
                    and initializer.parentArgumentCount == 1 then
                    linked = linked + 1
                else
                    wrong[#wrong + 1] = tostring(initializer.name)
                end
            end
        end
    end
    check("A5 indented, no predicate", #wrong == 0 and linked > 0,
        tostring(linked) .. " linked; wrong: " .. table.concat(wrong, ", "))

    -- A6: every slider shows its value through Blizzard's own label.
    local sliders, unlabelled = 0, {}
    for _, category in ipairs(HARNESS.settingsCategories) do
        for _, initializer in ipairs(category.layout.initializers) do
            if initializer.kind == "slider" then
                sliders = sliders + 1
                local options = initializer.options
                if not (options and options.labelArgumentCount == 1
                    and options.labelType == MinimalSliderWithSteppersMixin.Label.Right) then
                    unlabelled[#unlabelled + 1] = initializer.name
                end
            end
        end
    end
    check("A6 every slider labelled, no function", sliders > 0 and #unlabelled == 0,
        tostring(sliders) .. " sliders; unlabelled: " .. table.concat(unlabelled, ", "))

    -- A7: a Fraction is a whole percentage in the panel and a share of one in the store.
    local alpha = HARNESS.settingsByVariable.PersonalAddon_threatPanel_panelAlpha
    check("A7 panel form", alpha ~= nil and alpha:GetValue() == 80, alpha and alpha:GetValue())
    check("A7 default in panel form", alpha ~= nil and alpha.defaultValue == 80, alpha and alpha.defaultValue)
    check("A7 label with unit", alpha ~= nil and alpha.name == "Panel opacity (%)", alpha and alpha.name)
    local alphaSlider
    for _, initializer in ipairs(pageNamed("Combat").layout.initializers) do
        if initializer.setting == alpha then
            alphaSlider = initializer
        end
    end
    check("A7 bounds in percent", alphaSlider ~= nil and alphaSlider.options.minValue == 10
        and alphaSlider.options.maxValue == 100 and alphaSlider.options.step == 5)
    alpha:SetValue(85)
    HARNESS.frame()
    local stored = ns.ConfigStore.Get("threatPanel", "panelAlpha")
    check("A7 stored as a share of one", type(stored) == "number" and math.abs(stored - 0.85) < 1e-9, stored)
    local scaleSetting = HARNESS.settingsByVariable.PersonalAddon_damageBreakdown_scale
    check("A7 scale default 100", scaleSetting ~= nil and scaleSetting.defaultValue == 100,
        scaleSetting and scaleSetting.defaultValue)
    local offset = HARNESS.settingsByVariable.PersonalAddon_damageBreakdown_anchorOffsetX
    check("A7 pixel label", offset ~= nil and offset.name == "Horizontal offset (px)", offset and offset.name)
    local duration = HARNESS.settingsByVariable.PersonalAddon_toasts_durationSeconds
    check("A7 seconds label unchanged", duration ~= nil and duration.name == "Seconds on screen",
        duration and duration.name)

    -- A8: scale, with offsets kept in screen pixels.
    slash("set threatPanel scale 2")
    HARNESS.frame()
    local threatFrame = _G.PersonalAddonThreatPanel
    local _, _, _, threatX, threatY = threatFrame:GetPoint(1)
    check("A8 threat panel scaled", threatFrame.scale == 2, threatFrame.scale)
    check("A8 threat offsets divided", threatX == 0 and threatY == 4,
        tostring(threatX) .. "," .. tostring(threatY))
    slash("set damageBreakdown scale 0.5")
    HARNESS.frame()
    local breakdownFrame = _G.PersonalAddonDamageBreakdown
    local _, _, _, breakdownX, breakdownY = breakdownFrame:GetPoint(1)
    check("A8 breakdown scaled", breakdownFrame.scale == 0.5, breakdownFrame.scale)
    check("A8 breakdown offsets divided", breakdownX == 0 and breakdownY == 16,
        tostring(breakdownX) .. "," .. tostring(breakdownY))

    -- A9: the wider offsets.
    slash("set threatPanel anchorOffsetX 1200")
    check("A9 1200 accepted", ns.ConfigStore.Get("threatPanel", "anchorOffsetX") == 1200,
        ns.ConfigStore.Get("threatPanel", "anchorOffsetX"))
    local mark = #HARNESS.chat
    slash("set threatPanel anchorOffsetX 1201")
    check("A9 1201 refused, naming the bound", chatSince(mark):find("must be at most 1200", 1, true) ~= nil,
        chatSince(mark))
    check("A9 stored value stands", ns.ConfigStore.Get("threatPanel", "anchorOffsetX") == 1200)

    -- A10: /pa panel reports the pages and never opens Options.
    mark = #HARNESS.chat
    slash("panel")
    local said = chatSince(mark)
    check("A10 Options never opened", HARNESS.openToCategoryCalls == 0, HARNESS.openToCategoryCalls)
    check("A10 no Open export", ns.SettingsPanel.Open == nil)
    check("A10 pages listed", said:find("page Combat:", 1, true) ~= nil
        and said:find("page Bags & loot:", 1, true) ~= nil, said)
    check("A10 says where", said:find("Options > AddOns > PersonalAddon", 1, true) ~= nil, said)
    local view = ns.SettingsPanel.Inspect()
    check("A10 nothing unlabelled or unindented", view.unlabelled == 0 and view.unindented == 0,
        tostring(view.unlabelled) .. "/" .. tostring(view.unindented))
    check("A10 nothing skipped", #view.skipped == 0, table.concat(view.skipped, "; "))

    -- A12: every setting on its own page's category, so "These settings" resets that page.
    local function categoryOf(variable)
        local setting = HARNESS.settingsByVariable[variable]
        return setting and setting.category and setting.category.name
    end
    check("A12 threat panel on Combat", categoryOf("PersonalAddon_threatPanel_maximumRows") == "Combat",
        categoryOf("PersonalAddon_threatPanel_maximumRows"))
    check("A12 colours on Nameplates", categoryOf("PersonalAddon_nameplates_colourOnPlayer") == "Nameplates",
        categoryOf("PersonalAddon_nameplates_colourOnPlayer"))
    check("A12 toasts on Bags & loot", categoryOf("PersonalAddon_toasts_durationSeconds") == "Bags & loot",
        categoryOf("PersonalAddon_toasts_durationSeconds"))
    check("A12 reload switch on the parent", categoryOf("PersonalAddon_reloadCommand_enabled") == "PersonalAddon",
        categoryOf("PersonalAddon_reloadCommand_enabled"))

    -- A14: declared order first, then the rest by name.
    ns.ConfigSchema.Declare("phase12Schema", {
        b = { kind = ns.ConfigSchema.KIND.TOGGLE },
        a = { kind = ns.ConfigSchema.KIND.TOGGLE },
        z = { kind = ns.ConfigSchema.KIND.TOGGLE, order = 2 },
        y = { kind = ns.ConfigSchema.KIND.TOGGLE, order = 1 },
    })
    check("A14 order", table.concat(ns.ConfigSchema.CuratedKeysInOrder("phase12Schema"), ",") == "y,z,a,b",
        table.concat(ns.ConfigSchema.CuratedKeysInOrder("phase12Schema"), ","))

    -- A15: /pa set reflects a Fraction into the panel in percent.
    slash("set damageBreakdown panelAlpha 0.6")
    local breakdownAlpha = HARNESS.settingsByVariable.PersonalAddon_damageBreakdown_panelAlpha
    check("A15 reflected in percent", breakdownAlpha ~= nil and breakdownAlpha:GetValue() == 60,
        breakdownAlpha and breakdownAlpha:GetValue())
end

if HARNESS_SESSION == "phase12-nopages" then
    -- A11: no subcategories; every feature on the parent page, said once, no fault.
    check("A11 no pages", #HARNESS.settingsPages == 0, #HARNESS.settingsPages)
    local switches = select(2, switchNames(parent):gsub("[^,]+", ""))
    check("A11 every switch on the parent", switches == #ns.Registry.PublicIds(),
        tostring(switches) .. " of " .. tostring(#ns.Registry.PublicIds()))
    local all = table.concat(HARNESS.chat, "\n")
    check("A11 said once", count(all, "offers no settings subcategories") == 1, all)
    check("A11 controls still built", ns.SettingsPanel.Inspect().controlCount > 0)
end

-- Report -------------------------------------------------------------------------------
local errors = {}
for _, line in ipairs(HARNESS.chat) do
    if line:find("raised", 1, true) or line:find("faulted", 1, true) then
        errors[#errors + 1] = line
    end
end
HARNESS_RESULT = { passed = passed, failures = failures, errors = errors, chat = HARNESS.chat }
