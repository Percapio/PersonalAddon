-- Phase 12 additions (Architecture/20261006-Phase12.md section 14.1): the settings
-- API's pages, layouts, section headers, parent links and slider labels, and frames
-- that keep their scale. Loaded after stubs11.lua for every session.
--
-- The Settings stub replaces stubs.lua's. It keeps that stub's contract, so the
-- Phase 7-11 checks see what they saw: every control is recorded in
-- HARNESS.settingsControls as "<kind>:<name>", and setting:SetValue writes the
-- variable table and then runs the value-changed callbacks.

HARNESS.settingsCategories = {}
HARNESS.settingsPages = {}
HARNESS.settingsByVariable = {}
HARNESS.addOnCategories = {}
HARNESS.openToCategoryCalls = 0

local function newLayout(category)
    local layout = { category = category, initializers = {} }
    function layout:AddInitializer(initializer)
        initializer.layout = self
        self.initializers[#self.initializers + 1] = initializer
    end
    category.layout = layout
    return layout
end

local function newCategory(name, parent)
    local category = { ID = name, name = name, parent = parent, subcategories = {} }
    HARNESS.settingsCategories[#HARNESS.settingsCategories + 1] = category
    return category, newLayout(category)
end

local function newInitializer(kind, category, setting, extra)
    local initializer = {
        kind = kind, category = category, setting = setting,
        name = setting and setting.name, parentArgumentCount = nil,
    }
    for key, value in pairs(extra or {}) do
        initializer[key] = value
    end
    function initializer:SetParentInitializer(...)
        self.parentArgumentCount = select("#", ...)
        self.parentInitializer = (...)
    end
    category.layout:AddInitializer(initializer)
    if setting then
        HARNESS.settingsControls[#HARNESS.settingsControls + 1] = kind .. ":" .. setting.name
    end
    return initializer
end

Settings = {
    VarType = { Boolean = "boolean", Number = "number", String = "string" },
    RegisterVerticalLayoutCategory = function(name)
        return newCategory(name, nil)
    end,
    RegisterVerticalLayoutSubcategory = function(parentCategory, name)
        local subcategory, layout = newCategory(name, parentCategory)
        parentCategory.subcategories[#parentCategory.subcategories + 1] = subcategory
        HARNESS.settingsPages[#HARNESS.settingsPages + 1] = subcategory
        return subcategory, layout
    end,
    RegisterAddOnCategory = function(category)
        HARNESS.addOnCategories[#HARNESS.addOnCategories + 1] = category
    end,
    RegisterAddOnSetting = function(category, variable, variableKey, variableTable, variableType, name, defaultValue)
        local setting = {
            variable = variable, name = name, category = category, variableType = variableType,
            defaultValue = defaultValue, variableTable = variableTable, callbacks = {},
        }
        function setting:SetValueChangedCallback(fn) self.callbacks[#self.callbacks + 1] = fn end
        function setting:SetValue(value)
            variableTable[variableKey] = value
            for _, fn in ipairs(self.callbacks) do fn(self, value) end
        end
        function setting:GetValue() return variableTable[variableKey] end
        HARNESS.settingsByVariable[variable] = setting
        return setting
    end,
    CreateCheckbox = function(category, setting, tooltip)
        return newInitializer("checkbox", category, setting, { tooltip = tooltip })
    end,
    CreateSlider = function(category, setting, options, tooltip)
        return newInitializer("slider", category, setting, { options = options, tooltip = tooltip })
    end,
    CreateSliderOptions = function(minimum, maximum, step)
        local options = { minValue = minimum, maxValue = maximum, step = step }
        function options:SetLabelFormatter(...)
            self.labelArgumentCount = select("#", ...)
            self.labelType = (...)
        end
        return options
    end,
    CreateColorSwatch = function(category, setting, tooltip)
        return newInitializer("swatch", category, setting, { tooltip = tooltip })
    end,
    OpenToCategory = function()
        HARNESS.openToCategoryCalls = HARNESS.openToCategoryCalls + 1
    end,
}

function CreateSettingsListSectionHeaderInitializer(name, tooltip)
    return { kind = "header", name = name, tooltip = tooltip }
end

MinimalSliderWithSteppersMixin = { Label = { Left = 1, Right = 2, Top = 3, Min = 4, Max = 5 } }

-- Frames that keep their scale, for PanelChrome.Place (section 4).
local createFrameWithRegions = CreateFrame
function CreateFrame(frameType, name, parent, template)
    local frame = createFrameWithRegions(frameType, name, parent, template)
    rawset(frame, "SetScale", function(self, scale) self.scale = scale end)
    rawset(frame, "GetScale", function(self) return self.scale or 1 end)
    return frame
end
