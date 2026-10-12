-- Spikes/QuestProbe.lua
-- Phase 17's two spike questions (Architecture/20261011-Phase17.md section 10.4).
--
-- TEMPORARY. Deleted with its `/pa probe quests` route once section 10.4 records the
-- answers, as Phase 16's MacroProbe and Phase 15's GuildNameProbe were. An internal
-- feature, off by default, that calls nothing until a command is typed.
--
-- NEITHER QUESTION GATES THE BUILD. Both features work without them; the answers
-- make one of them prettier and the other honest about a gap. That is a deliberate
-- difference from spike S, which decided whether Phase 16 had a write path at all.
--
-- SQ1: WHICH MARKER TEXTURE ACTUALLY DRAWS. Art is not in the UI export, so no path
-- can be verified from a file we have. The Phase 17 audit also refused the obvious
-- trick -- set the texture, read GetTexture() back, treat nil as missing -- because
-- asset loading is asynchronous and GetTexture can hand back the path it was given
-- before the file is ever resolved. So this draws each candidate on a visible frame
-- and asks the operator to look.
--
-- SQ2: DOES A COLLAPSED QUEST HEADER HIDE ITS QUESTS from the log's index space?
-- GetNumQuestLogEntries' two returns are documented; which quests the first one
-- covers is client behaviour. The probe prints both numbers and every id the index
-- range yields, so collapsing a header and running it twice answers it. Nothing is
-- expanded or collapsed BY the probe: ExpandQuestHeader would raise
-- QUEST_LOG_UPDATE from inside our own call, which is the defect Phase 7 section 6.4
-- abandoned the quest-level sort over.

local ADDON_NAME, ns = ...

local FEATURE_ID = "questProbe"

local format, type, pcall, ipairs = string.format, type, pcall, ipairs
local concat = table.concat
local ClientRead = ns.ClientRead

-- The candidates, in the order the probe draws them. The last is the shipped value,
-- already drawn by Features/Toasts.lua, so it is the control: if that one does not
-- appear either, the probe's own frame is wrong rather than the paths.
local TEXTURE_CANDIDATES = {
    "Interface\\QuestFrame\\UI-Quest-BulletPoint",
    "Interface\\GossipFrame\\AvailableQuestIcon",
    "Interface\\GossipFrame\\ActiveQuestIcon",
    "Interface\\Minimap\\Tracking\\QuestBlob",
    "Interface\\Icons\\INV_Misc_QuestionMark",
}

local state = { enabled = false, frames = {} }

local function spikeLog()
    if type(_G.PersonalAddonSpikeLog) ~= "table" then
        _G.PersonalAddonSpikeLog = { spike = "Phase 17", lines = {} }
    end
    local log = _G.PersonalAddonSpikeLog
    if type(log.lines) ~= "table" then
        log.lines = {}
    end
    return log
end

-- Chat is not a record. Phase 16 section 2.6 is this project's receipt for that: a
-- whole spike report went to chat and none of it survived the session.
local function say(text)
    ns.Log.Info("[spike 17] " .. text)
    local log = spikeLog()
    log.lines[#log.lines + 1] = format("%s %s",
        _G.date and _G.date("%H:%M:%S") or "", tostring(text))
    log.addonVersion = ns.VERSION
end

local function sayError(text)
    ns.Log.Error("[spike 17] " .. text)
    local log = spikeLog()
    log.lines[#log.lines + 1] = format("%s ERROR %s",
        _G.date and _G.date("%H:%M:%S") or "", tostring(text))
end

-- SQ1 ---------------------------------------------------------------------------------

