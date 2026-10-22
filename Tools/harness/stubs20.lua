-- Offline stand-ins for Phase 20 (Architecture/20261021-Phase20.md section 16.1).
-- Loaded after every earlier stub file, for every session. Everything here WRAPS;
-- nothing replaces. Phase 19's lesson: an earlier session asserts on the old stub,
-- and replacing it silently retires that check.
--
-- Knobs, by subject:
--
--   HARNESS.spellCosts[spellId]   what C_Spell.GetSpellPowerCost answers: nil answers
--                                 NOTHING (the documented answer for a free spell), a
--                                 table is returned as is, HARNESS.SECRET is withheld,
--                                 "raise" raises
--
--   HARNESS.meterSpells           a list of {spellID=, totalAmount=, amountPerSecond=};
--                                 nil falls through to stubs8's two spells
--   HARNESS.meterTotal            the session's own totalAmount (default: the sum)
--   HARNESS.meterDuration         a number, "secret", or nil for stubs8's 10
--   HARNESS.meterEmpty            the session source answers nothing (no fight yet)
--   HARNESS.meterOff              IsDamageMeterAvailable answers false
--
--   unit.friend / friendSecret    what UnitIsFriend("player", unit) answers
--   HARNESS.npcRoles[npcId]       NpcDB.subName's answer, read BY NAME on every call
--   HARNESS.npcRoleRaises[npcId]  subName raises for that NPC
--   HARNESS.subNamePresent        false removes NpcDB.subName
--
--   HARNESS.justifyRefuse         "read": a name's GetJustifyH answers nil
--                                 "write": SetJustifyH is a silent no-op
--                                 "raise": SetJustifyH raises
--
--   HARNESS.interactionSecret     IsInteractingWithNpcOfType answers a withheld value
--   HARNESS.moneySecret           GetMoney answers a withheld value

-- The player's mana bar ---------------------------------------------------------------------
--
-- Every real client has one. Until Phase 20 only phase9 built it, so the five-second
-- rule declined at enable in every other session, and nobody saw that because
-- fiveSecondRule was not in run.py's WATCHED. Section 16.1 adds it there, which makes
-- the decline an error line in 23 sessions; the fix is the client's shape, not a
-- narrower watch. A session that builds its own (tests9.lua:109) replaces this one.
if not _G.PlayerFrameManaBar then
    local manaBar = CreateFrame("StatusBar", "PlayerFrameManaBar", PlayerFrame)
    manaBar:SetWidth(120)
    manaBar:SetHeight(10)
end

-- Spell costs ------------------------------------------------------------------------------

HARNESS.spellCosts = {}
HARNESS.spellCostCalls = 0

C_Spell = C_Spell or {}
C_Spell.GetSpellPowerCost = function(spellId)
    HARNESS.spellCostCalls = HARNESS.spellCostCalls + 1
    local cost = HARNESS.spellCosts[spellId]
    if cost == "raise" then
        error("GetSpellPowerCost refused")
    end
    return cost
end

-- The damage meter -------------------------------------------------------------------------

-- Fresh tables per call, as the client's are: a test that mutated what it was handed
-- would be testing its own fixture.
local function meterEntriesCopy()
    local out = {}
    for index, entry in ipairs(HARNESS.meterSpells) do
        out[index] = {
            spellID = entry.spellID,
            totalAmount = entry.totalAmount,
            amountPerSecond = entry.amountPerSecond,
        }
    end
    return out
end

local priorMeterAvailable = C_DamageMeter.IsDamageMeterAvailable
C_DamageMeter.IsDamageMeterAvailable = function(...)
    if HARNESS.meterOff then
        return false
    end
    return priorMeterAvailable(...)
end

local priorSessionSource = C_DamageMeter.GetCombatSessionSourceFromType
C_DamageMeter.GetCombatSessionSourceFromType = function(...)
    if HARNESS.meterEmpty then
        return nil
    end
    if HARNESS.meterSpells == nil then
        return priorSessionSource(...)
    end
    local sum = 0
    for _, entry in ipairs(HARNESS.meterSpells) do
        sum = sum + entry.totalAmount
    end
    return { totalAmount = HARNESS.meterTotal or sum, combatSpells = meterEntriesCopy() }
end

local priorDuration = C_DamageMeter.GetSessionDurationSeconds
C_DamageMeter.GetSessionDurationSeconds = function(...)
    if HARNESS.meterDuration == "secret" then
        return HARNESS.SECRET
    end
    if HARNESS.meterDuration ~= nil then
        return HARNESS.meterDuration
    end
    return priorDuration(...)
