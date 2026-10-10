"""Successor protocol-v1 persistent Python kernel (stdlib only).

The stdout file descriptor is exclusively a 4-byte-length-framed JSON channel.
Cell stdout and stderr are redirected into a bounded in-memory prefix. This is
trusted local execution, not a security sandbox.
"""
from __future__ import annotations

import ast
import asyncio
import contextvars
import inspect
import io
import json
import os
import signal
import struct
import sys
import traceback
from pathlib import Path
from typing import Any, BinaryIO

PROTOCOL = 1
MAX_REQUEST_BYTES = 64 * 1024 * 1024
MAX_OUTPUT_BYTES = 64 * 1024 * 1024


async def read_frame(stream: asyncio.StreamReader) -> bytes | None:
    try:
        header = await stream.readexactly(4)
    except asyncio.IncompleteReadError as error:
        if error.partial:
            raise ValueError("truncated frame header") from error
        return None
    size = struct.unpack(">I", header)[0]
    if size > MAX_REQUEST_BYTES:
        raise ValueError("request frame exceeds protocol limit")
    try:
        return await stream.readexactly(size)
    except asyncio.IncompleteReadError as error:
        raise ValueError("truncated frame payload") from error


def write_frame(stream: BinaryIO, value: dict[str, Any]) -> None:
    payload = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    stream.write(struct.pack(">I", len(payload)))
    stream.write(payload)
    stream.flush()


class Capture(io.TextIOBase):
    def __init__(self, limit: int) -> None:
        self.limit = limit
        self.data = bytearray()
        self.truncated = False

    @property
    def encoding(self) -> str:
        return "utf-8"

    def writable(self) -> bool:
        return True

    def write(self, text: str) -> int:
        if not isinstance(text, str):
            raise TypeError("write() argument must be str")
        original = len(text)
        room = self.limit - len(self.data)
        if room <= 0:
            if text:
                self.truncated = True
            return original
        # Encode in small pieces: one enormous print must not create a second
        # enormous bytes object merely to discover that the prefix is full.
        offset = 0
        while offset < len(text) and room > 0:
            piece = text[offset : offset + min(4096, room + 1)]
            encoded = piece.encode("utf-8", errors="replace")
            overflowed = len(encoded) > room
            self.data.extend(encoded[:room])
            room = self.limit - len(self.data)
            offset += len(piece)
            if overflowed:
                self.truncated = True
        if offset < len(text):
            self.truncated = True
        return original

    def text(self) -> str:
        return self.data.decode("utf-8", errors="ignore")


class CellScope:
    def __init__(self, capture: Capture):
        self.capture = capture
        self.active = True


_CURRENT_CELL: contextvars.ContextVar[CellScope | None] = contextvars.ContextVar("cell_output", default=None)


class RoutedOutput(io.TextIOBase):
    """Task-local attribution; late/background writes go to bounded native output.

    A task inherits its originating scope, not the next cell's. Closing the
    scope prevents later writes mutating a receipt that was already published.
    Raw OS descriptor writes remain unsupported protocol contamination.
    """
    def __init__(self, native):
        self.native = native

    @property
    def encoding(self) -> str:
        return "utf-8"

    def writable(self) -> bool:
        return True

    def write(self, text: str) -> int:
        scope = _CURRENT_CELL.get()
        sink = scope.capture if scope is not None and scope.active else self.native
        sink.write(text)
        return len(text)

    def flush(self) -> None:
        pass


async def evaluate(tree: ast.AST, mode: str, namespace: dict[str, Any]) -> Any:
    code = compile(tree, "<successor-cell>", mode, flags=ast.PyCF_ALLOW_TOP_LEVEL_AWAIT)
    value = eval(code, namespace, namespace)
    # Await compiled top-level-await code, not an arbitrary awaitable result:
    # a bare `run(...)` must return its handle instead of blocking for the job.
    return await value if code.co_flags & inspect.CO_COROUTINE else value


