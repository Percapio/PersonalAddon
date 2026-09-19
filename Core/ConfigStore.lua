-- Core/ConfigStore.lua
-- Hydration in four ordered steps: read, migrate, merge, prune (§5.2).
-- The order is load-bearing. Merging before migrating would type-check and
-- discard a value that a migration was about to change shape, and the
-- migration would then read the default instead of the user's data.

local ADDON_NAME, ns = ...

local ConfigStore = {}
ns.ConfigStore = ConfigStore

local type, pairs, tonumber, format = type, pairs, tonumber, string.format

local liveStore = nil
local liveDefaults = nil

local function newEmptyStore()
    return { schemaVersion = 0, features = {} }
end

function ConfigStore.IsConfigValue(value)
    local valueType = type(value)
    return valueType == "boolean" or valueType == "number" or valueType == "string"
end

-- Step 1: read verbatim. No type checks on settings, no merging. A migration
-- runs next and must see the table exactly as the client persisted it.
local function readPersisted(persisted, notices)
    if persisted == nil then
        return newEmptyStore(), nil
    end

    if type(persisted) ~= "table" then
        notices[#notices + 1] = "persisted config was not a table; quarantined and defaults loaded"
        return newEmptyStore(), persisted
    end

    if type(persisted.features) ~= "table" then
        notices[#notices + 1] = "persisted config had no feature table; quarantined and defaults loaded"
        return newEmptyStore(), persisted
    end

    persisted.schemaVersion = tonumber(persisted.schemaVersion) or 0
    return persisted, nil
end

-- Step 3: complete the store against registered defaults, type-checking as we
-- go. A mismatch takes the default and raises a notice -- this is the path
-- that survives a hand-edited saved variables file.
local function mergeDefaults(store, registeredDefaults, notices)
    for featureId, defaults in pairs(registeredDefaults) do
        local featureConfig = store.features[featureId]
        if type(featureConfig) ~= "table" then
            if featureConfig ~= nil then
                notices[#notices + 1] = format(
                    "config for '%s' was not a table; defaults taken", featureId)
            end
            featureConfig = {}
            store.features[featureId] = featureConfig
        end

        if type(featureConfig.settings) ~= "table" then
            if featureConfig.settings ~= nil then
                notices[#notices + 1] = format(
                    "settings for '%s' were not a table; defaults taken", featureId)
            end
            featureConfig.settings = {}
        end

        if type(featureConfig.enabled) ~= "boolean" then
            if featureConfig.enabled ~= nil then
                notices[#notices + 1] = format(
                    "enabled flag for '%s' was %s, expected boolean; default taken",
                    featureId, type(featureConfig.enabled))
            end
            featureConfig.enabled = (defaults.enabledByDefault == true)
        end

        local declared = defaults.settings or {}
        for key, defaultValue in pairs(declared) do
            local persistedValue = featureConfig.settings[key]
            if persistedValue == nil then
                featureConfig.settings[key] = defaultValue
            elseif type(persistedValue) ~= type(defaultValue) then
                notices[#notices + 1] = format(
                    "%s.%s had type %s, expected %s; default taken",
                    featureId, key, type(persistedValue), type(defaultValue))
                featureConfig.settings[key] = defaultValue
            end
        end
    end
end

-- Step 4: prune what no default claims. Renames belong to migrations, which
-- already ran; anything still unmatched here is dead weight from a removed
-- feature or a typo, and the notice is what catches a forgotten migration.
local function pruneObsolete(store, registeredDefaults, notices)
    for featureId, featureConfig in pairs(store.features) do
        local defaults = registeredDefaults[featureId]
        if defaults == nil then
            store.features[featureId] = nil
            notices[#notices + 1] = format(
                "pruned stored config for unknown feature '%s'", featureId)
        elseif type(featureConfig.settings) == "table" then
            local declared = defaults.settings or {}
            for key in pairs(featureConfig.settings) do
                if declared[key] == nil then
                    featureConfig.settings[key] = nil
                    notices[#notices + 1] = format(
                        "pruned obsolete key '%s.%s'", featureId, key)
                end
            end
        end
    end
end

-- Returns outcome, failure. Outcome always carries notices, even on failure.
function ConfigStore.Hydrate(persisted, registeredDefaults, currentSchemaVersion)
    currentSchemaVersion = currentSchemaVersion or ns.CURRENT_SCHEMA_VERSION
    registeredDefaults = registeredDefaults or {}

    local notices = {}
    local store, quarantined = readPersisted(persisted, notices)

    if quarantined == nil and store.schemaVersion > currentSchemaVersion then
        notices[#notices + 1] = format(
            "persisted schema v%d is newer than this build's v%d; quarantined without migrating",
            store.schemaVersion, currentSchemaVersion)
        quarantined = store
        store = newEmptyStore()
    end

    local migrated, failure = ns.Migrations.Apply(store, currentSchemaVersion)
    if failure then
        return { store = nil, quarantinedStore = quarantined, notices = notices }, failure
    end
    store = migrated

    mergeDefaults(store, registeredDefaults, notices)
    pruneObsolete(store, registeredDefaults, notices)

    return { store = store, quarantinedStore = quarantined, notices = notices }, nil
end

function ConfigStore.Adopt(store, registeredDefaults)
    liveStore = store
    liveDefaults = registeredDefaults
end

function ConfigStore.IsAdopted()
    return liveStore ~= nil
end

function ConfigStore.SchemaVersion()
    return liveStore and liveStore.schemaVersion or nil
end

function ConfigStore.Feature(featureId)
    if not liveStore then
        return nil
    end
    return liveStore.features[featureId]
end

function ConfigStore.IsEnabled(featureId)
    local featureConfig = ConfigStore.Feature(featureId)
    return featureConfig ~= nil and featureConfig.enabled == true
end

function ConfigStore.SetEnabled(featureId, enabled)
    local featureConfig = ConfigStore.Feature(featureId)
    if not featureConfig then
        return false, "unknown feature"
    end
    featureConfig.enabled = (enabled == true)
    return true
end

function ConfigStore.Get(featureId, key)
    local featureConfig = ConfigStore.Feature(featureId)
    if not featureConfig then
        return nil
    end
    return featureConfig.settings[key]
end

-- Type is checked against the registered default, not against the stored
-- value, so a store corrupted at rest cannot widen what a key will accept.
function ConfigStore.Set(featureId, key, value)
    local featureConfig = ConfigStore.Feature(featureId)
    if not featureConfig then
        return false, "unknown feature"
    end

    local defaults = liveDefaults and liveDefaults[featureId]
    local declared = defaults and defaults.settings and defaults.settings[key]
    if declared == nil then
        return false, format("'%s' declares no key '%s'", featureId, tostring(key))
    end
    if type(value) ~= type(declared) then
        return false, format("'%s.%s' expects %s, got %s",
            featureId, tostring(key), type(declared), type(value))
    end

    featureConfig.settings[key] = value
    return true
end

function ConfigStore.DeclaredKeys(featureId)
    local defaults = liveDefaults and liveDefaults[featureId]
    local declared = defaults and defaults.settings or {}
    local keys = {}
    for key in pairs(declared) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    return keys
end
