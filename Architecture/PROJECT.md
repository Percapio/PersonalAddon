# PersonalAddon — project facts

Revised 2026-11-28.

Claude reads this file through an import in `CLAUDE.md`; the auditor (`.github/copilot-instructions.md`)
reads it before every audit. Plans and audits quote the Revised line near their top, so a missed read
shows; bump it with every change. `Architecture/` is pushed to GitHub: keep account, realm, character and
guild names out of this file.

- **Facts:** the client, the UI export, `patch_check.py status` and the code outrank this file, and this
  file outranks Claude's memory. When they disagree, fix the lower-ranked source in the same change.
- **Rules:** README "Rules for Future Development" outranks this file, and this file outranks a plan's
  D-numbered decisions. A decision that departs from a Settled entry updates that entry in the same change.
- **Entries:** one line where possible. Cite a file with a symbol (function, setting, constant), not a line
  number, which moves. A statement about Blizzard's code names the premise that re-checks it.
- **Paths:** a path beginning `Blizzard_` is in the UI export, under
  `_forever_/BlizzardInterfaceCode/Interface/AddOns/`. One beginning with another addon's folder
  (`QuestieDB/`, `!BugGrabber/`) is under the client's `_forever_/Interface/AddOns/`. Every other path
  starts at the repo root.

## Domain
World of Warcraft addon for WoW Forever, controller-first (Gamepad UI), written in Lua 5.1.

| Fact | Where to read it |
|---|---|
| Game type `camelot`, in the `mainline` family | `Tools/config.toml` |
| Client build, export date, accepted build | `python Tools/patchcheck/patch_check.py status` |
| TOC interface | `## Interface` in `PersonalAddon.toc` |
| QuestieDB version and contract | `## Version`, `## X-Contract-Version` in `QuestieDB/QuestieDB_Forever.toc` |
| Offline Lua: lupa (Lua 5.1) on Python 3.12 or later | `Tools/requirements.txt`; setup in `Tools/README.md` |

This file records no build, export date or version number: each patch changes them, and a stale one here
would be believed. Read them where the table says.

- Forever is its own game. Classic and Mainline data aren't evidence for it: spell durations, item ids,
  ammo rules, class mechanics, stack sizes, constants. `Blizzard_FrameXMLBase/Camelot/Constants.lua` sets
  `DRUID_BEAR_FORM = 8` and `Blizzard_FrameXMLBase/Mainline/Constants.lua` sets 5;
  `Blizzard_FrameXMLBase.toc` excludes the Mainline file for `camelot`.
- Read the client, the export or the user's `/dump`, or ask. A Forever fact that can't be read offline
  becomes a question to the user or a gated in-game check, never a Classic default. Design examples use
  no Classic spell names.
- Which files load is `Tools/common/load_set.py`'s answer, not a hand reading of TOC tags. Files tagged
  `[AllowLoadGameType mainline]` load on this client.

## Conventions
- Plans are `Architecture/YYYYMMDD-PhaseNN.md` or `Architecture/YYYYMMDD-PatchNN.md`, each audited in a
  sibling `…Audit.md`. A plan records its decisions as D-numbers and answers its audit in an "Audit
  dispositions" section.
- Versions: a phase takes the next minor version and sets `## X-Phase` (Phase 22: `1.12.0`, `X-Phase: 22`,
  `ns.VERSION` `"1.12.0-phase22"`). A patch bumps the third digit and keeps `X-Phase` (Patch 03: `1.12.1`,
  `"1.12.1-patch03"`; Patch 02 D6). `ns.VERSION` is in `Core/Constants.lua`.

## Rules

### Layering
- `Core/` is substrate and loads before `Features/`, because features call `Registry.Register` at file
  scope. TOC order is load order (`PersonalAddon.toc`).
- Client values are read through `Core/ClientRead.lua` (README rule 10). `Tools/lint/secret_lint.py`
  enforces this; an exception needs an entry with its reason in `Tools/lint/secret_lint_allow.txt`.

