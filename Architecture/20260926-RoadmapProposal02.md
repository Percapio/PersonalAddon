# Addon Feature Roadmap Proposal

**Date:** 2026-09-26
**Target Addon:** PersonalAddon
**UI Environment:** WoW Forever Beta (`_classic_beta_`)

## Overview
This roadmap outlines the architecture and implementation strategy for three quality-of-life enhancements for the addon, focusing on Gamepad UI integration, nameplate visual clarity, and smart quest tracking.

---

## 1. Dynamic Gamepad Movement (Combat/Targeting)
### Description
Enhances the Blizzard Gamepad UI (Alpha) by dynamically remapping the left controller stick from default movement (turn/move) to strafe and backpedaling when the player is both in combat and targeting a hostile entity.

### Requirements & Logic
* **State Triggers:** 
  * Combat state (`PLAYER_REGEN_DISABLED` / `PLAYER_REGEN_ENABLED`).
  * Target state (`PLAYER_TARGET_CHANGED`, checking `UnitCanAttack("player", "target")` and `UnitIsDead("target")`).
* **Settings/Configuration:**
  * Master toggle to enable/disable the feature entirely.
  * **Transition Delay:** A configurable timer (in seconds) before reverting the controls back to standard movement after the hostile target is lost or combat drops. This prevents jarring back-and-forth control changes during chaotic fights.
* **Architecture/Risks:**
  * Must safely intercept or remap bindings (`MOVEFORWARD`, `MOVEBACKWARD`, `TURNLEFT`, `TURNRIGHT` -> `STRAFELEFT`, `STRAFERIGHT`).
  * **Taint Warning:** Since Blizzard's Gamepad UI is alpha, modifying bindings dynamically in combat can trigger action/UI taint. We will likely need to use a Secure State Driver (`RegisterStateDriver`) to swap bindings safely based on macro conditionals like `[combat,harm]`.

---

## 2. Enhanced Nameplate Coloring
### Description
Extends the addon's existing custom health bar coloring system for nameplates to accurately reflect tap-denial states and neutral mobs.

### Requirements & Logic
* **Tap Denied (Grey):** Triggered when a mob is tagged by a player outside of your party/raid. 
  * API: `UnitIsTapDenied("nameplateN")` 
* **Neutral (Yellow):** Triggered for unprovoked neutral creatures.
  * API: `UnitReaction("player", "nameplateN") == 4` (Neutral).
* **Color Priority Hierarchy:**
  1. **Tap Denied (Grey)** - *Highest priority, overrides all else.*
  2. **Threat / Active Combat (Red/Custom)** - *Already handled by existing scheme.*
  3. **Neutral (Yellow)**
  4. **Hostile / Default (Custom)** - *Fallback.*

### Implementation
* Inject checks into the current nameplate `UNIT_THREAT_LIST_UPDATE`, `NAME_PLATE_UNIT_ADDED`, and Healthbar update hooks.

---

## 3. Smart Quest Objective Tracker Sorting
### Description
A personal, always-on feature that overrides the default UI's objective tracker sorting mechanism. Quests will be grouped and ordered based on their level and the player's physical proximity to the objective.

### Requirements & Logic
* **Primary Sort:** Quest Level (Ascending). Low-level quests will always appear at the top.
* **Secondary Sort:** Proximity / Distance. If multiple quests are the same level, the ones closest to the player's current map coordinates will be sorted higher.
* **Settings:** Hardcoded as active (No toggle required).
* **Implementation Strategy:**
  * Hook into the native `ObjectiveTracker_Update` or `QuestObjectiveTracker_Update` functions.
  * Extract quest levels using `C_QuestLog.GetQuestInfo(questID)`.
  * Calculate proximity using `C_QuestLog.GetDistanceSqToQuest(questID)` or by polling the map POI (Point of Interest) APIs if exact distance isn't available.
  * Apply a custom Lua `table.sort` function to the data provider before the UI renders the blocks.
