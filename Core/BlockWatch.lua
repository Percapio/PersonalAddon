-- Core/BlockWatch.lua
-- Records every protected call the client refuses while naming this addon, with
-- the path that led to it, in a log that survives a reload
-- (Architecture/20260924-Patch01Implementation.md section 4).
--
-- The client raises ADDON_ACTION_BLOCKED / _FORBIDDEN synchronously, inside the
-- refused call, so the stack read in the handler IS the path that made the call.
-- Revision 1 of this file threw that stack away, dropped the event name, and kept
-- its tally in memory. The first refusal that mattered afterwards
-- (IsUserOAuthed(), 2026-09-24) could not be traced for all three reasons.
--
-- What it still cannot tell you: whether the refused call was ours. The client
-- names the addon it holds responsible, and taint spreads -- our code touches
-- something, Blizzard's code runs with our taint on it, and Blizzard's own
-- protected call is refused with our name attached. An attempt of "unknown" means
-- no deliberate action of ours was in flight: evidence of spread, not of a call.
--
-- A refusal is never suppressed. It is always recorded and counted; what is
-- limited is how often it prints, once per path per session.
--
-- Revision 3 (Architecture/20261002-Phase09.md section 6):
--   * a storm guard. On 2026-10-02 one session raised 6,144 refusals in 13 minutes
--     and ended in a script-limit kill and a disconnect; this handler ran inside
--     every one of those refused calls. During a storm it now only counts.
--   * the Gamepad defect (GAPBugs01 G1) is recognised by its sole caller rather
--     than by two fixed paths, and its explanation no longer blames Options.
--   * the same defect blamed on another addon gets the one /reload hint too.

local ADDON_NAME, ns = ...

local FEATURE_ID = "blockWatch"

local BlockWatch = {}
ns.BlockWatch = BlockWatch

local format, tostring, type, pairs, pcall = string.format, tostring, type, pairs, pcall
local find, sub, match, gsub, gmatch = string.find, string.sub, string.match, string.gsub, string.gmatch
local concat, remove = table.concat, table.remove

-- Constants (section 4.2), declared once ------------------------------------

local BLOCK_LOG_CAPACITY = 16
local STACK_TEXT_LIMIT = 6000
local STACK_TOP_FRAMES = 40
local STACK_BOTTOM_FRAMES = 20
-- The short read. This addon's own handler puts about eight frames above the
-- refused one; with the refused frame, SIGNATURE_DEPTH path frames and the odd
-- tail call, a signature needs about 14.
local SIGNATURE_READ_FRAMES = 24
local SIGNATURE_DEPTH = 4
local PATH_MEMO_CAPACITY = 32
local LOG_FORMAT_VERSION = 1
local WATCHED_PANELS = {
    "SettingsPanel", "GameMenuFrame", "EditModeManagerFrame",
    "CommunitiesFrame", "GuildControlUI", "AddonList",
}

local KIND_BLOCKED, KIND_FORBIDDEN = "Blocked", "Forbidden"
local UNKNOWN_ATTEMPT = "unknown"
local CAPTURED, WITHHELD, UNAVAILABLE = "Captured", "Withheld", "Unavailable"
local FIRST_EVER, SEEN_BEFORE = "FirstEver", "SeenBefore"

local OUR_PATH_PREFIX = ADDON_NAME .. "/"

local ClientRead = ns.ClientRead
local READ_PLAIN, READ_WITHHELD = ClientRead.PLAIN, ClientRead.WITHHELD

-- The known defect (Phase 9 section 6.3) -------------------------------------------
--
-- Revision 2 matched two fixed path signatures and blamed closing Options.
-- GAPBugs01 showed the refusal reproduces with no addons at all and reaches the
-- call by more routes than two: the delayed interact-icon refresh, whose stack ends
-- at the refused frame, printed as an untraced red line. In the 2026-10-02 export
-- SetPreferredGamepadInteractTarget has exactly one caller in the whole UI,
-- MainActionBarFrame.lua:255. So a refusal whose first frame is that file is the
-- defect, by whatever route the taint arrived. A first frame anywhere else means a
-- patch added a second caller: that refusal stays Untraced and prints red, which is
-- the intended alarm. Re-check the premise after each client patch.

local G1_EXPLANATION = "a Blizzard Gamepad UI defect that reproduces with no addons loaded. "
    .. "Addon or /run code that opened or closed a window, or an addon page drawn in "
    .. "Options, left its focus, binding and cursor state tainted, so controller actions are "
    .. "refused in whichever addon's name that state carries. /reload clears it"
local G1_HINT_KEY = "blockwatch:g1"

local ACTION_BARS = "Blizzard_GamepadActionBars/MainActionBarFrame.lua"
local INTERACT_TARGET = "SetPreferredGamepadInteractTarget()"

-- Returns the explanation for a known defect, or nil for Untraced. An empty
-- signature is always Untraced.
local function classifyRefusal(functionName, callSite)
    local first = callSite[1]
    if functionName == INTERACT_TARGET and first and first.file == ACTION_BARS then
        return G1_EXPLANATION
    end
    return nil
end

-- State ------------------------------------------------------------------------

local function newMemo()
    return { signatures = {}, entries = 0, hits = 0 }
end

local function newBlockLog()
    return { formatVersion = LOG_FORMAT_VERSION, records = {} }
end

-- A ring of the last STORM_REFUSALS refusal times, and what a storm has counted.
local function newStorm()
    return {
        ring = {},
        ringNext = 1,
        ringCount = 0,
        storming = false,
        since = nil,
        refusals = 0,
        byFunction = {},
        functionKeys = 0,
    }
end

