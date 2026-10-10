-- Phase 13 harness helpers (Architecture/20261009-Phase13.md section 11.1).
-- Two lookups the preview checks need, and nothing else: the frame stubs,
-- the settings stubs and the event pump are all Phase 8's and Phase 12's.

-- A frame by its global name. CreateFrame records every frame it builds, so this
-- finds the panels the features name without reaching into their state.
function HARNESS.frameByName(name)
    for index = 1, #HARNESS.frames do
        local frame = HARNESS.frames[index]
        if frame.name == name then
            return frame
        end
    end
    return nil
end

-- What the settings API holds for one variable, which for the preview toggle is
-- the panel's own value table. Reading it is how a check sees whether the
-- checkbox agrees with a state change the page did not cause.
function HARNESS.settingValue(variable)
    local setting = HARNESS.settingsByVariable[variable]
    if not setting then
        return nil
    end
    return setting:GetValue()
end

-- Rows live in a frame pool, so a width check has to see every frame the pool
-- built, not just the ones currently drawn.
function HARNESS.childWidths(parent)
    local widths = {}
    for index = 1, #HARNESS.frames do
        local frame = HARNESS.frames[index]
        if frame.parent == parent and frame.width ~= nil then
            widths[#widths + 1] = frame.width
        end
    end
    return widths
end
