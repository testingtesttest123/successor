"""Small awaitable/result and bounded-output API.

Copied/adapted from Albedo ``priv/python/albedo_api.py`` at
8920b8a8f4b295be0fde3d20aedf2a3cf5bcd450 (WTFPL v2).  Removed plugin,
host, protocol, and import machinery; retained Text, ReadyList, excerpt and the
OutputCapture protocol for the successor's incarnation-local coding helpers.
"""
from __future__ import annotations
from typing import Protocol

RETAIN = 1024 * 1024
OUTPUT_PREVIEW = 64 * 1024

def _ready(value):
    yield from ()
    return value

class Text(str):
    def __await__(self): return _ready(self)
    @property
    def content(self) -> str: return str(self)
    @property
    def text(self) -> str: return str(self)

class ReadyList(list):
    def __await__(self): return _ready(self)

def excerpt(text: str, chars: int, lines: int | None, *, end: bool, clipped: bool = False) -> Text:
    recovery = "use job.read() for complete text or job.save(path) for exact bytes"
    if lines is None:
        if not 0 <= chars <= OUTPUT_PREVIEW:
            raise ValueError(f"0 <= n <= {OUTPUT_PREVIEW} for previews; {recovery}")
        if clipped and chars > len(text):
            raise ValueError(f"the retained preview cannot supply {chars} characters; {recovery}")
        return Text((text[-chars:] if end else text[:chars]) if chars else "")
    if lines < 0:
        raise ValueError("lines must be nonnegative")
    kept = text.splitlines(keepends=True)
    if clipped and kept:
        if end: kept = kept[1:]
        elif not kept[-1].endswith(("\n", "\r")): kept = kept[:-1]
    if clipped and lines > len(kept):
        raise ValueError(f"the retained preview cannot supply {lines} lines; {recovery}")
    return Text("".join(kept[-lines:] if end else kept[:lines]) if lines else "")

class OutputCapture(Protocol):
    data: bytearray
    seen: int
    spill: str | None
    @property
    def retained(self) -> int: ...
    def read_bytes(self, offset: int, limit: int) -> bytes: ...
    def end_spill(self) -> None: ...
    def write(self, text: str) -> None: ...
    def write_bytes(self, data: bytes | bytearray | memoryview) -> None: ...
    def tail(self, limit: int = OUTPUT_PREVIEW) -> bytes: ...
    def read(self, offset: int = 0, limit: int = 4000) -> str: ...
