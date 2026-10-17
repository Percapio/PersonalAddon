-- Core/Constants.lua
-- Every tunable number lives here, named, so a beta patch that moves one is a
-- one-line change rather than a hunt through a phase calculation (§11.5).

local ADDON_NAME, ns = ...

ns.ADDON_NAME = ADDON_NAME
ns.VERSION = "1.9.0-phase19"

ns.SAVED_VARIABLE = "PersonalAddonDB"
ns.QUARANTINE_KEY = "quarantinedStore"
ns.CHAT_PREFIX = "|cff66ccffPersonalAddon|r: "

ns.CURRENT_SCHEMA_VERSION = 1

-- The five-second rule's length is server behaviour we cannot query, so it is
-- an assumed value recorded in one place (Architecture section 11.5).
--
-- The tick period, energize correlation window and energize ring size are gone
-- with the tick-phase design: this client protects power values, so there is no
-- observable tick. See Architecture section 11.1a.
ns.FSR_WINDOW = 5.0

ns.FEATURE_STATE = {
    REGISTERED = "REGISTERED",
    DISABLED = "DISABLED",
    ENABLING = "ENABLING",
    ENABLED = "ENABLED",
    FAULTED = "FAULTED",
}

ns.DROP_POLICY = {
    SURFACE_AND_FAIL = "SURFACE_AND_FAIL",
    RECYCLE_OLDEST = "RECYCLE_OLDEST",
}

-- onConfigChanged return values (§6.2). RELOAD_REQUIRED is not a failure.
ns.CONFIG_RESULT = {
    APPLIED = "APPLIED",
    RELOAD_REQUIRED = "RELOAD_REQUIRED",
}

-- Two states, not three. UNKNOWN existed to model "the phase estimate is
-- unrecoverable"; with no phase to estimate, not-in-window IS regenerating.
ns.TRACKER_STATE = {
    REGENERATING = "REGENERATING",
    IN_FSR = "IN_FSR",
}

-- Enum.PowerType exists on the modern client codebase; 0 is the correct
-- fallback value for mana on every client that lacks it.
ns.POWER_TYPE_MANA = (Enum and Enum.PowerType and Enum.PowerType.Mana) or 0

-- Phase 8 (Architecture/20260927-Phase08.md) ----------------------------------

-- Toasts waiting for a free slot, beyond which a new one is dropped and counted.
ns.TOAST_QUEUE_CAPACITY = 10
-- The toast pool. Equal to the largest maximumVisible the schema allows, so the
-- visible toasts can never exhaust it (section 6.2).
ns.TOAST_POOL_CAPACITY = 5
-- Loot messages waiting for the next frame (section 6.3).
ns.LOOT_INBOX_CAPACITY = 20
-- Loot deliveries per session whose stack is read, to check that no Blizzard Lua
-- raised them (section 6.5).
ns.STACK_CHECK_DELIVERIES = 20
-- Skills window rows: two professions, three weapon slots and Defense fit in six.
ns.SKILL_ROW_CAPACITY = 8
-- How long a sale may take to settle before it is reported as it stands (7.2).
ns.VEND_SETTLE_SECONDS = 3
-- Blizzard's own Skills tab keeps this as a file-local, so it cannot be read by
-- name (Camelot/SkillsFrame.lua:34).
ns.DEFENSE_SKILL_LINE = 95
-- The icon Blizzard's pet bar uses for Defensive on this client (PetActionBar.lua:3).
ns.DEFENSE_ICON = "Interface\\Icons\\Ability_Defend"

-- Phase 9 (Architecture/20261002-Phase09.md) ----------------------------------

