-- Features/SettingsPanel.lua
-- A panel in the client's own Settings > AddOns menu (Phase 6 section 9), built
-- from Blizzard-stored settings (Architecture/20260924-Patch01Implementation.md
-- section 5, option C4).
--
-- Built on the client's Settings API rather than Ace3, reversing a Phase 1
-- decision. The reason is the Gamepad UI: it navigates every client interface
-- with no addon involved, so a registered category is controller-navigable for
-- free, while AceGUI widgets are not built for controller focus at all.
--
-- Why Blizzard-stored settings and not proxy settings. A proxy setting hands the
-- settings panel our getter and setter, and the panel calls them inline: for every
-- value it draws, and in the close-time commit loop. Our code on Blizzard's stack
-- is taint, whatever that code does. On this beta, closing Options after a change
-- left the gamepad binding state tainted, and controller presses -- action,
-- cancel, targeting -- were refused until a reload (Patch01Implementation
-- section 2.1). A Blizzard-stored setting reads and writes a field of panelValues
-- itself, and reaches this addon only through its value-changed callback.
--
-- One rule follows, and everything below keeps it: after registration this file
-- writes only panelValues, and calls no method on a Blizzard setting or control.
-- A setting:SetValue from here would run Blizzard's setting and control code in
-- our execution, and whatever that code wrote would carry our taint. The cost is
-- that a control on screen shows a reverted or reflected value only the next time
-- it is drawn.
--
-- The panel writes through the SAME path as /pa set: ConfigStore, then
-- Registry.NotifyConfigChanged, one frame later. /pa set and /pa on|off keep
-- panelValues in step through the two Reflect functions at the bottom.
--
-- Since Phase 12 (Architecture/20261006-Phase12.md section 3) the controls are
-- spread over pages: the parent page, then Combat, Nameplates, Bags & loot and
-- Consumables, each a subcategory with its own "These settings" Defaults. Each
-- feature names its page; its options are indented under its switch; sliders show
-- their value through Blizzard's own pass-through label. Everything added for this
-- is still registration-time data: strings, Blizzard's own formatter, parent links
-- with no predicate. Blizzard calls none of our functions but the value-changed
-- callback.

local ADDON_NAME, ns = ...

local FEATURE_ID = "settingsPanel"

local format, type, tostring, floor = string.format, type, tostring, math.floor

local SWITCH, KEY = "Switch", "Key"
local CHECKBOX, SLIDER, PERCENT_SLIDER, COLOUR_SWATCH, CHOICE_CHECKBOX =
    "Checkbox", "Slider", "PercentSlider", "ColourSwatch", "ChoiceCheckbox"

local PAGE = ns.SETTINGS_PAGE
local PARENT_LABEL = "PersonalAddon"

-- The subcategories, in the order they appear under the parent (section 3.1). The
-- category list keeps registration order for subcategories.
local PAGE_ORDER = {
    { page = PAGE.COMBAT, label = "Combat" },
    { page = PAGE.NAMEPLATES, label = "Nameplates" },
    { page = PAGE.BAGS_AND_LOOT, label = "Bags & loot" },
    { page = PAGE.CONSUMABLES, label = "Consumables" },
}

local KNOWN_PAGES = { [PAGE.GENERAL] = true }
for index = 1, #PAGE_ORDER do
    KNOWN_PAGES[PAGE_ORDER[index].page] = true
end

-- What a unit adds to a control's label. Seconds labels already say seconds.
local UNIT_SUFFIX = {
    Pixels = " (px)",
    Fraction = " (%)",
}

local state = {
    categoryId = nil,
    registered = false,
    controlCount = 0,
    skipped = {},
    -- One entry per page built: { page, label, controlCount }.
    pages = {},
    unlabelled = 0,
    unindented = 0,
    -- The one table Blizzard's settings read and write. In memory for the
    -- session; the config store stays the only persisted copy.
    panelValues = {},
    bindings = {},
    settings = {},
    pending = {},
    pendingOrder = {},
    flushScheduled = false,
    reverts = 0,
    unreadable = 0,
}

-- API resolution ---------------------------------------------------------------

