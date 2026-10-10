"""Loads PersonalAddon's TOC files into a real Lua 5.1 (lupa) over stubbed client
APIs, then runs one test file per session, each in a fresh runtime.

Sessions: Phase 7's nameplate checks (tests.lua, "main" and "withheld"), Phase 8's
checks (tests8.lua, four variants), Phase 9's (tests9.lua, four variants),
Phase 10's (tests10.lua), Phase 11's (tests11.lua, three variants), Phase 12's
(tests12.lua, two variants) and Phase 13's (tests13.lua, two variants). The static secret-read lint (Tools/lint) runs first;
--no-lint skips it. Moved from c:\\tmp\\PersonalAddonHarness by
Architecture/20261002-Phase10.md section 2.

Usage: python Tools/harness/run.py [session...] [--no-lint] [--chat]
"""
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
TOOLS = HERE.parent
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

from lupa.lua51 import LuaRuntime  # noqa: E402

from common import paths  # noqa: E402

ADDON = paths.REPO

SESSIONS = [
    ("main", "tests.lua"),
    ("withheld", "tests.lua"),
    ("phase8", "tests8.lua"),
    ("phase8-withheld", "tests8.lua"),
    ("phase8-positional", "tests8.lua"),
    ("phase8-noglobals", "tests8.lua"),
    ("phase9", "tests9.lua"),
    ("phase9-raid", "tests9.lua"),
    ("phase9-baddiag", "tests9.lua"),
    ("phase9-noapi", "tests9.lua"),
    ("phase10", "tests10.lua"),
    ("phase10-noenum", "tests10.lua"),
    ("phase11", "tests11.lua"),
    ("phase11-hidden", "tests11.lua"),
    ("phase11-noplates", "tests11.lua"),
    ("phase12", "tests12.lua"),
    ("phase12-nopages", "tests12.lua"),
    ("phase13", "tests13.lua"),
    ("phase13-refused", "tests13.lua"),
]

# A chat line naming one of these alongside "raised" or "faulted" is an error.
WATCHED = ("nameplates", "settingsPanel", "equippedSkills", "toasts", "autoSortBags",
           "autoSellJunk", "damageBreakdown", "threatPanel", "Dispatch", "CallWindow")


def toc_files():
    for raw in (ADDON / "PersonalAddon.toc").read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if line and not line.startswith("#"):
            yield line


def run_session(session, tests):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute((HERE / "stubs.lua").read_text(encoding="utf-8"))
    lua.execute((HERE / "stubs8.lua").read_text(encoding="utf-8"))
    lua.execute((HERE / "stubs9.lua").read_text(encoding="utf-8"))
    lua.execute((HERE / "stubs11.lua").read_text(encoding="utf-8"))
    lua.execute((HERE / "stubs12.lua").read_text(encoding="utf-8"))
    lua.execute((HERE / "stubs13.lua").read_text(encoding="utf-8"))
    lua.globals().HARNESS_SESSION = session
    load = lua.eval(
        "function(src, name) local f, err = loadstring(src, '@' .. name) "
        "if not f then error(err) end f('PersonalAddon', HARNESS_NS) end"
    )
    for name in toc_files():
        path = ADDON / name.replace("\\", "/")
        load(path.read_text(encoding="utf-8"), name)
    lua.execute((HERE / tests).read_text(encoding="utf-8"))
    result = lua.globals().HARNESS_RESULT
    failures = list(result.failures.values())
    errors = [line for line in result.errors.values() if any(word in line for word in WATCHED)]
    print(f"[{session}] passed {result.passed}, failed {len(failures)}")
    for failure in failures:
        print("  FAIL", failure)
    for line in errors:
        print("  ERROR LINE", line)
    if "--chat" in sys.argv:
        for line in result.chat.values():
            print("   |", line)
    return len(failures) + len(errors)


def run_lint():
    """Phase 9 section 9.2: the static secret-read lint runs before any session."""
    from lint import secret_lint
    hits, stale, entries, sizes = secret_lint.lint()
    print("[lint] secret-capable from the docs: %d global, %d namespaced, %d widget methods, %d events" % sizes)
    for relative, number, name, rule, text in hits:
        print(f"  HIT {relative}:{number} {name} ({rule}): {text[:100]}")
    for entry in stale:
        print(f"  STALE allowlist entry: {entry['file']} | {entry['name']} | {entry['snippet']}")
    print(f"[lint] {len(hits)} hit(s), {len(entries)} allowlisted, {len(stale)} stale")
    return len(hits) + len(stale)


if __name__ == "__main__":
    only = [arg for arg in sys.argv[1:] if not arg.startswith("--")]
    total = 0 if "--no-lint" in sys.argv else run_lint()
    total += sum(run_session(session, tests) for session, tests in SESSIONS
                 if not only or session in only)
    sys.exit(1 if total else 0)
