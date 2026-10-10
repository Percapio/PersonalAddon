# PersonalAddon

A small, controller-first addon for the World of Warcraft Forever Beta (API 1.60.1). It
takes the one or two features I wanted from a handful of larger addons and builds them
to match the game's own look. It is built for, and tested with, Blizzard's Gamepad UI
(Alpha).

## Installation

1. Download or clone this repository.
2. Put the `PersonalAddon` folder in `_classic_beta_/Interface/AddOns/`.
3. Start the game and make sure the addon is enabled in the AddOns list.

Every feature can be switched on or off and adjusted in **Options > AddOns > PersonalAddon**,
on its pages **Combat**, **Nameplates** and **Bags & loot**, or with `/pa` commands (below).
Each feature's options sit indented under its switch, sliders show their value, and each
page's Defaults resets only that page.

## Features

**Combat**

- **Five-second rule.** For mana users, a white line sweeps across the mana bar and shows
  how long until spirit regeneration resumes. Casting again restarts it. The client
  hides mana values from addons, so the regeneration tick itself cannot be shown.
- **Nameplate colours.** Hostile and neutral nameplates are coloured from a damage
  dealer's point of view, highest priority first:

  | Colour | Meaning |
  |---|---|
  | Red | It is attacking you, even if another player tagged it |
  | Orange | You are about to pull it: your threat is above the tank's |
  | Grey | Tagged by a player outside your group, so you get no credit |
  | Green | It is attacking a party member or your pet |
  | Yellow | Neutral |
  | White | Hostile and attacking neither |

  Red and orange come first because they are about your safety: grey never hides a mob
  that is hitting you or that you are about to pull. Grey and yellow match the game's own
  colours by default. All six can be changed. Colours come from the game's threat data,
  so they also work in dungeons and raids.
- **Threat panel.** In combat, the mobs fighting you or your group are listed in the
  damage breakdown's place above the player frame:
  - their health as a bar, in the nameplate colours;
  - your threat on each, highest first;
  - your target marked, with level and elite tags.

  It needs enemy nameplates on, and it hides when the fight ends. Its scale, width and
  position are in Settings. Narrowing it below about 140 pixels drops the mob names and
  keeps the bars and your threat; it stops at 112, ten per cent under the player frame's
  own health bar.
- **Damage breakdown.** A small panel above the player frame lists your damage by spell,
  with icon, DPS and share of your total. It reads the game's own damage meter, so its
  numbers match it exactly. Choose the current fight or the whole session. By default it
  hides during combat, when it can only show the last fight, and its place goes to the
  threat panel. Its scale and position are in Settings, separate from the threat panel's.

**Bags and loot**

- **Equipped skills.** While your bags are open, a small panel at their left edge shows
  your primary professions, the skill of each equipped weapon, and Defense, as
  `rank / maximum`. Each weapon slot gets its own row; an empty main hand shows
  Unarmed, and a fishing pole shows Fishing. Its width and position are in Settings.
- **Toasts.** Pop-ups for looted money, looted items of green quality or better, and
  looted quest items of any quality. Purchases, quest rewards and crafted items do not
  show. Position, duration and each type can be adjusted.
- **Tidy bags when closed.** Closing your bags runs the game's own Clean Up Bags, at most
  once a minute, never in combat, and never while items are moving. It also holds back
  while something else is watching item locks, such as a bag item tracked in the
  Cooldown Manager. `/pa bags` says why a close did not sort.
- **Sell junk automatically.** Opening a merchant sells every grey item with the game's
  own Sell All Junk, with no confirmation popup, and a toast reports what it earned. If
  toasts are off, the summary goes to chat.

**Other**

- **Show all windows for adjusting.** A switch at the top of the settings menu's General
  page draws every window this addon owns -- the skills panel, the damage breakdown or
  threat panel, and two sample toasts -- filled with sample contents, above the Options
  window, so a change to a width, a scale or a position can be seen as it is made. The
  windows stay up after Options closes and switch off when a fight starts. The threat
  panel and the damage breakdown sit in the same place, so whichever one you last
  adjusted is the one shown. Sample contents are never real figures: `/pa threat`,
  `/pa dps`, `/pa skills` and `/pa toasts` each say `preview: on` while it is.
