"""The patch check (Architecture/20261002-Phase10.md section 6): GAPBugs01 R6 and
section 5 S4, made checkable.

Usage:
  python Tools/patchcheck/patch_check.py status
  python Tools/patchcheck/patch_check.py adopt
  python Tools/patchcheck/patch_check.py check [--baseline-export DIR]
  python Tools/patchcheck/patch_check.py accept [--reviewed] [--resume]

Exit codes: check gives 0 for Pass, 2 for Review, 1 for Fail; every command gives 3
when it refuses. status gives 0 for UpToDate and 2 when something is due.
"""
import argparse
import datetime
import difflib
import os
import pathlib
import shutil
import sys
import time
from dataclasses import dataclass, field

TOOLS = pathlib.Path(__file__).resolve().parents[1]
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

from common import docs_index, paths  # noqa: E402
from lint import secret_lint  # noqa: E402
from patchcheck import client_build, premises, store, surface, views  # noqa: E402
from patchcheck import report as report_module  # noqa: E402

REFUSED_EXIT = 3


class Refused(Exception):
    def __init__(self, kind, message):
        super().__init__(f"{kind}: {message}")
        self.kind = kind
        self.message = message


@dataclass
class ToolPaths:
    repo: pathlib.Path
    export: pathlib.Path
    binary: pathlib.Path
    store: pathlib.Path
    register: pathlib.Path
    reports: pathlib.Path
    verified: pathlib.Path
    allowlist: pathlib.Path
    config: dict = field(default_factory=dict)


def default_paths(config=None):
    config = config or paths.load_config()
    here = TOOLS / "patchcheck"
    return ToolPaths(paths.REPO, paths.EXPORT, paths.BINARY, pathlib.Path(config["store"]["path"]),
                     here / "premises.toml", here / "reports", here / "verified.json",
                     secret_lint.ALLOWLIST, config)


def _say(lines, out):
    for line in lines:
        out(line)


def _recover(tool_paths, out):
    actions = store.recover(tool_paths.store, tool_paths.verified)
    _say([f"recovery: {action}" for action in actions], out)
    return actions


def _require_export(tool_paths):
    if not paths.docs_root(tool_paths.export).is_dir():
        raise Refused("ExportMissing", f"no export at {tool_paths.export}")


def _require_fresh(tool_paths, client):
    exported_at = views.newest_mtime(tool_paths.export)
    if client.binary_modified_at > exported_at:
        raise Refused("ExportStale", "WowB.exe is newer than the export: export the UI again "
                      "(launch with -console; at the login screen, exportInterfaceFiles code)")
    return exported_at


def _when(seconds):
    return datetime.datetime.fromtimestamp(seconds).strftime("%Y-%m-%d %H:%M:%S")


# status -------------------------------------------------------------------------

def status(tool_paths, build_reader=client_build.read_client_build):
    """(kind, lines). Reads only: never recovers or repairs anything."""
    actions = store.pending_recovery(tool_paths.store, tool_paths.verified)
    incomplete = store.accept_incomplete(tool_paths.store, tool_paths.verified)
    resume_line = (f"the store holds export {incomplete[0][:16]} but verified.json records "
                   f"{incomplete[1][:16]}: run accept --resume") if incomplete else None
    if actions:
        lines = ["the next adopt, check or accept will:"] + [f"  {action}" for action in actions]
        return "RecoveryPending", lines + ([f"then {resume_line}"] if resume_line else [])
    verified = store.read_json(tool_paths.verified)
    if verified is None:
        return "BaselineMissing", ["no verified record: run adopt once"]
    if incomplete:
        return "AcceptIncomplete", [resume_line]
    client, reason = client_build.identify(tool_paths.binary, build_reader)
    notes = [f"build unreadable ({reason}); clients compared by WowB.exe's time"] if reason else []
    exported_at = views.newest_mtime(tool_paths.export)
    verified_client = client_build.ClientIdentity.from_json(verified["client"])
    if client.binary_modified_at > exported_at:
        return "ExportStale", notes + [f"WowB.exe ({_when(client.binary_modified_at)}) is newer than the export "
                                       f"({_when(exported_at)}): export the UI again, then check"]
    if client_build.differs(client, verified_client):
        return "CheckDue", notes + [f"client {client.label()} differs from the verified {verified_client.label()}: "
                                    "run check"]
    return "UpToDate", notes + [f"client {client.label()} is the verified one "
                                f"(accepted {_when(verified['acceptedAt'])}, {verified['acceptedBy']})"]


