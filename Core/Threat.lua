-- Core/Threat.lua
-- Who a mob is attacking, its standing, and the colour that follows, shared by the
-- nameplates and the threat panel (Architecture/20261005-Phase11.md section 2).
--
-- Moved out of Features/Nameplates.lua so that a mob's plate and its row on the
-- threat panel are coloured by the same code: two copies would drift, and reading
-- Nameplates' internals would tie the panel to a feature that can be off. Nothing
-- here keeps per-feature state. Every read is counted in the table the caller
-- passes, its own Diagnostics table. The one cache, whether this client lets us
-- read a unit's standing, is resolved once per UI load and only read afterwards.
--
-- Threat from GAPBugs01 section 3.6; standing from Phase 7 section 5.3; the colour
-- priority from Phase 7 section 5.4, with R7's AboutToPull second (Phase 11
-- section 2.3). Every client value goes through ClientRead (README rule 10).

local ADDON_NAME, ns = ...

local Threat = {}
ns.Threat = Threat

local ClientRead = ns.ClientRead
local PLAIN, ABSENT, WITHHELD = ClientRead.PLAIN, ClientRead.ABSENT, ClientRead.WITHHELD

local tonumber, sub = tonumber, string.sub

-- Diagnostics loads after this file; the counters are only bumped at run time.
local function bump(counters, name)
    ns.Diagnostics.Bump(counters, name)
end

local AGGRO = {
    ON_PLAYER = "OnPlayer",
    ABOUT_TO_PULL = "AboutToPull",
    ON_GROUP_OR_PET = "OnGroupOrPet",
    ELSEWHERE = "Elsewhere",
    UNKNOWN = "Unknown",
}
Threat.AGGRO = AGGRO

-- Whether the mob is on anyone's threat list in the group: the threat panel lists
-- only mobs fighting you or your group (Phase 11 section 5.2).
local ENGAGEMENT = {
    ENGAGED = "Engaged",
    NOT_ENGAGED = "NotEngaged",
    COULD_NOT_TELL = "CouldNotTell",
}
Threat.ENGAGEMENT = ENGAGEMENT

-- A unit's standing is independent of whom it is attacking (Phase 7 section 5.3).
local DISPOSITION = {
    TAP_DENIED = "TapDenied",
    NEUTRAL = "Neutral",
    HOSTILE = "Hostile",
    UNREADABLE = "Unreadable",
}
Threat.DISPOSITION = DISPOSITION

-- What a bar should show. CEDED hands a plate back to Blizzard's colour.
local VERDICT = {
    ON_PLAYER = "OnPlayer",
    ABOUT_TO_PULL = "AboutToPull",
    TAP_DENIED = "TapDenied",
    ON_GROUP_OR_PET = "OnGroupOrPet",
    NEUTRAL = "Neutral",
    ELSEWHERE = "Elsewhere",
    CEDED = "Ceded",
}
Threat.VERDICT = VERDICT

local STANDING = {
    NOT_YET_READ = "NotYetRead",
    READABLE = "Readable",
    WITHHELD = "Withheld",
}
Threat.STANDING = STANDING

-- The client's reaction scale; 4 is neutral, which is what Blizzard paints yellow.
local NEUTRAL_REACTION = 4

-- The verdict colours both features paint with. The keys are the nameplates
-- feature's settings, which take their defaults from here, so the two cannot
-- disagree (Phase 11 section 2.2). A missing or malformed value takes its default.
Threat.PALETTE_KEYS = {
    { verdict = VERDICT.ON_PLAYER, key = "colourOnPlayer", default = "ff4040" },
    { verdict = VERDICT.ABOUT_TO_PULL, key = "colourAboutToPull", default = "ff8000" },
    { verdict = VERDICT.TAP_DENIED, key = "colourTapDenied", default = "e6e6e6" },
    { verdict = VERDICT.ON_GROUP_OR_PET, key = "colourOnGroup", default = "40ff40" },
    { verdict = VERDICT.NEUTRAL, key = "colourNeutral", default = "ffff00" },
    { verdict = VERDICT.ELSEWHERE, key = "colourElsewhere", default = "ffffff" },
}