-- Diagnostics: UI loads kept in PersonalAddonDiagnostics, fault notes kept per UI
-- load, and the length each note is cut to (section 3.3).
ns.DIAGNOSTICS_FORMAT_VERSION = 1
ns.DIAGNOSTICS_SESSION_CAPACITY = 5
ns.DIAGNOSTICS_FAULT_NOTE_CAPACITY = 8
ns.DIAGNOSTICS_FAULT_NOTE_LENGTH = 300
-- The client's threat scale: 2 and 3 mean the unit is the mob's current target.
-- A client fact, not a preference (GAPBugs01 section 3.6).
ns.TANKING_STATUS = 2
-- Status 1: your threat is above the tank's and the mob is not on you yet. A
-- client fact (Phase 11 section 3).
ns.ABOUT_TO_PULL_STATUS = 1
-- Every eighth nameplate sweep asks whether this is an addon-restricted map: once
-- every two seconds at the default interval (section 4.2).
ns.RESTRICTION_SAMPLE_EVERY = 8
-- A refusal storm: this many refusals within this many seconds. Twenty is far
-- above any one panel change (a handful at most) and far below the 2026-10-02
-- storm's eight a second (section 6.2).
ns.STORM_REFUSALS = 20
ns.STORM_WINDOW_SECONDS = 10
ns.STORM_FUNCTION_CAPACITY = 16

-- Phase 11 (Architecture/20261005-Phase11.md) ---------------------------------

-- The threat panel's row pool, built at enable. Above the largest maximumRows the
-- schema allows (10), so no setting can exhaust it during a fight (section 5.5).
ns.THREAT_ROW_CAPACITY = 16

-- Phase 12 (Architecture/20261006-Phase12.md) ---------------------------------

-- The pages of the settings menu, in the order they appear under PersonalAddon
-- (section 3.1). General is the parent page itself. A feature names its page in
-- its registration; one that names none goes on the parent page.
ns.SETTINGS_PAGE = {
    GENERAL = "General",
    COMBAT = "Combat",
    NAMEPLATES = "Nameplates",
    BAGS_AND_LOOT = "BagsAndLoot",
    CONSUMABLES = "Consumables",
    QUESTS = "Quests",
}
-- After every declared settingsOrder, so an unplaced feature sorts last, in
-- registration order.
ns.SETTINGS_UNPLACED_ORDER = 1000

-- Phase 13 (Architecture/20261009-Phase13.md) ---------------------------------

-- The windows the preview knows, and the places on screen they are drawn in
-- (section 2.2). The static table that maps one to the other lives in
-- Core/Preview.lua; these are the names both it and the features use.
ns.PREVIEW_PANEL = {
    THREAT_PANEL = "ThreatPanel",
    DAMAGE_BREAKDOWN = "DamageBreakdown",
    EQUIPPED_SKILLS = "EquippedSkills",
    TOASTS = "Toasts",
}
ns.PREVIEW_GROUP = {
    PLAYER_FRAME = "PlayerFrame",
    BAGS = "Bags",
    SCREEN = "Screen",
}
-- Which window the player-frame group shows before anything has been adjusted.
-- The threat panel: it has the most geometry to set, and it is the one Phase 13
-- exists for (section 2.5).
ns.PREVIEW_INITIAL_FOCUS = ns.PREVIEW_PANEL.THREAT_PANEL
-- Above Blizzard's settings window, which is HIGH (section 3.1).
ns.PREVIEW_STRATA = "DIALOG"
-- The skills window's preview draws a fixed six rows. Its live height is what
-- you have equipped, behind reads that can be withheld, and width is what this
-- phase adjusts (section 5.4).
ns.PREVIEW_SKILL_ROWS = 6
-- Two samples: enough to show the stacking, few enough that the default
-- maximumVisible of 3 leaves a slot free, so the first real toast evicts
-- nothing (section 5.5).
ns.PREVIEW_TOAST_SAMPLES = 2

-- The threat panel's narrowest width: 10% under the player frame's health bar.
-- That bar is 124 x 20, declared in XML at
-- Blizzard_UnitFrame/Mainline/PlayerFrame.xml lines 124 and 173 and resized
-- nowhere in Lua, so 124 * 0.9 rounds to 112 (section 6.1, decision D7). The
-- fact about Blizzard's bar is in the patch check's register as
-- PLAYER-HEALTH-BAR-WIDTH, because this number is only right while it holds.
ns.THREAT_PANEL_MINIMUM_WIDTH = 112
ns.THREAT_PANEL_MAXIMUM_WIDTH = 400
-- A CONSEQUENCE of the line above, not a judgement about how narrow a bar may
-- usefully be: at the minimum width, with the level tag shown, this is what is
-- left for the bar.
ns.THREAT_BAR_MINIMUM = 22
-- Below this much bar the mob name is hidden rather than truncated to nothing.
-- Roughly six characters at GameFontHighlightSmall. A legibility floor, not a
-- preference (section 6.3, decision D8).
ns.THREAT_NAME_MINIMUM_BAR = 40