end

-- Entries from {spellId, total} pairs over one duration, each rate total / duration.
function HARNESS.meterFight(pairs_, duration, sessionTotal)
    local entries = {}
    for index, pair in ipairs(pairs_) do
        entries[index] = {
            spellID = pair[1],
            totalAmount = pair[2],
            amountPerSecond = pair[2] / duration,
        }
    end
    HARNESS.meterSpells = entries
    HARNESS.meterTotal = sessionTotal
    HARNESS.meterDuration = duration
    HARNESS.meterEmpty = false
    HARNESS.meterOff = false
end

-- Friendliness -----------------------------------------------------------------------------

-- Defaults to false, so every older session draws no role.
HARNESS.unitIsFriendCalls = 0
local priorUnitIsFriend = UnitIsFriend
function UnitIsFriend(left, right)
    HARNESS.unitIsFriendCalls = HARNESS.unitIsFriendCalls + 1
    local unit = HARNESS.resolve(right)
    if unit and unit.friendSecret then
        return HARNESS.SECRET
    end
    if unit and unit.friend ~= nil then
        return unit.friend == true
    end
    if priorUnitIsFriend then
        return priorUnitIsFriend(left, right)
    end
    return false
end

-- QuestieDB's subName ----------------------------------------------------------------------
--
-- Read by name on EVERY call. stubs17's getters close over the table they were built
-- with, which is the memory note's aliasing trap: replacing HARNESS.npcNames after a
-- build changes nothing the getter sees. This one cannot be caught that way.

HARNESS.npcRoles = {}
HARNESS.npcRoleRaises = {}
HARNESS.subNamePresent = true
HARNESS.subNameCalls = 0
HARNESS.friendlyToFactionCalls = 0

local priorBuildQuestie = HARNESS.buildQuestie
HARNESS.buildQuestie = function()
    priorBuildQuestie()
    if not NpcDB then
        return
    end
    if HARNESS.subNamePresent then
        NpcDB.subName = function(npcId)
            HARNESS.subNameCalls = HARNESS.subNameCalls + 1
            if HARNESS.npcRoleRaises[npcId] then
                error("subName raised")
            end
            return HARNESS.npcRoles[npcId]
        end
    else
        NpcDB.subName = nil
    end
    -- QuestieDB's own faction test is written for its two factions' race masks.
    -- Section 7.2 gates on the client's UnitIsFriend instead; any call here is a
    -- regression (R11).
    NpcDB.friendlyToFaction = function()
        HARNESS.friendlyToFactionCalls = HARNESS.friendlyToFactionCalls + 1
        error("friendlyToFaction must never be called")
    end
end
HARNESS.buildQuestie()

-- A nameplate's name -----------------------------------------------------------------------
--
-- stubs8's regions have SetJustifyH and no GetJustifyH, and their metatable answers
-- any unknown PascalCase method with a silent no-op -- so a check reading GetJustifyH
-- would read nil and pass for the wrong reason (the Phase 12, 18 and 19 note). This
-- region is its own table with both methods real, and a log of every write.

HARNESS.justifyRefuse = nil
HARNESS.justifyWrites = 0

