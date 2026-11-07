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

local pcall, type, tostring, format, pairs, ipairs = pcall, type, tostring, string.format, pairs, ipairs
local concat, sort = table.concat, table.sort
local find, gsub, lower, match, sub = string.find, string.gsub, string.lower, string.match, string.sub

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

-- What a frame with neither a name nor a debug name is called in chat.
local UNNAMED = "<unnamed>"

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
    return UNNAMED
end

local function isOurs(target)
    return target == frame or (ns.Dispatch ~= nil and ns.Dispatch.OwnsFrame(target))
end

-- Who created a listening frame (Architecture/20261104-Patch02.md section 3.3) --------
--
-- WORDS ONLY. This names the addon that holds tidy bags back; it decides nothing. Any
-- listener that is not ours holds the sort whatever its origin (decision D1), so a
-- wrong or unreadable answer here costs a notice its accuracy and nothing else.

local ORIGIN = { BLIZZARD = "Blizzard", ADDON = "AddOn", UNKNOWN = "Unknown" }
local UNKNOWN_REASON = { WITHHELD = "Withheld", NO_LOCATION = "NoLocation", UNPARSED = "Unparsed" }
CallWindow.ORIGIN = ORIGIN
CallWindow.UNKNOWN_REASON = UNKNOWN_REASON

