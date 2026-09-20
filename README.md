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
- **Aggro-Coloured Nameplates:** Colours hostile and neutral nameplates by who the monster is actually attacking, from a DPS perspective: red = it is on you, green = it is on a party member or your pet, white = neither.
  - **Nameplate size is not adjustable** and no longer offered. Two mechanisms were tried; both were accepted by the client and changed nothing on screen. `healthBar:SetHeight` is discarded on the next layout pass because the bar has two vertical anchors, and `C_NamePlate.SetNamePlateSize` sizes the plate's anchor region while the client keeps laying out the visible bar itself. In both cases the addon could confirm its own write and could not confirm the effect.
  - Name, guild and NPC role tag placement are *not* included: the client treats nameplate text as a restricted region that addons may not measure or move.
- **Damage Breakdown Panel:** A small panel above the player frame listing your own damage by spell — icon, DPS and share of your total — read from the client's own damage meter so the numbers match it exactly. Switches between the current fight and your overall session. (This replaces the originally planned scrolling combat text, which cannot be built correctly here: the client restricts addon access to the combat log, and every addon that tries misses hits.)

## What the game already does

Worth stating plainly, because it defines what this addon is *not* for. The
Gamepad UI (Alpha) already handles, with no addon involved:

- Navigating every interface with the controller.
- Switching between panels within an open interface using `L2` / `R2`.
- Accepting and declining quests, and choosing quest rewards.
- A built-in damage meter, which is where this addon's breakdown panel gets its
  numbers rather than counting its own.

Several features originally planned here turned out to be redundant against that
list. They were dropped rather than reimplemented worse.

## Tried and not deliverable

Attempted and abandoned, with the reason, so nobody spends the time twice:

- **Scrolling combat text.** The client restricts addon access to the combat log —
  `C_CombatLog.IsCombatLogRestricted()` returns true — and every addon that tries
  misses hits. Replaced by the damage breakdown panel, which reads the client's own
  meter.
- **Camera vertical pitch, DynamicCam style.** The client's
  `test_cameraDynamicPitch` settings accept the change and even confirm it with a
  dialog, then do nothing. Possibly because the Gamepad UI is still in Alpha. Worth
  revisiting if a later client patch wires them up.
- **Nameplate name, guild and role tag placement.** The client treats nameplate text
  as a restricted region that addons may not measure or move.
- **Minimal player frames.** Dropped by choice rather than by the client: vertical
  bars require repositioning Blizzard's, which may be equally restricted, and it
  would have broken the FSR indicator that anchors to the mana bar.

## Planned after v1

Not built yet, and deliberately out of scope for the first release:

- **Interaction frames at lower-centre:** move the gossip, quest, vendor, trainer
  and other NPC interaction frames to the lower centre of the screen, with the
  offset adjustable in the settings menu. The existing frames, repositioned —
  not replaced.
- **Paragraph paging for gossip:** break long gossip text into individual
  paragraphs so it is read a few lines at a time rather than as a wall, in the
  style of the Immersion addon. The frame stays Blizzard's; only the text
  presentation changes.

## Credits

Inspired by:
- Leatrix Plus
- FiveSecondRule
- Threat Plates
- Dynamic Cam (for the camera pitch idea, which this client will not do — see above)
- Immersion (for the paragraph-paging idea, planned after v1)

## License & Legal

**PersonalAddon** is distributed under the **Artistic License 2.0**.