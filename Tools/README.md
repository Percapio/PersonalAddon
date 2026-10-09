# Tools

Offline tooling for PersonalAddon. Nothing here loads in game: the client loads only
the files `PersonalAddon.toc` lists. The design is
[Architecture/20261002-Phase10.md](../Architecture/20261002-Phase10.md).

| Folder | What it does |
|---|---|
| `harness/` | Loads the addon into a real Lua 5.1 over stubbed client APIs and runs the Phase 7–12 checks, one fresh runtime per session: seventeen sessions, 439 checks |
| `lint/` | The secret-read lint (README rule 10): fails any read of a value the client may make secret that bypasses `ClientRead` |
| `patchcheck/` | The patch check (README rule 11): after a client patch, tests every fact our designs rely on about Blizzard's code against the new UI export |
| `common/` | What they share: paths, the API docs parser, the load set, the Lua index |

## Setup

Python 3.12 or later. The patch check and the lint need nothing else. The harness
needs lupa, in a virtual environment kept outside the repo:

```
python -m venv C:\tmp\PersonalAddonVenv
C:\tmp\PersonalAddonVenv\Scripts\pip install -r Tools\requirements.txt
```

Every path is worked out from where the tools sit, three folders below the client.
To override one, such as the baseline store's location, put the key in
`Tools/config.local.toml`, which git ignores. `Tools/config.toml` lists the keys.

## Commands

```
python Tools/harness/run.py [session...] [--no-lint] [--chat]
python Tools/lint/secret_lint.py
python Tools/patchcheck/patch_check.py status | adopt | check | accept [--reviewed] [--resume]
python Tools/patchcheck/tests/test_patch_check.py
```

## After a client patch

No design or test may rely on Blizzard's source until `status` reports `UpToDate`.

1. `python Tools/patchcheck/patch_check.py status`. Anything other than `UpToDate` means
   a check is due.
2. Export the new UI: launch the client with `-console`, open the console at the login
   screen and run `exportInterfaceFiles code`. Quit, then remove `-console` again.
3. `python Tools/patchcheck/patch_check.py check`. It writes a report to
   `Tools/patchcheck/reports/`, and exits 0 for Pass, 2 for Review, 1 for Fail.
4. Act on the verdict:
   - **Pass:** `accept`.
   - **Review:** read the report. Each premise that needs review says what to re-read.
     When every design still holds, `accept --reviewed`. When one does not, change the
     design or the code, and the register, then check again.
   - **Fail:** a premise broke, a name we use is gone, or the lint fails. Fix it, then
     check again. A Fail cannot be accepted.
5. Commit `Tools/patchcheck/verified.json` with the report.

`accept` copies the export into the baseline store, `C:\tmp\PersonalAddonBaseline` by
default, all or nothing. If it is interrupted, the next `adopt`, `check` or `accept`
recovers first and prints what it did; `status` only reports it. If the store is ever
lost, `check` still runs from `verified.json`, without line diffs.

## The premise register

`patchcheck/premises.toml` holds the facts a design relies on. A design that relies on
a new one adds an entry in the same change (README rule 11). Each entry names its
source, what to re-read if it stops holding, and one check: `Callers`, `Defined`,
`Pattern`, `FlagAbsent`, `FlagEquals` or `Watch`. Names our code uses, such as hook targets, events
and client functions, need no entry: the patch check finds them in the code each run.
