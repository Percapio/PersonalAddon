"""The derived surface: every Blizzard name PersonalAddon's code mentions that an
export defines or documents, compared across two exports
(Architecture/20261002-Phase10.md section 5).

Names: documented entries are spelled as the docs spell them (see DocsIndex);
globals defined in Blizzard's Lua or XML are `lua <Name>`; callback-registry
events are `registry <Name>`.
"""
import re
from dataclasses import dataclass, field

from common import docs_index
from common.lua_scan import strip_comment_and_strings
from lint.secret_lint import addon_files

DOCUMENTED = "Documented"
BLIZZARD_LUA = "BlizzardLua"
REGISTRY_EVENT = "RegistryEvent"

UNCHANGED = "Unchanged"
GONE = "Gone"
APPEARED = "Appeared"
MOVED = "Moved"
FLAGS_CHANGED = "FlagsChanged"

_IDENTIFIER = re.compile(r"(?<![.:\w])([A-Za-z_]\w*)")
_CHAIN = re.compile(r"([A-Za-z_][\w.]*)\.([A-Za-z_]\w*)")
_METHOD = re.compile(r"([A-Za-z_][\w.]*)([.:])([A-Za-z_]\w*)")
_LOCAL_LIST = re.compile(r"\blocal\s+(?!function\b)([A-Za-z_][\w\s,]*?)\s*(?:=|$)")
_LOCAL_FUNCTION = re.compile(r"\blocal\s+function\s+([A-Za-z_]\w*)")
_PARAMS = re.compile(r"\bfunction\b\s*[\w.:]*\s*\(([^)]*)\)")
_FOR_VARS = re.compile(r"\bfor\s+([A-Za-z_][\w\s,]*?)\s+(?:=|in)\b")
_ALIAS = re.compile(r"\blocal\s+([A-Za-z_]\w*)\s*=\s*(?:_G\.)?(C_[A-Za-z0-9_]+)\s*$")
_OURS = ("PersonalAddon", "SLASH_PERSONALADDON")


@dataclass
class SurfaceName:
    name: str
    origin: str
    kind: str = ""
    used_at: list = field(default_factory=list)


def _note(found, name, origin, kind, where):
    entry = found.get(name)
    if entry is None:
        entry = found[name] = SurfaceName(name, origin, kind)
    if where not in entry.used_at and len(entry.used_at) < 5:
        entry.used_at.append(where)


def _locals_of(lines):
    names = set()
    for raw in lines:
        code, _ = strip_comment_and_strings(raw)
        for pattern in (_LOCAL_LIST, _PARAMS, _FOR_VARS):
            for match in pattern.finditer(code):
                names.update(part.strip() for part in match.group(1).split(",") if part.strip())
        names.update(_LOCAL_FUNCTION.findall(code))
    names.discard("...")
    return names


def _documented_names(docs_list):
    """short name -> {(qualified name, kind)}, over every index given."""
    by_kind = {docs_index.GLOBAL_FUNCTION: {}, docs_index.NAMESPACED_FUNCTION: {},
               docs_index.WIDGET_METHOD: {}, docs_index.EVENT: {}}
    for docs in docs_list:
        for entry in docs.all_entries():
            if entry.kind == docs_index.NAMESPACED_FUNCTION and \
                    entry.namespace in docs_index.LUA_LIBRARY_NAMESPACES:
                continue
            by_kind[entry.kind].setdefault(entry.short_name, set()).add(entry.name)
    return by_kind