function HARNESS.newNameRegion(initial)
    local region = { justifyH = initial or "CENTER", writes = {}, shown = true }
    function region:GetJustifyH()
        if HARNESS.justifyRefuse == "read" then
            return nil
        end
        return self.justifyH
    end
    function region:SetJustifyH(value)
        HARNESS.justifyWrites = HARNESS.justifyWrites + 1
        self.writes[#self.writes + 1] = value
        if HARNESS.justifyRefuse == "raise" then
            error("SetJustifyH refused")
        end
        if HARNESS.justifyRefuse == "write" then
            return
        end
        self.justifyH = value
    end
    function region:IsShown() return self.shown end
    return region
end

-- Every plate gets a name and a showOnlyName flag. addPlate fires
-- NAME_PLATE_UNIT_ADDED before this wrap runs, so a session that wants the feature to
-- see them re-fires, as every nameplate session already does for its container.
local priorAddPlate = HARNESS.addPlate
function HARNESS.addPlate(token, unit, blizzardColour)
    local bar = priorAddPlate(token, unit, blizzardColour)
    local unitFrame = HARNESS.plates[token].UnitFrame
    unitFrame.name = unitFrame.name or HARNESS.newNameRegion()
    if unitFrame.showOnlyName == nil then
        unitFrame.showOnlyName = unit.showOnlyName == true
    end
    return bar
end

-- A complete plate -- bar, container, name -- built BEFORE NAME_PLATE_UNIT_ADDED fires
-- once, so an attach is counted once. Fields: npcId or guid, friend, friendSecret,
-- isPlayer, isPlayerSecret, guild, canAttack, reaction, showOnlyName, noName.
function HARNESS.addPlate20(token, fields)
    fields = fields or {}
    local unit = {
        id = token,
        reaction = fields.reaction or (fields.canAttack and 2 or 5),
        canAttack = fields.canAttack == true,
        friend = fields.friend,
        friendSecret = fields.friendSecret,
        isPlayer = fields.isPlayer,
        isPlayerSecret = fields.isPlayerSecret,
        guild = fields.guild,
    }
    HARNESS.units[token] = unit
    if fields.guid ~= nil then
        HARNESS.guids[token] = fields.guid
    elseif fields.npcId then
        HARNESS.guids[token] = HARNESS.creatureGuid(fields.npcId, fields.spawn)
    else
        HARNESS.guids[token] = nil
    end

    local bar = { r = 0, g = 1, b = 0 }
    function bar:GetStatusBarColor() return self.r, self.g, self.b, 1 end
    function bar:SetStatusBarColor(r, g, b) self.r, self.g, self.b = r, g, b end
    local container = { height = 13 }
    function container:GetHeight() return self.height end
    function container:SetHeight(value) self.height = value end
    function container:GetWidth() return 190 end
    local unitFrame = {
        healthBar = bar,
        HealthBarsContainer = container,
        showOnlyName = fields.showOnlyName == true,
    }
    if not fields.noName then
        unitFrame.name = HARNESS.newNameRegion()
    end
    local frame = { UnitFrame = unitFrame, namePlateUnitToken = token, unitToken = token }
    HARNESS.plates[token] = frame
    HARNESS.plateOrder[#HARNESS.plateOrder + 1] = token
    HARNESS.fire("NAME_PLATE_UNIT_ADDED", token)
    return frame
end

-- Blizzard's option tables -----------------------------------------------------------------
--
-- NamePlateConstants is new and nothing older reads it. NamePlateSetupOptions is NOT
-- defined here: no earlier stub defines it, and Phase 14's sessions assert on its
-- absence and on its replacement. A session that wants the name fields calls this,
-- which keeps whatever healthBarHeight is already there.
NamePlateConstants = NamePlateConstants or {}
NamePlateConstants.NAME_ANCHOR_STYLES = { InsideHealthBar = 1, AboveHealthBar = 2 }

function HARNESS.installNameOptions(style)
    NamePlateSetupOptions = NamePlateSetupOptions or {}
    NamePlateSetupOptions.healthBarHeight = NamePlateSetupOptions.healthBarHeight or 13
    NamePlateSetupOptions.unitNameAnchorStyle = style or NamePlateConstants.NAME_ANCHOR_STYLES.AboveHealthBar
    NamePlateSetupOptions.nameJustificationWhenAboveHealthBar = "CENTER"
end

-- One layout pass on one plate, as Blizzard runs it: UpdateAnchors writes the name's
-- alignment from the options table -- a field write here, so it is not counted as one
-- of ours -- then the post-hooks fire, UpdateAll's inside SetUnit's.
function HARNESS.layoutPass(token)
    local frame = HARNESS.plates[token]
    local unitFrame = frame and frame.UnitFrame
    if not unitFrame then
        return
    end
    if unitFrame.name then
        unitFrame.name.justifyH = (NamePlateSetupOptions
            and NamePlateSetupOptions.nameJustificationWhenAboveHealthBar) or "CENTER"
    end
    if CompactUnitFrame_UpdateAll then
        CompactUnitFrame_UpdateAll(unitFrame)
    end
    if CompactUnitFrame_SetUnit then
        CompactUnitFrame_SetUnit(unitFrame, token)
    end
end

-- The merchant -----------------------------------------------------------------------------

HARNESS.interactionSecret = false
local priorInteracting = C_PlayerInteractionManager.IsInteractingWithNpcOfType
C_PlayerInteractionManager.IsInteractingWithNpcOfType = function(...)
    if HARNESS.interactionSecret then
        return HARNESS.SECRET
    end
    return priorInteracting(...)
end
HARNESS.interactionRead = C_PlayerInteractionManager.IsInteractingWithNpcOfType

HARNESS.moneySecret = false
local priorGetMoney = GetMoney
function GetMoney(...)
    if HARNESS.moneySecret then
        return HARNESS.SECRET
    end
    return priorGetMoney(...)
end