-- The skills window's width bounds. The minimum is padding, icon, gap and the
-- least the rank text can have; the maximum is generous for
-- "Blacksmithing 300 / 300" (section 6.1).
ns.SKILL_PANEL_MINIMUM_WIDTH = 74
ns.SKILL_PANEL_MAXIMUM_WIDTH = 240
ns.SKILL_TEXT_MINIMUM = 44

-- Phase 14 (Architecture/20261010-Phase14.md) ---------------------------------

-- The floor on a health bar's height, in pixels. It bounds the RESULT where
-- barHeightFraction bounds the intent: 30% of the smallest base Blizzard can
-- produce (8px, the Classic style at Small scale) is 2.4px, which is a line and
-- not a bar (section 5.3).
ns.MINIMUM_BAR_PIXELS = 4

-- Phase 15 (Architecture/20261010-Phase15.md) ---------------------------------

-- One guild label per nameplate, from our own pool. Bounded by the client's
-- nameplate cap, which Phase 2 already assumes bounds the tracked set; the
-- threat panel's row pool is sized the same way. Exhaustion means the cap is
-- wrong and is reported, never absorbed (section 4.6).
ns.GUILD_LABEL_POOL_CAPACITY = 48
-- The guild line's size, in points. Absolute rather than a share of Blizzard's,
-- because the widget is ours and nothing else writes it (section 4.4).
ns.GUILD_FONT_MINIMUM = 6
ns.GUILD_FONT_MAXIMUM = 16
ns.GUILD_FONT_DEFAULT = 10
-- Pixels between the health bar's bottom edge and the guild line.
ns.GUILD_LABEL_GAP = 1
-- The guild line is secondary, and the faded white is what says so -- which is
-- why there are no brackets around the name (section 4.3).
ns.GUILD_LABEL_ALPHA = 0.7
-- Phase 18 section 2: the outline is what keeps the line legible at that alpha
-- over a bright nameplate, so the two belong together rather than as two
-- switches. THICKOUTLINE is not used: at GUILD_FONT_MINIMUM it leaves almost no
-- letter. Whether this client's SetFont accepts the flag at all is an in-game
-- fact -- the flags argument is typed TBFFlags and nothing in the UI export
-- defines that type -- so SetFont's success return is read rather than assumed.
ns.GUILD_LABEL_OUTLINE_FLAG = "OUTLINE"

-- Phase 16 (Architecture/20261011-Phase16.md) ---------------------------------

-- The macro kinds, and the order a name collision is settled in: the first kind
-- here that holds a name keeps it (section 5.5). Heal leads because it is the one
-- that matters in a fight.
ns.MACRO_KIND = {
    HEAL = "HealMacro",
    BANDAGE = "BandageMacro",
    FOOD = "FoodMacro",
    WATER = "WaterMacro",
}
ns.MACRO_KIND_ORDER = {
    ns.MACRO_KIND.HEAL,
    ns.MACRO_KIND.BANDAGE,
    ns.MACRO_KIND.FOOD,
    ns.MACRO_KIND.WATER,
}

-- What a bag item can be. Only these five reach a macro body (section 4.1).
ns.CONSUMABLE_KIND = {
    FOOD = "Food",
    DRINK = "Drink",
    HEALING_POTION = "HealingPotion",
    HEALTHSTONE = "Healthstone",
    BANDAGE = "Bandage",
}

-- The spells whose localized names identify an item's use effect. The IDs are
-- ours; every name comes from the client, so the classifier works in any locale
-- (section 4.1).
ns.CONSUMABLE_REFERENCE_SPELLS = {
    food = 433,
    drink = 430,
    healingPotion = 439,
    wellFed = 19705,
}

