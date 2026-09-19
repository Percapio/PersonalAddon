# PersonalAddon

A lightweight World of Warcraft Forever Beta (API Version 1.60.1) addon specifically tailored for me.

**Why?** I mostly like one or two features from a whole range of addons. Of the list below (under the Credits section), none were updated at the time of creating PersonalAddon to support WoW Forever Beta, and even if they were, I did not use most of their features (besides FiveSecondRule).

**What?** This addon cherry-picks specific features from the emulated addons with minimal frontend customization. The aesthetics of each feature will remain in-line with the Enhanced and/or Classic versions of WoW Forever.

**Controller First:** I play exclusively with a controller, so this addon is built to fully support the Gamepad UI (Alpha) currently being developed by the Blizzard team.

## Installation

1. Download or clone this repository.
2. Place the `PersonalAddon` folder into your WoW directory: `_classic_beta_/Interface/AddOns/`.
3. Launch World of Warcraft Forever Beta and ensure the addon is enabled in your AddOn list.

## Configuration

Customization for all features can be found in the native Blizzard settings menu under **Settings > Options > Addons > PersonalAddon**. 

## Features

This addon is modular in concept but monolithic in architecture. It targets the following specific features:

- **/rl Chat Command:** Type `/rl` to quickly execute `/reload`.
- **FiveSecondRule (FSR) Tracker:** For mana users, a white vertical line sweeps across the resource bar over the five-second rule, showing how long until spirit regen resumes. Casting again restarts it. (Regen *tick* timing is not shown: the client returns mana as a protected value that addons cannot read, so there is no tick to display.)
- **Threat-Based Healthbars:** Overrides default healthbars to be skinnier. Customizes placement of name, guild, and NPC role tags. Colors names based on threat from a DPS perspective (red = targeting you, green = targeting party, white = neutral).
- **Minimal Player Frames:** Hides the default portrait. Changes health/resource bars to be skinny and vertical, with customizable cardinal fill directions. Adds status icons (e.g., "in combat", "pvp mode").
- **Scrolling Combat Text:** Custom on-screen placement for outgoing damage and aura changes. Includes text behaviors (crit wobble, larger text) and customizable fade-out timers.
- **Camera Vertical Pitch:** Adjusts the vertical pitch of the camera to see less of the floor and more of the "world".
- **Immersion-like NPC Dialogues:** Replaces the default quest/gossip UI with a clean conversation box. Text is broken into manageable chunks (progressed via `X`). Loot choices are displayed in a right-side panel (`L2`/`R2` to toggle focus between chat and loot). Native Gamepad inputs (`A` accept, `B` cancel) are fully supported.

## Credits

Inspired by:
- Leatrix Plus
- FiveSecondRule
- Threat Plates
- Matt's Minimal Frames
- MikScrollingBattleText
- Dynamic Cam
- Immersion

## License & Legal

**PersonalAddon** is distributed under the **Artistic License 2.0**.