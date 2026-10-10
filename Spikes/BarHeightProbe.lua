-- Spikes/BarHeightProbe.lua
-- Spike N: can the nameplate health bar be made shorter, visibly, on this client?
--
-- TEMPORARY. Deleted with its `/pa probe barheight` route once the Phase 14 design
-- records the answers. Phase 7's QuestWatchProbe, Phase 8's BagWriteProbe and
-- Phase 12's MacroProbe followed the same pattern: an internal feature, off by
-- default, that calls nothing until one of its commands is typed.
--
-- WHY A PROBE AND NOT A DESIGN. Phase 2 section 4.9 shipped a bar resize that the
-- addon could confirm it had written and that never once changed a pixel on
-- screen. Its probe wrote the bar's CURRENT height back to itself, which cannot
-- tell an applied write from an ignored one. So this probe:
--   * writes a DIFFERENT height, never the current one;
--   * reads back a frame later, through ClientRead, and reports the number;
--   * and treats the read-back as evidence of nothing. The verdict is whether a
--     person looking at a nameplate saw it change.
--
-- WHAT IT DOES NOT DO. It installs no hook. The point of the survival checks is
-- to learn WHICH of Blizzard's layout passes clobbers the height; re-asserting
-- would hide exactly that.

local ADDON_NAME, ns = ...

local FEATURE_ID = "barHeightProbe"

local format, type, tostring, tonumber, pairs = string.format, type, tostring, tonumber, pairs
local ClientRead = ns.ClientRead
local PLAIN = ClientRead.PLAIN

local state = {
    enabled = false,
    -- container -> { original = number, wrote = number, plate = frame }
    held = {},
    heldCount = 0,
    wroteHeight = nil,
    lastCheck = nil,
}

-- Frame shape -------------------------------------------------------------------

-- Resolved rather than assumed, the same three-name way Features/Nameplates.lua
-- resolves the bar: every falsified assumption in this project was a well-known
-- API this client arranges differently.
local function resolveContainer(plate)
    local unitFrame = plate.UnitFrame or plate.unitFrame or plate
    return unitFrame.HealthBarsContainer or unitFrame.healthBarsContainer
end

local function currentPlates()
    local api = _G.C_NamePlate
    if not (api and ClientRead.Available(api.GetNamePlates)) then
        return nil, "C_NamePlate.GetNamePlates is missing on this client"
    end
    local ok, plates = pcall(api.GetNamePlates)
    if not ok or type(plates) ~= "table" then
        return nil, "C_NamePlate.GetNamePlates would not answer"
    end
    return plates
end

-- N2: is the height readable? GetHeight is secret-capable in the generated docs,
-- so it goes through ClientRead and the secret-read lint enforces that.
local function readHeight(container)
    return ClientRead.Call(container.GetHeight, "number", container)
end

-- Commands ----------------------------------------------------------------------

-- N1 and N2: what the probe can see before it writes anything.
local function commandLook()
    local plates, reason = currentPlates()
    if not plates then
        ns.Log.Error(reason)
        return
    end

    local seen, resolved, readable = 0, 0, 0
    for _, plate in pairs(plates) do
        seen = seen + 1
        local container = resolveContainer(plate)
        if container then
            resolved = resolved + 1
            local kind, height = readHeight(container)
            if kind == PLAIN then
                readable = readable + 1
                ns.Log.Info(format("  plate %d: container height %s", seen, tostring(height)))
            else
                ns.Log.Warn(format("  plate %d: height not readable (%s)", seen, tostring(height)))
            end
        else
            ns.Log.Warn(format("  plate %d: no HealthBarsContainer", seen))
        end
    end

    ns.Log.Info(format("N1/N2: %d plate(s), %d with a container, %d readable height(s)",
        seen, resolved, readable))
    if seen == 0 then
        ns.Log.Warn("no nameplates on screen; target something first")
    end
end