def derive_surface(addon_root, docs_list, definitions, registry_events):
    """docs_list: the DocsIndex of each export compared; definitions and
    registry_events: the union of names the exports' LuaIndex hold."""
    documented = _documented_names(docs_list)
    globals_ = documented[docs_index.GLOBAL_FUNCTION]
    namespaced = documented[docs_index.NAMESPACED_FUNCTION]
    methods = documented[docs_index.WIDGET_METHOD]
    events = documented[docs_index.EVENT]
    found = {}
    for path in addon_files(addon_root):
        relative = path.relative_to(addon_root).as_posix()
        lines = path.read_text(encoding="utf-8").splitlines()
        local_names = _locals_of(lines)
        aliases = {}
        for raw in lines:
            code, _ = strip_comment_and_strings(raw)
            alias = _ALIAS.search(code.strip())
            if alias:
                aliases.setdefault(alias.group(1), set()).add(alias.group(2))
        for number, raw in enumerate(lines, 1):
            code, strings = strip_comment_and_strings(raw)
            where = f"{relative}:{number}"
            for match in _IDENTIFIER.finditer(code):
                name = match.group(1)
                if name in local_names or name.startswith(_OURS):
                    continue
                if re.search(r"\bfunction\s+$", code[:match.start()]):
                    continue
                for qualified in globals_.get(name, ()):
                    _note(found, qualified, DOCUMENTED, docs_index.GLOBAL_FUNCTION, where)
                if name in definitions:
                    _note(found, f"lua {name}", BLIZZARD_LUA, "", where)
            for match in _CHAIN.finditer(code):
                chain, name = match.group(1), match.group(2)
                if chain.startswith("ns"):
                    continue
                if chain == "_G":
                    if name in definitions and not name.startswith(_OURS):
                        _note(found, f"lua {name}", BLIZZARD_LUA, "", where)
                    for qualified in globals_.get(name, ()):
                        _note(found, qualified, DOCUMENTED, docs_index.GLOBAL_FUNCTION, where)
                    continue
                namespace = chain[3:] if chain.startswith("_G.") else chain
                candidates = {namespace} if namespace.startswith("C_") else aliases.get(namespace, set())
                for candidate in candidates:
                    qualified = f"{candidate}.{name}"
                    if qualified in namespaced.get(name, ()):
                        _note(found, qualified, DOCUMENTED, docs_index.NAMESPACED_FUNCTION, where)
            for match in _METHOD.finditer(code):
                chain, _, name = match.groups()
                if chain.startswith("ns") or re.search(r"\bfunction\s+$", code[:match.start()]):
                    continue
                for qualified in methods.get(name, ()):
                    _note(found, qualified, DOCUMENTED, docs_index.WIDGET_METHOD, where)
            for literal in strings:
                for qualified in events.get(literal, ()):
                    _note(found, qualified, DOCUMENTED, docs_index.EVENT, where)
                if literal in definitions and not literal.startswith(_OURS):
                    _note(found, f"lua {literal}", BLIZZARD_LUA, "", where)
                if literal in registry_events:
                    _note(found, f"registry {literal}", REGISTRY_EVENT, "", where)
    return sorted(found.values(), key=lambda surface: surface.name)


def _lua_name(qualified):
    return qualified.split(" ", 1)[1]


def presence(view, surface):
    """Where the view defines a surface name: a sorted list of files, or None."""
    if not view.complete:
        known = view.record.get("surfaceDefinitions", {})
        return known.get(surface.name)
    if surface.origin == DOCUMENTED:
        entries = view.docs.get(surface.name)
        return sorted({entry.file for entry in entries}) if entries else None
    if surface.origin == BLIZZARD_LUA:
        files = view.lua.definitions.get(_lua_name(surface.name))
        return sorted(files) if files else None
    sites = view.lua.registry_events.get(_lua_name(surface.name))
    return sorted({site.file for site in sites}) if sites else None


def flags(view, surface):
    if surface.origin != DOCUMENTED:
        return None
    if not view.complete:
        return view.record.get("usedFlags", {}).get(surface.name)
    return view.docs.combined_flags(surface.name)


def compare_surface(surface, baseline, current):
    changes = []
    for name in surface:
        before, after = presence(baseline, name), presence(current, name)
        if before and not after:
            changes.append((name, GONE, {"before": before}))
        elif after and not before:
            changes.append((name, APPEARED, {"after": after}))
        elif not before and not after:
            continue
        elif name.origin == DOCUMENTED:
            old_flags, new_flags = flags(baseline, name), flags(current, name)
            if old_flags is not None and old_flags != new_flags:
                changes.append((name, FLAGS_CHANGED, {"before": old_flags, "after": new_flags}))
            else:
                changes.append((name, UNCHANGED, {}))
        elif before != after:
            changes.append((name, MOVED, {"before": before, "after": after}))
        else:
            changes.append((name, UNCHANGED, {}))
    return changes


def record_of(surface, view):
    """What a verified record keeps of the surface: definitions and flags."""
    definitions, used_flags = {}, {}
    for name in surface:
        where = presence(view, name)
        if where:
            definitions[name.name] = where
        if name.origin == DOCUMENTED and where:
            used_flags[name.name] = flags(view, name)
    return definitions, used_flags
