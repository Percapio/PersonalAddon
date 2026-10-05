"""Static secret-read lint (Architecture/20261002-Phase09.md section 9.2; moved into
the repo by Architecture/20261002-Phase10.md section 2).

Fails when PersonalAddon reads a secret-capable client function, widget method or
event anywhere but on a line that goes through ClientRead, unless an allowlist entry
gives the reason. "Secret-capable" comes from the client's own generated API docs,
read through DocsIndex: an entry carrying any key that begins with "Secret", other
than SecretArguments and SecretArgumentsAddAspect (which are about arguments, not
returns).

A boolean test on a secret value cannot be trapped in Lua 5.1, so the harness
cannot catch `if secret then` at run time. This lint is what does.

Usage: python Tools/lint/secret_lint.py      (exit 1 on any unallowlisted hit)
"""
import pathlib
import re
import sys

TOOLS = pathlib.Path(__file__).resolve().parents[1]
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

from common import docs_index, paths  # noqa: E402
from common.lua_scan import strip_comment_and_strings  # noqa: E402

ALLOWLIST = pathlib.Path(__file__).parent / "secret_lint_allow.txt"
SKIPPED_FILES = {"Core/ClientRead.lua"}


def read_docs(export_root=paths.EXPORT):
    """The four secret-capable name sets: globals, namespaced, widget methods, events."""
    return docs_index.secret_capable_sets(docs_index.build_docs_index(export_root))


def load_allowlist(allowlist=ALLOWLIST):
    entries = []
    if not pathlib.Path(allowlist).exists():
        return entries
    for raw in pathlib.Path(allowlist).read_text(encoding="utf-8").splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        parts = [part.strip() for part in raw.split("|")]
        if len(parts) != 4 or not parts[3]:
            raise SystemExit(f"bad allowlist line (file | name | snippet | reason): {raw}")
        entries.append({"file": parts[0], "name": parts[1], "snippet": parts[2], "reason": parts[3], "used": False})
    return entries


def allowed(entries, file, name, line):
    for entry in entries:
        if entry["file"] == file and entry["name"] == name and entry["snippet"] in line:
            entry["used"] = True
            return True
    return False


def addon_files(addon_root):
    addon_root = pathlib.Path(addon_root)
    return sorted(list(addon_root.glob("Core/*.lua")) + list(addon_root.glob("Features/*.lua")))


def lint(export_root=paths.EXPORT, addon_root=paths.REPO, allowlist=ALLOWLIST):
    globals_, namespaced, widget_methods, events = read_docs(export_root)
    entries = load_allowlist(allowlist)
    hits = []
    for path in addon_files(addon_root):
        relative = path.relative_to(addon_root).as_posix()
        if relative in SKIPPED_FILES:
            continue
        for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            code, strings = strip_comment_and_strings(raw)
            through_client_read = "ClientRead." in code
            found = []
            # Global functions: a bare identifier, not a field and not a definition.
            for match in re.finditer(r"(?<![.:\w])([A-Za-z_]\w*)", code):
                name = match.group(1)
                if name in globals_ and not re.search(r"\bfunction\s+$", code[:match.start()]):
                    found.append((name, "GlobalFunction"))
            # Namespaced functions, through any path that is not one of ours (ns....).
            for match in re.finditer(r"([A-Za-z_][\w.]*)\.([A-Za-z_]\w*)", code):
                chain, name = match.group(1), match.group(2)
                if name in namespaced and not chain.startswith("ns") and not re.search(r"\bfunction\s+$", code[:match.start()]):
                    found.append((name, "NamespacedFunction"))
            # Widget methods: a colon call, or a dot reference on a receiver outside ns.
            for match in re.finditer(r"([A-Za-z_][\w.]*)([.:])([A-Za-z_]\w*)", code):
                chain, separator, name = match.groups()
                if name not in widget_methods or chain.startswith("ns"):
                    continue
                if re.search(r"\bfunction\s+$", code[:match.start()]):
                    continue
                found.append((name, "WidgetMethod"))
            # Events: any string naming one. A subscription can span lines, so the
            # name is caught wherever it is written.
            for literal in strings:
                if literal in events:
                    found.append((literal, "Event"))
            seen = set()
            for name, rule in found:
                if (name, rule) in seen:
                    continue
                seen.add((name, rule))
                if rule != "Event" and through_client_read:
                    continue
                if allowed(entries, relative, name, raw):
                    continue
                hits.append((relative, number, name, rule, raw.strip()))
    stale = [entry for entry in entries if not entry["used"]]
    return hits, stale, entries, (len(globals_), len(namespaced), len(widget_methods), len(events))


if __name__ == "__main__":
    hits, stale, entries, sizes = lint()
    print("secret-capable from the docs: %d global, %d namespaced, %d widget methods, %d events" % sizes)
    for relative, number, name, rule, text in hits:
        print(f"  HIT {relative}:{number} {name} ({rule}): {text[:110]}")
    for entry in stale:
        print(f"  STALE allowlist entry: {entry['file']} | {entry['name']} | {entry['snippet']}")
    print(f"lint: {len(hits)} hit(s), {len(entries)} allowlist entr(y/ies), {len(stale)} stale")
    sys.exit(1 if hits or stale else 0)