- **`/rl`** reloads the interface.

## Commands

| Command | What it does |
|---|---|
| `/pa status` | Every feature and whether it is running |
| `/pa on <feature>`, `/pa off <feature>` | Switch a feature on or off |
| `/pa get <feature>`, `/pa set <feature> <key> <value>` | Read or change a setting |
| `/pa skills` | What the skills panel shows, row by row |
| `/pa toasts`, `/pa toasts test` | Toast counts; show one of each toast |
| `/pa bags`, `/pa vend` | The last sort or sale, and why any was skipped |
| `/pa dps`, `/pa threat`, `/pa plates`, `/pa fsr` | State of the damage breakdown, threat panel, nameplates and five-second rule |
| `/pa preview [on\|off\|threat\|dps]` | Show every window with sample contents while you adjust; which window each place is showing |
| `/pa panel` | How the settings pages built. It does not open Options: that call is restricted |
| `/pa blocked` | Actions the game refused with PersonalAddon named |
| `/pa diag` | Counters and fault notes from the last five sessions |
| `/pa diag clear` | Drop all but the current session's record |
| `/pa help` | The full list |

## Troubleshooting

**Any entry in `/pa blocked` is a bug in this addon**, even if nothing looked wrong —
**with one exception**, the known issue below. Please open an issue with that output.
Without BugGrabber, the game shows its own dialog for the same event.

How to tell the exception apart: the known issue refuses controller actions, most often
`SetPreferredGamepadInteractTarget`, and `/pa blocked` shows the stack reaching Blizzard's
own `MainActionBarFrame.lua` or `FrameControlsManager.lua` rather than any file of this
addon. The game blames whichever addon's taint the UI state happens to carry, so
`/pa diag` counts those under `refusalsOurs` even though the call was Blizzard's;
`knownDefectHintShown` beside it means this addon recognised the defect and said
`/reload`. Any **other** function name, or a stack that passes through
`Interface/AddOns/PersonalAddon/`, is this addon's bug.

**Known issue: the Gamepad UI and refused actions.** Any code that is not Blizzard's (an
addon, or `/run`) opening or closing a window, or closing Options with the controller after
an addon's page was drawn, can leave the Gamepad UI's focus, binding and cursor state
tainted. Later controller actions are then refused, most often updating the interact icon,
though a jump or a Game Menu button can be refused too. The game names whichever addon's
taint that state carries: it has been PersonalAddon, BugSack, Questie, Chatify, SnapPrice,
Auctionator, BetterForeverChat and DrinkBot, and with no addons at all, `/run`. This is a
Blizzard defect, still present on build 1.60.1.70334. **`/reload` clears it**, so reload
after using Options with the controller. Keep BugGrabber installed: without it,
Blizzard's own warning dialog takes part, and one session flooded until it disconnected.
PersonalAddon now counts such a flood quietly and says `/reload`. Details:
[Architecture/20261002-GAPBugs01.md](Architecture/20261002-GAPBugs01.md).

## What the game already does

The Gamepad UI already covers these, so this addon does not:

- Navigating every window with the controller, and switching panels with `L2` / `R2`.
- Accepting and declining quests and choosing rewards.
- Sorting tracked quests by distance on every zone change.
- A damage meter, which the breakdown panel reads rather than counting its own.
- Strafing and backpedalling in combat: Options → Gamepad → combat face-movement angle.
  180 always strafes; 115 strafes but turns you when you pull the stick back.
- Clean Up Bags, in the bag's Manage menu.
- Sell All Junk, a button in the merchant window.
- Reporting money gained at a merchant, in chat when you leave.

## Tried and not possible

Attempted and dropped, with the reason, so nobody spends the time twice:

The **Tried in** column says where the attempt is written up and which client it
failed on, so a later patch can be judged against it. The reason an idea failed is often
build-specific, which is what makes that column worth carrying.

