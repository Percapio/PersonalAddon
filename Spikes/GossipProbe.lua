-- Spikes/GossipProbe.lua
-- The Phase 5 go/no-go (§12). Phase 5's dialogue replacement is the only
-- roadmap item whose feasibility is genuinely unknown; every other phase is
-- laborious but obviously achievable. This answers the question in one session
-- instead of after four phases of committed design.
--
-- Delete this file once §12's Result is filled in. It is not the beginning of
-- Phase 5.

local ADDON_NAME, ns = ...

local FEATURE_ID = "gossipProbe"
local format, tostring = string.format, tostring

ns.GossipProbe = ns.GossipProbe or {}

local probe = {
    tokens = {},
    lastAttempt = nil,
    blocked = {},
}

local function recordBlocked(addonName, functionName)
    if addonName ~= ns.ADDON_NAME then
        return
    end
    local attempt = probe.lastAttempt or "unknown"
    probe.blocked[attempt] = functionName or "unnamed"
    ns.Log.Error(format("BLOCKED: '%s' attempt called a protected function (%s)",
        attempt, tostring(functionName)))
end

local function attemptGossip()
    if GossipFrame == nil or not GossipFrame:IsShown() then
        return false, "open a gossip window on a multi-option NPC first"
    end

    if C_GossipInfo and C_GossipInfo.GetOptions and C_GossipInfo.SelectOption then
        local options = C_GossipInfo.GetOptions()
        if type(options) ~= "table" or #options == 0 then
            return false, "this NPC exposes no gossip options"
        end
        local first = options[1]
        local identifier = first.gossipOptionID or first.gossipOptionId or 1
        probe.lastAttempt = "gossip"
        C_GossipInfo.SelectOption(identifier)
        return true, format("C_GossipInfo.SelectOption(%s) returned without error",
            tostring(identifier))
    end

    if _G.SelectGossipOption then
        local count = _G.GetNumGossipOptions and _G.GetNumGossipOptions() or 1
        if count < 1 then
            return false, "this NPC exposes no gossip options"
        end
        probe.lastAttempt = "gossip"
        _G.SelectGossipOption(1)
        return true, "SelectGossipOption(1) returned without error"
    end

    return false, "no gossip selection API on this client; Phase 5 must restyle rather than replace"
end

local function attemptAccept()
    if _G.AcceptQuest == nil then
        return false, "AcceptQuest is absent on this client"
    end
    local detail = _G.QuestFrameDetailPanel
    if detail == nil or not detail:IsShown() then
        return false, "open a quest detail page first"
    end
    probe.lastAttempt = "accept"
    _G.AcceptQuest()
    return true, "AcceptQuest() returned without error"
end

local function attemptReward()
    if _G.GetQuestReward == nil then
        return false, "GetQuestReward is absent on this client"
    end
    local rewardPanel = _G.QuestFrameRewardPanel
    if rewardPanel == nil or not rewardPanel:IsShown() then
        return false, "open a quest completion reward page first"
    end

    local choices = _G.GetNumQuestChoices and _G.GetNumQuestChoices() or 0
    probe.lastAttempt = "reward"
    _G.GetQuestReward(choices > 0 and 1 or 0)
    return true, format("GetQuestReward(%d) returned without error", choices > 0 and 1 or 0)
end

local function reportStatus()
    ns.Log.Info("gossip probe results this session:")
    local kinds = { "gossip", "accept", "reward" }
    for index = 1, #kinds do
        local kind = kinds[index]
        local blockedBy = probe.blocked[kind]
        ns.Log.Info(format("  %-7s %s", kind,
            blockedBy and ("BLOCKED at " .. blockedBy) or "no block recorded"))
    end
    ns.Log.Info("record these in Architecture/20260919-Phase01.md section 12")
    return true
end

-- Driven only by an explicit command. Nothing here runs on enable.
function ns.GossipProbe.Command(kind)
    if ns.Registry.State(FEATURE_ID) ~= ns.FEATURE_STATE.ENABLED then
        return false, "enable it first: /pa on " .. FEATURE_ID
    end

    kind = string.lower(kind or "status")

    if kind == "status" then
        return reportStatus()
    end

    if InCombatLockdown and InCombatLockdown() then
        return false, "out of combat only"
    end

    local ok, detail
    if kind == "gossip" then
        ok, detail = attemptGossip()
    elseif kind == "accept" then
        ok, detail = attemptAccept()
    elseif kind == "reward" then
        ok, detail = attemptReward()
    else
        return false, "usage: /pa probe <gossip|accept|reward|status>"
    end

    if ok then
        ns.Log.Info(detail)
        ns.Log.Info("watch for a BLOCKED line; absence of one is the pass condition")
    end
    return ok, detail
end

local function enable()
    local tokens = probe.tokens
    tokens[#tokens + 1] = ns.Dispatch.Subscribe(FEATURE_ID, "ADDON_ACTION_BLOCKED", recordBlocked)
    tokens[#tokens + 1] = ns.Dispatch.Subscribe(FEATURE_ID, "ADDON_ACTION_FORBIDDEN", recordBlocked)
    ns.Log.Info("gossip probe armed; run /pa probe gossip with a gossip window open")
    return true
end

local function disable()
    for index = #probe.tokens, 1, -1 do
        ns.Dispatch.Unsubscribe(probe.tokens[index])
        probe.tokens[index] = nil
    end
end

ns.Registry.Register(FEATURE_ID, {
    enabledByDefault = false,
    settings = {},
}, {
    enable = enable,
    disable = disable,
    onConfigChanged = function()
        return ns.CONFIG_RESULT.APPLIED
    end,
})
