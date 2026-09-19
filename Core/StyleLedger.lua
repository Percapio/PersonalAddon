-- Core/StyleLedger.lua
-- Records a foreign widget's original value before we overwrite it, so disable
-- restores what was actually there rather than what we believe Blizzard's
-- defaults to be (Phase 2 section 5).
--
-- A record's lifetime is one OCCUPANCY, not one session: nameplate frames are
-- recycled across units, and a record captured while frame X showed a small mob
-- would restore that mob's geometry onto whatever unit X shows later. Callers
-- restore and drop a widget's records the moment it detaches, before the client
-- can recycle it.
--
-- Restore need only be non-permanent, not exact. We are not the only writer:
-- once we stop re-asserting, Blizzard's own update path re-establishes its
-- current values on the next event it fires on.

local ADDON_NAME, ns = ...

local StyleLedger = {}
ns.StyleLedger = StyleLedger

local type, format, pcall = type, string.format, pcall

-- Each property knows how to read and write itself, so the ledger stores plain
-- values rather than closures.
local PROPERTY = {}

PROPERTY.BarWidth = {
    read = function(widget) return widget:GetWidth() end,
    write = function(widget, value) widget:SetWidth(value) end,
}

PROPERTY.BarHeight = {
    read = function(widget) return widget:GetHeight() end,
    write = function(widget, value) widget:SetHeight(value) end,
}

-- Anchors are captured as the full point list, because a widget with two or
-- three points restored from one point lands somewhere else entirely.
PROPERTY.Point = {
    read = function(widget)
        local count = widget:GetNumPoints()
        if not count or count == 0 then
            return nil
        end
        local points = {}
        for index = 1, count do
            local point, relativeTo, relativePoint, offsetX, offsetY = widget:GetPoint(index)
            points[index] = {
                point = point,
                relativeTo = relativeTo,
                relativePoint = relativePoint,
                offsetX = offsetX or 0,
                offsetY = offsetY or 0,
            }
        end
        return points
    end,
    write = function(widget, points)
        widget:ClearAllPoints()
        for index = 1, #points do
            local anchor = points[index]
            widget:SetPoint(anchor.point, anchor.relativeTo, anchor.relativePoint,
                anchor.offsetX, anchor.offsetY)
        end
    end,
}

PROPERTY.BarColour = {
    read = function(widget)
        if not widget.GetStatusBarColor then
            return nil
        end
        local red, green, blue, alpha = widget:GetStatusBarColor()
        return { red = red, green = green, blue = blue, alpha = alpha }
    end,
    write = function(widget, colour)
        widget:SetStatusBarColor(colour.red, colour.green, colour.blue, colour.alpha)
    end,
}

function StyleLedger.Create(ledgerName)
    return {
        ledgerName = ledgerName or "unnamed",
        records = {},
        widgetCount = 0,
        restored = 0,
        widgetGone = 0,
        writeRefused = 0,
    }
end

local function recordsFor(ledger, widget, create)
    local existing = ledger.records[widget]
    if existing or not create then
        return existing
    end
    existing = {}
    ledger.records[widget] = existing
    ledger.widgetCount = ledger.widgetCount + 1
    return existing
end

local function alreadyRecorded(records, property)
    for index = 1, #records do
        if records[index].property == property then
            return true
        end
    end
    return false
end

