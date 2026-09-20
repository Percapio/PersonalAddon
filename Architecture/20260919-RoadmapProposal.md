# PersonalAddon: Architecture & Roadmap Proposal
**Date:** September 19, 2026
**API Version:** 1.60.1 (WoW Forever Beta)

## 1. Architectural Approach

**Structure:** Monolithic
Since the addon is specifically tailored for a single user and focuses on cherry-picking specific features rather than acting as a full suite, a single cohesive codebase (monolithic architecture) is preferred. This eliminates the overhead of managing complex inter-module dependencies.

**Libraries & Dependencies:**
We will utilize established libraries only where they significantly accelerate development and have a low risk of becoming technical debt. 
- **LibStub & Ace3 (AceConfig/AceGUI):** Recommended strictly for generating the configuration panel under the native `Settings > Options > Addons > PersonalAddon` menu, saving us from writing boilerplate UI code. Core gameplay features will be written using the vanilla WoW API to ensure maximum performance and compatibility with the Gamepad UI (Alpha).

**Gamepad UI Compatibility:**
Since the target user plays exclusively on a controller, all features will be tested strictly against the Blizzard Gamepad UI (Alpha) utilizing Xbox-layout inputs (e.g., `A` Select/Accept, `B` Cancel, `X` Use/Page, `L2/R2` Interface toggle).

---

## 2. Development Roadmap

### Phase 1: Minimum Viable Product (MVP)
The foundation of the addon, focusing on the most critical quality-of-life enhancements.

* **Core Scaffolding:** Create the `.toc` file and base Lua structure.
* **`/rl` Command:** Implement a simple chat slash command to quickly execute `/reload` (inspired by Leatrix Plus).
* **FiveSecondRule (FSR) Tracker:** 
  * Add a tracker for mana users.
  * Render a white vertical ticking line on the character's resource bar.
  * Logic to track when FSR starts, resets, and the intervals between ticks.

### Phase 2: Healthbar / Nameplate Adjustments
Refining the on-screen enemies and allies (inspired by Threat Plates).

* **Visual Adjustments:** Override the default blizzard healthbars to be skinnier.
* **Data Positioning:** Reposition the player/enemy/NPC name, guild, and NPC role tags cleanly around the bar.
* **Threat-based Coloring:** Implement logic from a DPS perspective:
  * **Red:** Monster is targeting the player.
  * **Green:** Monster is targeting a party/raid member.
  * **White:** Not in combat with the player or the party.

### ~~Phase 3: Player Frame Modifications~~ — REJECTED 2026-09-19

**Dropped before design. Phase numbering is deliberately not compacted**, because
Phases 4 to 6 are referenced by number from `20260919-Phase01.md` and
`20260919-Phase02.md`.

Original scope, kept for the record:

* ~~**Portrait Removal:** Hide the default 3D/2D player portrait.~~
* ~~**Bar Redesign:** Transform the personal health and resource bars into skinny, vertical indicators.~~
* ~~**Directional Flow:** Set the depletion/fill direction to any of the four cardinal directions.~~
* ~~**Status Markers:** Attach iconography indicating "In Combat", "PvP Enabled".~~

**Why it was rejected.** Three reasons, of unequal weight:

1. **Vertical bars require repositioning Blizzard's bars**, and this client treats
   nameplate text as a restricted region that addons may not measure or move
   (`Phase02.md` §4.7). Whether the player frame's bars are restricted the same
   way is unknown, and the whole visual design rests on the answer.
2. **It breaks the Phase 1 FSR indicator.** That marker anchors to
   `PlayerFrameManaBar` and sweeps horizontally; making the bar vertical makes the
   sweep wrong. Repairing it means changing tested Phase 1 code to serve a Phase 3
   visual preference.
3. **Taint on `PlayerFrame`** — this reason was overstated when the decision was
   made, and the record should say so. Hiding, moving or reparenting `PlayerFrame`
   *itself* is genuinely protected and raises in combat. Hiding a portrait texture
   and resizing its child status bars is not: it is the same class of operation
   Phase 2 performs on nameplate bars, and Phase 1 has created a texture on
   `PlayerFrameManaBar` and read its geometry since it shipped. The narrow version
   carries roughly Phase 2's risk, not more.

