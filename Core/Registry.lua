-- Core/Registry.lua
-- Lifecycle owner (§6). Registration is declaration only; nothing touches a
-- frame before PLAYER_LOGIN. The disable post-condition is enforced here, by
-- calling Dispatch.UnsubscribeAll after every disable, rather than trusted to
-- each feature across five phases.

local ADDON_NAME, ns = ...

local Registry = {}
ns.Registry = Registry

local type, pairs, format, tostring = type, pairs, string.format, tostring
local STATE = ns.FEATURE_STATE
local RESULT = ns.CONFIG_RESULT

local features = {}
local order = {}
local hydrated = false
local loginSeen = false
local storeFailure = nil

function Registry.Register(featureId, defaults, lifecycle)
    assert(type(featureId) == "string" and featureId ~= "",
        "Registry.Register requires a featureId")
    assert(features[featureId] == nil, "duplicate feature id: " .. tostring(featureId))
    assert(type(defaults) == "table", "Registry.Register requires a defaults table")
    assert(type(lifecycle) == "table", "Registry.Register requires a lifecycle table")
    assert(type(lifecycle.enable) == "function", featureId .. " must provide enable")
    assert(type(lifecycle.disable) == "function", featureId .. " must provide disable")

    defaults.settings = defaults.settings or {}
    for key, value in pairs(defaults.settings) do
        assert(ns.ConfigStore.IsConfigValue(value), format(
            "%s.%s default must be boolean, number or string", featureId, tostring(key)))
    end

    features[featureId] = {
        id = featureId,
        defaults = defaults,
        lifecycle = lifecycle,
        state = STATE.REGISTERED,
        faultReason = nil,
    }
    order[#order + 1] = featureId
    return true
end

local function releaseFeature(record)
    local ok, err = ns.Isolation.Call(record.lifecycle.disable)
    -- Unconditional, and after disable, so the post-condition holds even when
    -- disable raised part-way through its own cleanup (§6.1).
    local released = ns.Dispatch.UnsubscribeAll(record.id)

    if not ok then
        ns.Log.OnceError("disable:" .. record.id, format(
            "'%s' raised during disable; the registry released %d subscription(s): %s",
            record.id, released, tostring(err)))
    end
    return ok, err
end

local function enterFault(record, reason, detail)
    if record.state == STATE.FAULTED then
        return false
    end

    record.state = STATE.FAULTED
    record.faultReason = reason
    releaseFeature(record)

    -- The stored preference is deliberately untouched: a fault caused by a
    -- transient client state clears on the next login rather than silently
    -- turning the feature off forever (§6.3).
    ns.Log.OnceError("fault:" .. record.id, format(
        "feature '%s' faulted (%s) and is disabled for this session; stored preference unchanged",
        record.id, tostring(reason)))
    if detail then
        ns.Log.OnceError("fault-detail:" .. record.id, tostring(detail))
    end
    return true
end

local function enterEnabled(record)
    record.state = STATE.ENABLING

    local config = ns.ConfigStore.Feature(record.id)
    local ok, success, reason = ns.Isolation.Call(record.lifecycle.enable, config)

    if not ok then
        enterFault(record, "enable raised", success)
        return false
    end
    if success ~= true then
        enterFault(record, format("enable failed: %s", tostring(reason or "unspecified")))
        return false
    end

    record.state = STATE.ENABLED
    record.faultReason = nil
    return true
end

function Registry.HydrateConfig()
    if hydrated then
        return false
    end
    hydrated = true

    local defaultsById = {}
    for index = 1, #order do
        local record = features[order[index]]
        defaultsById[record.id] = record.defaults
    end

    local persisted = _G[ns.SAVED_VARIABLE]
    -- A quarantine from an earlier session stays recoverable. Rebuilding the
    -- root below would otherwise drop it silently, which is the same class of
    -- quiet data loss the quarantine exists to prevent.
    local carriedQuarantine = nil
    if type(persisted) == "table" then
        carriedQuarantine = persisted[ns.QUARANTINE_KEY]
    end

    local outcome, failure = ns.ConfigStore.Hydrate(
        persisted, defaultsById, ns.CURRENT_SCHEMA_VERSION)

    ns.Log.Notices(outcome and outcome.notices)

    if failure then
        storeFailure = failure
        ns.Log.Error(format(
            "config store unusable (%s at v%s: %s); no features will be enabled this session",
            tostring(failure.reason), tostring(failure.version), tostring(failure.detail)))
        return false
    end

    local root = {
        schemaVersion = outcome.store.schemaVersion,
        features = outcome.store.features,
    }

    if outcome.quarantinedStore then
        root[ns.QUARANTINE_KEY] = outcome.quarantinedStore
        ns.Log.Error(format(
            "previous config quarantined at %s.%s and is recoverable by hand",
            ns.SAVED_VARIABLE, ns.QUARANTINE_KEY))
    elseif carriedQuarantine ~= nil then
        root[ns.QUARANTINE_KEY] = carriedQuarantine
    end

    _G[ns.SAVED_VARIABLE] = root
    ns.ConfigStore.Adopt(root, defaultsById)
    return true
end

function Registry.EnableConfigured()
    if storeFailure then
        return 0
    end

    local enabled = 0
    for index = 1, #order do
        local record = features[order[index]]
        if record.state == STATE.REGISTERED then
            if ns.ConfigStore.IsEnabled(record.id) then
                if enterEnabled(record) then
                    enabled = enabled + 1
                end
            else
                record.state = STATE.DISABLED
            end
        end
    end
    return enabled
end

function Registry.SetEnabled(featureId, enabled)
    local record = features[featureId]
    if not record then
        return false, "unknown feature"
    end
    if storeFailure then
        return false, "config store is unusable this session"
    end

    ns.ConfigStore.SetEnabled(featureId, enabled)

    if enabled then
        if record.state == STATE.ENABLED then
            return true
        end
        if not loginSeen then
            record.state = STATE.REGISTERED
            return true, "will enable at login"
        end
        if enterEnabled(record) then
            return true
        end
        return false, record.faultReason
    end

    if record.state == STATE.ENABLED
        or record.state == STATE.ENABLING
        or record.state == STATE.FAULTED then
        releaseFeature(record)
    end
    record.state = STATE.DISABLED
    record.faultReason = nil
    return true
end

function Registry.Fault(featureId, reason, detail)
    local record = features[featureId]
    if not record then
        return false
    end
    return enterFault(record, reason, detail)
end

-- Returns RESULT.APPLIED, or RESULT.RELOAD_REQUIRED plus the key that needs it.
function Registry.NotifyConfigChanged(featureId, key)
    local record = features[featureId]
    if not record or record.state ~= STATE.ENABLED then
        return RESULT.APPLIED
    end

    local hook = record.lifecycle.onConfigChanged
    if type(hook) ~= "function" then
        return RESULT.RELOAD_REQUIRED, key
    end

    local config = ns.ConfigStore.Feature(featureId)
    local ok, outcome, detail = ns.Isolation.Call(hook, config, key)

    if not ok then
        enterFault(record, format("onConfigChanged raised for '%s'", tostring(key)), outcome)
        return RESULT.APPLIED
    end
    if outcome == RESULT.RELOAD_REQUIRED then
        return RESULT.RELOAD_REQUIRED, detail or key
    end
    return RESULT.APPLIED
end

function Registry.State(featureId)
    local record = features[featureId]
    if not record then
        return nil
    end
    return record.state, record.faultReason
end

function Registry.Ids()
    local ids = {}
    for index = 1, #order do
        ids[index] = order[index]
    end
    return ids
end

function Registry.Exists(featureId)
    return features[featureId] ~= nil
end

function Registry.StoreFailure()
    return storeFailure
end

local boot = CreateFrame("Frame")
boot:RegisterEvent("ADDON_LOADED")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(_, event, loadedAddon)
    if event == "ADDON_LOADED" then
        if loadedAddon == ns.ADDON_NAME then
            Registry.HydrateConfig()
            boot:UnregisterEvent("ADDON_LOADED")
        end
        return
    end

    -- PLAYER_LOGIN: config is hydrated and frames are now safe to create.
    loginSeen = true
    Registry.EnableConfigured()
    boot:UnregisterEvent("PLAYER_LOGIN")
end)