-- N3: write a DIFFERENT height to every plate on screen, recording each original
-- first. A write with no recorded original is one that cannot be put back, which
-- is what Phase 2 section 5's ledger discipline exists to prevent.
local function commandSet(rawHeight)
    local wanted = tonumber(rawHeight)
    if not wanted or wanted < 2 or wanted > 40 then
        ns.Log.Warn("/pa probe barheight set <2-40>")
        return
    end

    local plates, reason = currentPlates()
    if not plates then
        ns.Log.Error(reason)
        return
    end

    local wrote, skippedSame, skippedUnreadable, refused = 0, 0, 0, 0
    for _, plate in pairs(plates) do
        local container = resolveContainer(plate)
        if container then
            local kind, original = readHeight(container)
            if kind ~= PLAIN then
                skippedUnreadable = skippedUnreadable + 1
            elseif original == wanted then
                -- The Phase 2 error, refused outright: writing a value back to
                -- itself proves only that the call is permitted.
                skippedSame = skippedSame + 1
            else
                local held = state.held[container]
                if not held then
                    held = { original = original, plate = plate }
                    state.held[container] = held
                    state.heldCount = state.heldCount + 1
                end
                if pcall(container.SetHeight, container, wanted) then
                    held.wrote = wanted
                    wrote = wrote + 1
                else
                    refused = refused + 1
                end
            end
        end
    end

    ns.Log.Info(format("N3: wrote %spx to %d plate(s); %d already that height, %d unreadable, %d refused",
        tostring(wanted), wrote, skippedSame, skippedUnreadable, refused))
    if skippedSame > 0 then
        ns.Log.Warn("a plate already at that height was left alone: writing a value back to itself tests nothing")
    end
    if wrote == 0 then
        -- Nothing was written, so there is nothing to look at and no height to
        -- claim in the report.
        return
    end
    state.wroteHeight = wanted
    ns.Log.Warn("NOW LOOK AT THE NAMEPLATE. The read-back below is not the answer; your eyes are.")

    -- A frame later, in our own execution, so Blizzard's layout for this frame has
    -- finished before anything is read.
    if C_Timer and C_Timer.After then
        C_Timer.After(0, function()
            local kept, lost, unreadable = 0, 0, 0
            for container, held in pairs(state.held) do
                local kind, height = readHeight(container)
                if kind ~= PLAIN then
                    unreadable = unreadable + 1
                elseif held.wrote and height == held.wrote then
                    kept = kept + 1
                else
                    lost = lost + 1
                end
            end
            ns.Log.Info(format("N3 read-back a frame later: %d kept, %d already changed, %d unreadable",
                kept, lost, unreadable))
        end)
    end
end

-- N4: run after each trigger. Says whether the written height is still there.
local function commandCheck()
    if state.heldCount == 0 then
        ns.Log.Warn("nothing written yet; /pa probe barheight set <px> first")
        return
    end

    local kept, lost, unreadable, gone = 0, 0, 0, 0
    for container, held in pairs(state.held) do
        if not held.wrote then
            gone = gone + 1
        else
            local kind, height = readHeight(container)
            if kind ~= PLAIN then
                unreadable = unreadable + 1
            elseif height == held.wrote then
                kept = kept + 1
            else
                lost = lost + 1
                ns.Log.Info(format("  reverted to %s (we wrote %s)",
                    tostring(height), tostring(held.wrote)))
            end
        end
    end

    state.lastCheck = format("%d kept, %d reverted, %d unreadable", kept, lost, unreadable)
    ns.Log.Info(format("N4: %s, of %d plate(s) held", state.lastCheck, state.heldCount))
    ns.Log.Warn("AND LOOK: is the bar on screen still short? A kept number with a tall bar is the Phase 2 trap.")
end

local function commandRestore()
    local restored, missing = 0, 0
    for container, held in pairs(state.held) do
        if held.original and pcall(container.SetHeight, container, held.original) then
            restored = restored + 1
        else
            missing = missing + 1
        end
        state.held[container] = nil
    end
    state.heldCount = 0
    state.wroteHeight = nil
    ns.Log.Info(format("restored %d plate(s), %d could not be put back", restored, missing))
    ns.Log.Info("Blizzard's own layout re-establishes its values anyway: restore need only be non-permanent")
end

local function commandReport()
    ns.Log.Info(format("bar-height probe: enabled=%s held=%d wrote=%s",
        tostring(state.enabled), state.heldCount, tostring(state.wroteHeight)))
    if state.lastCheck then
        ns.Log.Info("  last check: " .. state.lastCheck)
    end
    ns.Log.Info("  look | set <px> | check | restore")
end

-- Lifecycle ---------------------------------------------------------------------

local function enable()
    state.enabled = true
    return true
end

local function disable()
    if state.heldCount > 0 then
        commandRestore()
    end
    state.enabled = false
end

ns.Registry.Register(FEATURE_ID, {
    enabledByDefault = false,
    internal = true,
    label = "Bar height probe (spike N)",
    settings = {},
    schema = {},
}, {
    enable = enable,
    disable = disable,
    onConfigChanged = function() return ns.CONFIG_RESULT.APPLIED end,
})

ns.BarHeightProbe = {
    Route = function(subcommand, argument)
        -- Switches itself on at the first command rather than making the operator
        -- type an exact, case-sensitive feature id into a chat box. It still
        -- calls nothing until a command is typed, which is the property that
        -- matters: a probe must not act on login.
        if not state.enabled then
            ns.Registry.SetEnabled(FEATURE_ID, true)
            if not state.enabled then
                ns.Log.Error("the probe would not enable; /pa status barHeightProbe says why")
                return
            end
            ns.Log.Info("bar-height probe on. /pa off barHeightProbe when you are done (it restores first)")
        end
        local word = string.lower(tostring(subcommand or ""))
        if word == "" or word == "report" then
            commandReport()
        elseif word == "look" then
            commandLook()
        elseif word == "set" then
            commandSet(argument)
        elseif word == "check" then
            commandCheck()
        elseif word == "restore" then
            commandRestore()
        else
            ns.Log.Warn("/pa probe barheight [look | set <px> | check | restore]")
        end
    end,
}
