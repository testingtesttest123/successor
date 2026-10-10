"""Bounded first-and-tail output retention with an exact prefix spill.

Copied/adapted from Albedo ``priv/python/albedo_capture.py`` at
8920b8a8f4b295be0fde3d20aedf2a3cf5bcd450 (WTFPL v2).  Removed global spill
pruning, traces, images and host hooks. Spill ownership is per Capture.
"""
from __future__ import annotations
import os, re, tempfile
from pathlib import Path
from typing import BinaryIO
from .api import OUTPUT_PREVIEW as PREVIEW, RETAIN

SPILL_LIMIT = 16 * 1024 * 1024
ENCODE_CHARS = 64 * 1024

class Capture:
    def __init__(self, id: str, kind: str = "job", spill_dir: str | os.PathLike[str] | None = None) -> None:
        self.id, self.kind = id, kind
        self.data = bytearray()
        self._tail: bytearray | None = None
        self.seen = 0
        self.spill: str | None = None
        self.spilled = 0
        self._spill_file: BinaryIO | None = None
        self.spill_dir = None if spill_dir is None else os.fspath(spill_dir)

    def write(self, text: str) -> None:
        room = RETAIN - len(self.data)
        if text.isascii() and len(text) > room + PREVIEW and self.spill_dir is None:
            self.write_bytes(text[:room].encode())
            self.seen += len(text) - room - PREVIEW
            self.write_bytes(text[-PREVIEW:].encode())
            return
        # Encode bounded character windows: RoutedOutput may hand us a very large
        # Unicode string, and spilling must not require a second whole-output byte copy.
        for offset in range(0, len(text), ENCODE_CHARS):
            self.write_bytes(text[offset : offset + ENCODE_CHARS].encode("utf-8", errors="replace"))

    def write_bytes(self, data: bytes | bytearray | memoryview) -> None:
        size = len(data)
        self.seen += size
        room = RETAIN - len(self.data)
        if size <= room:
            self.data += data
        else:
            if self._tail is None:
                self._tail = self.data[-PREVIEW:]
                self.data += data[:room]
                self.data = self.data[:]
            if size >= PREVIEW:
                self._tail = bytearray(data[-PREVIEW:])
            else:
                self._tail += data
                del self._tail[:-PREVIEW]
        if self.seen > RETAIN and self.spill_dir is not None:
            self._spill(data, size)

    def _spill(self, data: bytes | bytearray | memoryview, size: int) -> None:
        if self._spill_file is None:
            if self.spill is not None or self.spilled or self.spill_dir is None:
                return
            try:
                Path(self.spill_dir).mkdir(parents=True, exist_ok=True)
                fd, path = tempfile.mkstemp(prefix=re.sub(r"[^\w.-]", "_", self.id)+"-", suffix=".txt", dir=self.spill_dir)
                self._spill_file = os.fdopen(fd, "wb", buffering=0)
                self.spill = path
                prefix = self.data[:self.seen-size]
                self.spilled = self._spill_file.write(prefix)
                if self.spilled != len(prefix): raise OSError("incomplete output spill write")
            except OSError:
                self.end_spill(); self.spilled = -1; self.spill = None; return
        try:
            piece = data[:max(0, SPILL_LIMIT-self.spilled)]
            written = self._spill_file.write(piece)
            self.spilled += written
            if written != len(piece): raise OSError("incomplete output spill write")
        except OSError:
            self.end_spill(); self.spill = None; self.spilled = -1; return
        if self.spilled >= SPILL_LIMIT: self.end_spill()

    def end_spill(self) -> None:
        if self._spill_file is not None:
            self._spill_file.close(); self._spill_file = None

    def tail(self, limit: int = PREVIEW) -> bytes:
        limit = min(limit, PREVIEW)
        if limit <= 0: return b""
        source = self.data if self._tail is None else self._tail
        return bytes(source[-limit:])

    @property
    def retained(self) -> int:
        return max(len(self.data), self.spilled if self.spill else 0)

    def read_bytes(self, offset: int, limit: int) -> bytes:
        if offset < 0: raise ValueError("offset must be nonnegative")
        if limit <= 0 or offset >= self.seen: return b""
        end = min(offset + limit, self.seen)
        if end <= len(self.data): return bytes(self.data[offset:end])
        if self.spill is None or end > self.spilled:
            raise ValueError("requested output was not retained")
        with open(self.spill, "rb") as source:
            source.seek(offset); result = source.read(end-offset)
        if len(result) != end-offset:
            raise OSError(f"output spill file is incomplete: {self.spill}")
        return result

    def read(self, offset: int = 0, limit: int = 4000) -> str:
        return self.read_bytes(offset, min(max(0, limit), PREVIEW)).decode("utf-8", errors="ignore")