local watch = {
    tokens = {},
    blockLog = nil,
    attemptLabel = nil,
    memo = newMemo(),
    storm = newStorm(),
    -- Bound at enable to this UI load's diagnostics table (Phase 9 section 6.6).
    counters = {},
}

-- Set by a probe around a deliberate attempt, so a refusal that follows can be
-- attributed to it. Cleared by passing nil; a probe that forgets to clear leaves
-- every later refusal mislabelled as its own, so the label is the probe's to own.
function BlockWatch.NoteAttempt(label)
    watch.attemptLabel = label
end

function BlockWatch.CurrentAttempt()
    return watch.attemptLabel
end

-- Reading the stack (section 4.3) ------------------------------------------------

local function captured(text)
    return { state = CAPTURED, text = text }
end

-- Where the read starts does not matter: the parser skips this addon's frames.
local function readLiveStack(topFrames, bottomFrames)
    local kind, text = ClientRead.Call(_G.debugstack, "string", 1, topFrames, bottomFrames)
    if kind == READ_PLAIN then
        return captured(text)
    end
    if kind == READ_WITHHELD and text == ClientRead.SECRET_VALUE then
        return { state = WITHHELD }
    end
    return { state = UNAVAILABLE }
end

local LINE_OURS, LINE_LUA, LINE_CLIENT, LINE_TAIL, LINE_OTHER = 1, 2, 3, 4, 5