-- ScriptRegion:GetSourceLocation, read through ClientRead (rule 10): it carries
-- SecretReturnsForAspect ObjectDebug. ClientRead answers every failure as WITHHELD with
-- a detail, so the detail decides (audit finding 1): only a secret is Withheld; a
-- missing method, a raise, nil or "" is NoLocation; a non-string answer is Unparsed.
-- Returns the origin and, for AddOn, the folder in the case the client gave it, or,
-- for Unknown, the reason.
local function listenerOrigin(target)
    if type(target) ~= "table" then
        return ORIGIN.UNKNOWN, UNKNOWN_REASON.NO_LOCATION
    end
    local kind, location = ClientRead.Call(target.GetSourceLocation, "string", target)
    if kind == ClientRead.WITHHELD then
        if location == ClientRead.SECRET_VALUE then
            return ORIGIN.UNKNOWN, UNKNOWN_REASON.WITHHELD
        elseif location == ClientRead.UNEXPECTED_TYPE then
            return ORIGIN.UNKNOWN, UNKNOWN_REASON.UNPARSED
        end
        return ORIGIN.UNKNOWN, UNKNOWN_REASON.NO_LOCATION
    end
    if kind ~= PLAIN or location == "" then
        return ORIGIN.UNKNOWN, UNKNOWN_REASON.NO_LOCATION
    end

    local slashed = gsub(location, "\\", "/")
    local lowered = lower(slashed)
    for index = 1, #ns.BLIZZARD_SOURCE_ROOTS do
        if find(lowered, ns.BLIZZARD_SOURCE_ROOTS[index], 1, true) then
            return ORIGIN.BLIZZARD
        end
    end
    -- Matched on the lower-cased copy, cut from the original: the name keeps its case.
    local first, last = match(lowered, ns.ADDON_FOLDER_PATTERN)
    if not first then
        return ORIGIN.UNKNOWN, UNKNOWN_REASON.UNPARSED
    end
    local folder = sub(slashed, first, last - 1)
    if sub(lower(folder), 1, #ns.BLIZZARD_FOLDER_PREFIX) == ns.BLIZZARD_FOLDER_PREFIX then
        return ORIGIN.BLIZZARD
    end
    return ORIGIN.ADDON, folder
end
CallWindow.ListenerOrigin = listenerOrigin

-- Who is registered for each event now, this addon's own frames left out. Returns a
-- map of event name to listeners, or nil when the client has no
-- GetFramesRegisteredForEvent, in which case the question cannot be answered.
--
-- Each listener is { label, origin, folder (AddOn only), reason (Unknown only), frame }.
-- frame is kept so a frame listening to both events is named once (section 3.3); it is
-- never printed.
function CallWindow.Listeners(names)
    local reader = _G.GetFramesRegisteredForEvent
    if type(reader) ~= "function" then
        return nil
    end
    local byEvent = {}
    for index = 1, #names do
        local results = { pcall(reader, names[index]) }
        local listeners = {}
        if results[1] then
            for position = 2, #results do
                local target = results[position]
                if not isOurs(target) then
                    local origin, detail = listenerOrigin(target)
                    listeners[#listeners + 1] = {
                        label = frameLabel(target),
                        origin = origin,
                        folder = origin == ORIGIN.ADDON and detail or nil,
                        reason = origin == ORIGIN.UNKNOWN and detail or nil,
                        frame = target,
                    }
                end
            end
        end
        byEvent[names[index]] = listeners
    end
    return byEvent
end

function CallWindow.AnyListener(byEvent)
    for _, listeners in pairs(byEvent) do
        if #listeners > 0 then
            return true
        end
    end
    return false
end

local function ownerTag(listener)
    if listener.origin == ORIGIN.ADDON then
        return listener.folder
    elseif listener.origin == ORIGIN.BLIZZARD then
        return "Blizzard"
    end
    return "?"
end

-- A stable one-line description, "EVENT: frame (owner), frame (owner); EVENT: none",
-- for chat and for keying a once-only notice by the list it describes. The owner is the
-- addon's folder, Blizzard, or ? when it could not be read. Not neutralized: callers
-- neutralize where they print, because folders and labels are third-party text.
function CallWindow.Describe(byEvent)
    local parts = {}
    for eventName, listeners in pairs(byEvent) do
        local labels = {}
        for index = 1, #listeners do
            local listener = listeners[index]
            labels[#labels + 1] = format("%s (%s)", tostring(listener.label), tostring(ownerTag(listener)))
        end
        parts[#parts + 1] = format("%s: %s", eventName,
            #labels > 0 and concat(labels, ", ") or "none")
    end
    sort(parts)
    return concat(parts, "; ")
end

-- Reading order (section 3.3): the events sorted by name, then each event's listeners
-- in the client's order.
local function inReadingOrder(byEvent, visit)
    local events = {}
    for eventName in pairs(byEvent) do
        events[#events + 1] = eventName
    end
    sort(events)
    for _, eventName in ipairs(events) do
        local listeners = byEvent[eventName]
        for index = 1, #listeners do
            visit(listeners[index])
        end
    end
end

-- The distinct addon folders among the listeners, in reading order. Blizzard and
-- unknown origins contribute nothing.
function CallWindow.AddOnOwners(byEvent)
    local owners, seen = {}, {}
    inReadingOrder(byEvent, function(listener)
        if listener.origin == ORIGIN.ADDON and not seen[listener.folder] then
            seen[listener.folder] = true
            owners[#owners + 1] = listener.folder
        end
    end)
    return owners
end

-- The words of one hold-back notice (section 3.3, audit finding 4). With an addon
-- among the listeners, the addon row names every owner, joined by ", " in both places.
-- Otherwise the Blizzard row names the distinct labels: a frame listening to both
-- events once, and "<unnamed>" once, followed by " x<N>" when N unnamed frames listen.
-- The verb agrees with the count. Every folder and label is neutralized here.
function CallWindow.HoldBackNotice(byEvent)
    local neutralize = ns.EscapeGuard.Neutralize
    local owners = CallWindow.AddOnOwners(byEvent)
    if #owners > 0 then
        local named = {}
        for index = 1, #owners do
            named[index] = neutralize(owners[index])
        end
        local joined = concat(named, ", ")
        return format("tidy bags is off while %s %s for item locks: a sort would run their code "
            .. "inside this addon's call. Disable %s, or use Clean Up Bags from the bag menu.",
            joined, #owners == 1 and "listens" or "listen", joined)
    end

    local names, seenLabel, seenFrame = {}, {}, {}
    local unnamedCount, unnamedAt = 0, nil
    inReadingOrder(byEvent, function(listener)
        if listener.frame ~= nil then
            if seenFrame[listener.frame] then
                return
            end
            seenFrame[listener.frame] = true
        end
        if listener.label == UNNAMED then
            unnamedCount = unnamedCount + 1
            if not unnamedAt then
                names[#names + 1] = UNNAMED
                unnamedAt = #names
            end
        elseif not seenLabel[listener.label] then
            seenLabel[listener.label] = true
            names[#names + 1] = neutralize(tostring(listener.label))
        end
    end)
    if unnamedAt and unnamedCount > 1 then
        names[unnamedAt] = format("%s x%d", UNNAMED, unnamedCount)
    end
    local single = #names == 1 and unnamedCount <= 1
    return format("tidy bags is waiting: %s %s for item locks right now (an open panel, a "
        .. "Cooldown Manager bag item, or the bag tutorial); it tries again at the next close.",
        concat(names, ", "), single and "listens" or "listen")
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
