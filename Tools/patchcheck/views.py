"""ExportView and BaselineView (Architecture/20261002-Phase10.md sections 1.4 and
6.3): everything the patch check knows about one export.
"""
import hashlib
import pathlib
from dataclasses import dataclass, field
from typing import Optional

from common import docs_index, load_set, lua_index, paths


@dataclass
class ExportView:
    root: object
    docs: object
    load_set: object
    lua: object
    hashes: dict
    exported_at: float

    @property
    def complete(self):
        return True


@dataclass
class DegradedView:
    """A baseline known only from its verified record: the store's copy is gone."""
    record: dict
    hashes: dict = field(default_factory=dict)

    @property
    def complete(self):
        return False


def hash_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def hash_export(export_root):
    """ExportPath (relative to the export root's Interface/AddOns) -> SHA-256, and the
    newest modification time. Files outside Interface/AddOns are hashed with their
    path relative to the export root."""
    export_root = pathlib.Path(export_root)
    hashes, newest = {}, 0.0
    addons = paths.addons_root(export_root)
    for path in sorted(export_root.rglob("*")):
        if not path.is_file():
            continue
        try:
            relative = path.relative_to(addons).as_posix()
        except ValueError:
            relative = "../" + path.relative_to(export_root).as_posix()
        hashes[relative] = hash_file(path)
        newest = max(newest, path.stat().st_mtime)
    return hashes, newest


def export_digest(hashes):
    """One digest for a whole export (Phase 10 section 6.2): SHA-256 of the lines
    "<path>\\t<sha>\\n", sorted by path, in UTF-8."""
    digest = hashlib.sha256()
    for relative in sorted(hashes):
        digest.update(f"{relative}\t{hashes[relative]}\n".encode("utf-8"))
    return digest.hexdigest()


def newest_mtime(export_root):
    newest = 0.0
    for path in paths.addons_root(export_root).rglob("*"):
        if path.is_file():
            newest = max(newest, path.stat().st_mtime)
    return newest


def build_view(export_root, config, call_names=()):
    if not paths.addons_root(export_root).is_dir():
        raise docs_index.ExportMissing(str(paths.addons_root(export_root)))
    docs = docs_index.build_docs_index(export_root)
    loaded = load_set.resolve_load_set(export_root, config)
    lua = lua_index.build_lua_index(export_root, loaded, call_names)
    hashes, exported_at = hash_export(export_root)
    return ExportView(export_root, docs, loaded, lua, hashes, exported_at)


def baseline_file_text(view, relative):
    """A baseline file's text, or None when the view is degraded or lacks it."""
    if not view.complete:
        return None
    path = paths.addons_root(view.root) / relative
    return path.read_text(encoding="utf-8", errors="replace") if path.exists() else None


def baseline_hash(view, relative) -> Optional[str]:
    if view.complete:
        return view.hashes.get(relative)
    return view.record.get("watchedHashes", {}).get(relative)