-- Reads and records the widget's current value (once per occupancy), then writes
-- ours. Records NOTHING when the write is refused: a record for a property we
-- never changed makes restore write over a value Blizzard was already managing.
function StyleLedger.Apply(ledger, widget, property, newValue)
    local handler = PROPERTY[property]
    if not handler then
        return false, "UNKNOWN_PROPERTY"
    end
    if widget == nil then
        return false, "WIDGET_MISSING"
    end

    -- Do not create the record list yet. A refused write must leave no trace,
    -- or disable inherits a widget entry holding nothing to restore.
    local existing = recordsFor(ledger, widget, false)
    local firstTouch = not (existing and alreadyRecorded(existing, property))

    local original
    if firstTouch then
        local readable, value = pcall(handler.read, widget)
        if not readable then
            ledger.writeRefused = ledger.writeRefused + 1
            return false, "READ_REFUSED"
        end
        if value == nil then
            return false, "NOT_READABLE"
        end
        original = value
    end

    if not pcall(handler.write, widget, newValue) then
        ledger.writeRefused = ledger.writeRefused + 1
        return false, "WRITE_REFUSED"
    end

    if firstTouch then
        local records = recordsFor(ledger, widget, true)
        records[#records + 1] = { property = property, original = original }
    end
    return true
end

-- Writes ours without recording, for a property whose original is already held.
-- Used by the re-assert path, which must not re-capture.
function StyleLedger.Reapply(ledger, widget, property, newValue)
    local handler = PROPERTY[property]
    if not handler or widget == nil then
        return false, "UNKNOWN_PROPERTY"
    end
    local records = recordsFor(ledger, widget, false)
    if not records or not alreadyRecorded(records, property) then
        -- Never re-assert a property we hold no original for: that would leave a
        -- value behind that disable cannot undo.
        return false, "NOT_RECORDED"
    end
    if not pcall(handler.write, widget, newValue) then
        ledger.writeRefused = ledger.writeRefused + 1
        return false, "WRITE_REFUSED"
    end
    return true
end

function StyleLedger.Reads(ledger, widget, property)
    local handler = PROPERTY[property]
    if not handler or widget == nil then
        return nil
    end
    local ok, value = pcall(handler.read, widget)
    if not ok then
        return nil
    end
    return value
end

function StyleLedger.HasRecord(ledger, widget, property)
    local records = recordsFor(ledger, widget, false)
    if not records then
        return false
    end
    return alreadyRecorded(records, property)
end

-- Restores one property and forgets it, leaving the widget's other records
-- intact. Used when a colour must revert without unstyling the geometry.
function StyleLedger.RestoreProperty(ledger, widget, property)
    local records = recordsFor(ledger, widget, false)
    if not records then
        return false
    end

    for index = 1, #records do
        if records[index].property == property then
            local handler = PROPERTY[property]
            local ok = pcall(handler.write, widget, records[index].original)
            table.remove(records, index)
            if ok then
                ledger.restored = ledger.restored + 1
            else
                ledger.widgetGone = ledger.widgetGone + 1
            end
            if #records == 0 then
                ledger.records[widget] = nil
                ledger.widgetCount = ledger.widgetCount - 1
            end
            return ok
        end
    end
    return false
end

-- Replays in INSERTION order, which restores dimensions before anchors. An
-- anchor written against a size we have not yet reverted lands in the wrong
-- place, and callers record dimensions first.
function StyleLedger.RestoreWidget(ledger, widget)
    local records = recordsFor(ledger, widget, false)
    if not records then
        return 0
    end

    local restored = 0
    for index = 1, #records do
        local record = records[index]
        local handler = PROPERTY[record.property]
        if handler and pcall(handler.write, widget, record.original) then
            restored = restored + 1
            ledger.restored = ledger.restored + 1
        else
            ledger.widgetGone = ledger.widgetGone + 1
        end
    end

    ledger.records[widget] = nil
    ledger.widgetCount = ledger.widgetCount - 1
    return restored
end

function StyleLedger.RestoreAll(ledger)
    local widgets = {}
    for widget in pairs(ledger.records) do
        widgets[#widgets + 1] = widget
    end
    for index = 1, #widgets do
        StyleLedger.RestoreWidget(ledger, widgets[index])
    end
    return {
        restored = ledger.restored,
        widgetGone = ledger.widgetGone,
        writeRefused = ledger.writeRefused,
    }
end

function StyleLedger.Stats(ledger)
    return ledger.widgetCount, ledger.restored, ledger.widgetGone, ledger.writeRefused
end