| Idea | Why not | Tried in |
|---|---|---|
| Scrolling combat text | The client restricts the combat log for addons, so every attempt misses hits. The damage breakdown replaces it | [Phase 4](Architecture/20260919-Phase04.md) §1.1, build not recorded |
| Camera pitch, DynamicCam style | The client accepts the settings and then ignores them. Worth retrying after a client patch | [Phase 5](Architecture/20260919-Phase05.md) §4.5b, build not recorded |
| Moving nameplate names, guilds and role tags | The client treats nameplate text as a restricted region | [Phase 2](Architecture/20260919-Phase02.md) §4.7, build not recorded |
| Resizing nameplates | Both methods tried are accepted and change nothing on screen. A third frame was never tried: see [Roadmap 03](Architecture/20261009-RoadmapProposal03.md) §3 | [Phase 2](Architecture/20260919-Phase02.md) §4.9, build not recorded |
| Minimal player frames | Dropped by choice: it would mean moving Blizzard's frames, and the five-second-rule line anchors to the mana bar | [Phase 6](Architecture/20260919-Phase06.md), never attempted |
| Quest tracker sorted by level | Reordering means removing and re-adding watches, and the game runs the tracker's update inside that call, carrying this addon's taint into the tracker | [Phase 7](Architecture/20260926-Phase07.md) §6.4, client of 2026-09-24 |
| Blizzard's own loot toasts | Its loot alerts never fire for ordinary loot, in either UI mode. The toasts here are drawn by this addon | [Phase 8](Architecture/20260927-Phase08.md), client of 2026-09-24 |
| Raid markers on the threat panel | The client always hides them | [Phase 11](Architecture/20261005-Phase11.md), build 1.60.1.70235 |
| Greying out a feature's options while it is off | It needs a modify predicate, a function Blizzard calls on every draw (rule 1). The options are indented under their switch instead | [Phase 12](Architecture/20261006-Phase12.md) §3.4, build 1.60.1.70291 |

## Planned

Both are **on hold** under rule 8 below. The NPC windows are Blizzard panels, and moving
them goes through the same panel system as the known issue above.

- **NPC windows at lower centre:** move the gossip, quest, vendor and trainer windows to
  the lower centre of the screen, with an adjustable offset.
- **Paragraph paging for gossip:** show long gossip text a few lines at a time, in the
  style of Immersion.

## Rules for future development

The game decides whether code is trusted one run at a time. If Blizzard's interface calls
our code, or reads a value our code wrote, the rest of that run counts as ours. This is
called *taint*. A protected action later in that run is then refused in our name, even
though we never asked for it. Blizzard state written during that run can carry the taint
into later runs. The design documents in [Architecture/](Architecture/) cite these rules
by number, so the numbers stay fixed.

1. **Blizzard's Lua never calls ours inline.** Our code runs only from our own event
   handlers, `hooksecurefunc` post-hooks, timers, and callbacks delivered through
   Blizzard's callback registry.
   - An event handler is a separate run only if the event arrives on its own. Some events
     arrive while the call that raised them is still running, and then our handler runs
     inside that call (rule 9). The generated API docs flag each event as
     `SynchronousEvent` or `UniqueEvent`. A unique event cannot arrive inside a call; for
     a synchronous one, find out what raises it before subscribing.
   - Settings use `Settings.RegisterAddOnSetting` with a value-changed callback, never
     proxy settings with getters and setters.
   - No dropdowns: their option lists are functions Blizzard calls. Two-value choices are
     checkboxes.
   - No commit, default or refresh hooks, slider label formatters of ours, colour-picker
     callbacks, or functions stored in Blizzard's tables. Blizzard's own pass-through
     slider label (`SetLabelFormatter` with no function) is allowed: it stores Blizzard's
     function, not ours.
   - No predicates on settings: a parent link (`SetParentInitializer`) takes no function,
     so an option is indented under its switch but never greyed out.
2. **We never write into Blizzard's variables or tables.** No `print()`, which goes
   through a shared chat global; no fields on Blizzard frames; no entries in
   `UIPanelWindows`, `UISpecialFrames` or other Blizzard registries. Slash-command
   registration is the one accepted exception.
3. **Our frames stay out of Blizzard's panel system.** Never `ShowUIPanel` or
   `HideUIPanel` one of ours. The panel system drives the Gamepad UI's controls, which is
   where refusals happen.
4. **Hooks are `hooksecurefunc` post-hooks only**, never replacements, and each is O(1).
5. **Work triggered by Blizzard's interface runs a frame later**, in our own code
   (`C_Timer.After(0)`), from a queue we own and can cancel.