local function settingsApi()
    local api = _G.Settings
    if type(api) ~= "table" then
        return nil
    end
    return api
end

local function firstFunction(api, ...)
    for index = 1, select("#", ...) do
        local name = select(index, ...)
        if type(api[name]) == "function" then
            return api[name], name
        end
    end
    return nil
end

-- The right-hand value label of Blizzard's slider. Read, never written.
local function sliderValueLabel()
    local mixin = _G.MinimalSliderWithSteppersMixin
    local labels = type(mixin) == "table" and mixin.Label or nil
    return type(labels) == "table" and labels.Right or nil
end

local function resolveControls(api)
    local controls = {}
    controls.registerCategory = firstFunction(api,
        "RegisterVerticalLayoutCategory", "RegisterCanvasLayoutCategory")
    controls.registerSubcategory = firstFunction(api, "RegisterVerticalLayoutSubcategory")
    controls.addCategory = firstFunction(api, "RegisterAddOnCategory")
    -- Blizzard-stored settings only. RegisterProxySetting is deliberately not a
    -- fallback: it would silently restore the carrier this panel exists to remove.
    controls.registerSetting = firstFunction(api, "RegisterAddOnSetting")
    controls.checkbox = firstFunction(api, "CreateCheckbox", "CreateCheckBox")
    controls.slider = firstFunction(api, "CreateSlider")
    controls.sliderOptions = firstFunction(api, "CreateSliderOptions")
    -- CreateColorSwatch, not CreateColorPicker: the Phase 6 spike guessed both
    -- picker spellings wrong and the enumeration supplied the real name.
    controls.colourSwatch = firstFunction(api, "CreateColorSwatch")
    -- A global of Blizzard_SettingControls.lua, not a Settings field. Its data is
    -- two strings (section 3.2).
    controls.sectionHeader = type(_G.CreateSettingsListSectionHeaderInitializer) == "function"
        and _G.CreateSettingsListSectionHeaderInitializer or nil
    controls.valueLabel = sliderValueLabel()

    local varType = (type(api.VarType) == "table") and api.VarType or nil
    controls.varTypes = {
        boolean = varType and varType.Boolean or "boolean",
        number = varType and varType.Number or "number",
        string = varType and varType.String or "string",
    }
    return controls
end

-- Presentation (section 5.3) ----------------------------------------------------

local function variableFor(featureId, key)
    return format("PersonalAddon_%s_%s", featureId, tostring(key))
end

local function percent(value)
    return floor(value * 100 + 0.5)
end

