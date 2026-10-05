"""DocsIndex: the generated API docs as entries with every flag they declare
(Architecture/20261002-Phase10.md section 3.1).

One entry per documented function, widget method and event. Names follow the docs:
`UnitThreatSituation`, `C_Item.GetItemQualityByID`, `SimpleStatusBarAPI:SetValue`
(the documenting system, then the method), and `event CHAT_MSG_LOOT`.
"""
import re
from dataclasses import dataclass, field

from . import paths
from .lua_table import LuaParseError, LuaTable, parse_docs_file, render

ENTRY_IDENTITY_KEYS = {"Name", "Type", "Arguments", "Returns", "Payload", "Documentation", "LiteralName"}
FIELD_IDENTITY_KEYS = {"Name", "Documentation"}
FIELD_LISTS = ("Arguments", "Returns", "Payload")
LUA_LIBRARY_NAMESPACES = {"table", "string", "math", "bit", "coroutine", "os", "io", "debug"}

GLOBAL_FUNCTION = "GlobalFunction"
NAMESPACED_FUNCTION = "NamespacedFunction"
WIDGET_METHOD = "WidgetMethod"
EVENT = "Event"

# The lint's definition (Phase 9 section 9.2), kept exactly: an entry key that begins
# with "Secret", other than SecretArguments and SecretArgumentsAddAspect; or a field
# key containing such a word.
_SECRET_ENTRY_KEY = re.compile(r"Secret(?!Arguments)[A-Za-z]+")
_SECRET_FIELD_KEY = re.compile(r"Secret(?!Arguments)[A-Za-z]+")


class ExportMissing(Exception):
    pass


@dataclass
class DocEntry:
    name: str
    kind: str
    short_name: str
    system: str
    namespace: str
    flags: dict
    field_flags: dict
    file: str


@dataclass
class DocsIndex:
    entries: dict = field(default_factory=dict)
    parse_errors: list = field(default_factory=list)

    def add(self, entry):
        self.entries.setdefault(entry.name, []).append(entry)

    def get(self, name):
        return self.entries.get(name, [])

    def all_entries(self):
        for group in self.entries.values():
            yield from group

    def combined_flags(self, name):
        """Every flag of every entry documenting name, fields prefixed by their list."""
        combined = {}
        for entry in self.get(name):
            for key, value in entry.flags.items():
                combined[key] = value
            for field_name, flags in entry.field_flags.items():
                for key, value in flags.items():
                    combined[f"{field_name}.{key}"] = value
        return combined


def is_secret_capable(entry):
    if any(_SECRET_ENTRY_KEY.fullmatch(key) for key in entry.flags):
        return True
    return any(_SECRET_FIELD_KEY.search(key)
               for flags in entry.field_flags.values() for key in flags)


def _field_flags(table):
    found = {}
    for list_name in FIELD_LISTS:
        listed = table.get(list_name)
        if not isinstance(listed, LuaTable):
            continue
        for item in listed.items:
            if not isinstance(item, LuaTable):
                continue
            label = f"{list_name}.{item.get('Name', '?')}"
            found[label] = {key: render(value) for key, value in item.fields.items()
                            if key not in FIELD_IDENTITY_KEYS}
    return found


def _entry_flags(table):
    return {key: render(value) for key, value in table.fields.items()
            if key not in ENTRY_IDENTITY_KEYS}


def build_docs_index(export_root):
    root = paths.docs_root(export_root)
    if not root.is_dir():
        raise ExportMissing(str(root))
    index = DocsIndex()
    for path in sorted(root.glob("*.lua")):
        relative = path.relative_to(paths.addons_root(export_root)).as_posix()
        try:
            system = parse_docs_file(path.read_text(encoding="utf-8", errors="replace"))
        except LuaParseError as error:
            index.parse_errors.append(f"{relative}: {error}")
            continue
        if not isinstance(system, LuaTable):
            index.parse_errors.append(f"{relative}: the file's value is not a table")
            continue
        system_name = system.get("Name") or path.stem
        system_type = system.get("Type") or ""
        namespace = system.get("Namespace") or ""
        functions = system.get("Functions")
        for item in functions.items if isinstance(functions, LuaTable) else []:
            if not isinstance(item, LuaTable) or item.get("Type") != "Function":
                continue
            short = item.get("Name")
            if system_type == "ScriptObject":
                kind, name = WIDGET_METHOD, f"{system_name}:{short}"
            elif namespace:
                kind, name = NAMESPACED_FUNCTION, f"{namespace}.{short}"
            else:
                kind, name = GLOBAL_FUNCTION, short
            index.add(DocEntry(name, kind, short, system_name, namespace,
                               _entry_flags(item), _field_flags(item), relative))
        events = system.get("Events")
        for item in events.items if isinstance(events, LuaTable) else []:
            if not isinstance(item, LuaTable) or item.get("Type") != "Event":
                continue
            literal = item.get("LiteralName")
            if not literal:
                continue
            index.add(DocEntry(f"event {literal}", EVENT, literal, system_name, namespace,
                               _entry_flags(item), _field_flags(item), relative))
    return index


def secret_capable_sets(index):
    """The four sets the secret-read lint matches against (Phase 9 section 9.2)."""
    globals_, namespaced, widget_methods, events = set(), set(), set(), set()
    for entry in index.all_entries():
        if not is_secret_capable(entry):
            continue
        if entry.kind == EVENT:
            events.add(entry.short_name)
        elif entry.kind == WIDGET_METHOD:
            widget_methods.add(entry.short_name)
        elif entry.kind == NAMESPACED_FUNCTION:
            if entry.namespace not in LUA_LIBRARY_NAMESPACES:
                namespaced.add(entry.short_name)
        else:
            globals_.add(entry.short_name)
    return globals_, namespaced, widget_methods, events
