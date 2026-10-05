"""LuaIndex: global definitions, call sites and callback-registry events in the
files the client loads (Architecture/20261002-Phase10.md section 3.3).

Lua files have comments and string contents blanked before definitions and calls
are matched. XML frame names come from the raw markup. Lua inside XML script
elements is blanked and searched for calls like any Lua file, so a caller added in
an XML handler is not missed.
"""
import re
from dataclasses import dataclass, field

from . import paths
from .lua_scan import blank_lua, line_of

_DEFINE_FUNCTION = re.compile(r"^function\s+([A-Za-z_]\w*)\s*\(", re.MULTILINE)
_DEFINE_ASSIGN = re.compile(r"^([A-Za-z_]\w*)\s*=(?!=)", re.MULTILINE)
_REGISTRY_EVENT = re.compile(r"TriggerEvent\(\s*\"([^\"]+)\"")
_XML_NAME = re.compile(r"<[A-Za-z]+\b[^>]*?\bname\s*=\s*\"([^\"$][^\"]*)\"")
_XML_SCRIPT_BLOCK = re.compile(r"<(Scripts|Script)\b([^>]*)>(.*?)</\1>", re.DOTALL | re.IGNORECASE)
_XML_TAG = re.compile(r"<[^>]+>")
_XML_ENTITIES = {"&lt;": "<", "&gt;": ">", "&amp;": "&", "&quot;": "\"", "&apos;": "'"}
_DOCS_PREFIX = paths.DOCS_FOLDER + "/"


@dataclass
class SourceLine:
    file: str
    line: int


@dataclass
class LuaIndex:
    definitions: dict = field(default_factory=dict)
    call_sites: dict = field(default_factory=dict)
    registry_events: dict = field(default_factory=dict)

    def defines(self, name):
        return name in self.definitions


def _record(table, key, value):
    table.setdefault(key, [])
    if value not in table[key]:
        table[key].append(value)


def _decode_entities(text):
    """Entities decoded and padded to their original length, so offsets still map
    onto the file's lines."""
    for entity, char in _XML_ENTITIES.items():
        text = text.replace(entity, char + " " * (len(entity) - 1))
    return text


def _scan_calls(blanked, original_text, offset_base, relative, call_pattern, index):
    if call_pattern is None:
        return
    for match in call_pattern.finditer(blanked):
        name = match.group(1)
        before = blanked[max(0, match.start() - 12):match.start()]
        if re.search(r"\bfunction\s+$", before):
            continue
        _record(index.call_sites, name,
                SourceLine(relative, line_of(original_text, offset_base + match.start())))


def build_lua_index(export_root, load_set, call_names=()):
    """Definitions and registry events for every loaded file; call sites only for
    call_names, the names a premise asks about (Callers), which keeps the index small."""
    addons = paths.addons_root(export_root)
    index = LuaIndex()
    call_pattern = None
    if call_names:
        alternatives = "|".join(sorted(re.escape(name) for name in call_names))
        call_pattern = re.compile(r"(?<![\w.:])(" + alternatives + r")\s*\(")
    for relative in sorted(load_set.files):
        if relative.startswith(_DOCS_PREFIX):
            continue
        lowered = relative.lower()
        if not (lowered.endswith(".lua") or lowered.endswith(".xml")):
            continue
        text = (addons / relative).read_text(encoding="utf-8", errors="replace")
        if lowered.endswith(".lua"):
            blanked = blank_lua(text)
            for pattern in (_DEFINE_FUNCTION, _DEFINE_ASSIGN):
                for match in pattern.finditer(blanked):
                    if match.group(1) != "local":
                        _record(index.definitions, match.group(1), relative)
            for match in _REGISTRY_EVENT.finditer(text):
                _record(index.registry_events, match.group(1),
                        SourceLine(relative, line_of(text, match.start())))
            _scan_calls(blanked, text, 0, relative, call_pattern, index)
        else:
            for match in _XML_NAME.finditer(text):
                _record(index.definitions, match.group(1), relative)
            for block in _XML_SCRIPT_BLOCK.finditer(text):
                if block.group(1).lower() == "script" and re.search(r"\bfile\s*=", block.group(2)):
                    continue
                body_start = block.start(3)
                inner = block.group(3)
                code = _XML_TAG.sub(lambda tag: " " * len(tag.group(0)), inner)
                code = _decode_entities(code) if "&" in code else code
                blanked = blank_lua(code)
                for match in _REGISTRY_EVENT.finditer(code):
                    _record(index.registry_events, match.group(1),
                            SourceLine(relative, line_of(text, body_start + match.start())))
                _scan_calls(blanked, text, body_start, relative, call_pattern, index)
    return index