-- The allies whose threat makes a monster green: your pet first, then the party
-- or the raid. Built once, so a sweep concatenates no strings (Phase 9 section 4).
local PARTY_ALLIES = { "pet", "party1", "party2", "party3", "party4" }
local RAID_ALLIES = { "pet" }
for index = 1, 40 do
    RAID_ALLIES[#RAID_ALLIES + 1] = "raid" .. index
end

local capability = {
    -- Checked on the first standing read of the UI load and cached (Phase 2
    -- section 4.7): a refusal can arrive as a log line and a nil, not an error.
    standing = STANDING.NOT_YET_READ,
}

-- Group -------------------------------------------------------------------------

-- The group's shape, read once per sweep. A raid, a party, or nobody; when the
-- roster functions are absent or withheld, a party is assumed, which costs four
-- reads of possibly empty tokens and claims nothing.
function Threat.Allies()
    local raidKind, inRaid = ClientRead.Call(IsInRaid, "boolean")
    if raidKind == PLAIN and inRaid then
        local sizeKind, size = ClientRead.Call(GetNumGroupMembers, "number")
        if sizeKind == PLAIN and size >= 1 then
            return RAID_ALLIES, math.min(size, 40) + 1
        end
        return PARTY_ALLIES, #PARTY_ALLIES
    end
    local groupKind, inGroup = ClientRead.Call(IsInGroup, "boolean")
    if groupKind == PLAIN and not inGroup then
        return PARTY_ALLIES, 1
    end
    return PARTY_ALLIES, #PARTY_ALLIES
end

-- Threat ------------------------------------------------------------------------

-- One threat read, counted by result in the caller's table. 2 and 3 mean the unit
-- is the mob's current target; nil means it is not on the mob's threat list.
function Threat.ReadStatus(unit, mobToken, counters)
    local kind, status = ClientRead.Call(UnitThreatSituation, "number", unit, mobToken)
    if kind == PLAIN then
        bump(counters, "threatReadsPlain")
    elseif kind == ABSENT then
        bump(counters, "threatReadsAbsent")
    else
        bump(counters, "threatReadsWithheld")
    end
    return kind, status
end
local readStatus = Threat.ReadStatus

-- Who the monster is attacking, from threat, never from its target (GAPBugs01
-- section 3.6). A mob has one current target, so an ally found tanking settles it
-- even when the player's own read was withheld. Reading stops at the first unit
-- found tanking. Returns the aggro, how many reads were withheld, and whether the
-- mob is engaged with you or your group.
--
-- R7 (Phase 11 section 3): a player at status 1 -- above the tank, not tanking --
-- is AboutToPull, and the reads stop there.
function Threat.ClassifyAggro(unitToken, allies, allyCount, counters)
    local withheld, engaged = 0, false
    local kind, status = readStatus("player", unitToken, counters)
    if kind == PLAIN then
        engaged = true
        if status >= ns.TANKING_STATUS then
            return AGGRO.ON_PLAYER, 0, ENGAGEMENT.ENGAGED
        end
        if status == ns.ABOUT_TO_PULL_STATUS then
            return AGGRO.ABOUT_TO_PULL, 0, ENGAGEMENT.ENGAGED
        end
    elseif kind == WITHHELD then
        withheld = withheld + 1
    end

    for index = 1, allyCount do
        local allyKind, allyStatus = readStatus(allies[index], unitToken, counters)
        if allyKind == PLAIN then
            engaged = true
            if allyStatus >= ns.TANKING_STATUS then
                return AGGRO.ON_GROUP_OR_PET, withheld, ENGAGEMENT.ENGAGED
            end
        elseif allyKind == WITHHELD then
            withheld = withheld + 1
        end
    end

    local engagement = ENGAGEMENT.NOT_ENGAGED
    if engaged then
        engagement = ENGAGEMENT.ENGAGED
    elseif withheld > 0 then
        engagement = ENGAGEMENT.COULD_NOT_TELL
    end
    if withheld > 0 then
        return AGGRO.UNKNOWN, withheld, engagement
    end
    return AGGRO.ELSEWHERE, 0, engagement
end

-- Your scaled threat on a mob: 100 means it is on you. The third return of
-- UnitDetailedThreatSituation, which is MayReturnNothing: Absent when you are not
-- on its threat list. Counted in the caller's table.
function Threat.ReadScaledPercent(unitToken, counters)
    local kind, percent = ClientRead.CallNth(UnitDetailedThreatSituation, 3, "number", "player", unitToken)
    if kind == PLAIN then
        bump(counters, "percentReadsPlain")
    elseif kind == ABSENT then
        bump(counters, "percentReadsAbsent")
    else
        bump(counters, "percentReadsWithheld")
    end
    return kind, percent
end

-- Standing ----------------------------------------------------------------------

-- Tapped and neutral are what Blizzard's own plates already paint grey and yellow
-- (CompactUnitFrame_UpdateHealthColor). None of the three reads carries a
-- secret-return flag in this client's generated API documentation, and Blizzard's
-- plates make the first two on every colour update. Documentation is evidence, not
-- proof, so each value goes through ClientRead before it is compared. Absent (nil)
-- is accepted as "no", the direction that claims nothing.

-- Returns tapDenied, playerControlled, reaction, readable.
local function readStanding(unitToken, counters)
    local tapKind, tapDenied = ClientRead.Call(UnitIsTapDenied, "boolean", unitToken)
    local controlKind, controlled = ClientRead.Call(UnitPlayerControlled, "boolean", unitToken)
    local reactionKind, reaction = ClientRead.Call(UnitReaction, "number", "player", unitToken)
    if tapKind == WITHHELD or controlKind == WITHHELD or reactionKind == WITHHELD then
        bump(counters, "standingReadsWithheld")
        return nil, nil, nil, false
    end
    return tapDenied == true, controlled == true, reaction, true
end

-- Once per UI load, on the first mob either feature asks about.
local function checkDispositionCapability(unitToken, counters)
    local present = type(UnitIsTapDenied) == "function"
        and type(UnitPlayerControlled) == "function"
        and type(UnitReaction) == "function"
    local readable = present and select(4, readStanding(unitToken, counters))
    if readable then
        capability.standing = STANDING.READABLE
        return
    end
    capability.standing = STANDING.WITHHELD
    ns.Log.Once("plates:standingwithheld",
        "this client withholds whether a nameplate unit is tapped or neutral; those plates keep the aggro colours")
end

-- Pre: the capability is not withheld.
local function classifyDisposition(unitToken, counters)
    local tapDenied, controlled, reaction, readable = readStanding(unitToken, counters)
    if not readable then
        -- Never claim a standing we did not read (Phase 2 section 9.0).
        return DISPOSITION.UNREADABLE
    end
    -- Mirrors CompactUnitFrame_IsTapDenied: a player or pet is never tap-denied.
    if tapDenied and not controlled then
        return DISPOSITION.TAP_DENIED
    end
    if reaction == NEUTRAL_REACTION then
        return DISPOSITION.NEUTRAL
    end
    return DISPOSITION.HOSTILE
end

function Threat.Disposition(unitToken, counters)
    if capability.standing == STANDING.NOT_YET_READ then
        checkDispositionCapability(unitToken, counters)
    end
    if capability.standing == STANDING.WITHHELD then
        return DISPOSITION.UNREADABLE
    end
    return classifyDisposition(unitToken, counters)
end

function Threat.StandingCapability()
    return capability.standing
end

-- Verdict -----------------------------------------------------------------------

-- The one place a mob's colour is decided, for both features (Phase 7 section 5.4,
-- Phase 11 section 2.3). Priority: on you, about to pull, tapped, group or pet,
-- unknown (ceded), neutral, hostile. Grey never hides a mob that is hitting you,
-- nor one you are about to pull.
--
-- Tapped is shown even when aggro is Unknown, because Blizzard paints tapped grey
-- ahead of its own threat red, so grey is exactly what ceding would show. Neutral
-- is not: there Blizzard's colour carries threat-list membership we could not
-- read, and yellow would claim "not on you". Unreadable behaves as Hostile.
function Threat.ResolveVerdict(aggro, disposition)
    if aggro == AGGRO.ON_PLAYER then
        return VERDICT.ON_PLAYER
    end
    if aggro == AGGRO.ABOUT_TO_PULL then
        return VERDICT.ABOUT_TO_PULL
    end
    if disposition == DISPOSITION.TAP_DENIED then
        return VERDICT.TAP_DENIED
    end
    if aggro == AGGRO.ON_GROUP_OR_PET then
        return VERDICT.ON_GROUP_OR_PET
    end
    if aggro == AGGRO.UNKNOWN then
        return VERDICT.CEDED
    end
    if disposition == DISPOSITION.NEUTRAL then
        return VERDICT.NEUTRAL
    end
    return VERDICT.ELSEWHERE
end

-- Palette -----------------------------------------------------------------------

-- Nil when hex is not six hexadecimal digits.
local function hexToColour(hex)
    if type(hex) ~= "string" or #hex < 6 then
        return nil
    end
    local red = tonumber(sub(hex, 1, 2), 16)
    local green = tonumber(sub(hex, 3, 4), 16)
    local blue = tonumber(sub(hex, 5, 6), 16)
    if not red or not green or not blue then
        return nil
    end
    return { red = red / 255, green = green / 255, blue = blue / 255, alpha = 1 }
end

-- Every verdict but Ceded, from a settings table holding PALETTE_KEYS' keys.
function Threat.PaletteFrom(settings)
    local palette = {}
    local keys = Threat.PALETTE_KEYS
    for index = 1, #keys do
        local entry = keys[index]
        palette[entry.verdict] = hexToColour(settings and settings[entry.key]) or hexToColour(entry.default)
    end
    return palette
end

-- The colour settings with their defaults, for the nameplates feature's declaration.
function Threat.PaletteDefaults()
    local defaults = {}
    local keys = Threat.PALETTE_KEYS
    for index = 1, #keys do
        defaults[keys[index].key] = keys[index].default
    end
    return defaults
end