local function commandTextures()
    say("SQ1: which quest-marker texture draws?")
    if type(_G.CreateFrame) ~= "function" then
        sayError("no CreateFrame on this client")
        return
    end

    -- A row of labelled swatches in the middle of the screen, ours and parented to
    -- UIParent (rule 6). Each is QUEST_MARKER_SIZE, the size the real marker uses,
    -- so a path that draws at a different scale is visible too.
    for index = 1, #TEXTURE_CANDIDATES do
        local path = TEXTURE_CANDIDATES[index]
        local frame = state.frames[index]
        if not frame then
            frame = CreateFrame("Frame", nil, _G.UIParent)
            frame:SetSize(ns.QUEST_MARKER_SIZE * 3, ns.QUEST_MARKER_SIZE * 3)
            frame:SetPoint("CENTER", _G.UIParent, "CENTER",
                (index - 3) * ns.QUEST_MARKER_SIZE * 4, 120)
            local texture = frame:CreateTexture(nil, "OVERLAY")
            texture:SetAllPoints(frame)
            frame.texture = texture
            local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            label:SetPoint("TOP", frame, "BOTTOM", 0, -2)
            label:SetText(tostring(index))
            frame.label = label
            state.frames[index] = frame
        end
        frame.texture:SetTexture(path)
        frame:Show()

        -- Reported, not trusted: the audit's point is that this can answer with the
        -- path it was handed whether or not the file exists.
        local readBack = "<none>"
        local ok, value = pcall(frame.texture.GetTexture, frame.texture)
        if ok and value ~= nil then
            readBack = tostring(value)
        end
        say(format("  %d. %s", index, path))
        say(format("     GetTexture said: %s", ns.EscapeGuard.Neutralize(readBack)))
    end

    say("  Five swatches are now above the middle of your screen, numbered 1 to 5.")
    say("  Number 5 is the shipped fallback and is known to draw, so it is the control.")
    say("  Say which numbers actually show an icon. /pa probe quests hide clears them.")
    say("  Whatever the answer, both features already work: this only changes")
    say("  ns.QUEST_MARKER_TEXTURE in Core/Constants.lua.")
end

local function commandHide()
    for index = 1, #state.frames do
        local frame = state.frames[index]
        if frame then
            frame:Hide()
        end
    end
    say("SQ1's swatches are hidden")
end

-- SQ2 ---------------------------------------------------------------------------------