-- The 15 Classic healthstones. Matched by ID because their use spells carry a
-- different name at each tier, and because they count as summoned by kind.
ns.HEALTHSTONE_ITEMS = {
    [5512] = true, [19004] = true, [19005] = true,
    [5511] = true, [19006] = true, [19007] = true,
    [5509] = true, [19008] = true, [19009] = true,
    [5510] = true, [19010] = true, [19011] = true,
    [9421] = true, [19012] = true, [19013] = true,
}

-- Consumable-class items only, and emptied rather than evicted one at a time: a
-- scan sees about 100 slots, so overflow means something unusual is carried, not
-- that the cache is the wrong size (Phase 12 audit finding 4).
ns.CLASSIFICATION_CACHE_CAPACITY = 128

-- How long after entering the world the feature waits for the client to report
-- this character's macros before giving up and maintaining only what it finds by
-- name (section 5.3).
ns.MACROS_KNOWN_TIMEOUT = 60

-- Added to a cooldown's remaining time before re-planning, so the timer fires
-- after the client has cleared it rather than on the same tick (section 5.7).
ns.COOLDOWN_TIMER_SLACK = 0.2

-- Retries back off without jitter: one client, and nothing contends for the
-- write (section 5.2).
ns.MACRO_RETRY_FIRST_DELAY = 2
ns.MACRO_RETRY_MAXIMUM_DELAY = 30
ns.MACRO_RETRY_LIMIT = 20

-- A macro name the client will accept. 16 pending spike S7 (section 7).
ns.MACRO_NAME_MAXIMUM = 16

-- The question-mark icon the Macros window itself defaults to. With #showtooltip
-- the button shows the chosen item anyway (section 4.4).
ns.MACRO_DEFAULT_ICON = 134400

-- A macro body is at most this long (Blizzard_MacroUI.xml:123). The longest body
-- this feature plans is under 80, so the bound is a guard, not a budget.
ns.MACRO_BODY_MAXIMUM = 255

-- Action slots to look through when asking whether a macro sits on a bar
-- (Phase 16 section 2.9). Six pages of twelve, plus the override and special
-- ranges, is 120 on this client: NUM_ACTIONBAR_PAGES * NUM_ACTIONBAR_BUTTONS
-- (ActionButtonUtil.lua:2-5) covers the pages, and the conventional total covers
-- the rest. Read out of combat only, once per rebuild, like the bag scan.
ns.ACTION_SLOT_MAXIMUM = 120

-- Phase 17 (Architecture/20261011-Phase17.md) ---------------------------------

-- Shared empty list, returned where a caller must get a table it may read but
-- never keep. One table rather than one per miss.
ns.EMPTY_LIST = {}

-- The same idea for the claim shape the bridge answers with (Phase 19 section 3).
-- answered is false, so a caller that gets this one caches nothing.
ns.EMPTY_CLAIM_SHAPE = {
    claims = ns.EMPTY_LIST,
    extraNpcIds = ns.EMPTY_LIST,
    rowsBySlot = { [1] = 0, [2] = 0, [3] = 0, [4] = 0, [5] = 0, [6] = 0 },
    answered = false,
}

-- The QuestieDB contract this addon is written against, and the only data flavour
-- its answers mean anything for (section 2.3). RequireContract is a range check, so
-- asking for 3 keeps working as QuestieDB adds to it; the flavour gate is the one
-- RequireContract cannot do, and seven flavour TOCs sit in that folder.
ns.QUESTIE_REQUIRED_CONTRACT = 3
ns.QUESTIE_REQUIRED_FLAVOR = "Forever"

-- Entities cached per id for the UI load. QuestieDB's data is baked into a TOC and
-- static for the session, so nothing is invalidated; the cap is there because a
-- session can hover a lot of NPCs (section 2.4).
ns.QUEST_BRIDGE_CACHE_CAPACITY = 256

-- The tooltip block's header. The client's own AVAILABLE_QUEST is preferred, so the
-- header is in the player's locale like every other string this addon draws; this is
-- what it falls back to when that global is not readable (section 3.4).
ns.NPC_QUESTS_HEADER_FALLBACK = "Available Quests"

