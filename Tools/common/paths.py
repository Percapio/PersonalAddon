"""Where everything is (Architecture/20261002-Phase10.md section 2.2).

Every path derives from this file's location: the repo is
<client>/Interface/AddOns/PersonalAddon, so the client root is three levels above
it. Tools/config.toml holds defaults; Tools/config.local.toml, ignored by git,
overrides any key.
"""
import pathlib
import tomllib

TOOLS = pathlib.Path(__file__).resolve().parents[1]
REPO = TOOLS.parent
CLIENT = REPO.parents[2]
EXPORT = CLIENT / "BlizzardInterfaceCode"
BINARY = CLIENT / "WowB.exe"

ADDONS_SUBPATH = pathlib.Path("Interface") / "AddOns"
DOCS_FOLDER = "Blizzard_APIDocumentationGenerated"


def _merge(base, override):
    merged = dict(base)
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key] = _merge(merged[key], value)
        else:
            merged[key] = value
    return merged


def load_config():
    """The merged configuration: config.toml, then config.local.toml over it."""
    with open(TOOLS / "config.toml", "rb") as handle:
        config = tomllib.load(handle)
    local = TOOLS / "config.local.toml"
    if local.exists():
        with open(local, "rb") as handle:
            config = _merge(config, tomllib.load(handle))
    return config


def addons_root(export_root):
    """The Interface/AddOns folder of an export."""
    return pathlib.Path(export_root) / ADDONS_SUBPATH


def docs_root(export_root):
    """The generated API docs folder of an export."""
    return addons_root(export_root) / DOCS_FOLDER