# check --------------------------------------------------------------------------

def _flag_detail(before, after):
    before, after = before or {}, after or {}
    parts = []
    for key in sorted(set(before) | set(after)):
        if key not in before:
            parts.append(f"+{key}={after[key]}")
        elif key not in after:
            parts.append(f"-{key}")
        elif before[key] != after[key]:
            parts.append(f"{key}: {before[key]} -> {after[key]}")
    return "; ".join(parts[:6]) + (f"; and {len(parts) - 6} more" if len(parts) > 6 else "")


def _surface_items(changes):
    items = []
    for name, change, detail in changes:
        if change == surface.FLAGS_CHANGED:
            text = _flag_detail(detail["before"], detail["after"])
        elif change == surface.MOVED:
            text = f"{', '.join(detail['before'])} -> {', '.join(detail['after'])}"
        elif change == surface.GONE:
            text = f"was in {', '.join(detail['before'])}"
        elif change == surface.APPEARED:
            text = f"now in {', '.join(detail['after'])}"
        else:
            text = ""
        items.append({"name": name.name, "origin": name.origin, "kind": name.kind, "change": change,
                      "detail": text, "usedAt": name.used_at})
    return items


def _watched(register, baseline, current):
    found = []
    for file in premises.watched_files(register):
        before_hash, after_hash = views.baseline_hash(baseline, file), current.hashes.get(file)
        if before_hash == after_hash:
            continue
        item = {"file": file}
        if before_hash is None:
            item["change"] = "Added"
        elif after_hash is None:
            item["change"] = "Removed"
        else:
            item["change"] = "Modified"
        if baseline.complete:
            old_text = views.baseline_file_text(baseline, file)
            new_path = paths.addons_root(current.root) / file
            new_text = new_path.read_text(encoding="utf-8", errors="replace") if new_path.exists() else ""
            diff = list(difflib.unified_diff((old_text or "").splitlines(), new_text.splitlines(),
                                             f"baseline/{file}", f"current/{file}", lineterm="", n=2))
            item["diff"] = diff
            item["added"] = sum(1 for line in diff if line.startswith("+") and not line.startswith("+++"))
            item["removed"] = sum(1 for line in diff if line.startswith("-") and not line.startswith("---"))
        found.append(item)
    return found


def _docs_changes(baseline, current):
    if not baseline.complete:
        return [], [], []
    old_names, new_names = set(baseline.docs.entries), set(current.docs.entries)
    changed = sorted(name for name in old_names & new_names
                     if baseline.docs.combined_flags(name) != current.docs.combined_flags(name))
    return sorted(new_names - old_names), sorted(old_names - new_names), changed