-- At most this many quest lines on one tooltip, then "+n more". A data defect
-- cannot grow a tooltip without bound (section 3.4).
ns.NPC_QUEST_LINE_CAPACITY = 10

-- The marker above a nameplate (section 4.4). A frame with one anchor and no size
-- is 0x0 and draws nothing, so the size is explicit.
ns.QUEST_MARKER_SIZE = 16
-- Settled by spike SQ1 (section 10.4): all five candidates resolved to real file
-- IDs on this client, so the question was which one MEANS it rather than which one
-- exists. This is the icon the gossip frame puts on an NPC that has a quest for
-- you, which is the same thing a marker says about a mob.
-- The question-mark fallback it replaced is Interface\Icons\INV_Misc_QuestionMark,
-- file ID 134400, still drawn by Features/Toasts.lua.
ns.QUEST_MARKER_TEXTURE = "Interface\\GossipFrame\\AvailableQuestIcon"
-- One marker per plate, sized as the guild label's pool and for the same reason:
-- the client's nameplate cap bounds the tracked set, so exhaustion means the cap
-- assumption is wrong and is reported rather than absorbed.
ns.QUEST_MARKER_POOL_CAPACITY = 48

-- Phase 18 section 3: the marker's default place, a few pixels to the LEFT of the
-- health bar. The anchor is the marker's right edge against the container's left,
-- so a negative offset moves it further out and 0 would butt it against the bar.
-- Phase 17 put it centred above the bar; that placement is NOT reachable from
-- these sliders, which is stated rather than papered over (section 3.1).
ns.QUEST_MARKER_OFFSET_X = -4
ns.QUEST_MARKER_OFFSET_Y = 0
-- Symmetric, because the vertical anchor is now the bar's centre rather than its
-- top. Phase 17's -20..40 encoded "above the bar", which the new anchor retires.
ns.QUEST_MARKER_OFFSET_LIMIT = 40

-- At most this many NPC ids from one quest. A widely-dropped quest item can name
-- a lot of creatures through ItemDB.npcDrops, and one quest should not be able to
-- fill the marker set on its own (section 4.2).
ns.QUEST_TARGETS_PER_QUEST_MAXIMUM = 64

-- Action slots are not involved here; this is the quest log's own index space
-- (section 4.2). GetNumQuestLogEntries' first return bounds it, and its second
-- return is how a short read is noticed.
ns.QUEST_LOG_INDEX_MAXIMUM = 150

-- Phase 19: objective-aware markers (Architecture/20261016-Phase19.md section 2) --------

-- QuestieDB's objectives tuple, by slot. Its Types/General.t.lua:46 types the tuple
-- as {creature[], object[], item[], reputationPair, killCredit[], spell[]} -- slot 4
-- is a SINGLE pair, not a list, which is why rowsBySlot counts it by shape rather
-- than by length (section 3).
ns.QUEST_OBJECTIVE_SLOT = {
    CREATURE_KILL = 1,
    OBJECT = 2,
    ITEM = 3,
    REPUTATION = 4,
    KILL_CREDIT = 5,
    SPELL = 6,
}

-- The order the slots appear in the client's objective list, by default. The
-- published per-quest exceptions live in LibQuestieDB.ObjectiveFirst and move one
-- slot to the front of this order (section 2.2).
ns.QUEST_OBJECTIVE_SLOT_ORDER = { 1, 2, 3, 4, 5, 6 }

-- Which LibQuestieDB.ObjectiveFirst set names which slot. eventObjectiveFirst is
-- absent on purpose: it names a client objective QuestieDB models no row for, so
-- such a quest must fail the count check rather than be reordered (section 2.2).
ns.QUEST_OBJECTIVE_FIRST_FIELDS = {
    { field = "objectObjectiveFirst", slot = 2 },
    { field = "itemObjectiveFirst", slot = 3 },
    { field = "killCreditObjectiveFirst", slot = 5 },
    { field = "spellObjectiveFirst", slot = 6 },
}

