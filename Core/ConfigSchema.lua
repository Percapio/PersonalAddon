-- Core/ConfigSchema.lua
-- Kinds, bounds and labels for config keys (Phase 6 section 5).
--
-- This is validation first and a menu second. Before it, `/pa set nameplates
-- maximumRows 9999` succeeded: the type was right, so the store took it, and
-- the panel grew absurd until someone noticed. Declaring bounds refuses that and
-- names the bound it missed.
--
-- The menu is the second consumer, present at the moment of writing, which is the
-- bar Phase 2 section 13 set after FramePool was built two phases early on a claim
-- about a consumer that never arrived.

local ADDON_NAME, ns = ...

local ConfigSchema = {}
ns.ConfigSchema = ConfigSchema

local type, pairs, tonumber, format = type, pairs, tonumber, string.format

ConfigSchema.KIND = {
    TOGGLE = "Toggle",
    NUMBER = "Number",
    CHOICE = "Choice",
    COLOUR = "Colour",
    TEXT = "Text",
}

ConfigSchema.VIOLATION = {
    WRONG_KIND = "WrongKind",
    BELOW_MINIMUM = "BelowMinimum",
    ABOVE_MAXIMUM = "AboveMaximum",
    NOT_A_CHOICE = "NotAChoice",
    NOT_A_COLOUR = "NotAColour",
    NO_SCHEMA = "NoSchema",
}

local KIND = ConfigSchema.KIND
local VIOLATION = ConfigSchema.VIOLATION

local schemas = {}

-- Declared by the feature, beside its defaults. The feature is the only thing that
-- knows what its key MEANS -- that maximumRows is a row count between 1 and 10. The
-- declaration is semantic, never a widget name: a feature that named a control
-- would have to change when the panel toolkit did, which is exactly what happened
-- to the panel toolkit between Phase 1 and Phase 6.
function ConfigSchema.Declare(featureId, keySchemas)
    if type(keySchemas) ~= "table" then
        return
    end

    local byKey = schemas[featureId] or {}
    schemas[featureId] = byKey

    for key, declaration in pairs(keySchemas) do
        assert(type(declaration) == "table",
            format("%s.%s schema must be a table", featureId, tostring(key)))
        assert(declaration.kind ~= nil,
            format("%s.%s schema must declare a kind", featureId, tostring(key)))
        byKey[key] = {
            kind = declaration.kind,
            label = declaration.label or key,
            description = declaration.description,
            minimum = declaration.minimum,
            maximum = declaration.maximum,
            step = declaration.step,
            choices = declaration.choices,
            curated = (declaration.curated ~= false),
        }
    end
end

function ConfigSchema.For(featureId, key)
    local byKey = schemas[featureId]
    return byKey and byKey[key] or nil
end

