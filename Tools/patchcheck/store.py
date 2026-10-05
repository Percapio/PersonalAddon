"""The baseline store and the verified record (Architecture/20261002-Phase10.md
section 6.3).

<store>/export/         the last accepted export (the BlizzardInterfaceCode tree)
<store>/manifest.json   every file's SHA-256, plus the verified record
<store>/last-check.json the last check's machine-readable result, for accept
<store>/diffs/          full watched-file diffs, one file per check

Accepting commits at one atomic rename: manifest.new.json over manifest.json. Until
then, manifest.new.json marks a swap in progress, and recovery rolls back.
"""
import json
import os
import pathlib
import shutil

EXPORT = "export"
EXPORT_NEW = "export.new"
EXPORT_OLD = "export.old"
MANIFEST = "manifest.json"
MANIFEST_NEW = "manifest.new.json"
LAST_CHECK = "last-check.json"
DIFFS = "diffs"


def read_json(path):
    path = pathlib.Path(path)
    if not path.exists():
        return None
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path, value):
    """Written to a temporary file, then renamed over the target."""
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def pending_recovery(store, verified_path):
    """What recovery would do now, as printable actions, without doing any of it."""
    store = pathlib.Path(store)
    actions = []
    if (store / MANIFEST_NEW).exists():
        if (store / EXPORT_NEW).exists():
            actions.append(f"delete {EXPORT_NEW}/ (accept stopped before its commit)")
        if (store / EXPORT_OLD).exists():
            if (store / EXPORT).exists():
                actions.append(f"delete {EXPORT}/, the uncommitted new copy")
            actions.append(f"rename {EXPORT_OLD}/ back to {EXPORT}/")
        actions.append(f"delete {MANIFEST_NEW} (roll back to the last accepted export)")
        return actions
    if (store / EXPORT_NEW).exists():
        actions.append(f"delete {EXPORT_NEW}/ (accept stopped while copying)")
    if (store / EXPORT_OLD).exists():
        actions.append(f"delete {EXPORT_OLD}/ (accept stopped after its commit)")
    return actions


def recover(store, verified_path):
    """Runs the recovery pending_recovery describes; returns the actions taken."""
    store = pathlib.Path(store)
    actions = pending_recovery(store, verified_path)
    if (store / MANIFEST_NEW).exists():
        if (store / EXPORT_NEW).exists():
            shutil.rmtree(store / EXPORT_NEW)
        if (store / EXPORT_OLD).exists():
            if (store / EXPORT).exists():
                shutil.rmtree(store / EXPORT)
            os.replace(store / EXPORT_OLD, store / EXPORT)
        (store / MANIFEST_NEW).unlink()
        return actions
    if (store / EXPORT_NEW).exists():
        shutil.rmtree(store / EXPORT_NEW)
    if (store / EXPORT_OLD).exists():
        shutil.rmtree(store / EXPORT_OLD)
    return actions


def accept_incomplete(store, verified_path):
    """(store digest, verified digest) when step 5 was interrupted, else None."""
    manifest = read_json(pathlib.Path(store) / MANIFEST)
    verified = read_json(verified_path)
    if not manifest or not verified:
        return None
    stored = manifest.get("record", {}).get("exportDigest")
    recorded = verified.get("exportDigest")
    if stored and recorded and stored != recorded:
        return stored, recorded
    return None


def baseline_export(store):
    root = pathlib.Path(store) / EXPORT
    return root if root.is_dir() else None