def run_check(tool_paths, now=time.time, build_reader=client_build.read_client_build,
              baseline_export=None, out=print):
    """Compares the current export with the baseline and writes the report."""
    _recover(tool_paths, out)
    register = premises.load_register(tool_paths.register)
    _require_export(tool_paths)
    client, reason = client_build.identify(tool_paths.binary, build_reader)
    _require_fresh(tool_paths, client)
    verified = store.read_json(tool_paths.verified)
    config = tool_paths.config
    names = premises.call_names(register)

    if baseline_export is not None:
        baseline = views.build_view(pathlib.Path(baseline_export), config, names)
        baseline_identity = {"build": None, "binaryModifiedAt": baseline.exported_at,
                             "label": f"export at {pathlib.Path(baseline_export)}"}
    else:
        if verified is None:
            raise Refused("BaselineMissing", "no verified record: run adopt once")
        stored = store.baseline_export(tool_paths.store)
        baseline = views.build_view(stored, config, names) if stored else views.DegradedView(verified)
        identity = client_build.ClientIdentity.from_json(verified["client"])
        baseline_identity = dict(identity.to_json(), label=identity.label())
    current = views.build_view(tool_paths.export, config, names)

    docs_list = [current.docs] + ([baseline.docs] if baseline.complete else [])
    definitions = set(current.lua.definitions)
    registry_events = set(current.lua.registry_events)
    if baseline.complete:
        definitions |= set(baseline.lua.definitions)
        registry_events |= set(baseline.lua.registry_events)
    else:
        for known in baseline.record.get("surfaceDefinitions", {}):
            kind, _, plain = known.partition(" ")
            if kind == "lua":
                definitions.add(plain)
            elif kind == "registry":
                registry_events.add(plain)
    names_on_surface = surface.derive_surface(tool_paths.repo, docs_list, definitions, registry_events)
    surface_changes = surface.compare_surface(names_on_surface, baseline, current)

    evaluated = []
    for premise in register:
        outcome = premises.evaluate_premise(premise, current, baseline)
        evaluated.append({"id": premise.id, "statement": premise.statement, "source": premise.source,
                          "consequence": premise.consequence, "status": outcome.status,
                          "evidence": outcome.evidence, "changedFiles": outcome.changed_files})

    hits, stale, entries, sizes = secret_lint.lint(tool_paths.export, tool_paths.repo, tool_paths.allowlist)
    docs_added, docs_removed, docs_changed = _docs_changes(baseline, current)
    if baseline.complete:
        old_files, new_files = set(baseline.hashes), set(current.hashes)
        export_added, export_removed = sorted(new_files - old_files), sorted(old_files - new_files)
        export_modified = sum(1 for file in old_files & new_files if baseline.hashes[file] != current.hashes[file])
    else:
        export_added, export_removed, export_modified = [], [], 0

    definitions_record, flags_record = surface.record_of(names_on_surface, current)
    counts = {"total": len(names_on_surface)}
    for _, change, _ in surface_changes:
        counts[change] = counts.get(change, 0) + 1
    checked_at = now()
    result = {
        "formatVersion": 1,
        "checkedAt": checked_at,
        "client": dict(client.to_json(), label=client.label()),
        "buildNote": reason,
        "baseline": baseline_identity,
        "exportDigest": views.export_digest(current.hashes),
        "exportedAt": current.exported_at,
        "degraded": not baseline.complete,
        "premises": evaluated,
        "surface": _surface_items(surface_changes),
        "surfaceCounts": counts,
        "watched": _watched(register, baseline, current),
        "lint": {"hits": [f"{h[0]}:{h[1]} {h[2]} ({h[3]})" for h in hits],
                 "stale": [f"{e['file']} | {e['name']} | {e['snippet']}" for e in stale],
                 "allowlisted": len(entries), "sizes": list(sizes)},
        "exportAdded": export_added,
        "exportRemoved": export_removed,
        "exportModifiedCount": export_modified,
        "docsAdded": docs_added,
        "docsRemoved": docs_removed,
        "docsFlagsChanged": docs_changed,
        "docsParseErrors": current.docs.parse_errors + (baseline.docs.parse_errors if baseline.complete else []),
        "loadSet": {"files": len(current.load_set.files), "unknownTags": current.load_set.unknown_tags,
                    "missingFiles": current.load_set.missing_files},
        "record": {
            "watchedHashes": {file: current.hashes.get(file) for file in premises.watched_files(register)
                              if current.hashes.get(file)},
            "surfaceDefinitions": definitions_record,
            "usedFlags": flags_record,
        },
    }
    result["verdict"] = report_module.judge(result)
    stamp = datetime.datetime.fromtimestamp(checked_at).strftime("%Y-%m-%d")
    name = f"{stamp}-{client.label()}"
    tool_paths.reports.mkdir(parents=True, exist_ok=True)
    report_path = tool_paths.reports / f"{name}.md"
    report_path.write_text(report_module.render_markdown(result, config), encoding="utf-8")
    result["report"] = report_path.name
    diffs = pathlib.Path(tool_paths.store) / store.DIFFS
    diffs.mkdir(parents=True, exist_ok=True)
    (diffs / f"{name}.diff").write_text("\n".join(line for item in result["watched"]
                                                  for line in item.get("diff", [])) + "\n", encoding="utf-8")
    saved = dict(result)
    saved["watched"] = [{key: value for key, value in item.items() if key != "diff"} for item in result["watched"]]
    store.write_json(pathlib.Path(tool_paths.store) / store.LAST_CHECK, saved)
    out(f"{result['verdict']['kind']}: report {report_path}")
    _say([f"  {reason_line}" for reason_line in result["verdict"]["reasons"][:20]], out)
    return result