### Invariants
- README "Rules for Future Development", rules 1–11, bind every design. "Known Exceptions (Kept on
  Purpose)" lists the only exceptions; a design that adds one names it there.
- No design or test may rely on Blizzard's source until `python Tools/patchcheck/patch_check.py status`
  reports `UpToDate` (`Tools/README.md`, "After a client patch"). Until then a plan is marked not buildable.
- A design that relies on Blizzard behaviour adds its premise to `Tools/patchcheck/premises.toml` in the
  same change (README rule 11).
- Accepting a client build (`patch_check.py accept [--reviewed]`) is the user's decision and the user's
  command.
- A faction-dependent design works for both factions, from the client's per-character answer
  (`UnitIsFriend`, `UnitReaction`, `UnitFactionGroup`). This began as Phase 20 D4, for NPC role plates,
  which the user reports working in game (2026-11-28).

## Review checklist
Claude checks a plan against this list before handing it to the auditor, and the auditor checks it again.
README rules 1–11 give the detail.

- **Taint** (rules 1–3, 5–8): Blizzard code calls our code inline, reads a value we wrote, or handles our
  frames, beyond the Known Exceptions. A protected-action refusal attributed to PersonalAddon is a critical
  defect (rule 7).
- **Synchronous events** (rule 9): a client call that changes shared state runs listeners, ours included,
  inside the call.
- **Secret values** (rule 10): a read that bypasses `ClientRead`; arithmetic, comparison or concatenation
  on a value that can be secret; `Withheld` treated as false; no stated behaviour in combat or on
  restricted maps.
- **Premises** (rule 11): reliance on Blizzard code with no register entry, or evidence from a file that
  doesn't load for `camelot`.
- **Hooks** (rule 4): anything but a post-hook, or work above O(1); a nameplate hook runs inside Blizzard's
  draw call.
- **Re-entrancy:** state shared by event handlers, tickers, `OnUpdate` scripts, hooks and our coroutines,
  when one runs inside another.
- **Late data:** data that arrives later by event (uncached item or quest data) with no named event, no
  bound on the wait, or no path for when it never arrives.
- **Deferred work** (rule 5): work deferred to a later frame that bypasses the addon-owned cancellable
  queue, or still runs after its feature is disabled (Phase 21 audit, finding 8).
- **Lifecycle:** no stated state after `/reload`, logout, a loading screen, or disable then enable.
  SavedVariables reach disk only at `/reload`, logout or exit; a crash loses the session's writes.
- **Bounds:** a table keyed by unit, GUID, plate or session with no removal path or cap; a SavedVariable
  with no cap or clear command.
- **Untrusted text:** strings from QuestieDB, other addons, chat or slash arguments reaching a FontString
  except through `EscapeGuard.Neutralize`.
- **Silent degradation:** a refused write, a `Withheld` read, or a feature standing itself down with no
  diagnostics counter or one-time log line.
- **Failure paths:** a client read, write or callback with no branch for raised, refused, `Withheld` or
  nil.
- **Structure:** coupling across module boundaries; abstraction with one caller; an assumption the plan
  relies on without stating it; a hardcoded value that should be a setting, unless a Settled entry fixes
  it.
- **Publication:** account, realm, character or guild names in anything pushed (`Architecture/`,
  `README.md`).

## Hazards
- Docs are not proof of absence. Before calling a client API absent, find a Blizzard caller that runs on
  this client. Phase 4 called `C_Spell.GetSpellPowerCost` missing, and it is present (Phase 20,
  "Corrects"; premise `SPELL-COST-NIL-IS-FREE`).
- In `Blizzard_APIDocumentationGenerated`, `HasRestrictions = true` means refused from tainted code, which
  differs from `IsProtectedFunction`.
