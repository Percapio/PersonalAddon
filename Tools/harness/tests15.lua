-- Phase 15 offline checks (Architecture/20261010-Phase15.md section 10.1).
-- One session, "phase15". The attach path is shared, so every other nameplate
-- session exercises this incidentally and must stay green.

local ns = HARNESS_NS
local passed, failures = 0, {}
HARNESS.expectedFaults = {}

local function check(name, condition, detail)
    if condition then
        passed = passed + 1
    else
        failures[#failures + 1] = name .. (detail ~= nil and (" -- " .. tostring(detail)) or "")
    end
end

local function slash(text)
    SlashCmdList.PERSONALADDON_DEBUG(text)
end

-- The hook candidates this session needs, defined before login so the feature's
-- post-hooks install on them.
function CompactUnitFrame_SetUnit(_unitFrame, _token) end
function CompactUnitFrame_UpdateHealthColor(_unitFrame) end

NamePlateSetupOptions = { healthBarHeight = 13 }

-- Guild data, keyed by token. HARNESS.SECRET stands for a value this client will
-- not show; nil for a player with no guild.
HARNESS.guilds = {}
HARNESS.players = {}
GetGuildInfo = function(token)
    local value = HARNESS.guilds[token]
    if value == nil then
        return nil
    end
    return value, "Rank", 1
end
UnitIsPlayer = function(token)
    local value = HARNESS.players[token]
    if value == nil then
        return true
    end
    return value
end

local containers = {}
local function addPlate(token, guild, isPlayer)
    HARNESS.guilds[token] = guild
    HARNESS.players[token] = isPlayer
    HARNESS.addPlate(token, { reaction = 5, canAttack = false }, { 0, 1, 0 })
    local plate = HARNESS.plates[token]
    plate.unitToken = token
    local container = { height = 13 }
    function container:GetHeight() return self.height end
    function container:SetHeight(value) self.height = value end
    function container:GetWidth() return 190 end
    plate.UnitFrame.HealthBarsContainer = container
    containers[token] = container
    -- addPlate fired NAME_PLATE_UNIT_ADDED before the container existed, so the
    -- feature resolved none. Re-fire now that it does.
    HARNESS.fire("NAME_PLATE_UNIT_ADDED", token)
    return plate
end

local function setSetting(key, value)
    ns.ConfigStore.Set("nameplates", key, value)
    ns.Registry.NotifyConfigChanged("nameplates", key)
    HARNESS.frame()
end

HARNESS.fire("ADDON_LOADED", "PersonalAddon")
HARNESS.fire("PLAYER_LOGIN")
HARNESS.frame()
check("U1 nameplates enabled", ns.Registry.State("nameplates") == "ENABLED",
    ns.Registry.State("nameplates"))

-- U2: off by default ------------------------------------------------------------
addPlate("nameplate1", "The Silver Hand", true)
HARNESS.frame()
local view = ns.Nameplates.Inspect()
check("U2 off by default", view.guildNames == false)
check("U3 no label, no read", view.guildLabels == 0 and view.guildReadsPlain == 0,
    view.guildLabels .. "/" .. view.guildReadsPlain)

-- U4: a player with a guild ------------------------------------------------------
setSetting("guildNames", true)
view = ns.Nameplates.Inspect()
check("U4 a guild was read", view.guildReadsPlain >= 1, view.guildReadsPlain)
check("U5 a label was attached", view.guildLabels == 1, view.guildLabels)

-- U6: the text, and the trust boundary -------------------------------------------
-- The escape checks are the ones that matter most: this is the point where
-- server-delivered, player-chosen text reaches a font string.
addPlate("nameplate2", "|cffff0000Red Guild|r", true)
addPlate("nameplate3", "|Hitem:1234|h[Linked]|h", true)
addPlate("nameplate4", "Plain Name", true)
HARNESS.frame()

local texts = {}
for _, record in pairs(HARNESS.frames) do
    if record.parent == UIParent and record.text and record.text.text then
        texts[#texts + 1] = record.text.text
    end
end
local joined = table.concat(texts, "\n")
check("U6 a plain name reaches the font string whole",
    joined:find("Plain Name", 1, true) ~= nil, joined)
-- The invariant EscapeGuard actually guarantees: every pipe is part of a pair.
-- Looking for "|c" is wrong, because "||c" contains it.
local unpaired = joined:gsub("||", "")
check("U7 no unpaired pipe survives", unpaired:find("|", 1, true) == nil, unpaired)
check("U8 every pipe is doubled",
    joined:find("||cffff0000", 1, true) ~= nil
    and joined:find("||Hitem:1234", 1, true) ~= nil, joined)
check("U9 and no brackets are added",
    joined:find("<", 1, true) == nil and joined:find(">", 1, true) == nil, joined)

-- U10: a player with no guild ----------------------------------------------------
local before = ns.Nameplates.Inspect().guildReadsNoGuild
addPlate("nameplate5", nil, true)
HARNESS.frame()
view = ns.Nameplates.Inspect()
check("U10 no guild means no label", view.guildReadsNoGuild > before,
    view.guildReadsNoGuild .. " vs " .. before)

-- U11: an empty guild name is no guild -------------------------------------------
before = ns.Nameplates.Inspect().guildReadsNoGuild
addPlate("nameplate6", "", true)
HARNESS.frame()
check("U11 an empty name is no guild",
    ns.Nameplates.Inspect().guildReadsNoGuild > before)

-- U12: an NPC is answered by UnitIsPlayer, without asking about its guild --------
local guildAsked = 0
local realGetGuildInfo = GetGuildInfo
GetGuildInfo = function(token)
    guildAsked = guildAsked + 1
    return realGetGuildInfo(token)
end
addPlate("nameplate7", "Should Not Be Asked", false)
HARNESS.frame()
check("U12 an NPC gets no label",
    ns.Nameplates.Inspect().guildReadsNoGuild > 0)
check("U13 and GetGuildInfo was never called for it", guildAsked == 0, guildAsked)
GetGuildInfo = realGetGuildInfo

-- U14: a withheld guild is not "no guild" ----------------------------------------
before = ns.Nameplates.Inspect().guildReadsWithheld
addPlate("nameplate8", HARNESS.SECRET, true)
HARNESS.frame()
view = ns.Nameplates.Inspect()
check("U14 a secret guild is withheld, not NoGuild",
    view.guildReadsWithheld > before, view.guildReadsWithheld)

-- U15: a withheld UnitIsPlayer stops before the guild read -----------------------
guildAsked = 0
realGetGuildInfo = GetGuildInfo
GetGuildInfo = function(token)
    guildAsked = guildAsked + 1
    return realGetGuildInfo(token)
end
local realUnitIsPlayer = UnitIsPlayer
UnitIsPlayer = function(token)
    if token == "nameplate9" then return HARNESS.SECRET end
    return realUnitIsPlayer(token)
end
addPlate("nameplate9", "Never Read", true)
HARNESS.frame()
check("U15 a secret UnitIsPlayer asks nothing about the guild", guildAsked == 0, guildAsked)
UnitIsPlayer = realUnitIsPlayer
GetGuildInfo = realGetGuildInfo

-- U16: GetGuildInfo missing -------------------------------------------------------
local saved = GetGuildInfo
GetGuildInfo = nil
before = ns.Nameplates.Inspect().guildReadsUnavailable
addPlate("nameplate10", "Unreachable", true)
HARNESS.frame()
view = ns.Nameplates.Inspect()
check("U16 a missing API is Unavailable", view.guildReadsUnavailable > before,
    view.guildReadsUnavailable)
check("U17 and the colour path still runs", view.sweeps >= 0)
GetGuildInfo = saved

-- U18: a plate recycled onto another unit ------------------------------------------
HARNESS.guilds["nameplate1"] = "A Different Guild"
HARNESS.fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
HARNESS.frame()
HARNESS.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
HARNESS.frame()
local found = false
for _, record in pairs(HARNESS.frames) do
    if record.text and record.text.text == "A Different Guild" then found = true end
end
check("U18 a recycled plate shows the new occupant's guild", found)

-- U19: PLAYER_GUILD_UPDATE, the audit's finding 3 ----------------------------------
before = ns.Nameplates.Inspect().guildRefreshes
HARNESS.guilds["nameplate4"] = "Joined A Guild"
HARNESS.fire("PLAYER_GUILD_UPDATE", "nameplate4")
HARNESS.frame()
view = ns.Nameplates.Inspect()
check("U19 the event is counted once", view.guildRefreshes == before + 1,
    view.guildRefreshes .. " vs " .. (before + 1))
found = false
for _, record in pairs(HARNESS.frames) do
    if record.text and record.text.text == "Joined A Guild" then found = true end
end
check("U20 a guild changed in view is picked up", found)

HARNESS.guilds["nameplate4"] = nil
HARNESS.fire("PLAYER_GUILD_UPDATE", "nameplate4")
HARNESS.frame()
found = false
for _, record in pairs(HARNESS.frames) do
    if record.shown and record.text and record.text.text == "Joined A Guild" then
        found = true
    end
end
check("U21 a guild lost in view releases the label", not found)

-- U22: the font size reaches every label the pool built ----------------------------
setSetting("guildFontSize", 16)
local wrongSize, seenSizes = 0, 0
for _, record in pairs(HARNESS.frames) do
    if record.parent == UIParent and record.text and record.height ~= nil
        and record.text.textHeight ~= nil then
        seenSizes = seenSizes + 1
        if record.text.textHeight ~= 16 then
            wrongSize = wrongSize + 1
        end
    end
end
check("U22 some labels were found to check", seenSizes > 0, seenSizes)
check("U23 every label the pool built carries the new size", wrongSize == 0, wrongSize)
setSetting("guildFontSize", 10)

-- U24: the schema bounds it ---------------------------------------------------------
check("U24 the size is bounded",
    ns.ConfigSchema.Validate("nameplates", "guildFontSize", 5) == nil
    and ns.ConfigSchema.Validate("nameplates", "guildFontSize", 17) == nil
    and ns.ConfigSchema.Validate("nameplates", "guildFontSize", 10) == 10)

-- U25: turning it off releases everything at once ------------------------------------
setSetting("guildNames", false)
check("U25 off releases every label", ns.Nameplates.Inspect().guildLabels == 0,
    ns.Nameplates.Inspect().guildLabels)
setSetting("guildNames", true)
check("U26 on reads every tracked plate again",
    ns.Nameplates.Inspect().guildLabels > 0, ns.Nameplates.Inspect().guildLabels)

-- U27: no label is parented to a nameplate -------------------------------------------
local underPlate = 0
for _, record in pairs(HARNESS.frames) do
    if record.text and record.parent ~= UIParent and record.parent ~= nil then
        for _, plate in pairs(HARNESS.plates) do
            if record.parent == plate or record.parent == plate.UnitFrame then
                underPlate = underPlate + 1
            end
        end
    end
end
check("U27 no label sits under a nameplate (rule 6)", underPlate == 0, underPlate)

-- U28: /pa plates reports it -----------------------------------------------------------
local mark = #HARNESS.chat
slash("plates")
local said = false
for index = mark + 1, #HARNESS.chat do
    if tostring(HARNESS.chat[index]):find("guild names: on", 1, true) then
        said = true
    end
end
check("U28 /pa plates reports the setting", said)

setSetting("guildNames", false)
mark = #HARNESS.chat
slash("plates")
said = false
for index = mark + 1, #HARNESS.chat do
    if tostring(HARNESS.chat[index]):find("guild names: off", 1, true) then
        said = true
    end
end
check("U29 and says so when off", said)

-- U30: disable releases everything ------------------------------------------------------
setSetting("guildNames", true)
ns.Registry.SetEnabled("nameplates", false)
HARNESS.frame()
check("U30 disable released every label",
    ns.Nameplates.Inspect().guildLabels == 0, ns.Nameplates.Inspect().guildLabels)

-- U31: the spike is gone -----------------------------------------------------------------
check("U31 the spike's route is deleted", ns.GuildNameProbe == nil)

-- Report ---------------------------------------------------------------------------------
local errors = {}
for _, line in ipairs(HARNESS.chat) do
    if line:find("raised", 1, true) or line:find("faulted", 1, true) then
        errors[#errors + 1] = line
    end
end
HARNESS_RESULT = { passed = passed, failures = failures, errors = errors, chat = HARNESS.chat }