function ConfigSchema.CuratedKeys(featureId)
    local byKey = schemas[featureId]
    if not byKey then
        return {}
    end
    local keys = {}
    for key, declaration in pairs(byKey) do
        if declaration.curated then
            keys[#keys + 1] = key
        end
    end
    table.sort(keys)
    return keys
end

-- Colours are stored as six hex digits, because the config store holds only
-- primitives (Phase 1 section 5.1) and a table would need a recursive merge on
-- every load for no benefit.
local function isHexColour(value)
    if type(value) ~= "string" or #value ~= 6 then
        return false
    end
    return tonumber(value, 16) ~= nil
end

function ConfigSchema.HexToRgb(value)
    if not isHexColour(value) then
        return 1, 1, 1
    end
    return tonumber(string.sub(value, 1, 2), 16) / 255,
           tonumber(string.sub(value, 3, 4), 16) / 255,
           tonumber(string.sub(value, 5, 6), 16) / 255
end

-- The client's colour swatch feeds its value to CreateColorFromHexString, which
-- requires EIGHT digits in AARRGGBB order. The store holds six (RRGGBB) because it
-- holds only primitives and the alpha is never varied. So the conversion lives at
-- the boundary that needs it rather than widening what the store accepts.
function ConfigSchema.ToSwatchHex(storedValue)
    if not isHexColour(storedValue) then
        return "ffffffff"
    end
    return "ff" .. storedValue
end

-- Tolerant by design: the control may hand back an eight-digit string, a six-digit
-- string, or a colour object, and which one is not worth a fourth round of
-- guessing at this client.
function ConfigSchema.FromSwatch(value)
    if type(value) == "table" then
        if type(value.GetRGB) == "function" then
            local ok, red, green, blue = pcall(value.GetRGB, value)
            if ok then
                return ConfigSchema.RgbToHex(red, green, blue)
            end
        end
        if value.r and value.g and value.b then
            return ConfigSchema.RgbToHex(value.r, value.g, value.b)
        end
        return nil
    end

    if type(value) ~= "string" then
        return nil
    end
    if #value == 8 then
        return string.sub(value, 3)
    end
    if #value == 6 then
        return value
    end
    return nil
end

function ConfigSchema.RgbToHex(red, green, blue)
    local function channel(component)
        local scaled = math.floor((tonumber(component) or 0) * 255 + 0.5)
        if scaled < 0 then scaled = 0 end
        if scaled > 255 then scaled = 255 end
        return scaled
    end
    return format("%02x%02x%02x", channel(red), channel(green), channel(blue))
end

-- Returns the value on success, or nil plus a violation and a human reason. The
-- reason names the bound, because "invalid value" tells the user nothing they did
-- not already know.
function ConfigSchema.Validate(featureId, key, candidate)
    local declaration = ConfigSchema.For(featureId, key)
    if not declaration then
        -- A key with no schema is not an error: the store's type check still
        -- applies, and only curated keys need declarations.
        return candidate, nil, nil
    end

    local kind = declaration.kind

    if kind == KIND.TOGGLE then
        if type(candidate) ~= "boolean" then
            return nil, VIOLATION.WRONG_KIND, "expects true or false"
        end
        return candidate
    end

    if kind == KIND.NUMBER then
        local number = tonumber(candidate)
        if number == nil then
            return nil, VIOLATION.WRONG_KIND, "expects a number"
        end
        if declaration.minimum and number < declaration.minimum then
            return nil, VIOLATION.BELOW_MINIMUM,
                format("must be at least %s", tostring(declaration.minimum))
        end
        if declaration.maximum and number > declaration.maximum then
            return nil, VIOLATION.ABOVE_MAXIMUM,
                format("must be at most %s", tostring(declaration.maximum))
        end
        return number
    end

    if kind == KIND.CHOICE then
        local permitted = {}
        for index = 1, #(declaration.choices or {}) do
            local option = declaration.choices[index]
            permitted[#permitted + 1] = tostring(option.value)
            if option.value == candidate then
                return candidate
            end
        end
        return nil, VIOLATION.NOT_A_CHOICE,
            format("must be one of: %s", table.concat(permitted, ", "))
    end

    if kind == KIND.COLOUR then
        if not isHexColour(candidate) then
            return nil, VIOLATION.NOT_A_COLOUR, "expects six hex digits, e.g. ff4040"
        end
        return candidate
    end

    return candidate
end

function ConfigSchema.DescribeBounds(featureId, key)
    local declaration = ConfigSchema.For(featureId, key)
    if not declaration then
        return nil
    end
    if declaration.kind == KIND.NUMBER and declaration.minimum and declaration.maximum then
        return format("%s to %s", tostring(declaration.minimum),
            tostring(declaration.maximum))
    end
    if declaration.kind == KIND.CHOICE then
        local names = {}
        for index = 1, #(declaration.choices or {}) do
            names[#names + 1] = tostring(declaration.choices[index].value)
        end
        return table.concat(names, " / ")
    end
    if declaration.kind == KIND.TOGGLE then
        return "true / false"
    end
    if declaration.kind == KIND.COLOUR then
        return "six hex digits"
    end
    return nil
end