# adopt and accept ---------------------------------------------------------------------

def _copy_and_verify(source, destination, expected_digest):
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(source, destination)
    hashes, _ = views.hash_export(destination)
    digest = views.export_digest(hashes)
    if expected_digest is not None and digest != expected_digest:
        shutil.rmtree(destination)
        raise Refused("ExportChangedSinceCheck", "the export changed after it was checked: check again")
    return hashes, digest


def _no_fault(step):
    return None


def adopt(tool_paths, now=time.time, build_reader=client_build.read_client_build, out=print):
    """Records the current export as verified without comparing it. Used once."""
    _recover(tool_paths, out)
    if store.read_json(tool_paths.verified) is not None or store.baseline_export(tool_paths.store):
        raise Refused("BaselineExists", "a baseline already exists; adopt runs only once")
    register = premises.load_register(tool_paths.register)
    _require_export(tool_paths)
    client, reason = client_build.identify(tool_paths.binary, build_reader)
    exported_at = _require_fresh(tool_paths, client)
    current = views.build_view(tool_paths.export, tool_paths.config, premises.call_names(register))
    names_on_surface = surface.derive_surface(tool_paths.repo, [current.docs], set(current.lua.definitions),
                                              set(current.lua.registry_events))
    definitions_record, flags_record = surface.record_of(names_on_surface, current)
    digest = views.export_digest(current.hashes)
    record = {
        "client": client.to_json(),
        "exportDigest": digest,
        "exportedAt": exported_at,
        "acceptedAt": now(),
        "acceptedBy": "Adopted",
        "report": None,
        "watchedHashes": {file: current.hashes.get(file) for file in premises.watched_files(register)
                          if current.hashes.get(file)},
        "surfaceDefinitions": definitions_record,
        "usedFlags": flags_record,
    }
    store_root = pathlib.Path(tool_paths.store)
    store_root.mkdir(parents=True, exist_ok=True)
    hashes, _ = _copy_and_verify(tool_paths.export, store_root / store.EXPORT_NEW, digest)
    store.write_json(store_root / store.MANIFEST_NEW, {"formatVersion": 1, "record": record, "hashes": hashes})
    os.replace(store_root / store.EXPORT_NEW, store_root / store.EXPORT)
    os.replace(store_root / store.MANIFEST_NEW, store_root / store.MANIFEST)
    store.write_json(tool_paths.verified, record)
    out(f"adopted {client.label()} (exported {_when(exported_at)}) as the verified baseline"
        + (f"; build unreadable: {reason}" if reason else ""))
    return record