async def execute(source: str, namespace: dict[str, Any], capture: Capture) -> tuple[bool, str]:
    try:
        tree = ast.parse(source, filename="<successor-cell>", mode="exec")
        if tree.body and isinstance(tree.body[-1], ast.Expr):
            prefix = ast.Module(body=tree.body[:-1], type_ignores=tree.type_ignores)
            if prefix.body:
                await evaluate(prefix, "exec", namespace)
            value = await evaluate(ast.Expression(tree.body[-1].value), "eval", namespace)
            if value is not None:
                from successor_tools.api import Text
                display = str(value) if isinstance(value, Text) else repr(value)
                capture.write(display)
                if not display.endswith("\n"):
                    capture.write("\n")
        else:
            await evaluate(tree, "exec", namespace)
        return True, ""
    except BaseException as exc:
        traceback.print_exc(file=capture)
        return False, f"{type(exc).__name__}: {exc}"[:4096]


def _terminate_group(_signum: int, _frame: object) -> None:
    signal.signal(signal.SIGTERM, signal.SIG_DFL)
    os.killpg(os.getpgrp(), signal.SIGTERM)


class OutputView:
    """Expose inspection, not registry allocation, in the public namespace."""
    __slots__ = ("_registry",)

    def __init__(self, registry):
        self._registry = registry

    def read(self, id: str, offset: int = 0, limit: int = 4000):
        return self._registry.read(id, offset, limit)

    def list(self):
        return self._registry.list()


async def serve() -> int:
    # -I excludes even the script's directory. Add only our installed, trusted
    # helper package, never the agent's scratch/project directory.
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from successor_tools import files
    from successor_tools.jobs import JobRuntime
    from successor_tools.output import OutputRegistry

    workspace = Path.cwd()
    output = OutputRegistry(workspace / ".successor-runtime" / "output")
    runtime = JobRuntime(workspace, output)
    files.initialize(runtime)
    injected = {"files": files, "run": runtime.run, "jobs": runtime.jobs,
                "output": OutputView(output), "Path": Path, "asyncio": asyncio}
    namespace: dict[str, Any] = {"__name__": "__main__", "__builtins__": __builtins__, **injected}
    outgoing = sys.stdout.buffer
    native = output.capture("native")
    sys.stdout = sys.stderr = RoutedOutput(native)
    incoming = asyncio.StreamReader(limit=65536)
    transport, _ = await asyncio.get_running_loop().connect_read_pipe(
        lambda: asyncio.StreamReaderProtocol(incoming), sys.stdin.buffer)
    write_frame(outgoing, {
        "v": PROTOCOL, "type": "ready", "pid": os.getpid(), "pgid": os.getpgrp()
    })
    try:
        while True:
            try:
                frame = await read_frame(incoming)
                if frame is None:
                    return 0
                request = json.loads(frame)
                if not isinstance(request, dict):
                    raise ValueError("request is not an object")
                cell_id = request.get("id")
                source = request.get("source")
                maximum = request.get("max_output_bytes")
                if (
                    request.get("v") != PROTOCOL
                    or request.get("type") != "execute"
                    or not isinstance(cell_id, str)
                    or not isinstance(source, str)
                    or not isinstance(maximum, int)
                    or isinstance(maximum, bool)
                    or not 0 <= maximum <= MAX_OUTPUT_BYTES
                ):
                    raise ValueError("invalid execute request")
                for name, value in injected.items():
                    namespace.setdefault(name, value)
                capture = Capture(maximum)
                scope = CellScope(capture)
                token = _CURRENT_CELL.set(scope)
                try:
                    ok, error = await execute(source, namespace, capture)
                finally:
                    scope.active = False
                    _CURRENT_CELL.reset(token)
                response: dict[str, Any] = {
                    "v": PROTOCOL, "type": "result", "id": cell_id,
                    "status": "succeeded" if ok else "failed",
                    "output": capture.text(), "truncated": capture.truncated,
                }
                if not ok:
                    response["error"] = error
                write_frame(outgoing, response)
            except (BrokenPipeError, EOFError):
                return 0
            except BaseException:
                # Never invent a completion or replay an uncertain exchange.
                return 2
    finally:
        transport.close()
        # Cooperative EOF cleanup is useful, but owner-loss/SIGKILL cleanup must
        # work independently: inherited guardian leases/lifetime pipes do that.
        try:
            await asyncio.wait_for(runtime.shutdown(), timeout=5)
        except BaseException:
            pass


def main() -> int:
    try:
        os.setsid()
    except OSError:
        pass  # native owner refuses a handshake without group leadership
    signal.signal(signal.SIGTERM, _terminate_group)
    return asyncio.run(serve())


if __name__ == "__main__":
    raise SystemExit(main())
