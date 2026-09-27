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

## Troubleshooting

`/pa blocked` lists every action the game refused with PersonalAddon named: which function it was, how often it happened, and the path that led to it. Any entry is a bug in this addon, even when nothing looks wrong, so please open an issue with that output.

Without BugGrabber installed, the game reports the same event with its own dialog, saying PersonalAddon was blocked from an action. `/pa blocked` has the detail.

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

## Rules for future development

World of Warcraft decides whether code is trusted one run at a time. If Blizzard's own
interface calls one of our functions, or reads a value our code wrote, the rest of that
run counts as ours. This is called taint. Any protected action later in that run is then
refused with PersonalAddon named, even though we never asked for it. Blizzard state
written during the run can carry the taint into later runs too. It has already happened
twice: `SetPreferredGamepadInteractTarget()` was traced to the settings panel calling our
code, and `C_Discord.IsUserOAuthed()` most likely has the same cause. See
[Architecture/20260924-Patch01.md](Architecture/20260924-Patch01.md).

Check any new feature against these rules before planning it:

1. **Blizzard's Lua never calls ours inline.** Our code runs only through paths the client
   keeps separate: our own event handlers, `hooksecurefunc` post-hooks, timers, and
   callbacks Blizzard delivers through its callback registry.
   - Settings are registered with `Settings.RegisterAddOnSetting` and a value-changed
     callback (a callback-registry delivery), never as proxy settings with getter and
     setter functions.
   - No dropdowns: a dropdown's option list is a function Blizzard calls. Two-value
     choices are checkboxes, and anything longer needs a spike (rule 8).
   - No canvas commit, default or refresh hooks, no slider label formatters, no
     colour-picker callbacks, and no functions stored in Blizzard's tables.
2. **We never write into Blizzard's variables or tables.**
   - No `print()`, because it resolves a shared chat global.
   - No fields on Blizzard frames.
   - No entries in `UIPanelWindows`, `UISpecialFrames` or any other Blizzard registry.

   The standard `SLASH_*` / `SlashCmdList` slash-command registration is the one accepted
   exception.
3. **Our frames stay out of Blizzard's panel system.** Never `ShowUIPanel` or
   `HideUIPanel` one of ours. The panel manager drives the Gamepad UI's binding stack,
   which is where the refusals happen.
4. **Hooks are `hooksecurefunc` post-hooks only.** Never replace a Blizzard function or
   script, and keep every hook O(1).
5. **Work triggered by Blizzard's interface runs one frame later, in our own code**
   (`C_Timer.After(0)`), from a queue we own and can cancel.
6. **We draw on our own frames.** Anchor them to Blizzard's frames; don't add textures or
   children to Blizzard's frames.
7. **We never call protected functions.** A refusal naming PersonalAddon is a defect
   even when it looks harmless. BugGrabber hides Blizzard's dialog for it, so silence is
   not proof.
8. **Anything that changes a Blizzard UI panel needs a spike first.** That covers gossip,
   quest, merchant, trainer, settings, the Game Menu and Edit Mode. The spike must show a
   safe path before the feature is planned.

Known exceptions, kept on purpose and revisited only if a refusal points at them:

- The FSR marker is a texture created on Blizzard's mana bar (`Features/FiveSecondRule.lua`).
- `Core/Log.lua` falls back to `print()` only when no chat frame exists at all.

To check a refusal, `/pa blocked` shows what was refused and where it came from. To see
how taint spread into it:

1. Run `/console taintLog 2`, then `/reload`.
2. Play until the refusal happens again, then quit.
3. Read `Logs/taint.log`.
4. Run `/console taintLog 0`, because the log slows the client.

## Planned after v1

Not built yet, and deliberately out of scope for the first release. **Both are on hold
under rule 8.** The NPC interaction frames are Blizzard UI panels, which the panel manager
positions and hides itself, through the same path the settings-panel refusals went
through. Neither goes ahead unless a spike finds a route that never touches Blizzard's
panel system.

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