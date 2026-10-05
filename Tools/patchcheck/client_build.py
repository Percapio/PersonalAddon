"""The client's identity: its build, read from WowB.exe's version resource, and the
binary's modification time (Architecture/20261002-Phase10.md section 6.1).

The build is the FileVersion string ("1.60.1.70205"). The fixed version numbers
cannot hold it: 70205 does not fit in 16 bits.
"""
import ctypes
import os
import re
import struct
from dataclasses import dataclass
from typing import Optional

NO_VERSION_RESOURCE = "NoVersionResource"
UNPARSABLE = "Unparsable"


@dataclass
class ClientIdentity:
    build: Optional[str]
    binary_modified_at: float

    def to_json(self):
        return {"build": self.build, "binaryModifiedAt": self.binary_modified_at}

    @staticmethod
    def from_json(data):
        return ClientIdentity(data.get("build"), float(data.get("binaryModifiedAt", 0)))

    def label(self):
        return self.build or f"unknown-{int(self.binary_modified_at)}"


def differs(left, right):
    """Two clients differ by build when both builds are known, by the binary's time
    otherwise (Phase 10 section 6.1)."""
    if left.build and right.build:
        return left.build != right.build
    return int(left.binary_modified_at) != int(right.binary_modified_at)


def read_client_build(binary):
    """Returns (build, None) or (None, reason)."""
    try:
        version = ctypes.WinDLL("version")
    except (AttributeError, OSError):
        return None, NO_VERSION_RESOURCE
    path = str(binary)
    size = version.GetFileVersionInfoSizeW(path, None)
    if not size:
        return None, NO_VERSION_RESOURCE
    buffer = ctypes.create_string_buffer(size)
    if not version.GetFileVersionInfoW(path, 0, size, buffer):
        return None, NO_VERSION_RESOURCE
    pointer, length = ctypes.c_void_p(), ctypes.c_uint()
    if not version.VerQueryValueW(buffer, "\\VarFileInfo\\Translation", ctypes.byref(pointer),
                                  ctypes.byref(length)) or length.value < 4:
        return None, NO_VERSION_RESOURCE
    language, codepage = struct.unpack("<HH", ctypes.string_at(pointer.value, 4))
    query = f"\\StringFileInfo\\{language:04x}{codepage:04x}\\FileVersion"
    if not version.VerQueryValueW(buffer, query, ctypes.byref(pointer), ctypes.byref(length)) \
            or not length.value:
        return None, NO_VERSION_RESOURCE
    text = ctypes.wstring_at(pointer.value, length.value).rstrip("\x00").strip()
    if not re.fullmatch(r"\d+(\.\d+){3}", text):
        return None, f"{UNPARSABLE}: {text}"
    return text, None


def identify(binary, build_reader=read_client_build):
    """The client's identity and, when the build was unreadable, why."""
    build, reason = build_reader(binary)
    return ClientIdentity(build, os.path.getmtime(binary)), reason