**What remains available, if it is ever wanted.** Keep the border, hide the
portrait, and rescale both bars *in place* — no repositioning, no orientation
change, no FSR interaction, no new widgets. That is a small, well-understood piece
of work that avoids all three reasons above. It is not scheduled.

### ~~Phase 4: Scrolling Combat Text~~ — REPLACED 2026-09-19

**Superseded by `20260919-Phase04.md`: a post-combat damage breakdown panel.**

`C_CombatLog.IsCombatLogRestricted()` returns **true** — the client states
outright that addon access to the combat log is restricted. Measured against it:
MikScrollingBattleText registered roughly one hit in three, and Epic Damage Meter
missed one spell across eleven fights. Both build on an incomplete source, and for
a feature whose whole output is numbers that is disqualifying in the worst way:
not visibly broken, just quietly wrong.

The client ships an accurate first-party damage meter and a sanctioned API,
`C_DamageMeter`, which returns per-spell totals, per-second rates and session
history. Phase 4 reads that instead.

Original scope, kept for the record:
Replacing the default floating combat text (inspired by MikScrollingBattleText).

* **Text Anchoring:** Create custom screen anchors for outgoing damage and aura/combat state changes.
* **Animation & Behavior:** Add text behaviors, notably a "wobble" effect and size increase for critical strikes.
* **Fade Timers:** Implement customizable fade delays before text is cleared from the screen.

### Phase 5: Camera — RESCOPED 2026-09-19

**Phase 5 is camera pitch only.** The NPC interaction work below was rescoped and
deferred to after v1 ships; its decisions are recorded at the end of this section
so they are not lost.

Original scope:
Enhancing the viewport and NPC interactions for a better gamepad experience.

* **Camera Vertical Pitch:** Adjust the default camera pitch to frame the world better (seeing less floor and more horizon, inspired by Dynamic Cam).
* **Immersion-like NPC Dialogues:** 
  * Replace the default gossip/quest UI with a customized interaction box.
  * Break text into digestible chunks, using `X` to progress/page.
  * Render loot choices in a side panel.
  * Implement Gamepad UI bindings (`L2`/`R2` to toggle focus between text and loot, `A` to accept/confirm, `B` to cancel/close).

#### Deferred to after v1: NPC interaction frames

The original scope assumed a full custom dialogue box, in the style of Immersion.
That assumption was wrong, and the Gamepad UI is why: it already navigates every
interface, switches panels with `L2` / `R2`, and handles quest accept, decline and
reward selection. Rebuilding any of that would have been reimplementing working
client features, worse.

What is actually wanted is much smaller, and is **the existing frames, changed** —
not replaced:

| Decision | Choice |
|---|---|
| Which frames | Every NPC interaction frame: gossip, quest, vendor, trainer, bank |
| Position | Lower centre, as a config offset, exposed by the Phase 6 settings menu |
| Gossip text | Long text broken into individual paragraphs, read a few lines at a time |

Two notes for whoever picks this up:

**Paragraph paging needs no text measurement.** Splitting on paragraph breaks is a
string operation on `C_GossipInfo.GetText()`, so none of the restricted-region
problems from `20260919-Phase02.md` §4.7 apply to the chunking itself. Whether
Blizzard's gossip font string can be *written* is a separate question and needs a
probe; the fallback is our own font string overlaid on the frame.

**Repositioning a Blizzard frame is the competing-writer problem again.** See
`20260919-Phase02.md` §9.5 and §9.6. Some interaction frames are also managed by
the client's own layout system, which will fight a naive `SetPoint`.

### Phase 6: Configuration Menu & Polish
Integrating the settings into the WoW client.

* **Settings Integration:** Hook into the native `Settings > Options > Addons` menu.
* **Options Mapping:** Connect the in-game UI toggles to the features built in Phases 1-5.
* **Gamepad Verification:** Final pass to ensure all visual elements and the settings menu behave predictably when navigating with a controller.