local function commandLog()
    say("SQ2: does a collapsed header hide its quests from the log's index space?")
    local api = _G.C_QuestLog
    if type(api) ~= "table" or type(api.GetNumQuestLogEntries) ~= "function" then
        sayError("no C_QuestLog.GetNumQuestLogEntries on this client")
        return
    end

    local kind, shown, total = ClientRead.CallMany(api.GetNumQuestLogEntries, 2, "number")
    if kind ~= ClientRead.PLAIN then
        sayError("GetNumQuestLogEntries would not answer (" .. tostring(kind) .. ")")
        return
    end
    say(format("  numShownEntries = %d, numQuests = %d", shown, total))

    local ids, headers = {}, 0
    for index = 1, shown do
        local idKind, questId = ClientRead.Call(api.GetQuestIDForLogIndex, "number", index)
        if idKind == ClientRead.PLAIN and questId > 0 then
            ids[#ids + 1] = tostring(questId)
        else
            headers = headers + 1
        end
    end
    say(format("  the index range yielded %d quest ids and %d non-quest entries",
        #ids, headers))
    say("  ids: " .. (#ids > 0 and concat(ids, ", ") or "none"))

    if #ids == total then
        say(format("  COMPLETE: %d ids for %d quests, so nothing is hidden right now",
            #ids, total))
    else
        say(format("  SHORT BY %d: %d ids for %d quests", total - #ids, #ids, total))
    end
    say("  Now collapse a quest category in the quest log and run this again.")
    say("  If the count drops, collapsed headers hide their quests and the README")
    say("  has to say a collapsed category loses its markers. If it does not, nothing")
    say("  changes: /pa quests already reports the shortfall either way.")
end

-- Per-quest objective sources ------------------------------------------------------------
--
-- Added after the second in-game run (section 10.6), where the kill-target set held
-- three ids for a whole quest log and nothing said which source had or had not
-- contributed. This prints every source for every quest in the log, so a thin set is
-- a one-command diagnosis rather than a session of guessing.

local function countOf(value)
    if type(value) ~= "table" then
        return 0
    end
    return #value
end

local function commandObjectives()
    say("every objective source, per quest in the log")
    local api = _G.C_QuestLog
    if type(api) ~= "table" or type(_G.QuestDB) ~= "table" then
        sayError("no quest log or no QuestDB")
        return
    end
    local kind, shown, total = ClientRead.CallMany(api.GetNumQuestLogEntries, 2, "number")
    if kind ~= ClientRead.PLAIN then
        sayError("GetNumQuestLogEntries would not answer")
        return
    end
    say(format("  %d shown entries, %d quests", shown, total))

    for index = 1, shown do
        local idKind, questId = ClientRead.Call(api.GetQuestIDForLogIndex, "number", index)
        if idKind == ClientRead.PLAIN and questId > 0 then
            local nameKind, name = ClientRead.Call(_G.QuestDB.name, "string", questId)
            say(format("  quest %d: %s", questId,
                nameKind == ClientRead.PLAIN and ns.EscapeGuard.Neutralize(name) or "<no name>"))

            local ok, objectives = pcall(_G.QuestDB.objectives, questId)
            if not ok or type(objectives) ~= "table" then
                say("    objectives: none at all")
            else
                say(format("    slot1 creature=%d  slot2 object=%d  slot3 item=%d  slot5 credit=%d  slot6 spell=%d",
                    countOf(objectives[1]), countOf(objectives[2]), countOf(objectives[3]),
                    countOf(objectives[5]), countOf(objectives[6])))
                -- Slot 3's droppers are the half that was missing.
                local items = objectives[3]
                if type(items) == "table" then
                    for position = 1, #items do
                        local row = items[position]
                        if type(row) == "table" and type(row[1]) == "number" then
                            local dropOk, drops = pcall(_G.ItemDB and _G.ItemDB.npcDrops, row[1])
                            say(format("      item %d drops from %d npc(s)", row[1],
                                dropOk and countOf(drops) or -1))
                        end
                    end
                end
            end

            local extraOk, extras = pcall(_G.QuestDB.extraObjectives, questId)
            if extraOk and type(extras) == "table" and #extras > 0 then
                local monsters = 0
                for position = 1, #extras do
                    local row = extras[position]
                    if type(row) == "table" and type(row[5]) == "table" then
                        for refIndex = 1, #row[5] do
                            local reference = row[5][refIndex]
                            if type(reference) == "table" and reference[1] == "monster" then
                                monsters = monsters + 1
                            end
                        end
                    end
                end
                say(format("    extraObjectives: %d entr(ies), %d monster reference(s)",
                    #extras, monsters))
            end

            -- With names, because a bare id cannot tell you that this quest wants
            -- the Dark Runner rather than the Shadow Weaver you are standing on.
            local targets = ns.QuestieDBBridge.KillTargetsForQuest(questId)
            local named = {}
            for position = 1, #targets do
                local npcId = targets[position]
                local npcName = ns.QuestieDBBridge.NpcName(npcId)
                named[position] = npcName
                    and format("%d (%s)", npcId, ns.EscapeGuard.Neutralize(npcName))
                    or tostring(npcId)
            end
            say(format("    -> %d target npc id(s)%s", #targets,
                #named > 0 and (": " .. concat(named, ", ")) or ""))
        end
    end
    say("  Compare the last line of each quest with the mob you expected a marker on.")
end

-- Lifecycle ------------------------------------------------------------------------------

local function enable()
    state.enabled = true
    return true
end

local function disable()
    state.enabled = false
    commandHide()
end

ns.Registry.Register(FEATURE_ID, {
    enabledByDefault = false,
    internal = true,
    label = "Quest probe (Phase 17)",
    description = "Temporary. Answers Phase 17's two spike questions.",
    settings = {},
}, {
    enable = enable,
    disable = disable,
})

ns.QuestProbe = {
    Run = function(subject)
        if not state.enabled then
            local ok, reason = ns.Registry.SetEnabled(FEATURE_ID, true)
            if not ok then
                ns.Log.Error("[spike 17] could not enable the probe: " .. tostring(reason))
                return
            end
        end
        subject = (subject or ""):lower()
        if subject == "textures" then
            commandTextures()
        elseif subject == "hide" then
            commandHide()
        elseif subject == "log" then
            commandLog()
        elseif subject == "objectives" then
            commandObjectives()
        elseif subject == "clear" then
            _G.PersonalAddonSpikeLog = { spike = "Phase 17", lines = {} }
            ns.Log.Info("[spike 17] the saved report is empty again")
        elseif subject == "show" then
            local log = spikeLog()
            ns.Log.Info(format("[spike 17] %d line(s) saved", #log.lines))
            for index = 1, #log.lines do
                ns.Log.Info("  " .. tostring(log.lines[index]))
            end
        else
            ns.Log.Info("Every line is also saved to PersonalAddonSpikeLog, so the report")
            ns.Log.Info("can be read off disk after you quit -- no chat copying.")
            ns.Log.Warn("Saved variables are written on /reload or logout. A run followed by")
            ns.Log.Warn("neither leaves NOTHING behind, so finish with /reload.")
            ns.Log.Info("/pa probe quests textures   SQ1: draw the five candidate markers")
            ns.Log.Info("/pa probe quests hide       clear SQ1's swatches")
            ns.Log.Info("/pa probe quests log        SQ2: the quest log's index space")
            ns.Log.Info("/pa probe quests objectives every objective source, per quest in your log")
            ns.Log.Info("/pa probe quests show       print the saved report")
            ns.Log.Info("/pa probe quests clear      empty it before a fresh run")
        end
    end,
}
