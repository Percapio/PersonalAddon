-- Features/SettingsPanel.lua
-- A panel in the client's own Settings > AddOns menu (Phase 6 section 9).
--
-- Built on the client's Settings API rather than Ace3, reversing a Phase 1
-- decision. The reason is the Gamepad UI: it navigates every client interface
-- with no addon involved, so a registered category is controller-navigable for
-- free, while AceGUI widgets are not built for controller focus at all. For a
-- controller-first addon the dependency would have bought less boilerplate at the
-- cost of the one interface the user could not drive.
--
-- The panel writes through the SAME path as /pa set: ConfigStore then
-- Registry.NotifyConfigChanged. It touches no feature directly and gains nothing
-- the slash command does not have.
--
-- It subscribes to NOTHING (section 9.1). State is read when the panel is built
-- and after each action it takes. A feature that faults while the panel sits open
-- and untouched reads as enabled until the user interacts -- a stale reading of
-- one idle panel, against no teardown path to get wrong. This project has met
-- "work outliving the thing that scheduled it" four times; this is the one
-- instance fixed by not scheduling.

local ADDON_NAME, ns = ...

local FEATURE_ID = "settingsPanel"

local format, type, pairs, tostring = string.format, type, pairs, tostring

local state = {
    categoryId = nil,
    registered = false,
    controlCount = 0,
    skipped = {},
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

-- Reading the enumerated list carefully matters here. The namespace also carries
-- SetupCVarCheckbox and friends, which bind a control straight to a CVar and are
-- the more prominent names. This addon's config lives in its own store, so the
-- proxy form -- which takes a getter and a setter -- is the correct one.
local function resolveControls(api)
    local controls = {}
    controls.registerCategory = firstFunction(api,
        "RegisterVerticalLayoutCategory", "RegisterCanvasLayoutCategory")
    controls.addCategory = firstFunction(api, "RegisterAddOnCategory")
    controls.registerSetting = firstFunction(api,
        "RegisterProxySetting", "RegisterAddOnSetting")
    controls.checkbox = firstFunction(api, "CreateCheckbox", "CreateCheckBox")
    controls.slider = firstFunction(api, "CreateSlider")
    controls.sliderOptions = firstFunction(api, "CreateSliderOptions")
    controls.dropdown = firstFunction(api, "CreateDropdown", "CreateDropDown")
    controls.textContainer = firstFunction(api, "CreateControlTextContainer")
    -- CreateColorSwatch, not CreateColorPicker: the Phase 6 spike guessed both
    -- picker spellings wrong and the enumeration supplied the real name.
    controls.colourSwatch = firstFunction(api, "CreateColorSwatch")
    return controls
end

-- Binding ----------------------------------------------------------------------

local function currentValue(featureId, key)
    return ns.ConfigStore.Get(featureId, key)
end

-- One writer for every control, and the same one /pa set uses. A control that
-- wrote to a feature directly would be a second path to keep in step with the
-- first, and the first is the tested one.
local function writeValue(featureId, key, value)
    local ok, reason = ns.ConfigStore.Set(featureId, key, value)
    if not ok then
        -- A control whose range came from the same schema should not be able to
        -- produce an out-of-bounds value. If this fires, the schema and the
        -- control disagree, and that is worth seeing rather than smoothing over.
        ns.Log.OnceError("panel:refused:" .. featureId .. "." .. key, format(
            "the settings panel offered a value the store refused (%s.%s): %s",
            featureId, tostring(key), tostring(reason)))
        return false
    end

    -- Logged because "I moved the slider and nothing happened" is otherwise
    -- indistinguishable between a control that never called us, a store that
    -- refused, and a feature with nothing on screen to change.
    ns.Log.Info(format("%s.%s = %s", featureId, tostring(key), tostring(value)))

    local outcome, detail = ns.Registry.NotifyConfigChanged(featureId, key)
    if outcome == ns.CONFIG_RESULT.RELOAD_REQUIRED then
        -- The reason Phase 1 section 6.2 chose a returned value over a registry
        -- flag: the caller is the party that knows how to tell the user, and this
        -- is finally that caller.
        ns.Log.Warn(format("%s takes effect after a reload", tostring(detail or key)))
    end
    return true
end

local function enabledGetter(featureId)
    return function()
        return ns.ConfigStore.IsEnabled(featureId)
    end
end

local function enabledSetter(featureId)
    return function(value)
        ns.Registry.SetEnabled(featureId, value == true)
    end
end

-- Building ---------------------------------------------------------------------

local function noteSkipped(featureId, key, why)
    state.skipped[#state.skipped + 1] = format("%s.%s (%s)",
        featureId, tostring(key), why)
end

local function addToggle(api, controls, category, featureId, key, declaration,
                         getter, setter)
    if not controls.checkbox or not controls.registerSetting then
        noteSkipped(featureId, key, "no checkbox control")
        return false
    end

    local variable = format("PersonalAddon_%s_%s", featureId, tostring(key))
    local ok, setting = pcall(controls.registerSetting, category, variable,
        "boolean", declaration.label, getter() == true, getter, setter)
    if not ok or not setting then
        noteSkipped(featureId, key, "setting refused")
        return false
    end

    local created = pcall(controls.checkbox, category, setting, declaration.description)
    if not created then
        noteSkipped(featureId, key, "checkbox refused")
        return false
    end
    return true
end

local function addSlider(api, controls, category, featureId, key, declaration)
    if not controls.slider or not controls.registerSetting then
        noteSkipped(featureId, key, "no slider control")
        return false
    end

    local variable = format("PersonalAddon_%s_%s", featureId, tostring(key))
    local ok, setting = pcall(controls.registerSetting, category, variable,
        "number", declaration.label, currentValue(featureId, key),
        function() return currentValue(featureId, key) end,
        function(value) writeValue(featureId, key, value) end)
    if not ok or not setting then
        noteSkipped(featureId, key, "setting refused")
        return false
    end

    local options = nil
    if controls.sliderOptions then
        local optionsOk, built = pcall(controls.sliderOptions,
            declaration.minimum, declaration.maximum, declaration.step)
        options = optionsOk and built or nil
    end

    local created = pcall(controls.slider, category, setting, options,
        declaration.description)
    if not created then
        noteSkipped(featureId, key, "slider refused")
        return false
    end
    return true
end

local function addChoice(api, controls, category, featureId, key, declaration)
    if not controls.dropdown or not controls.registerSetting or not controls.textContainer then
        noteSkipped(featureId, key, "no dropdown control")
        return false
    end

    local variable = format("PersonalAddon_%s_%s", featureId, tostring(key))
    local ok, setting = pcall(controls.registerSetting, category, variable,
        "string", declaration.label, currentValue(featureId, key),
        function() return currentValue(featureId, key) end,
        function(value) writeValue(featureId, key, value) end)
    if not ok or not setting then
        noteSkipped(featureId, key, "setting refused")
        return false
    end

    local function optionsGenerator()
        local container = controls.textContainer()
        for index = 1, #(declaration.choices or {}) do
            local option = declaration.choices[index]
            container:Add(option.value, option.label or tostring(option.value))
        end
        return container:GetData()
    end

    local created = pcall(controls.dropdown, category, setting, optionsGenerator,
        declaration.description)
    if not created then
        noteSkipped(featureId, key, "dropdown refused")
        return false
    end
    return true
end

local function addColour(api, controls, category, featureId, key, declaration)
    if not controls.colourSwatch or not controls.registerSetting then
        noteSkipped(featureId, key, "no colour swatch control")
        return false
    end

    local variable = format("PersonalAddon_%s_%s", featureId, tostring(key))
    -- The swatch wants AARRGGBB; the store holds RRGGBB. Handing it six digits
    -- made CreateColorFromHexString refuse and the control index a nil colour.
    local function swatchGetter()
        return ns.ConfigSchema.ToSwatchHex(currentValue(featureId, key))
    end
    local function swatchSetter(value)
        local stored = ns.ConfigSchema.FromSwatch(value)
        if not stored then
            ns.Log.OnceError("panel:colour:" .. featureId .. "." .. key, format(
                "the colour control returned something unreadable for %s.%s (%s)",
                featureId, tostring(key), type(value)))
            return
        end
        writeValue(featureId, key, stored)
    end

    local ok, setting = pcall(controls.registerSetting, category, variable,
        "string", declaration.label, swatchGetter(), swatchGetter, swatchSetter)
    if not ok or not setting then
        noteSkipped(featureId, key, "setting refused")
        return false
    end

    local created = pcall(controls.colourSwatch, category, setting,
        declaration.description)
    if not created then
        noteSkipped(featureId, key, "colour swatch refused")
        return false
    end
    return true
end

local KIND_BUILDERS = nil

local function addFeatureSection(api, controls, category, featureId)
    local KIND = ns.ConfigSchema.KIND
    local defaults = ns.Registry.Defaults(featureId)
    local label = (defaults and defaults.label) or featureId

    -- The feature's own on/off switch, always first.
    if addToggle(api, controls, category, featureId, "enabled",
        { label = label, description = defaults and defaults.description },
        enabledGetter(featureId), enabledSetter(featureId)) then
        state.controlCount = state.controlCount + 1
    end

    local keys = ns.ConfigSchema.CuratedKeys(featureId)
    for index = 1, #keys do
        local key = keys[index]
        local declaration = ns.ConfigSchema.For(featureId, key)
        local builder = KIND_BUILDERS[declaration.kind]

        if not builder then
            noteSkipped(featureId, key, "no builder for kind " .. tostring(declaration.kind))
        elseif builder(api, controls, category, featureId, key, declaration) then
            state.controlCount = state.controlCount + 1
        end
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

    local KIND = ns.ConfigSchema.KIND
    KIND_BUILDERS = {
        [KIND.TOGGLE] = function(a, c, cat, f, k, d)
            return addToggle(a, c, cat, f, k, d,
                function() return currentValue(f, k) == true end,
                function(value) writeValue(f, k, value == true) end)
        end,
        [KIND.NUMBER] = addSlider,
        [KIND.CHOICE] = addChoice,
        [KIND.COLOUR] = addColour,
    }

    state.controlCount = 0
    state.skipped = {}

    local ok, category = pcall(controls.registerCategory, "PersonalAddon")
    if not ok or not category then
        return nil, "registering the category was refused"
    end

    -- Only the features a user should see. The probes and the isolation test
    -- scaffolding are marked internal and never reach here (section 6).
    local ids = ns.Registry.PublicIds()
    for index = 1, #ids do
        addFeatureSection(api, controls, category, ids[index])
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

-- The panel subscribes to nothing and schedules nothing, so there is nothing to
-- tear down. Whether a registered category can be removed is unanswered by the
-- spike (Phase 6 section 4.0); until it is, the panel persisting after disable is
-- a documented exception like the slash command in Phase 1 section 10 -- it is
-- inert, because every control reads through the config store.
local function disable()
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

ns.SettingsPanel = {
    Open = function()
        local api = settingsApi()
        local opener = api and firstFunction(api, "OpenToCategory")
        if not opener or not state.categoryId then
            return false, "no settings category to open"
        end
        return pcall(opener, state.categoryId)
    end,
    Inspect = function()
        return {
            registered = state.registered,
            controlCount = state.controlCount,
            skipped = state.skipped,
        }
    end,
}