- QuestieDB's data is third-party and attacker-reachable: `LibQuestieDB.RegisterCorrection`,
  `RegisterRuntimeCorrection` and `GetRegistrar` are public (`QuestieDB/src/api.lua`).
- Every QuestieDB table read returns a fresh copy (`QuestieDB/src/read/shared.lua`, "Value ownership"):
  cache on our side, never read per nameplate or per frame.
- Keep `IdsByName` and `BuildNameIndex` off per-plate and per-frame paths. `IdsByName` builds the whole
  name index synchronously whenever none exists, and a name correction, which any addon can register,
  drops it. `BuildNameIndexAsync` splits the pass but needs a coroutine we own.
- Read QuestieDB's flavour-resolved enums (`LibQuestieDB.Enum.classKeys`, `.npcFlags`), never literal bits
  or a hand-picked `Enum.byExpansion` entry (Patch 02 §4.3).
- A probe or diagnostic writes to a SavedVariable that is read off disk after `/reload` or logout. Output
  that exists only in chat is not evidence.

## Workload
- Nameplate sweep: every 0.25 s by default (`defaultSettings.sweepInterval`, `Features/Nameplates.lua`).
  The threat panel sweeps on its own `updateInterval` setting (`Features/ThreatPanel.lua`).
- Group size: up to `MAX_RAID_MEMBERS` = 40 (`Blizzard_FrameXMLBase/Shared/Constants.lua`).
- `PersonalAddonBlockLog` keeps at most 16 records (`BLOCK_LOG_CAPACITY`, `Core/BlockWatch.lua`);
  `PersonalAddonDiagnostics` keeps the last five sessions (`ns.DIAGNOSTICS_SESSION_CAPACITY`,
  `Core/Constants.lua`).

## Verification
- Offline: `python Tools/harness/run.py` (it runs the lint first), `python Tools/lint/secret_lint.py`,
  `python Tools/patchcheck/tests/test_patch_check.py`.
- The harness needs lupa importable by the `python` that runs it (`Tools/README.md`, "Setup").
- A new check proves it bites with a mutation pass: one deliberate breakage at a time, a failing check for
  each, every file restored byte for byte (Phase 22 §14.1, Patch 03 §14.1).
- After any in-game run, read `PersonalAddonDiagnostics`, `PersonalAddonBlockLog` and BugGrabber's log.
  BugGrabber records only the first block per addon per UI load (`!BugGrabber/BugGrabber.lua`, its
  `badAddons` table), and the block log only refusals that name PersonalAddon, so read both before
  concluding "no refusal".
- `/dump` runs insecurely: `DevTools_DumpCommand` calls `forceinsecure()` before it evaluates
  (`Blizzard_SharedXML/Dump.lua`; premise `DUMP-FORCES-INSECURE`). So `/dump canaccessvalue(<expr>)`
  shows what addon code sees.

## Settled
Kept elsewhere and not copied here:
- Blizzard-code premises: `Tools/patchcheck/premises.toml`, re-checked for each client build.
- Features tried and dropped, with phase and build: README, "Tried and Not Possible".
- Features the client already provides: README, "What the Game Already Does".

S-numbers are never reused: a retired entry stays, struck through, with the reason.

| # | Kind | Statement | Evidence |
|---|---|---|---|
| S1 | Decision | The five-second rule's tick line is a fixed 2.0 s rhythm by the user's choice, not a fact about Forever; a review must not "correct" it to game data | Patch 03 §1, D4 and D24 |
| S2 | Declined | Threat cue, auto-repair | Phase 21, D13 (§1.3) |
| S3 | Declined | An enemy-player alert | Phase 22, D6 (§1.3) |
| S4 | Decision | Phase 12 Part B (consumable macros) is on hold, since 2026-10-07. Its stand-ins, DrinkBot and AutoPotion, were uninstalled by 2026-11-28; resuming it is the user's call | Phase 12 §1.1 |
