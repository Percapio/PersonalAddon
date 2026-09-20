-- Features/ReloadCommand.lua
-- Trivial by design. Its real job is the load smoke test: if /rl responds, the
-- .toc, the load order, the config store and the registry all executed (§10).

local ADDON_NAME, ns = ...

local FEATURE_ID = "reloadCommand"
local COMMAND_KEY = "PERSONALADDON_RELOAD"
local TOKEN = "/rl"

local claimed = false

-- Slash registration is last-writer-wins and silent. Walk the SLASH_* globals
-- of every other registered command so a collision surfaces instead of one of
-- the two addons quietly losing.
local function tokenOwner()
    for key in pairs(SlashCmdList) do
        if key ~= COMMAND_KEY then
            local index = 1
            while true do
                local slash = _G["SLASH_" .. key .. index]
                if not slash then
                    break
                end
                if string.lower(slash) == TOKEN then
                    return key
                end
                index = index + 1
            end
        end
    end
    return nil
end

local function enable()
    local owner = tokenOwner()
    if owner then
        return nil, string.format("%s is already owned by %s", TOKEN, owner)
    end

    _G["SLASH_" .. COMMAND_KEY .. "1"] = TOKEN
    SlashCmdList[COMMAND_KEY] = function()
        ReloadUI()
    end
    claimed = true
    return true
end

local function disable()
    if not claimed then
        return
    end
    SlashCmdList[COMMAND_KEY] = nil
    claimed = false
    -- The client's typed-command hash retains a stale entry that cannot be
    -- cleared from Lua. The handler is gone, so the token becomes unrecognised
    -- rather than harmful -- the one documented exception to the §6.1
    -- post-condition (§10).
end

local function onConfigChanged()
    return ns.CONFIG_RESULT.APPLIED
end

ns.Registry.Register(FEATURE_ID, {
    enabledByDefault = true,
    label = "Reload command",
    description = "Adds /rl as a shortcut for reloading the interface.",
    settings = {},
    schema = {},
}, {
    enable = enable,
    disable = disable,
    onConfigChanged = onConfigChanged,
})