6. **We draw on our own frames**, anchored to Blizzard's but never parented to them. The
   Gamepad UI rebuilds a panel's navigation, in whoever's code is running, whenever a
   frame is created under that panel. A child of ours under a Blizzard panel would put
   our taint there.
7. **We never call protected functions.** A refusal naming PersonalAddon is a defect even
   when it looks harmless. BugGrabber hides the game's dialog, so silence is not proof.
8. **Anything that changes a Blizzard panel needs a test first:** gossip, quest,
   merchant, trainer, settings, the Game Menu and Edit Mode. The test must show a safe
   path before the feature is planned.
9. **A client call we make can run Blizzard's event handlers before it returns.** Treat
   any call that changes state other code listens to as running those listeners inside
   our run, until a test shows otherwise. The `SynchronousEvent` flag narrows which calls
   to test; it does not replace the test. Confirmed so far:
   - `AddQuestWatch` delivers `QUEST_WATCH_LIST_CHANGED` inside the call, so the
     quest-level sort was not built.
   - `C_Container.SortBags` delivers `ITEM_LOCK_CHANGED` and `ITEM_LOCKED` inside the
     call, so tidy bags checks nothing is listening before every sort.
   - `C_MerchantFrame.SellAllJunkItems` delivers nothing inside the call.
10. **A value from the client may be secret.** A successful call is not a readable
    answer. On addon-restricted maps such as dungeons and raids, and in combat, many
    functions return secret values, and comparing, testing or doing arithmetic on one
    raises in our code. Read client values through `ClientRead`
    (`Core/ClientRead.lua`), which checks `canaccessvalue` before anything else touches
    the value. Treat `Withheld` as "could not tell", never as "no". The generated docs
    flag which functions can return secrets (`SecretWhen*`, `SecretReturnsForAspect`),
    and the harness's secret-read lint fails any read that bypasses `ClientRead`.
11. **A design that relies on a fact about Blizzard's code records it.** Add the fact to
    the patch check's register, `Tools/patchcheck/premises.toml`, in the same change.
    After a client patch, run the patch check before relying on any design
    ([Tools/README.md](Tools/README.md)).

Known exceptions, kept on purpose:

- The five-second-rule line is a texture on Blizzard's mana bar
  (`Features/FiveSecondRule.lua`).
- `Core/Log.lua` falls back to `print()` only when no chat frame exists.
- Chat output: `Core/Log.lua` calls the chat frame's `AddMessage`, which stores our
  text in its history. From there it reaches the shared fade list `FADEFRAMES`, so
  Blizzard's chat refresh and fade code run tainted while our lines are fading. No path
  from there to a protected call has been seen.
- The settings page: Blizzard's Settings API stores our controls' initializer data and
  callback handles in its own tables when we register them. Every addon with a settings
  page does this.

To trace how taint reached a refusal:

1. Keep BugGrabber installed. `/console taintLog 1`, then `/reload`.
2. Do the one thing that triggers the refusal, then quit.
3. In `Logs/taint.log`, the line just above each "An action was blocked" entry is where
   that execution became tainted; look that line up in the exported UI source. An
   "Execution tainted by … while reading …" line names the variable outright.
4. `/console taintLog 0`. Never use level 4: it logged 32,000 lines in ten seconds and
   helped one session flood until it disconnected. Copy `taint.log` before logging in
   again, because the client rewrites it.

## Development

Nothing under `Tools/` loads in game; the client loads only the files the TOC lists.

- `Tools/harness/`: runs the addon offline in a real Lua 5.1 against stubbed client
  APIs. `python Tools/harness/run.py`.
- `Tools/lint/`: the secret-read lint (rule 10). The harness runs it first.
- `Tools/patchcheck/`: after a client patch, checks every fact our designs rely on
  about Blizzard's code against the new UI export (rule 11).
  `python Tools/patchcheck/patch_check.py status` says whether a check is due.

Setup, and the procedure after a client patch: [Tools/README.md](Tools/README.md).

## Credits

Inspired by Leatrix Plus, FiveSecondRule, Threat Plates, DynamicCam (the camera idea
this client will not do) and Immersion (the gossip-paging idea).

## License

PersonalAddon is distributed under the **Artistic License 2.0**.