-- The client's objective type string for each QuestieDB slot. THE UNVERIFIED TABLE
-- of this phase: the UI export carries a consumer for "progressbar" only, so these
-- five strings come from outside it and /pa quests prints what the client actually
-- returned so one in-game run can correct them (section 2.2, in-game check 1).
ns.CLIENT_OBJECTIVE_TYPE_FOR_SLOT = {
    [1] = "monster",
    [2] = "object",
    [3] = "item",
    [4] = "reputation",
    [5] = "monster",
    [6] = "spell",
}

-- Objective types we know of. A type in here that contradicts its slot is a
-- TypeContradiction; a type that is not in here at all is an UnknownObjectiveType,
-- and they are different diagnoses (section 2.2).
ns.KNOWN_OBJECTIVE_TYPES = {
    monster = true, object = true, item = true, reputation = true,
    spell = true, event = true, player = true, progressbar = true,
}

-- The scope sentinel, as a scalar so a Lua table can be keyed by it: a claim with
-- no client objective behind it is satisfied only by the quest's own completion
-- (section 2.3, audit finding 2).
ns.QUEST_CLAIM_QUEST_LEVEL = 0

-- Phase 19: the rare and elite ring (section 4) ----------------------------------------

-- One ring per plate, sized as the guild label's pool and for the same reason.
ns.RARITY_RING_POOL_CAPACITY = 48

-- The ring's width as a multiple of the level badge's MEASURED width. The badge is
-- wider than it is tall, so a square ring sized from the width surrounds it and
-- crosses the bar's top and bottom edges (decision D5); sizing from the height
-- would instead track our own bar-height setting, which section 4.2 rejects.
ns.RARITY_RING_WIDTH_FACTOR = 1.25

ns.RARITY_RING_SIZE_MINIMUM = 0.6
ns.RARITY_RING_SIZE_MAXIMUM = 2.0
ns.RARITY_RING_SIZE_STEP = 0.05

-- Tighter than the marker's +-40: the badge is 28 wide and a ring further out than
-- this is no longer on it.
ns.RARITY_RING_OFFSET_LIMIT = 24

-- The ring must draw OVER the badge's own box, or its inner edge is hidden behind
-- it. Our frames are UIParent children, so the plate's strata governs whether this
-- is enough; it is the single knob if the in-game check fails (section 12).
ns.RARITY_RING_STRATA = "HIGH"

-- Blizzard's LEVEL_INDICATOR_WIDTH (Blizzard_NamePlateConstants.lua), used only
-- when the badge's own GetWidth does not answer.
ns.LEVEL_INDICATOR_WIDTH_FALLBACK = 28

ns.RARITY_TIER = { BOSS = "Boss", SILVER = "Silver", GOLD = "Gold" }

-- The artwork, from Camelot's own target frame
-- (Blizzard_UnitFrame/Camelot/TargetFrameUtils.lua:9-19 via Mainline/TargetFrame.lua:423).
-- Verified by use rather than by name: this client sets these three every time the
-- player targets an elite. Rare and rare-elite share the silver surround because
-- that file's ShouldUseSilverUnitFrame does (section 4.3).
ns.RARITY_RING_ATLAS = {
    Boss = "UI-HUD-UnitFrame-Target-PortraitOn-Boss-Gold-Winged",
    Silver = "UI-HUD-UnitFrame-Target-PortraitOn-Boss-Rare-Silver-Winged",
    Gold = "UI-HUD-UnitFrame-Target-PortraitOn-Boss-Gold",
}

-- The classification strings that earn a ring, mapped to their tier. "worldboss"
-- is here as well as UnitIsBossMob because the two are not the same question and
-- either one answering yes is a boss (section 4.5).
ns.RARITY_TIER_FOR_CLASSIFICATION = {
    worldboss = "Boss",
    rare = "Silver",
    rareelite = "Silver",
    elite = "Gold",
}

-- A ring whose aspect could not be read is drawn square. The target-frame gold
-- surround is very nearly square, so this is the right guess when GetAtlasInfo
-- answers without usable numbers.
ns.RARITY_RING_ASPECT_FALLBACK = 1.0
