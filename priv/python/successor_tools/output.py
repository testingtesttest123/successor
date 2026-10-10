"""Honest bounded output reads and atomic complete-output saves.

Copied/adapted from Albedo ``priv/python/albedo_output.py`` and registry behavior
in ``priv/python/albedo_cells.py`` at 8920b8a8f4b295be0fde3d20aedf2a3cf5bcd450
(WTFPL v2). Removed SSH/daemon hooks; registry and spill directory are local to
one successor kernel incarnation. Forgetting never deletes retained artifacts.
"""
from __future__ import annotations
import os, tempfile
from pathlib import Path
from .api import OUTPUT_PREVIEW, RETAIN, OutputCapture, ReadyList, Text, excerpt
from .capture import Capture

def _retention_error(capture: OutputCapture) -> ValueError:
    spill = getattr(capture, "spill", None)
    recovery = (f"The retained spill file is {spill}; it does not contain the discarded suffix. " if spill else "")
    return ValueError(
        f"output has {capture.seen} bytes, but only the first {capture.retained} are retained; "
        "refusing incomplete output. Paginate the retained prefix with "
        "job.read(offset=0, limit=65536) or output.read(id, offset=0, limit=65536), "
        "advancing the byte offset. Bytes beyond retention cannot be recovered by pagination. "
        + recovery + "For job artifacts beyond retention, attach a complete sink before awaiting."
    )

def read_page(capture: OutputCapture, offset: int, limit: int) -> Text:
    if offset < 0 or not 0 <= limit <= OUTPUT_PREVIEW:
        raise ValueError(f"offset >= 0 and 0 <= limit <= {OUTPUT_PREVIEW}; page with offset=")
    if not limit: return Text("")
    if min(offset+limit, capture.seen) > capture.retained: raise _retention_error(capture)
    return Text(capture.read(offset, limit))

class JobOutput:
    capture: OutputCapture
    duration: float | None
    exit_code: int | None
    _read: bool
    def tail(self, n: int = 4000, *, lines: int | None = None) -> Text:
        data = self.capture.tail()
        result = excerpt(data.decode("utf-8", errors="ignore"), n, lines, end=True, clipped=self.capture.seen > len(data))
        if self.exit_code is not None: self._read = True
        return result
    def head(self, n: int = 4000, *, lines: int | None = None) -> Text:
        data = self.capture.data[:OUTPUT_PREVIEW]
        result = excerpt(data.decode("utf-8", errors="ignore"), n, lines, end=False, clipped=self.capture.seen > len(data))
        if self.exit_code is not None: self._read = True
        return result
    def _require_complete(self) -> None:
        if self.duration is None: raise RuntimeError("output is still running; await job before job.read() or job.save(path)")
        if self.capture.seen > self.capture.retained: raise _retention_error(self.capture)
    def read(self, offset: int = 0, limit: int | None = None) -> Text:
        if limit is None:
            if offset < 0: raise ValueError("offset must be nonnegative")
            self._require_complete()
            size = max(0, self.capture.seen-offset)
            if size > RETAIN:
                raise ValueError("whole text reads are limited to 1 MiB; paginate with job.read(offset=0, limit=65536), advancing the byte offset, or job.save(path) for the complete artifact. Output past 1 MiB is automatically stored on disk (up to 16 MiB).")
            result = Text(self.capture.read_bytes(offset, size).decode("utf-8", errors="replace"))
        else: result = read_page(self.capture, offset, limit)
        if self.duration is not None: self._read = True
        return result
    def save(self, path: str | os.PathLike[str]) -> Text:
        self._require_complete()
        target = Path(path).expanduser().absolute(); target.parent.mkdir(parents=True, exist_ok=True)
        fd, name = tempfile.mkstemp(dir=target.parent, prefix=f".{target.name}.", suffix=".tmp")
        temporary = Path(name)
        try:
            with os.fdopen(fd, "wb") as sink:
                for offset in range(0, self.capture.seen, OUTPUT_PREVIEW): sink.write(self.capture.read_bytes(offset, OUTPUT_PREVIEW))
                sink.flush(); os.fsync(sink.fileno())
            os.replace(temporary, target)
        finally: temporary.unlink(missing_ok=True)
        self._read = True
        return Text(str(target))

class OutputRegistry:
    def __init__(self, spill_dir: str | os.PathLike[str]) -> None:
        self.spill_dir = Path(spill_dir)
        self.spill_dir.mkdir(parents=True, exist_ok=True)
        self._captures: dict[str, Capture] = {}
    def capture(self, id: str) -> Capture:
        if id not in self._captures: self._captures[id] = Capture(id, spill_dir=self.spill_dir)
        return self._captures[id]
    def read(self, id: str, offset: int = 0, limit: int = 4000) -> Text:
        try: capture = self._captures[id]
        except KeyError: raise KeyError(f"no retained output for {id!r}") from None
        return read_page(capture, offset, limit)
    def list(self) -> ReadyList: return ReadyList(self._captures)
    def forget(self, id: str) -> None:
        capture = self._captures.pop(id, None)
        if capture is not None: capture.end_spill()