-- The forms this client's stack reader printed on 2026-09-24 (section 4.3). A
-- leading "..." marks elided frames. A line matching no form is LINE_OTHER, never
-- an error.
local function parseStackLine(rawLine)
    local line = gsub(rawLine, "^%s+", "")
    line = gsub(line, "^%.+", "")
    if find(line, "^%[C%]:") then
        return { kind = LINE_CLIENT, name = match(line, "^%[C%]: in function '([^']+)'") }
    end
    if find(line, "^%[tail call%]") then
        return { kind = LINE_TAIL }
    end
    local path = match(line, "^%[Interface/AddOns/([^%]]+)%]:%d+:")
    if not path then
        return { kind = LINE_OTHER }
    end
    local kind = (sub(path, 1, #OUR_PATH_PREFIX) == OUR_PATH_PREFIX) and LINE_OURS or LINE_LUA
    return { kind = kind, file = path, fn = match(line, "in function '([^']+)'") }
end

local function stripCallSuffix(name)
    return (gsub(tostring(name), "%(%)$", ""))
end

-- Accepts 'Name' and a namespaced 'C_Something.Name': which one this client
-- prints for a namespaced function is not yet known (T10).
local function namesMatch(printedName, bareName)
    if bareName == "" then
        return false
    end
    if printedName == bareName then
        return true
    end
    local boundaryAt = #printedName - #bareName
    if boundaryAt < 1 then
        return false
    end
    local boundary = sub(printedName, boundaryAt, boundaryAt)
    return (boundary == "." or boundary == ":") and sub(printedName, boundaryAt + 1) == bareName
end

-- The frames that identify a refusal's path: up to SIGNATURE_DEPTH Lua frames
-- after the refused frame, found by name so that a deliberate attempt keeps its
-- own frames (T8). Without the name, the leading run of this addon's handler
-- frames and client frames is skipped instead; when nothing else follows, the
-- signature is empty (T11), which is always Untraced.
local function callSiteOf(capture, refusedName)
    if not capture or capture.state ~= CAPTURED then
        return {}
    end

    local lines = {}
    for rawLine in gmatch(capture.text, "[^\r\n]+") do
        lines[#lines + 1] = parseStackLine(rawLine)
    end

    local bareName = stripCallSuffix(refusedName)
    local start = nil
    for index = 1, #lines do
        local line = lines[index]
        if line.kind == LINE_CLIENT and line.name and namesMatch(line.name, bareName) then
            start = index + 1
            break
        end
    end
    if not start then
        start = #lines + 1
        for index = 1, #lines do
            local lineKind = lines[index].kind
            if lineKind ~= LINE_OURS and lineKind ~= LINE_CLIENT and lineKind ~= LINE_TAIL then
                start = index
                break
            end
        end
    end

    local signature = {}
    for index = start, #lines do
        if #signature == SIGNATURE_DEPTH then
            break
        end
        local line = lines[index]
        if line.kind == LINE_LUA or line.kind == LINE_OURS then
            signature[#signature + 1] = { file = line.file, fn = line.fn }
        end
    end
    return signature
end

local function sameSignature(left, right)
    if #left ~= #right then
        return false
    end
    for index = 1, #left do
        if left[index].file ~= right[index].file or left[index].fn ~= right[index].fn then
            return false
        end
    end
    return true
end

local function copySignature(signature)
    local copy = {}
    for index = 1, #signature do
        copy[index] = { file = signature[index].file, fn = signature[index].fn }
    end
    return copy
end

local function renderFrame(frame)
    return frame.file .. ":" .. (frame.fn or "anonymous")
end

local function pathKeyOf(functionName, callSite)
    local parts = { functionName }
    for index = 1, #callSite do
        parts[#parts + 1] = renderFrame(callSite[index])
    end
    return concat(parts, ">")
end

-- A repeat of text this session has already parsed costs a lookup, not a parse.
-- Bounded: emptied when full.
local function signatureViaMemo(memo, shortRead, refusedName)
    if not shortRead or shortRead.state ~= CAPTURED then
        return {}
    end
    local byText = memo.signatures[refusedName]
    local remembered = byText and byText[shortRead.text]
    if remembered then
        memo.hits = memo.hits + 1
        return remembered
    end

    local signature = callSiteOf(shortRead, refusedName)
    if memo.entries >= PATH_MEMO_CAPACITY then
        memo.signatures = {}
        memo.entries = 0
    end
    byText = memo.signatures[refusedName]
    if not byText then
        byText = {}
        memo.signatures[refusedName] = byText
    end
    byText[shortRead.text] = signature
    memo.entries = memo.entries + 1
    return signature
end

-- The persisted log (section 4.4) ------------------------------------------------

local function findRecord(blockLog, functionName, callSite)
    local records = blockLog.records
    for index = 1, #records do
        local record = records[index]
        if record.functionName == functionName and sameSignature(record.callSite, callSite) then
            return record
        end
    end
    return nil
end

-- Insertion order is firstSeenAt order, so evicting the first record evicts the
-- oldest, with ties broken the same way every time.
local function insertEvictingOldest(blockLog, record, capacity)
    local records = blockLog.records
    records[#records + 1] = record
    while #records > capacity do
        remove(records, 1)
    end
end

local function truncateCapture(capture, limit)
    if capture.state == CAPTURED and #capture.text > limit then
        return captured(sub(capture.text, 1, limit))
    end
    return capture
end

local function isSequence(value)
    if type(value) ~= "table" then
        return false
    end
    local entries = 0
    for _ in pairs(value) do
        entries = entries + 1
    end
    return entries == #value
end

local function isValidFrame(frame)
    return type(frame) == "table" and type(frame.file) == "string"
        and (frame.fn == nil or type(frame.fn) == "string")
end

local function isValidStack(stack)
    if type(stack) ~= "table" then
        return false
    end
    if stack.state == CAPTURED then
        return type(stack.text) == "string"
    end
    return stack.state == WITHHELD or stack.state == UNAVAILABLE
end

local function isValidRecord(record)
    if type(record) ~= "table" or type(record.functionName) ~= "string" then
        return false
    end
    if record.kind ~= KIND_BLOCKED and record.kind ~= KIND_FORBIDDEN then
        return false
    end
    if not isSequence(record.callSite) or not isSequence(record.shownPanels) then
        return false
    end
    for index = 1, #record.callSite do
        if not isValidFrame(record.callSite[index]) then
            return false
        end
    end
    for index = 1, #record.shownPanels do
        if type(record.shownPanels[index]) ~= "string" then
            return false
        end
    end
    return isValidStack(record.firstStack)
        and type(record.firstSeenAt) == "number"
        and type(record.clientBuild) == "string"
        and type(record.attempt) == "string"
        and type(record.inCombat) == "boolean"
        and type(record.count) == "number" and record.count >= 1
end

-- Returns the bound log, then "Created", "Restored" or "Reset", then for a Reset
-- the reason and the records discarded, or for a Restore the records trimmed.
-- Any bad record resets the whole log: dropping one quietly would hide a writer
-- bug.
local function bindBlockLog(persisted, capacity)
    if persisted == nil then
        return newBlockLog(), "Created"
    end
    local records = type(persisted) == "table" and persisted.records or nil
    local held = type(records) == "table" and #records or 0
    if type(records) ~= "table" or not isSequence(records) then
        return newBlockLog(), "Reset", "WrongShape", held
    end
    if persisted.formatVersion ~= LOG_FORMAT_VERSION then
        return newBlockLog(), "Reset", "UnknownFormatVersion", held
    end
    for index = 1, #records do
        if not isValidRecord(records[index]) then
            return newBlockLog(), "Reset", "WrongShape", held
        end
    end
    local trimmed = 0
    while #records > capacity do
        remove(records, 1)
        trimmed = trimmed + 1
    end
    return persisted, "Restored", nil, trimmed
end

-- Bound on first use in a session: enable, or any /pa blocked subcommand. Both
-- run after PLAYER_LOGIN, when saved variables are loaded.
local function ensureBound()
    if watch.blockLog then
        return watch.blockLog
    end
    local blockLog, outcome, reason, affected = bindBlockLog(_G.PersonalAddonBlockLog, BLOCK_LOG_CAPACITY)
    watch.blockLog = blockLog
    _G.PersonalAddonBlockLog = blockLog

    if outcome == "Reset" then
        ns.Log.OnceError("blockwatch:reset", format(
            "the saved block log was unreadable (%s), so a new one was started; %d record(s) discarded",
            tostring(reason), affected or 0))
    elseif outcome == "Restored" and (affected or 0) > 0 then
        ns.Log.Once("blockwatch:trimmed", format(
            "the saved block log held more than %d records; the %d oldest were dropped",
            BLOCK_LOG_CAPACITY, affected))
    end
    return blockLog
end

-- Recording (section 4.3) ------------------------------------------------------

local function clientBuild()
    if type(_G.GetBuildInfo) ~= "function" then
        return "unknown"
    end
    local version, build = _G.GetBuildInfo()
    if version and build then
        return tostring(version) .. "." .. tostring(build)
    end
    return tostring(version or "unknown")
end

-- Blizzard's panels, so their Shown aspect can be secret: read through ClientRead
-- (Phase 9 section 5.2), and a withheld answer reads as not shown.
local function shownPanels(watchList)
    local shown = {}
    for index = 1, #watchList do
        local name = watchList[index]
        local frame = _G[name]
        if type(frame) == "table" then
            local kind, isShown = ClientRead.Call(frame.IsShown, "boolean", frame)
            if kind == READ_PLAIN and isShown then
                shown[#shown + 1] = name
            elseif kind == READ_WITHHELD and isShown == ClientRead.SECRET_VALUE then
                ns.Diagnostics.Bump(watch.counters, "panelReadsWithheld")
            end
        end
    end
    return shown
end

local liveProbe = {
    now = function()
        return time()
    end,
    -- Frame time, for the storm window: time() has one-second resolution.
    clock = function()
        return GetTime()
    end,
    build = clientBuild,
    inCombat = function()
        return type(InCombatLockdown) == "function" and InCombatLockdown() == true
    end,
    shownPanels = shownPanels,
    readStack = readLiveStack,
}

-- A repeat of a known path costs one short read and a lookup; only a path not
-- yet in the log pays for the full read. Returns nil when another addon was
-- blamed, otherwise the record, its known-defect explanation (nil when
-- Untraced) and whether it was FirstEver or SeenBefore.
local function recordRefusal(kind, blamedAddon, functionName, attempt, probe, memo, blockLog)
    if blamedAddon ~= ADDON_NAME then
        return nil
    end

    local shortRead = probe.readStack(SIGNATURE_READ_FRAMES, 0)
    local callSite = signatureViaMemo(memo, shortRead, functionName)
    local explanation = classifyRefusal(functionName, callSite)

    local existing = findRecord(blockLog, functionName, callSite)
    if existing then
        existing.count = existing.count + 1
        return { record = existing, explanation = explanation, occurrence = SEEN_BEFORE }
    end

    local record = {
        functionName = functionName,
        kind = kind,
        callSite = copySignature(callSite),
        firstStack = truncateCapture(
            probe.readStack(STACK_TOP_FRAMES, STACK_BOTTOM_FRAMES), STACK_TEXT_LIMIT),
        firstSeenAt = probe.now(),
        clientBuild = probe.build(),
        attempt = attempt,
        inCombat = probe.inCombat(),
        shownPanels = probe.shownPanels(WATCHED_PANELS),
        count = 1,
    }
    insertEvictingOldest(blockLog, record, BLOCK_LOG_CAPACITY)
    return { record = record, explanation = explanation, occurrence = FIRST_EVER }
end

-- Surfacing (section 4.5) --------------------------------------------------------

-- Everything that came from the client passes through here before it reaches
-- chat, so a function or frame name cannot form a link or colour escape.
local function neutralize(text)
    return ns.EscapeGuard.Neutralize(tostring(text))
end

local function formatSeen(record)
    local dateOf = _G.date
    local when = (type(dateOf) == "function") and dateOf("%Y-%m-%d %H:%M", record.firstSeenAt)
        or tostring(record.firstSeenAt)
    return format(" First seen %s, build %s.", when, neutralize(record.clientBuild))
end

-- The known defect prints once per UI load, whichever addon it names and by
-- whichever path it arrived: one key for all of them.
local function hintKnownDefect(blamedAddon)
    local blame = (blamedAddon == ADDON_NAME) and ""
        or format("blamed on %s: ", neutralize(blamedAddon))
    if ns.Log.Once(G1_HINT_KEY, format("%s refused, %s%s.", INTERACT_TARGET, blame, G1_EXPLANATION)) then
        watch.counters.knownDefectHintShown = true
    end
end

-- Untraced paths print once per path per session; repeats are counted and print
-- nothing.
local function surface(disposition)
    local record = disposition.record
    if disposition.explanation then
        hintKnownDefect(ADDON_NAME)
        return
    end

    local key = "blockwatch:" .. pathKeyOf(record.functionName, record.callSite)
    local seen = (disposition.occurrence == SEEN_BEFORE) and formatSeen(record) or ""
    local via = record.callSite[1] and neutralize(renderFrame(record.callSite[1])) or "no path frames"
    local panels = (#record.shownPanels > 0) and concat(record.shownPanels, ", ") or "none"
    ns.Log.OnceError(key, format(
        "BLOCKED (%s): %s refused with %s named. Attempt: %s. Via: %s. Open: %s. /pa blocked for the record.%s",
        record.kind, neutralize(record.functionName), ADDON_NAME, neutralize(record.attempt),
        via, panels, seen))
end

-- The storm guard (Phase 9 section 6.2) ----------------------------------------------

-- Pushes one refusal time onto the ring. True when this refusal makes the ring
-- full and its oldest entry is within the window of the newest. Never true before
-- the ring holds STORM_REFUSALS entries (Phase 9 audit finding 6).
local function stormPush(storm, now)
    local ring = storm.ring
    ring[storm.ringNext] = now
    storm.ringNext = storm.ringNext % ns.STORM_REFUSALS + 1
    if storm.ringCount < ns.STORM_REFUSALS then
        storm.ringCount = storm.ringCount + 1
    end
    if storm.ringCount < ns.STORM_REFUSALS then
        return false
    end
    -- After the advance, ringNext points at the oldest entry.
    return now - ring[storm.ringNext] <= ns.STORM_WINDOW_SECONDS
end

-- Counts a refusal made during a storm by its function, bounded: names beyond the
-- capacity fold into "other", so a storm hides no function, only its stacks.
local function stormCount(storm, functionName)
    storm.refusals = storm.refusals + 1
    local key = functionName
    if storm.byFunction[key] == nil and key ~= "other" then
        if storm.functionKeys >= ns.STORM_FUNCTION_CAPACITY then
            key = "other"
        else
            storm.functionKeys = storm.functionKeys + 1
        end
    end
    storm.byFunction[key] = (storm.byFunction[key] or 0) + 1
end

local OUTCOME_STORMING = "Storming"
local OUTCOME_STORM_ENTERED = "StormEntered"
local OUTCOME_OTHER_KNOWN = "OtherAddonKnownDefect"
local OUTCOME_IGNORED = "Ignored"
local OUTCOME_RECORDED = "Recorded"

-- Decides what one refusal means, touching only the state passed in, so the
-- self-test can drive it with scratch state and a sample probe. The storm check
-- comes first and reads nothing: during a storm a refusal costs one clock read
-- and one count.
local function judgeRefusal(context, kind, blamedAddon, functionName)
    local storm = context.storm
    if storm.storming then
        stormCount(storm, functionName)
        return OUTCOME_STORMING
    end
    local now = context.probe.clock()
    if stormPush(storm, now) then
        storm.storming = true
        storm.since = now
        stormCount(storm, functionName)
        return OUTCOME_STORM_ENTERED
    end
    if blamedAddon ~= ADDON_NAME then
        if functionName == INTERACT_TARGET then
            return OUTCOME_OTHER_KNOWN
        end
        return OUTCOME_IGNORED
    end
    return OUTCOME_RECORDED, recordRefusal(kind, blamedAddon, functionName, context.attempt,
        context.probe, context.memo, context.blockLog)
end

local function onRefusal(kind, addonName, functionName)
    local blamed = tostring(addonName or "<name>")
    local name = tostring(functionName or "unnamed()")
    local outcome, disposition = judgeRefusal({
        storm = watch.storm,
        probe = liveProbe,
        memo = watch.memo,
        blockLog = ensureBound(),
        attempt = tostring(watch.attemptLabel or UNKNOWN_ATTEMPT),
    }, kind, blamed, name)

    local counters = watch.counters
    if outcome == OUTCOME_STORMING then
        ns.Diagnostics.Bump(counters, "refusalsDuringStorm")
    elseif outcome == OUTCOME_STORM_ENTERED then
        ns.Diagnostics.Bump(counters, "stormsEntered")
        ns.Diagnostics.Bump(counters, "refusalsDuringStorm")
        ns.Log.OnceError("blockwatch:storm", format(
            "%d refusals in %d s: the Gamepad UI is refusing actions in a loop (a Blizzard defect, GAPBugs01 G1). /reload clears it. Until then this addon only counts them.",
            ns.STORM_REFUSALS, ns.STORM_WINDOW_SECONDS))
    elseif outcome == OUTCOME_OTHER_KNOWN then
        ns.Diagnostics.Bump(counters, "refusalsOthersKnownDefect")
        hintKnownDefect(blamed)
    elseif outcome == OUTCOME_RECORDED and disposition then
        ns.Diagnostics.Bump(counters, "refusalsOurs")
        surface(disposition)
    end
end

-- Self-test (section 4.7) --------------------------------------------------------
--
-- Sample A is the stack BugGrabber stored at 19:15:47 on 2026-09-24 for the
-- traced refusal, with its two handler lines replaced by five of this addon's.
-- Blizzard file paths only; nothing about the player.

local SAMPLE_A_LINES = {
    "[Interface/AddOns/PersonalAddon/Core/BlockWatch.lua]:1: in function <Interface/AddOns/PersonalAddon/Core/BlockWatch.lua:1>",
    "[C]: in function 'xpcall'",
    "[Interface/AddOns/PersonalAddon/Core/Isolation.lua]:33: in function 'Call'",
    "[Interface/AddOns/PersonalAddon/Core/Dispatch.lua]:165: in function 'invoke'",
    "[Interface/AddOns/PersonalAddon/Core/Dispatch.lua]:235: in function <Interface/AddOns/PersonalAddon/Core/Dispatch.lua:208>",
    "[C]: in function 'SetPreferredGamepadInteractTarget'",
    "[Interface/AddOns/Blizzard_GamepadActionBars/MainActionBarFrame.lua]:255: in function 'UpdateInteractIcons'",
    "[Interface/AddOns/Blizzard_GamepadActionBars/MainActionBarFrame.lua]:66: in function <...ns/Blizzard_GamepadActionBars/MainActionBarFrame.lua:49>",
    "[tail call]: ?",
    "[Interface/AddOns/Blizzard_GamepadSharedUtility/InputBindingStack/InputBindingManager.lua]:42: in function <...redUtility/InputBindingStack/InputBindingManager.lua:38>",
    "[Interface/AddOns/Blizzard_GamepadSharedUtility/InputBindingStack/InputBindingManager.lua]:190: in function 'RemoveSet'",
    "[Interface/AddOns/Blizzard_GamepadSharedUtility/InputBindingStack/BindingSetFactory.lua]:264: in function 'DeactivateBindingGroup'",
    "[Interface/AddOns/Blizzard_GamepadSharedUtility/FrameControlsManager.lua]:117: in function <...izzard_GamepadSharedUtility/FrameControlsManager.lua:113>",
    "[Interface/AddOns/Blizzard_GamepadSharedUtility/FrameControlsManager.lua]:542: in function 'FrameHidden'",
    "[Interface/AddOns/Blizzard_GamepadSharedUtility/FrameControlsManager.lua]:226: in function <...izzard_GamepadSharedUtility/FrameControlsManager.lua:221>",
    "...[Interface/AddOns/Blizzard_UIParentPanelManager/Shared/UIParentPanelManager.lua]:513: in function 'MoveUIPanel'",
    "[Interface/AddOns/Blizzard_UIParentPanelManager/Shared/UIParentPanelManager.lua]:570: in function 'HideUIPanelImplementation'",
    "[Interface/AddOns/Blizzard_UIParentPanelManager/Shared/UIParentPanelManager.lua]:530: in function 'HideUIPanel'",
    "[Interface/AddOns/Blizzard_UIParentPanelManager/Shared/UIParentPanelManager.lua]:133: in function <...UIParentPanelManager/Shared/UIParentPanelManager.lua:124>",
    "[C]: in function 'SetAttribute'",
    "[Interface/AddOns/Blizzard_UIParentPanelManager/Shared/UIParentPanelManager.lua]:933: in function 'HideUIPanel'",
    "[Interface/AddOns/Blizzard_Settings_Shared/Blizzard_SettingsPanel.lua]:296: in function 'TransitionBackOpeningPanel'",
    "[Interface/AddOns/Blizzard_Settings_Shared/Blizzard_SettingsPanel.lua]:291: in function 'ExitWithCommit'",
    "[Interface/AddOns/Blizzard_Settings_Shared/Blizzard_SettingsPanel.lua]:260: in function 'Close'",
    "[Interface/AddOns/Blizzard_Settings_Shared/Blizzard_SettingsPanel.lua]:65: in function <.../Blizzard_Settings_Shared/Blizzard_SettingsPanel.lua:64>",
}
local SAMPLE_A = concat(SAMPLE_A_LINES, "\n")

-- The delayed interact-icon refresh (GAPBugs01 section 2.2, path B): the refused
-- frame is followed directly by the sole caller, inside an anonymous closure.
local SAMPLE_DELAYED = concat({
    SAMPLE_A_LINES[1], SAMPLE_A_LINES[2], SAMPLE_A_LINES[3], SAMPLE_A_LINES[4], SAMPLE_A_LINES[5],
    "[C]: in function 'SetPreferredGamepadInteractTarget'",
    "[Interface/AddOns/Blizzard_GamepadActionBars/MainActionBarFrame.lua]:255: in function <...ns/Blizzard_GamepadActionBars/MainActionBarFrame.lua:237>",
    "[C]: ?",
}, "\n")

-- clock is optional; the probe counts its stack reads so a test can prove a storm
-- reads nothing.
local function sampleProbe(text, clock)
    local probe = { stackReads = 0 }
    probe.now = function() return 0 end
    probe.clock = clock or function() return 0 end
    probe.build = function() return "selftest" end
    probe.inCombat = function() return false end
    probe.shownPanels = function() return {} end
    probe.readStack = function()
        probe.stackReads = probe.stackReads + 1
        return captured(text)
    end
    return probe
end

local function scratchContext(probe)
    return {
        storm = newStorm(),
        probe = probe,
        memo = newMemo(),
        blockLog = newBlockLog(),
        attempt = UNKNOWN_ATTEMPT,
    }
end

-- Replaces exactly one occurrence, so a sample edit that silently misses fails
-- the case instead of testing the unedited sample.
local function edited(text, pattern, replacement)
    local result, replaced = gsub(text, pattern, replacement, 1)
    if replaced ~= 1 then
        error("the sample edit did not apply: " .. pattern)
    end
    return result
end

-- The signature a sample yields must start at the sole caller and be classified
-- as the known defect.
local function expectKnownDefect(text)
    local signature = callSiteOf(captured(text), INTERACT_TARGET)
    if not signature[1] or signature[1].file ~= ACTION_BARS then
        return false, format("signature was %s", pathKeyOf("", signature))
    end
    if not classifyRefusal(INTERACT_TARGET, signature) then
        return false, "the sole caller's path was not classified as the known defect"
    end
    return true
end

local SELF_TESTS = {
    { caseName = "T1 known defect, RemoveSet", run = function()
        return expectKnownDefect(SAMPLE_A)
    end },
    { caseName = "T2 known defect, AddBindingSet", run = function()
        return expectKnownDefect(edited(SAMPLE_A, "'RemoveSet'", "'AddBindingSet'"))
    end },
    { caseName = "T3 a changed first frame is Untraced", run = function()
        local text = edited(SAMPLE_A,
            "Blizzard_GamepadActionBars/MainActionBarFrame%.lua%]:255",
            "Blizzard_GamepadActionBars/OtherCaller.lua]:255")
        if classifyRefusal(INTERACT_TARGET, callSiteOf(captured(text), INTERACT_TARGET)) then
            return false, "a second caller was classified as the known defect"
        end
        return true
    end },
    { caseName = "T4 withheld stack", run = function()
        local signature = callSiteOf({ state = WITHHELD }, INTERACT_TARGET)
        if #signature ~= 0 then
            return false, "a withheld stack produced frames"
        end
        if classifyRefusal(INTERACT_TARGET, signature) then
            return false, "an empty signature was classified as the known defect"
        end
        return true
    end },
    { caseName = "T5 elision markers", run = function()
        return expectKnownDefect((gsub(SAMPLE_A, "([^\n]+)", "...%1")))
    end },
    { caseName = "T6 capacity and eviction", run = function()
        local scratch, memo = newBlockLog(), newMemo()
        local probe = sampleProbe(SAMPLE_A)
        for index = 1, BLOCK_LOG_CAPACITY + 1 do
            recordRefusal(KIND_FORBIDDEN, ADDON_NAME, "SelfTest" .. index .. "()", UNKNOWN_ATTEMPT,
                probe, memo, scratch)
        end
        if #scratch.records ~= BLOCK_LOG_CAPACITY then
            return false, format("%d records kept", #scratch.records)
        end
        if scratch.records[1].functionName ~= "SelfTest2()" then
            return false, "the first-written record was not the one evicted"
        end
        return true
    end },
    { caseName = "T7 a repeat is counted", run = function()
        local scratch, memo = newBlockLog(), newMemo()
        local probe = sampleProbe(SAMPLE_A)
        local first = recordRefusal(KIND_FORBIDDEN, ADDON_NAME, INTERACT_TARGET, UNKNOWN_ATTEMPT,
            probe, memo, scratch)
        local second = recordRefusal(KIND_FORBIDDEN, ADDON_NAME, INTERACT_TARGET, UNKNOWN_ATTEMPT,
            probe, memo, scratch)
        if not first or first.occurrence ~= FIRST_EVER or not second or second.occurrence ~= SEEN_BEFORE then
            return false, "occurrences were not FirstEver then SeenBefore"
        end
        if #scratch.records ~= 1 or scratch.records[1].count ~= 2 then
            return false, format("%d record(s), count %s", #scratch.records,
                tostring(scratch.records[1] and scratch.records[1].count))
        end
        return true
    end },
    { caseName = "T8 a deliberate attempt keeps its own frame", run = function()
        local text = edited(SAMPLE_A, "(%[C%]: in function 'SetPreferredGamepadInteractTarget'\n)",
            "%1[Interface/AddOns/PersonalAddon/Features/Probe.lua]:10: in function 'attempt'\n")
        local first = callSiteOf(captured(text), INTERACT_TARGET)[1]
        if not first or first.file ~= "PersonalAddon/Features/Probe.lua" or first.fn ~= "attempt" then
            return false, "the first frame was " .. (first and renderFrame(first) or "missing")
        end
        return true
    end },
    { caseName = "T9 chat escapes are neutralized", run = function()
        local rendered = neutralize("|cffff0000red|r")
        if rendered ~= "||cffff0000red||r" then
            return false, "rendered as " .. rendered
        end
        return true
    end },
    { caseName = "T10 a namespaced refused frame", run = function()
        return expectKnownDefect(edited(SAMPLE_A, "in function 'SetPreferredGamepadInteractTarget'",
            "in function 'C_Test.SetPreferredGamepadInteractTarget'"))
    end },
    { caseName = "T11 only handler and client frames", run = function()
        local text = concat({ SAMPLE_A_LINES[1], SAMPLE_A_LINES[2], SAMPLE_A_LINES[3],
            SAMPLE_A_LINES[4], SAMPLE_A_LINES[5], "[C]: ?" }, "\n")
        local signature = callSiteOf(captured(text), INTERACT_TARGET)
        if #signature ~= 0 then
            return false, format("%d frame(s) read", #signature)
        end
        return true
    end },
    { caseName = "T12 the path memo", run = function()
        local memo = newMemo()
        local capture = captured(SAMPLE_A)
        signatureViaMemo(memo, capture, INTERACT_TARGET)
        signatureViaMemo(memo, capture, INTERACT_TARGET)
        if memo.hits ~= 1 or memo.entries ~= 1 then
            return false, format("hits %d, entries %d after a repeat", memo.hits, memo.entries)
        end
        local bounded = newMemo()
        for index = 1, PATH_MEMO_CAPACITY + 1 do
            signatureViaMemo(bounded, captured(SAMPLE_A .. "\nselftest " .. index), INTERACT_TARGET)
            if bounded.entries > PATH_MEMO_CAPACITY then
                return false, format("the memo held %d entries", bounded.entries)
            end
        end
        return true
    end },
    { caseName = "T13 a changed later frame is still the known defect", run = function()
        return expectKnownDefect(edited(SAMPLE_A, "InputBindingStack/InputBindingManager%.lua%]:42",
            "InputBindingStack/OtherManager.lua]:42"))
    end },
    { caseName = "T14 the delayed refresh path", run = function()
        return expectKnownDefect(SAMPLE_DELAYED)
    end },
    { caseName = "T15 a storm counts and reads nothing", run = function()
        local now = 0
        local probe = sampleProbe(SAMPLE_A, function() return now end)
        local context = scratchContext(probe)
        for index = 1, ns.STORM_REFUSALS - 1 do
            now = index * 0.1
            local outcome = judgeRefusal(context, KIND_FORBIDDEN, ADDON_NAME, INTERACT_TARGET)
            if outcome ~= OUTCOME_RECORDED then
                return false, format("refusal %d was %s before the ring was full", index, outcome)
            end
        end
        local readsBefore = probe.stackReads
        now = ns.STORM_REFUSALS * 0.1
        local tripped = judgeRefusal(context, KIND_FORBIDDEN, ADDON_NAME, INTERACT_TARGET)
        now = now + 0.1
        local after = judgeRefusal(context, KIND_FORBIDDEN, ADDON_NAME, INTERACT_TARGET)
        if tripped ~= OUTCOME_STORM_ENTERED or after ~= OUTCOME_STORMING then
            return false, format("outcomes were %s then %s", tostring(tripped), tostring(after))
        end
        if probe.stackReads ~= readsBefore then
            return false, format("the storm read the stack %d time(s)", probe.stackReads - readsBefore)
        end
        if context.storm.refusals ~= 2 or context.storm.byFunction[INTERACT_TARGET] ~= 2 then
            return false, format("the storm counted %d", context.storm.refusals)
        end
        return true
    end },
    { caseName = "T16 another addon's known defect: a hint, no record", run = function()
        local context = scratchContext(sampleProbe(SAMPLE_A))
        local outcome = judgeRefusal(context, KIND_FORBIDDEN, "BugSack", INTERACT_TARGET)
        if outcome ~= OUTCOME_OTHER_KNOWN then
            return false, "outcome was " .. tostring(outcome)
        end
        if #context.blockLog.records ~= 0 or context.probe.stackReads ~= 0 then
            return false, "another addon's refusal was recorded or read"
        end
        return true
    end },
    { caseName = "T17 another addon's other refusal is ignored", run = function()
        local context = scratchContext(sampleProbe(SAMPLE_A))
        local outcome = judgeRefusal(context, KIND_BLOCKED, "SomeAddon", "CastSpellByName()")
        if outcome ~= OUTCOME_IGNORED or #context.blockLog.records ~= 0 then
            return false, "outcome was " .. tostring(outcome)
        end
        return true
    end },
}

-- Touches neither the persisted log nor the session's memo, and prints nothing:
-- the caller reports. cases defaults to the self-tests above; the harness passes its
-- own to check the recording.
local function runSelfTest(cases)
    cases = cases or SELF_TESTS
    local report = { passed = 0, total = #cases, failed = {} }
    for index = 1, #cases do
        local case = cases[index]
        local ok, passed, reason = pcall(case.run)
        if ok and passed then
            report.passed = report.passed + 1
        else
            report.failed[#report.failed + 1] = {
                caseName = case.caseName,
                reason = ok and tostring(reason or "failed") or ("raised: " .. tostring(passed)),
            }
        end
    end
    return report
end

-- Public surface (section 4.2) -----------------------------------------------------

-- Distinguishes "observing and saw nothing" from "not observing", which is the
-- confusion that made the first controlled run worthless.
function BlockWatch.IsObserving()
    return #watch.tokens > 0
end

function BlockWatch.Records()
    return ensureBound().records
end

function BlockWatch.Capacity()
    return BLOCK_LOG_CAPACITY
end

function BlockWatch.StackOf(index)
    local record = ensureBound().records[index]
    return record and record.firstStack or nil
end

function BlockWatch.Clear()
    local blockLog = ensureBound()
    local removed = #blockLog.records
    blockLog.records = {}
    return removed
end

-- Runs the self-tests and keeps the result in this UI load's diagnostics record, so
-- an in-game run can be read from disk afterwards (Phase 10 section 7.3): the run
-- count, this run's passed and total, and a fault note per failed case.
function BlockWatch.SelfTest(cases)
    local report = runSelfTest(cases)
    local counters = ns.Diagnostics.CountersFor(FEATURE_ID)
    ns.Diagnostics.Bump(counters, "selftestRuns")
    counters.selftestPassed = report.passed
    counters.selftestTotal = report.total
    for index = 1, #report.failed do
        local failure = report.failed[index]
        ns.Diagnostics.NoteFault(FEATURE_ID, format("selftest %s: %s", tostring(failure.caseName),
            tostring(failure.reason)))
    end
    return report
end

-- What this UI load's storm guard has seen, for /pa blocked. byFunction is a copy,
-- sorted by count, so the caller cannot disturb the live counts.
function BlockWatch.StormSummary()
    local storm = watch.storm
    local byFunction = {}
    for name, count in pairs(storm.byFunction) do
        byFunction[#byFunction + 1] = { name = name, count = count }
    end
    table.sort(byFunction, function(left, right) return left.count > right.count end)
    return {
        storming = storm.storming,
        since = storm.since,
        refusals = storm.refusals,
        byFunction = byFunction,
        threshold = ns.STORM_REFUSALS,
        windowSeconds = ns.STORM_WINDOW_SECONDS,
    }
end

-- One /pa blocked line for one record, safe for chat.
function BlockWatch.Describe(index, record)
    local frames = {}
    for position = 1, math.min(3, #record.callSite) do
        frames[#frames + 1] = renderFrame(record.callSite[position])
    end
    local via = (#frames > 0) and concat(frames, " < ") or "no path frames"
    local status = classifyRefusal(record.functionName, record.callSite) and "KnownDefect" or "Untraced"
    return neutralize(format("%d. %dx %s [%s] %s attempt=%s via %s",
        index, record.count, record.functionName, record.kind, status, record.attempt, via))
end

-- The lines /pa blocked stack prints: a header, then the stored stack. Nil when
-- there is no such record.
function BlockWatch.StackLines(index)
    local record = ensureBound().records[index]
    if not record then
        return nil
    end
    local lines = {
        neutralize(format("record %d: %s [%s].", index, record.functionName, record.kind))
            .. formatSeen(record),
    }
    local stack = record.firstStack
    if stack.state == WITHHELD then
        lines[#lines + 1] = "the client withheld this stack"
    elseif stack.state ~= CAPTURED then
        lines[#lines + 1] = "no stack reader was available"
    else
        for line in gmatch(stack.text, "[^\r\n]+") do
            lines[#lines + 1] = neutralize(line)
        end
    end
    return lines
end

-- Lifecycle -------------------------------------------------------------------------

-- One handler per event: Dispatch passes event arguments without the event name,
-- so a shared handler could not tell a BLOCKED refusal from a FORBIDDEN one.
local HANDLERS = {
    ADDON_ACTION_BLOCKED = function(addonName, functionName)
        onRefusal(KIND_BLOCKED, addonName, functionName)
    end,
    ADDON_ACTION_FORBIDDEN = function(addonName, functionName)
        onRefusal(KIND_FORBIDDEN, addonName, functionName)
    end,
}

local function enable()
    ensureBound()
    watch.counters = ns.Diagnostics.CountersFor(FEATURE_ID)

    local subscribed = 0
    for _, eventName in ipairs({ "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN" }) do
        local token = ns.Dispatch.Subscribe(FEATURE_ID, eventName, HANDLERS[eventName])
        if token then
            watch.tokens[#watch.tokens + 1] = token
            subscribed = subscribed + 1
        end
    end

    if subscribed == 0 then
        return false, "this client refused both blocked-action events, so protected-call blame cannot be observed"
    end
    return true
end

-- The log stays bound and on disk; only /pa blocked clear empties it.
local function disable()
    for index = #watch.tokens, 1, -1 do
        ns.Dispatch.Unsubscribe(watch.tokens[index])
        watch.tokens[index] = nil
    end
    watch.attemptLabel = nil
end

local function onConfigChanged()
    return ns.CONFIG_RESULT.APPLIED
end

ns.Registry.Register(FEATURE_ID, {
    enabledByDefault = true,
    internal = true,
    label = "Blocked-action watch",
    description = "Records protected calls the client refuses with this addon named, with the path that led to each.",
    settings = {},
    schema = {},
}, {
    enable = enable,
    disable = disable,
    onConfigChanged = onConfigChanged,
})