-- How one curated key is shown. A two-value choice is a checkbox: a dropdown's
-- option list is a function Blizzard calls, and README rule 1 keeps our functions
-- off Blizzard's stack. The feature itself does not change; what it stores does
-- not change either. A Fraction is shown as a whole percentage, so Blizzard's
-- pass-through label reads 80 rather than 0.8000000119 (Phase 12 section 3.6).
local function presentationFor(declaration)
    local KIND = ns.ConfigSchema.KIND
    if not declaration then
        return nil, "no schema"
    end
    if declaration.kind == KIND.TOGGLE then
        return { kind = CHECKBOX }
    end
    if declaration.kind == KIND.NUMBER then
        if declaration.minimum and declaration.maximum and declaration.step then
            if declaration.unit == ns.ConfigSchema.UNIT.FRACTION then
                return {
                    kind = PERCENT_SLIDER,
                    minimum = percent(declaration.minimum),
                    maximum = percent(declaration.maximum),
                    step = percent(declaration.step),
                }
            end
            return {
                kind = SLIDER,
                minimum = declaration.minimum,
                maximum = declaration.maximum,
                step = declaration.step,
            }
        end
        return nil, "a slider needs a minimum, a maximum and a step"
    end
    if declaration.kind == KIND.COLOUR then
        return { kind = COLOUR_SWATCH }
    end
    if declaration.kind == KIND.CHOICE then
        local choices = declaration.choices or {}
        if #choices == 2 then
            return {
                kind = CHOICE_CHECKBOX,
                offValue = choices[1].value,
                onValue = choices[2].value,
                label = choices[2].label or tostring(choices[2].value),
            }
        end
        return nil, format("%d choices; only two-value choices are shown, as checkboxes (README rule 1)",
            #choices)
    end
    return nil, "no control for kind " .. tostring(declaration.kind)
end

local function toPanelForm(presentation, storedValue)
    if presentation.kind == COLOUR_SWATCH then
        -- The swatch wants AARRGGBB; the store holds RRGGBB.
        return ns.ConfigSchema.ToSwatchHex(storedValue)
    end
    if presentation.kind == CHOICE_CHECKBOX then
        return storedValue == presentation.onValue
    end
    if presentation.kind == PERCENT_SLIDER and type(storedValue) == "number" then
        return percent(storedValue)
    end
    return storedValue
end

-- The value in store form, or nil when a colour cannot be read.
local function toStoreForm(presentation, panelValue)
    if presentation.kind == COLOUR_SWATCH then
        return ns.ConfigSchema.FromSwatch(panelValue)
    end
    if presentation.kind == CHOICE_CHECKBOX then
        if panelValue == true then
            return presentation.onValue
        end
        return presentation.offValue
    end
    if presentation.kind == CHECKBOX then
        return panelValue == true
    end
    if presentation.kind == PERCENT_SLIDER and type(panelValue) == "number" then
        return panelValue / 100
    end
    return panelValue
end

local function panelVarType(controls, presentation)
    if presentation.kind == CHECKBOX or presentation.kind == CHOICE_CHECKBOX then
        return controls.varTypes.boolean
    end
    if presentation.kind == SLIDER or presentation.kind == PERCENT_SLIDER then
        return controls.varTypes.number
    end
    return controls.varTypes.string
end

-- A key's label with its unit, as section 3.1 shows it. A two-value choice keeps
-- its second choice's label.
local function labelFor(declaration, presentation)
    if presentation.kind == CHOICE_CHECKBOX then
        return presentation.label
    end
    return declaration.label .. (UNIT_SUFFIX[declaration.unit] or "")
end

local function storedValueFor(binding)
    if binding.target == SWITCH then
        return ns.ConfigStore.IsEnabled(binding.featureId)
    end
    return ns.ConfigStore.Get(binding.featureId, binding.key)
end

-- Sets the panel's copy of one value to what the config store holds. Writes
-- panelValues only; calls nothing on the setting or its control. Reverting a
-- refused value and reflecting a slash command are both this.
local function copyStoredValueToPanel(binding)
    local stored = storedValueFor(binding)
    if stored == nil then
        return
    end
    state.panelValues[binding.variable] = toPanelForm(binding.presentation, stored)
end

-- Applying a change out of Blizzard's call stack --------------------------------
--
-- The store write happens in the value-changed callback; the APPLY is deferred one
-- frame into our own execution, coalesced per variable: dragging a slider fires
-- the callback continuously, and each intermediate value need not be applied.
--
-- Cancellation belongs here, with the thing that scheduled it: disable() empties
-- the queue, and the flush re-checks that the feature is still registered.

local function applyKey(featureId, key)
    local outcome, detail = ns.Registry.NotifyConfigChanged(featureId, key)
    if outcome == ns.CONFIG_RESULT.RELOAD_REQUIRED then
        -- The reason Phase 1 section 6.2 chose a returned value over a registry
        -- flag: the caller is the party that knows how to tell the user.
        ns.Log.Warn(format("%s takes effect after a reload", tostring(detail or key)))
    end
end

local function applyBinding(binding)
    if binding.target == SWITCH then
        ns.Registry.SetEnabled(binding.featureId, state.panelValues[binding.variable] == true)
        return
    end
    applyKey(binding.featureId, binding.key)
end

local function flushPendingApplies()
    state.flushScheduled = false

    local queued, order = state.pending, state.pendingOrder
    state.pending, state.pendingOrder = {}, {}

    if not state.registered then
        return
    end

    for index = 1, #order do
        local binding = queued[order[index]]
        if binding and ns.Registry.Defaults(binding.featureId) then
            applyBinding(binding)
        end
    end
end

-- A client without C_Timer.After still applies, synchronously, because a setting
-- that silently never takes effect is worse than applying inside the callback --
-- and that trade is stated rather than left to be discovered.
--
-- Deliberately not cached, so the fallback branch stays reachable on a healthy
-- client instead of only after a restart.
local function canDefer()
    if C_Timer ~= nil and type(C_Timer.After) == "function" then
        return true
    end
    ns.Log.Once("panel:nodefer",
        "this client has no C_Timer.After, so settings apply inside the settings window rather than a frame later")
    return false
end

local function scheduleApply(binding)
    if not canDefer() then
        applyBinding(binding)
        return
    end

    if not state.pending[binding.variable] then
        state.pendingOrder[#state.pendingOrder + 1] = binding.variable
    end
    state.pending[binding.variable] = binding

    if not state.flushScheduled then
        state.flushScheduled = true
        C_Timer.After(0, flushPendingApplies)
    end
end

-- The value-changed callback (section 5.4) --------------------------------------

-- Receives a change the panel has already stored in panelValues. A refused or
-- unreadable value is set back in panelValues at once; the control on screen
-- shows the stored value the next time it is drawn, and the notice says so.
local function onPanelValueChanged(binding, panelValue)
    if binding.target == SWITCH then
        scheduleApply(binding)
        return "Accepted"
    end

    local storeValue = toStoreForm(binding.presentation, panelValue)
    if storeValue == nil and binding.presentation.kind == COLOUR_SWATCH then
        state.unreadable = state.unreadable + 1
        ns.Log.OnceError("panel:colour:" .. binding.variable, format(
            "the colour control returned something unreadable for %s.%s (%s); the stored colour stands and the control shows it when next drawn",
            binding.featureId, tostring(binding.key), type(panelValue)))
        copyStoredValueToPanel(binding)
        return "UnreadableColour"
    end

    local ok, reason = ns.ConfigStore.Set(binding.featureId, binding.key, storeValue)
    if not ok then
        -- A control whose range came from the same schema should not be able to
        -- produce an out-of-bounds value. If this fires, the schema and the control
        -- disagree, and that is worth seeing rather than smoothing over.
        state.reverts = state.reverts + 1
        ns.Log.OnceError("panel:refused:" .. binding.variable, format(
            "the settings panel offered a value the store refused (%s.%s): %s; the stored value stands and the control shows it when next drawn",
            binding.featureId, tostring(binding.key), tostring(reason)))
        copyStoredValueToPanel(binding)
        return "Refused"
    end

    scheduleApply(binding)
    return "Accepted"
end

-- The function handed to SetValueChangedCallback: the registry calls it with
-- (setting, value). If an export ever shows different arguments, this is the one
-- place that changes.
local function valueChangedHandlerFor(binding)
    return function(_, value)
        return onPanelValueChanged(binding, value)
    end
end

-- Building ---------------------------------------------------------------------

local function noteSkipped(featureId, key, why)
    state.skipped[#state.skipped + 1] = format("%s.%s (%s)",
        featureId, tostring(key), why)
end

-- Slider options with Blizzard's own value label on the right (section 3.5).
-- SetLabelFormatter with no function stores the client's file-local pass-through
-- formatter: no function of ours is stored, so README rule 1 still holds. Without
-- the label, the slider still works and is counted for /pa panel.
local function sliderOptions(controls, presentation)
    if not controls.sliderOptions then
        return nil
    end
    local optionsOk, options = pcall(controls.sliderOptions,
        presentation.minimum, presentation.maximum, presentation.step)
    if not optionsOk or type(options) ~= "table" then
        return nil
    end
    local labelled = controls.valueLabel ~= nil and type(options.SetLabelFormatter) == "function"
        and pcall(options.SetLabelFormatter, options, controls.valueLabel)
    if not labelled then
        state.unlabelled = state.unlabelled + 1
    end
    return options
end

-- Returns the control's initializer when the client handed one back, so that the
-- feature's options can be indented under its switch.
local function createControl(controls, presentation, category, setting, tooltip)
    if presentation.kind == SLIDER or presentation.kind == PERCENT_SLIDER then
        if not controls.slider then
            return false, "no slider control"
        end
        local ok, initializer = pcall(controls.slider, category, setting,
            sliderOptions(controls, presentation), tooltip)
        if not ok then
            return false, "slider refused"
        end
        return true, initializer
    end
    if presentation.kind == COLOUR_SWATCH then
        if not controls.colourSwatch then
            return false, "no colour swatch control"
        end
        local ok, initializer = pcall(controls.colourSwatch, category, setting, tooltip)
        if not ok then
            return false, "colour swatch refused"
        end
        return true, initializer
    end
    if not controls.checkbox then
        return false, "no checkbox control"
    end
    local ok, initializer = pcall(controls.checkbox, category, setting, tooltip)
    if not ok then
        return false, "checkbox refused"
    end
    return true, initializer
end

-- Registers one control over panelValues. The value-changed handler is the only
-- function of this addon's handed to the settings API; the default is the
-- feature's DECLARED default, so Blizzard's Defaults button does what it says.
-- (Revision 1 passed the current value, so Defaults restored the login-time
-- values: Patch01 R8.) The setting is registered on its own page's category, so
-- that page's "These settings" resets it and nothing else (section 3.3).
--
-- Returns true and the control's initializer, which may be nil, or false.
local function buildControl(controls, category, binding, declaredDefault, label, tooltip)
    local keyName = binding.key or "enabled"
    if declaredDefault == nil then
        noteSkipped(binding.featureId, keyName, "no declared default")
        return false
    end

    local stored = storedValueFor(binding)
    if stored == nil then
        stored = declaredDefault
    end
    state.panelValues[binding.variable] = toPanelForm(binding.presentation, stored)

    local ok, setting = pcall(controls.registerSetting, category, binding.variable, binding.variable,
        state.panelValues, panelVarType(controls, binding.presentation), label,
        toPanelForm(binding.presentation, declaredDefault))
    if not ok or type(setting) ~= "table" then
        state.panelValues[binding.variable] = nil
        noteSkipped(binding.featureId, keyName, "setting refused")
        return false
    end

    if type(setting.SetValueChangedCallback) ~= "function"
        or not pcall(setting.SetValueChangedCallback, setting, valueChangedHandlerFor(binding)) then
        state.panelValues[binding.variable] = nil
        noteSkipped(binding.featureId, keyName, "value-changed callback refused")
        return false
    end

    local created, initializerOrWhy = createControl(controls, binding.presentation, category, setting, tooltip)
    if not created then
        state.panelValues[binding.variable] = nil
        noteSkipped(binding.featureId, keyName, initializerOrWhy)
        return false
    end

    state.bindings[binding.variable] = binding
    state.settings[binding.variable] = setting
    state.controlCount = state.controlCount + 1
    return true, initializerOrWhy
end

-- A section header: a Blizzard initializer whose data is two strings, drawn by
-- Blizzard's own template (section 3.2). Not counted as a control.
local function addHeader(controls, page, name, tooltip)
    if not controls.sectionHeader or not page.layout or type(page.layout.AddInitializer) ~= "function" then
        return false
    end
    local ok, initializer = pcall(controls.sectionHeader, name, tooltip)
    if not ok or type(initializer) ~= "table" then
        return false
    end
    return pcall(page.layout.AddInitializer, page.layout, initializer)
end

-- Indents a key's control under its feature's switch (section 3.4). With no
-- predicate the client indents the control while its parent is on the page and
-- never greys it out; Blizzard's own control listens to the parent setting, and
-- nothing of ours is stored. Called while building, never after.
local function indentUnder(control, switch)
    if type(control) ~= "table" or type(switch) ~= "table"
        or type(control.SetParentInitializer) ~= "function" then
        state.unindented = state.unindented + 1
        return false
    end
    if not pcall(control.SetParentInitializer, control, switch) then
        state.unindented = state.unindented + 1
        return false
    end
    return true
end

local function addFeatureSection(controls, page, featureId, headed)
    local defaults = ns.Registry.Defaults(featureId)
    local label = (defaults and defaults.label) or featureId
    local before = state.controlCount

    if headed then
        addHeader(controls, page, label, defaults and defaults.description)
    end

    -- The feature's own on/off switch, always first.
    local switch = {
        variable = variableFor(featureId, "enabled"),
        featureId = featureId,
        target = SWITCH,
        presentation = { kind = CHECKBOX },
    }
    local _, switchInitializer = buildControl(controls, page.category, switch,
        defaults ~= nil and defaults.enabledByDefault == true, label, defaults and defaults.description)

    local keys = ns.ConfigSchema.CuratedKeysInOrder(featureId)
    local currentGroup = nil
    for index = 1, #keys do
        local key = keys[index]
        local declaration = ns.ConfigSchema.For(featureId, key)
        local presentation, why = presentationFor(declaration)
        local declaredDefault = defaults and defaults.settings and defaults.settings[key]

        if not presentation then
            noteSkipped(featureId, key, why)
        else
            if declaration.group and declaration.group ~= currentGroup then
                currentGroup = declaration.group
                addHeader(controls, page, declaration.group, declaration.groupDescription)
            end
            local binding = {
                variable = variableFor(featureId, key),
                featureId = featureId,
                target = KEY,
                key = key,
                presentation = presentation,
            }
            local built, initializer = buildControl(controls, page.category, binding, declaredDefault,
                labelFor(declaration, presentation), declaration.description)
            if built then
                indentUnder(initializer, switchInitializer)
            end
        end
    end

    page.controlCount = page.controlCount + (state.controlCount - before)
end

-- The public features on each page, in each feature's declared order. A feature
-- naming a page this panel does not know goes on the parent page, said once.
local function featuresByPage()
    local byPage = {}
    local ids = ns.Registry.PublicIds()
    for index = 1, #ids do
        local featureId = ids[index]
        local page, position = ns.Registry.PlacementOf(featureId)
        if not KNOWN_PAGES[page] then
            ns.Log.Once("panel:unknownpage:" .. featureId, format(
                "%s names a settings page that does not exist (%s); it is shown on the PersonalAddon page",
                featureId, tostring(page)))
            page = PAGE.GENERAL
        end
        local list = byPage[page] or {}
        byPage[page] = list
        list[#list + 1] = { featureId = featureId, position = position }
    end
    for _, list in pairs(byPage) do
        table.sort(list, function(left, right)
            if left.position ~= right.position then
                return left.position < right.position
            end
            return left.featureId < right.featureId
        end)
    end
    return byPage
end

local function newPage(page, label, category, layout)
    local record = { page = page, label = label, category = category, layout = layout, controlCount = 0 }
    state.pages[#state.pages + 1] = record
    return record
end

local function buildSections(controls, page, entries)
    local headed = #entries >= 2
    for index = 1, #entries do
        addFeatureSection(controls, page, entries[index].featureId, headed)
    end
end

local function buildPanel()
    local api = settingsApi()
    if not api then
        return nil, "this client exposes no Settings namespace"
    end

    local controls = resolveControls(api)
    if not controls.registerCategory or not controls.addCategory then
        return nil, "this client will not let an addon register a settings category"
    end
    if not controls.registerSetting then
        return nil, "this client offers no Blizzard-stored settings, so the panel is not built; /pa set remains"
    end

    state.controlCount = 0
    state.skipped = {}
    state.pages = {}
    state.unlabelled = 0
    state.unindented = 0

    local ok, category, layout = pcall(controls.registerCategory, PARENT_LABEL)
    if not ok or not category then
        return nil, "registering the category was refused"
    end
    local parent = newPage(PAGE.GENERAL, PARENT_LABEL, category, layout)
    addHeader(controls, parent, format("PersonalAddon %s", tostring(ns.VERSION)),
        "/pa help lists every command.")

    -- Only the features a user should see. The probes and the isolation test
    -- scaffolding are marked internal and never reach here (Phase 6 section 6).
    local byPage = featuresByPage()
    local parentEntries = byPage[PAGE.GENERAL] or {}
    local pagesToBuild = {}

    if not controls.registerSubcategory then
        ns.Log.Once("panel:nosubcategories",
            "this client offers no settings subcategories, so every setting is on the PersonalAddon page")
    end

    for index = 1, #PAGE_ORDER do
        local spec = PAGE_ORDER[index]
        local entries = byPage[spec.page]
        if entries and #entries > 0 then
            local subcategory, sublayout
            if controls.registerSubcategory then
                local registered
                registered, subcategory, sublayout = pcall(controls.registerSubcategory, category, spec.label)
                if not registered then
                    subcategory = nil
                end
            end
            if subcategory then
                pagesToBuild[#pagesToBuild + 1] = {
                    page = newPage(spec.page, spec.label, subcategory, sublayout),
                    entries = entries,
                }
            else
                -- One page that cannot be registered costs its own page, not its
                -- controls: they go on the parent page.
                if controls.registerSubcategory then
                    ns.Log.Once("panel:nopage:" .. spec.page, format(
                        "this client would not register the %s page; its settings are on the PersonalAddon page",
                        spec.label))
                end
                for entry = 1, #entries do
                    parentEntries[#parentEntries + 1] = entries[entry]
                end
            end
        end
    end

    buildSections(controls, parent, parentEntries)
    for index = 1, #pagesToBuild do
        buildSections(controls, pagesToBuild[index].page, pagesToBuild[index].entries)
    end

    if state.controlCount == 0 then
        return nil, "no control could be created"
    end

    local added = pcall(controls.addCategory, category)
    if not added then
        return nil, "adding the category to the menu was refused"
    end

    state.categoryId = category.ID or category
    state.registered = true

    if #state.skipped > 0 then
        -- One uncreatable control costs a row, not the panel.
        ns.Log.Once("panel:skipped", format(
            "%d settings control(s) could not be created; /pa panel lists them",
            #state.skipped))
    end
    return category
end

-- Lifecycle ---------------------------------------------------------------------

local function enable()
    if state.registered then
        -- A registered category cannot reliably be unregistered, so the panel is
        -- built at most once per session. Re-enabling reuses it rather than
        -- stacking a second copy in the menu.
        return true
    end

    local category, reason = buildPanel()
    if not category then
        return nil, reason
    end
    return true
end

-- Neither the category nor its settings can be unregistered, so the controls
-- stay on screen and keep writing through, as the proxy setters did before them
-- (Phase 6 section 9's documented exception). What CAN be abandoned is work this
-- feature scheduled and has not run yet.
local function disable()
    state.pending = {}
    state.pendingOrder = {}
    -- flushScheduled stays true if a timer is already in flight: the callback is
    -- not cancellable, so it must remain able to clear the flag when it runs.
    -- It will find an empty queue and do nothing.
end

local function onConfigChanged()
    return ns.CONFIG_RESULT.APPLIED
end

ns.Registry.Register(FEATURE_ID, {
    enabledByDefault = true,
    internal = true,
    label = "Settings panel",
    settings = {},
    schema = {},
}, {
    enable = enable,
    disable = disable,
    onConfigChanged = onConfigChanged,
})

-- There is no Open. Settings.OpenToCategory calls C_SettingsUtil.OpenSettingsPanel,
-- which the docs flag HasRestrictions: from this addon it is a refused call, and an
-- insecure caller opening a panel (Phase 12 section 3.8).
ns.SettingsPanel = {
    Inspect = function()
        local pages = {}
        for index = 1, #state.pages do
            local page = state.pages[index]
            pages[index] = { label = page.label, controlCount = page.controlCount }
        end
        return {
            registered = state.registered,
            controlCount = state.controlCount,
            pages = pages,
            skipped = state.skipped,
            unlabelled = state.unlabelled,
            unindented = state.unindented,
            reverts = state.reverts,
            unreadable = state.unreadable,
        }
    end,
    -- Called by /pa set after its write succeeds. No callback fires; an open panel
    -- shows the value the next time the control is drawn.
    ReflectStoredValue = function(featureId, key)
        if not state.registered then
            return false
        end
        local binding = state.bindings[variableFor(featureId, key)]
        if not binding or binding.target ~= KEY then
            return false
        end
        copyStoredValueToPanel(binding)
        return true
    end,
    -- Called by /pa on|off whatever SetEnabled returned: the stored flag changed.
    ReflectEnabled = function(featureId)
        if not state.registered then
            return false
        end
        local binding = state.bindings[variableFor(featureId, "enabled")]
        if not binding or binding.target ~= SWITCH then
            return false
        end
        copyStoredValueToPanel(binding)
        return true
    end,
}
