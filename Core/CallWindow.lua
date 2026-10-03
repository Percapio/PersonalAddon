-- Core/CallWindow.lua
-- The Phase 8 spike's two instruments, kept for the production writes that the spike
-- cleared (Architecture/20260927-Phase08.md section 4.5).
--
-- A client call can deliver events before it returns, and every listener of those
-- events then runs inside our execution (README rule 9). The spike found SortBags
-- delivering ITEM_LOCK_CHANGED and ITEM_LOCKED inside the call (section 8.4). So
-- auto-sort reads who listens to those two before every sort, and both auto-sort and
-- auto-sell make every write inside a window that records what arrived during it. An
-- event the spike did not see then faults the feature once, instead of tainting
-- quietly on every write.

local ADDON_NAME, ns = ...

local CallWindow = {}
ns.CallWindow = CallWindow

local pcall, type, tostring, format = pcall, type, tostring, string.format
local concat, sort = table.concat, table.sort

-- Where RegisterAllEvents is missing, the window listens for the bag and merchant
-- events a sort or sale could raise.
local FALLBACK_EVENTS = {
    "BAG_UPDATE", "BAG_UPDATE_DELAYED", "BAG_CONTAINER_UPDATE", "BAG_NEW_ITEMS_UPDATED",
    "ITEM_LOCK_CHANGED", "ITEM_LOCKED", "ITEM_UNLOCKED", "INVENTORY_SEARCH_UPDATE",
    "MERCHANT_UPDATE", "PLAYER_MONEY", "UNIT_INVENTORY_CHANGED",
}

-- No parent: never under a Blizzard panel, never shown, and registered for nothing
-- outside a window.
local frame = CreateFrame("Frame")

local ClientRead = ns.ClientRead
local PLAIN = ClientRead.PLAIN

-- Runs one write inside an all-events window. Returns the events delivered between
-- register and unregister -- exactly those that arrived while the call ran --
-- deduplicated in arrival order, then whether the write ran without raising, and
-- the error when it did not.
function CallWindow.Capture(write)
    local names, seen = {}, {}
    frame:SetScript("OnEvent", function(_, eventName)
        if not seen[eventName] then
            seen[eventName] = true
            names[#names + 1] = eventName
        end
    end)
    if type(frame.RegisterAllEvents) == "function" then
        frame:RegisterAllEvents()
    else
        for index = 1, #FALLBACK_EVENTS do
            pcall(frame.RegisterEvent, frame, FALLBACK_EVENTS[index])
        end
    end

    local ok, err = pcall(write)

    frame:UnregisterAllEvents()
    frame:SetScript("OnEvent", nil)
    return names, ok, err
end

-- A listener is usually a Blizzard frame, and a frame's name can be secret, so both
-- reads go through ClientRead (Phase 9 section 5.2).
local function frameLabel(target)
    if type(target) ~= "table" then
        return tostring(target)
    end
    local kind, name = ClientRead.Call(target.GetName, "string", target)
    if kind == PLAIN and name ~= "" then
        return name
    end
    kind, name = ClientRead.Call(target.GetDebugName, "string", target)
    if kind == PLAIN and name ~= "" then
        return name
    end
    return "<unnamed>"
end

local function isOurs(target)
    return target == frame or (ns.Dispatch ~= nil and ns.Dispatch.OwnsFrame(target))
end

-- Who is registered for each event now, this addon's own frames left out. Returns a
-- map of event name to frame labels, or nil when the client has no
-- GetFramesRegisteredForEvent, in which case the question cannot be answered.
function CallWindow.Listeners(names)
    local reader = _G.GetFramesRegisteredForEvent
    if type(reader) ~= "function" then
        return nil
    end
    local byEvent = {}
    for index = 1, #names do
        local results = { pcall(reader, names[index]) }
        local labels = {}
        if results[1] then
            for position = 2, #results do
                local target = results[position]
                if not isOurs(target) then
                    labels[#labels + 1] = frameLabel(target)
                end
            end
        end
        byEvent[names[index]] = labels
    end
    return byEvent
end

function CallWindow.AnyListener(byEvent)
    for _, labels in pairs(byEvent) do
        if #labels > 0 then
            return true
        end
    end
    return false
end

-- A stable one-line description, "EVENT: frame, frame; EVENT: none", for chat and
-- for keying a once-only notice by the list it describes.
function CallWindow.Describe(byEvent)
    local parts = {}
    for eventName, labels in pairs(byEvent) do
        parts[#parts + 1] = format("%s: %s", eventName,
            #labels > 0 and concat(labels, ", ") or "none")
    end
    sort(parts)
    return concat(parts, "; ")
end

-- The names not in expected (a set), in arrival order.
function CallWindow.Unexpected(names, expected)
    local unexpected = {}
    for index = 1, #names do
        if not expected[names[index]] then
            unexpected[#unexpected + 1] = names[index]
        end
    end
    return unexpected
end
