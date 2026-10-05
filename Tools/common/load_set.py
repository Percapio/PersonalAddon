"""LoadSet: the exported files the client loads in game for one game type and text
locale (Architecture/20261002-Phase10.md section 3.2).

Some exported files never load on this client (BossBanner, for one). A name only
such a file defines must not count as defined. The rules below are read from the
export's own TOC tags; a tag they do not know is treated as allowing, and listed.
"""
import re
from dataclasses import dataclass, field

from . import paths

_TRAILING_TAG = re.compile(r"\[([A-Za-z]+)(?::?\s+([^\]]*))?\]")
_PATH_TAG = re.compile(r"^\[(Family|Game)\][\\/]", re.IGNORECASE)
_XML_INCLUDE = re.compile(r"<(?:Script|Include)\b[^>]*?\bfile\s*=\s*\"([^\"]+)\"", re.IGNORECASE)

NO_EFFECT_TAGS = {"bootstrap", "allowloadenvironment", "loadintoenvironment"}


@dataclass
class LoadSet:
    files: set = field(default_factory=set)
    unknown_tags: list = field(default_factory=list)
    missing_files: list = field(default_factory=list)


def _values(text):
    """A tag's values; the export separates them with commas, spaces, or both."""
    return {value.lower() for value in re.split(r"[\s,]+", text or "") if value}


def _matches_client(values, config):
    return bool(values & {game_type.lower() for game_type in config["game_types"]})


def _file_index(addons):
    """Lower-cased relative path -> the path as it is on disk."""
    found = {}
    for path in addons.rglob("*"):
        if path.is_file():
            relative = path.relative_to(addons).as_posix()
            found[relative.lower()] = relative
    return found


def _choose_toc(folder):
    tocs = [path for path in folder.glob("*.toc")]
    named = [path for path in tocs if path.stem.lower() == folder.name.lower()]
    if named:
        return named[0]
    return tocs[0] if len(tocs) == 1 else None


def _header(lines, config, unknown, toc_name):
    """The TOC's ## lines. A header line can carry its own tags, as in
    `## AllowLoad: game [AllowLoadGameType classic]`; it applies only when they allow
    this client."""
    header = {}
    for line in lines:
        match = re.match(r"^##\s*([^:]+):\s*(.*)$", line)
        if not match:
            continue
        value = match.group(2)
        tags = _TRAILING_TAG.findall(value)
        if tags and not _line_allowed(tags, config, unknown, toc_name):
            continue
        header[match.group(1).strip().lower()] = _TRAILING_TAG.sub("", value).strip()
    return header


def _line_allowed(tags, config, unknown, toc_name):
    locale = config["text_locale"].lower()
    for name, value in tags:
        key = name.lower()
        values = _values(value)
        if key == "allowloadgametype":
            if not _matches_client(values, config):
                return False
        elif key == "excludeloadgametype":
            if _matches_client(values, config):
                return False
        elif key == "allowload":
            if "glue" in values and "game" not in values and "both" not in values:
                return False
        elif key == "allowloadtextlocale":
            if locale not in values:
                return False
        elif key == "excludeloadtextlocale":
            if locale in values:
                return False
        elif key in NO_EFFECT_TAGS:
            continue
        else:
            unknown.append(f"{toc_name}: [{name}{(' ' + value) if value else ''}]")
    return True


def resolve_load_set(export_root, config=None):
    config = config or paths.load_config()
    addons = paths.addons_root(export_root)
    index = _file_index(addons)
    result = LoadSet()
    xml_queue = []

    def add(relative, source):
        actual = index.get(relative.lower())
        if actual is None:
            result.missing_files.append(f"{relative} (listed by {source})")
            return
        if actual in result.files:
            return
        result.files.add(actual)
        if actual.lower().endswith(".xml"):
            xml_queue.append(actual)

    for folder in sorted(path for path in addons.iterdir() if path.is_dir()):
        toc = _choose_toc(folder)
        if toc is None:
            continue
        lines = toc.read_text(encoding="utf-8", errors="replace").splitlines()
        toc_name = toc.relative_to(addons).as_posix()
        header = _header(lines, config, result.unknown_tags, toc_name)
        allowed_types = header.get("allowloadgametype")
        if allowed_types and not _matches_client(_values(allowed_types), config):
            continue
        if header.get("allowload", "").strip().lower() == "glue":
            continue
        for raw in lines:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            prefix = ""
            path_tag = _PATH_TAG.match(line)
            if path_tag:
                prefix = (config["family_folder"] if path_tag.group(1).lower() == "family"
                          else config["game_folder"]) + "/"
                line = line[path_tag.end():]
            tags = _TRAILING_TAG.findall(line)
            path_part = prefix + _TRAILING_TAG.sub("", line).strip()
            if not _line_allowed(tags, config, result.unknown_tags, toc_name):
                continue
            add(f"{folder.name}/{path_part.replace(chr(92), '/')}", toc_name)

    # An XML include names its file relative to the XML's own folder or, as
    # Blizzard_SettingsDefinitions_Frame/Mainline/Colorblind.xml does, to the addon's
    # root; the first that exists is the one taken.
    while xml_queue:
        xml = xml_queue.pop()
        text = (addons / xml).read_text(encoding="utf-8", errors="replace")
        base = xml.rsplit("/", 1)[0]
        addon_folder = xml.split("/", 1)[0]
        for included in _XML_INCLUDE.findall(text):
            target = included.replace("\\", "/")
            if target.lower().startswith("interface/addons/"):
                candidates = [target[len("interface/addons/"):]]
            else:
                candidates = [f"{base}/{target}", f"{addon_folder}/{target}"]
            candidates = [_normalise(candidate) for candidate in candidates]
            chosen = next((candidate for candidate in candidates if candidate.lower() in index), candidates[0])
            add(chosen, xml)
    result.missing_files.sort()
    result.unknown_tags = sorted(set(result.unknown_tags))
    return result


def _normalise(relative):
    parts = []
    for part in relative.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            if parts:
                parts.pop()
            continue
        parts.append(part)
    return "/".join(parts)
