-- Phase 7 offline checks. HARNESS_SESSION selects which set runs: "main" or
-- "withheld" (standing reads return secrets from the first read on).

local ns = HARNESS_NS
local passed, failures = 0, {}

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

local function chatMark()
    return #HARNESS.chat
end

local function chatSince(mark)
    local lines = {}
    for index = mark + 1, #HARNESS.chat do
        lines[#lines + 1] = HARNESS.chat[index]
    end
    return table.concat(lines, "\n")
end

local function near(bar, red, green, blue)
    return math.abs(bar.r - red) < 0.011 and math.abs(bar.g - green) < 0.011
        and math.abs(bar.b - blue) < 0.011
end

local function colourOf(bar)
    return string.format("%.3f %.3f %.3f", bar.r, bar.g, bar.b)
end

-- Blizzard's own colour function, as far as these checks need it: tapped grey
-- first, then red for anything on the player's threat list, then selection.
HARNESS.unitForFrame = {}
function CompactUnitFrame_UpdateHealthColor(unitFrame)
    local token = HARNESS.unitForFrame[unitFrame]
    local unit = token and HARNESS.units[token]
    if not unit then
        return
    end
    local r, g, b
    if unit.tapDenied and not unit.controlled then
        r, g, b = 0.9, 0.9, 0.9
    elseif unit.inCombat then
        r, g, b = 1, 0, 0
    elseif unit.reaction == 4 then
        r, g, b = 1, 1, 0
    else
        r, g, b = 1, 0, 0
    end
    unitFrame.healthBar:SetStatusBarColor(r, g, b)
end

local addPlate = HARNESS.addPlate
HARNESS.addPlate = function(token, unit, colour)
    local bar = addPlate(token, unit, colour)
    HARNESS.unitForFrame[HARNESS.plates[token].UnitFrame] = token
    return bar
end

-- Boot -------------------------------------------------------------------------------
HARNESS.fire("ADDON_LOADED", "PersonalAddon")
HARNESS.fire("PLAYER_LOGIN")
HARNESS.frame()

check("nameplates enabled at login", ns.Registry.State("nameplates") == "ENABLED",
    ns.Registry.State("nameplates"))

local RED, GREEN, WHITE = { 1, 0.251, 0.251 }, { 0.251, 1, 0.251 }, { 1, 1, 1 }
local GREY, YELLOW = { 0.902, 0.902, 0.902 }, { 1, 1, 0 }
local BLIZZARD_GREY, BLIZZARD_RED = { 0.9, 0.9, 0.9 }, { 1, 0, 0 }

if HARNESS_SESSION == "withheld" then
    HARNESS.secretStanding = true
    local neutral = HARNESS.addPlate("nameplate1", { canAttack = true, reaction = 4 }, YELLOW)
    local tapped = HARNESS.addPlate("nameplate2", { canAttack = true, tapDenied = true, reaction = 2 }, BLIZZARD_GREY)
    HARNESS.advance(0.3)
    local view = ns.Nameplates.Inspect()
    check("withheld: capability cached as Withheld", view.standingCapability == "Withheld",
        view.standingCapability)
    check("withheld: idle neutral falls back to Phase 2 white", near(neutral, 1, 1, 1), colourOf(neutral))
    check("withheld: idle tapped falls back to Phase 2 white", near(tapped, 1, 1, 1), colourOf(tapped))
    local all = table.concat(HARNESS.chat, "\n")
    check("withheld: surfaced once", select(2, all:gsub("withholds whether a nameplate unit is tapped", "")) == 1)
else
    -- Settings panel: the two new swatches come from the schema alone.
    local controls = table.concat(HARNESS.settingsControls, "\n")
    check("panel: tapped swatch built", controls:find("swatch:Tagged by a player outside your group", 1, true) ~= nil)
    check("panel: neutral swatch built", controls:find("swatch:Neutral, and on neither you nor your group", 1, true) ~= nil)
    check("panel: relabelled toggle", controls:find("checkbox:Colour nameplates", 1, true) ~= nil)
    check("panel: relabelled white", controls:find("swatch:Hostile, and attacking neither", 1, true) ~= nil)
    check("panel: probe not offered", controls:find("Quest watch probe", 1, true) == nil)

    -- Nameplates: every row of section 5.4 --------------------------------------------
    local bars = {
        tappedIdle = HARNESS.addPlate("nameplate1", { canAttack = true, tapDenied = true, reaction = 2 }, BLIZZARD_GREY),
        tappedOnYou = HARNESS.addPlate("nameplate2", { canAttack = true, tapDenied = true, reaction = 2, targetId = "player", inCombat = true }, BLIZZARD_GREY),
        tappedOnParty = HARNESS.addPlate("nameplate3", { canAttack = true, tapDenied = true, reaction = 2, targetId = "party1", inCombat = true }, BLIZZARD_GREY),
        neutralIdle = HARNESS.addPlate("nameplate4", { canAttack = true, reaction = 4 }, YELLOW),
        neutralOnYou = HARNESS.addPlate("nameplate5", { canAttack = true, reaction = 4, targetId = "player", inCombat = true }, BLIZZARD_RED),
        neutralOnParty = HARNESS.addPlate("nameplate6", { canAttack = true, reaction = 4, targetId = "party1", inCombat = true }, BLIZZARD_RED),
        hostileIdle = HARNESS.addPlate("nameplate7", { canAttack = true, reaction = 2 }, BLIZZARD_RED),
        neutralUnknown = HARNESS.addPlate("nameplate8", { canAttack = true, reaction = 4, inCombat = true, hiddenTarget = true }, BLIZZARD_RED),
        tappedUnknown = HARNESS.addPlate("nameplate9", { canAttack = true, tapDenied = true, reaction = 2, inCombat = true, hiddenTarget = true }, BLIZZARD_GREY),
        hostileUnknown = HARNESS.addPlate("nameplate10", { canAttack = true, reaction = 2, inCombat = true, hiddenTarget = true }, BLIZZARD_RED),
        controlledTapped = HARNESS.addPlate("nameplate11", { canAttack = true, tapDenied = true, controlled = true, reaction = 2 }, BLIZZARD_RED),
        neutralOnStranger = HARNESS.addPlate("nameplate12", { canAttack = true, reaction = 4, targetId = "stranger", inCombat = true }, BLIZZARD_RED),
    }
    HARNESS.advance(0.3)

    check("tapped, idle: grey", near(bars.tappedIdle, unpack(GREY)), colourOf(bars.tappedIdle))
    check("tapped, hitting you: RED", near(bars.tappedOnYou, unpack(RED)), colourOf(bars.tappedOnYou))
    check("tapped, on party: grey", near(bars.tappedOnParty, unpack(GREY)), colourOf(bars.tappedOnParty))
    check("neutral, idle: yellow", near(bars.neutralIdle, unpack(YELLOW)), colourOf(bars.neutralIdle))
    check("neutral, hitting you: red", near(bars.neutralOnYou, unpack(RED)), colourOf(bars.neutralOnYou))
    check("neutral, on party: green", near(bars.neutralOnParty, unpack(GREEN)), colourOf(bars.neutralOnParty))
    check("hostile, idle: white", near(bars.hostileIdle, unpack(WHITE)), colourOf(bars.hostileIdle))
    check("neutral, aggro unknown: Blizzard's colour kept", near(bars.neutralUnknown, unpack(BLIZZARD_RED)), colourOf(bars.neutralUnknown))
    check("tapped, aggro unknown: grey", near(bars.tappedUnknown, unpack(GREY)), colourOf(bars.tappedUnknown))
    check("hostile, aggro unknown: Blizzard's colour kept", near(bars.hostileUnknown, unpack(BLIZZARD_RED)), colourOf(bars.hostileUnknown))
    check("player-controlled is never tap-denied: white", near(bars.controlledTapped, unpack(WHITE)), colourOf(bars.controlledTapped))
    check("neutral, on a stranger: yellow", near(bars.neutralOnStranger, unpack(YELLOW)), colourOf(bars.neutralOnStranger))

    local view = ns.Nameplates.Inspect()
    local v = view.verdicts
    check("verdict counts", v.OnPlayer == 2 and v.TapDenied == 3 and v.OnGroupOrPet == 1
        and v.Neutral == 2 and v.Elsewhere == 2 and v.Ceded == 2,
        string.format("onPlayer=%s tapDenied=%s group=%s neutral=%s elsewhere=%s ceded=%s",
            tostring(v.OnPlayer), tostring(v.TapDenied), tostring(v.OnGroupOrPet),
            tostring(v.Neutral), tostring(v.Elsewhere), tostring(v.Ceded)))
    check("standing readable", view.standingCapability == "Readable", view.standingCapability)

    -- Criterion 5: with default colours, Blizzard repainting idle tapped and neutral
    -- plates is not a contest. Criterion 7's shape: a green plate Blizzard repaints red is.
    CompactUnitFrame_UpdateHealthColor(HARNESS.plates.nameplate1.UnitFrame)
    CompactUnitFrame_UpdateHealthColor(HARNESS.plates.nameplate4.UnitFrame)
    check("idle tapped and neutral do not contest", ns.Nameplates.Inspect().contested == 0,
        ns.Nameplates.Inspect().contested)
    CompactUnitFrame_UpdateHealthColor(HARNESS.plates.nameplate6.UnitFrame)
    check("green plate repainted red is contested", ns.Nameplates.Inspect().contested == 1,
        ns.Nameplates.Inspect().contested)
    check("contested plate corrected in the same frame", near(bars.neutralOnParty, unpack(GREEN)), colourOf(bars.neutralOnParty))

    local mark = chatMark()
    slash("plates")
    local plates = chatSince(mark)
    check("/pa plates prints verdicts", plates:find("verdicts: onPlayer=2 tapDenied=3 onGroupOrPet=1 neutral=2 elsewhere=2 ceded=2", 1, true) ~= nil, plates)
    check("/pa plates prints contested", plates:find("contested=1", 1, true) ~= nil, plates)

    -- yieldSelectedTarget cedes the selected plate whatever its standing.
    HARNESS.selectedTarget = "nameplate1"
    slash("set nameplates yieldSelectedTarget true")
    CompactUnitFrame_UpdateHealthColor(HARNESS.plates.nameplate1.UnitFrame)
    HARNESS.advance(0.3)
    check("yield: selected tapped plate ceded", ns.Nameplates.Inspect().verdicts.Ceded == 3,
        ns.Nameplates.Inspect().verdicts.Ceded)
    check("yield: shows Blizzard's grey", near(bars.tappedIdle, unpack(BLIZZARD_GREY)), colourOf(bars.tappedIdle))
    slash("set nameplates yieldSelectedTarget false")
    HARNESS.selectedTarget = nil
    HARNESS.advance(0.3)

    -- A mob becoming tapped is picked up by the next sweep.
    HARNESS.units.nameplate7.tapDenied = true
    HARNESS.advance(0.3)
    check("becomes tapped: grey next sweep", near(bars.hostileIdle, unpack(GREY)), colourOf(bars.hostileIdle))

    -- Palette change applies live.
    slash("set nameplates colourNeutral ffcc00")
    check("neutral colour change applied", near(bars.neutralIdle, 1, 0.8, 0), colourOf(bars.neutralIdle))

    -- Colouring off restores every state, the new ones included.
    slash("set nameplates aggroColouring false")
    check("off: tapped restored to Blizzard's grey", near(bars.tappedIdle, unpack(BLIZZARD_GREY)), colourOf(bars.tappedIdle))
    check("off: neutral restored to Blizzard's yellow", near(bars.neutralIdle, unpack(YELLOW)), colourOf(bars.neutralIdle))
    check("off: tapped-on-you restored", near(bars.tappedOnYou, unpack(BLIZZARD_GREY)), colourOf(bars.tappedOnYou))
    slash("set nameplates aggroColouring true")
    slash("set nameplates colourNeutral ffff00")
    HARNESS.advance(0.3)

end

-- Report ---------------------------------------------------------------------------------
local errors = {}
for _, line in ipairs(HARNESS.chat) do
    if line:find("raised", 1, true) or line:find("faulted", 1, true) then
        errors[#errors + 1] = line
    end
end
HARNESS_RESULT = { passed = passed, failures = failures, errors = errors, chat = HARNESS.chat }
