"""The premise register (Architecture/20261002-Phase10.md section 4): each fact a
design relies on about Blizzard's code, with a check. FlagEquals since
Architecture/20261005-Phase11.md section 7.1.
"""
import pathlib
import re
import tomllib
from dataclasses import dataclass, field

from common import paths
from . import views

CHECK_KINDS = {"Callers", "Defined", "Pattern", "FlagAbsent", "FlagEquals", "Watch"}

HOLDS = "Holds"
NEEDS_REVIEW = "NeedsReview"
BROKEN = "Broken"
UNKNOWN = "Unknown"


class RegisterInvalid(Exception):
    def __init__(self, faults):
        super().__init__("; ".join(faults))
        self.faults = faults


@dataclass
class Premise:
    id: str
    statement: str
    source: str
    consequence: str
    check: dict


@dataclass
class Outcome:
    status: str
    evidence: str = ""
    changed_files: list = field(default_factory=list)


def _valid_path(value):
    if not isinstance(value, str) or not value:
        return False
    if value.startswith(("/", "\\")) or re.match(r"^[A-Za-z]:", value) or "\\" in value:
        return False
    return all(part not in ("", ".", "..") for part in value.split("/"))


def load_register(file):
    """Reads and validates the register. Raises RegisterInvalid naming every fault."""
    try:
        with open(file, "rb") as handle:
            data = tomllib.load(handle)
    except (OSError, tomllib.TOMLDecodeError) as error:
        raise RegisterInvalid([f"cannot read {file}: {error}"])
    faults, premises, seen = [], [], set()
    for position, entry in enumerate(data.get("premise", []), 1):
        label = entry.get("id") or f"entry {position}"
        for key in ("id", "statement", "source", "consequence", "check"):
            if not entry.get(key):
                faults.append(f"{label}: missing {key}")
        if entry.get("id") in seen:
            faults.append(f"{label}: duplicate id")
        seen.add(entry.get("id"))
        check = entry.get("check") or {}
        kind = check.get("kind")
        if kind not in CHECK_KINDS:
            faults.append(f"{label}: unknown check kind {kind!r}")
        for key in ("file",):
            if key in check and not _valid_path(check[key]):
                faults.append(f"{label}: bad path {check[key]!r}")
        for key in ("files",):
            for value in check.get(key, []):
                if not _valid_path(value):
                    faults.append(f"{label}: bad path {value!r}")
        if kind == "Pattern":
            try:
                re.compile(check.get("regex", ""))
            except re.error as error:
                faults.append(f"{label}: bad regex: {error}")
            if check.get("expect") not in ("Present", "Absent"):
                faults.append(f"{label}: expect must be Present or Absent")
        if kind == "Callers" and not isinstance(check.get("count"), int):
            faults.append(f"{label}: Callers needs an integer count")
        if kind == "FlagAbsent" and not (check.get("entry") and check.get("flag")):
            faults.append(f"{label}: FlagAbsent needs entry and flag")
        if kind == "FlagEquals" and not (check.get("entry") and check.get("flag")
                                         and isinstance(check.get("value"), str) and check.get("value")):
            faults.append(f"{label}: FlagEquals needs entry, flag and value")
        if kind in ("Callers", "Defined") and not check.get("name"):
            faults.append(f"{label}: {kind} needs a name")
        if kind == "Watch" and not check.get("files"):
            faults.append(f"{label}: Watch needs files")
        premises.append(Premise(entry.get("id"), entry.get("statement"), entry.get("source"),
                                entry.get("consequence"), check))
    if not premises:
        faults.append("the register holds no premise")
    if faults:
        raise RegisterInvalid(faults)
    return premises


def call_names(premises):
    return {premise.check["name"] for premise in premises if premise.check.get("kind") == "Callers"}


def watched_files(premises):
    found = []
    for premise in premises:
        if premise.check.get("kind") == "Watch":
            for file in premise.check["files"]:
                if file not in found:
                    found.append(file)
    return found


def evaluate_premise(premise, current, baseline):
    check = premise.check
    kind = check["kind"]
    if kind == "Callers":
        sites = current.lua.call_sites.get(check["name"], [])
        where = sorted({site.file for site in sites})
        expected = sorted(set(check.get("files", [])))
        evidence = ", ".join(f"{site.file}:{site.line}" for site in sites) or "no call site"
        if len(sites) == check["count"] and (not expected or where == expected):
            return Outcome(HOLDS, evidence)
        return Outcome(BROKEN, f"{len(sites)} call site(s): {evidence}")
    if kind == "Defined":
        files = current.lua.definitions.get(check["name"])
        return Outcome(HOLDS, ", ".join(files)) if files else \
            Outcome(BROKEN, f"{check['name']} is not defined by any loaded file")
    if kind == "Pattern":
        file = check["file"]
        if file not in current.load_set.files:
            return Outcome(UNKNOWN, f"{file} is not loaded on this client")
        text = (paths.addons_root(current.root) / file).read_text(encoding="utf-8", errors="replace")
        match = re.search(check["regex"], text, re.MULTILINE)
        present = match is not None
        where = f" at line {text.count(chr(10), 0, match.start()) + 1}" if match else ""
        if present == (check["expect"] == "Present"):
            return Outcome(HOLDS, f"{'present' if present else 'absent'}{where}")
        return Outcome(BROKEN, f"expected {check['expect'].lower()}, found {'present' if present else 'absent'}{where}")
    if kind == "FlagAbsent":
        entries = current.docs.get(check["entry"])
        if not entries:
            return Outcome(BROKEN, f"{check['entry']} is no longer documented")
        flagged = [entry.file for entry in entries if check["flag"] in entry.flags]
        if flagged:
            return Outcome(BROKEN, f"{check['flag']} is now set ({', '.join(flagged)})")
        return Outcome(HOLDS, f"{check['flag']} absent")
    if kind == "FlagEquals":
        # The value as the docs write it: a string keeps its quotes.
        entries = current.docs.get(check["entry"])
        if not entries:
            return Outcome(BROKEN, f"{check['entry']} is no longer documented")
        differing = [f"{entry.flags.get(check['flag'], 'absent')} ({entry.file})" for entry in entries
                     if entry.flags.get(check["flag"]) != check["value"]]
        if differing:
            return Outcome(BROKEN, f"{check['flag']} is now {'; '.join(differing)}")
        return Outcome(HOLDS, f"{check['flag']} = {check['value']}")
    changed, unknown = [], []
    for file in check["files"]:
        if file not in current.load_set.files:
            unknown.append(f"{file} is not loaded on this client")
            continue
        before = views.baseline_hash(baseline, file)
        if before is None:
            unknown.append(f"no baseline hash for {file}")
            continue
        if current.hashes.get(file) != before:
            changed.append(file)
    if unknown:
        return Outcome(UNKNOWN, "; ".join(unknown))
    if changed:
        return Outcome(NEEDS_REVIEW, f"{len(changed)} file(s) changed", changed)
    return Outcome(HOLDS, f"{len(check['files'])} file(s) unchanged")