def accept(tool_paths, now=time.time, reviewed=False, resume=False,
           build_reader=client_build.read_client_build, fault=_no_fault, out=print):
    """Makes the last checked export the new baseline. All or nothing; commits at
    one atomic rename (Phase 10 section 6.3). fault(step) lets tests stop it."""
    _recover(tool_paths, out)
    store_root = pathlib.Path(tool_paths.store)
    if resume:
        incomplete = store.accept_incomplete(store_root, tool_paths.verified)
        if not incomplete:
            out("nothing to resume")
            return store.read_json(tool_paths.verified)
        record = store.read_json(store_root / store.MANIFEST)["record"]
        store.write_json(tool_paths.verified, record)
        out("resumed: verified.json rewritten from the store's manifest")
        return record
    last = store.read_json(store_root / store.LAST_CHECK)
    if last is None:
        raise Refused("NoCheck", "no check has run against this store: run check first")
    kind = last["verdict"]["kind"]
    if kind == report_module.FAIL:
        raise Refused("VerdictFail", "the last check failed; fix the design, code or register, then check again")
    if kind == report_module.REVIEW and not reviewed:
        raise Refused("NotReviewed", "the last check needs review: read its report, then accept --reviewed")
    hashes_now, _ = views.hash_export(tool_paths.export)
    if views.export_digest(hashes_now) != last["exportDigest"]:
        raise Refused("ExportChangedSinceCheck", "the export changed after it was checked: check again")
    record = dict(last["record"])
    record.update({
        "client": {"build": last["client"]["build"], "binaryModifiedAt": last["client"]["binaryModifiedAt"]},
        "exportDigest": last["exportDigest"],
        "exportedAt": last["exportedAt"],
        "acceptedAt": now(),
        "acceptedBy": "Accepted" if kind == report_module.PASS else "AcceptedAfterReview",
        "report": last.get("report"),
    })
    hashes, _ = _copy_and_verify(tool_paths.export, store_root / store.EXPORT_NEW, last["exportDigest"])
    fault("copied")
    store.write_json(store_root / store.MANIFEST_NEW, {"formatVersion": 1, "record": record, "hashes": hashes})
    fault("manifest-new")
    if (store_root / store.EXPORT).exists():
        os.replace(store_root / store.EXPORT, store_root / store.EXPORT_OLD)
    fault("between-renames")
    os.replace(store_root / store.EXPORT_NEW, store_root / store.EXPORT)
    fault("renamed")
    os.replace(store_root / store.MANIFEST_NEW, store_root / store.MANIFEST)
    fault("committed")
    store.write_json(tool_paths.verified, record)
    fault("verified")
    if (store_root / store.EXPORT_OLD).exists():
        shutil.rmtree(store_root / store.EXPORT_OLD)
    out(f"accepted {last['client']['label']} ({record['acceptedBy']})")
    return record


# command line -------------------------------------------------------------------------

def main(argv=None):
    parser = argparse.ArgumentParser(description="PersonalAddon's patch check (Phase 10 section 6)")
    parser.add_argument("command", choices=["status", "adopt", "check", "accept"])
    parser.add_argument("--reviewed", action="store_true", help="accept a Review verdict after reading its report")
    parser.add_argument("--resume", action="store_true", help="finish an accept that stopped before verified.json")
    parser.add_argument("--baseline-export", help="compare against this export folder instead of the store")
    for option in ("export", "store", "verified", "reports", "register", "binary"):
        parser.add_argument(f"--{option}")
    arguments = parser.parse_args(argv)
    tool_paths = default_paths()
    for option in ("export", "store", "verified", "reports", "register", "binary"):
        value = getattr(arguments, option)
        if value:
            setattr(tool_paths, option, pathlib.Path(value))
    try:
        if arguments.command == "status":
            kind, lines = status(tool_paths)
            print(kind)
            _say([f"  {line}" for line in lines], print)
            return 0 if kind == "UpToDate" else 2
        if arguments.command == "adopt":
            adopt(tool_paths)
            return 0
        if arguments.command == "check":
            result = run_check(tool_paths, baseline_export=arguments.baseline_export)
            return report_module.EXIT_CODES[result["verdict"]["kind"]]
        accept(tool_paths, reviewed=arguments.reviewed, resume=arguments.resume)
        return 0
    except Refused as refusal:
        print(f"refused: {refusal.kind}: {refusal.message}")
        return REFUSED_EXIT
    except premises.RegisterInvalid as invalid:
        print("refused: RegisterInvalid")
        _say([f"  {fault}" for fault in invalid.faults], print)
        return REFUSED_EXIT
    except docs_index.ExportMissing as missing:
        print(f"refused: ExportMissing: {missing}")
        return REFUSED_EXIT


if __name__ == "__main__":
    sys.exit(main())
