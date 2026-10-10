"""Supervised asynchronous local jobs and pipelines.

Adapted from Albedo at commit 8920b8a8f4b295be0fde3d20aedf2a3cf5bcd450,
principally ``priv/python/albedo_plugins/run.py`` (Job, Command, Outlet, Feed,
admission/retention lifecycle) and ``priv/python/albedo_output.py`` (JobOutput
integration). Albedo is WTFPL v2. Successor changes: instance-owned state,
minimal environment, bounded queue-backed feeds, and the successor guardian /
lease protocol; daemon wakes, remote execution, tracing, shell shims, and host
hooks were removed.
"""
from __future__ import annotations

import asyncio
import fcntl
import json
import math
import os
from collections import OrderedDict, deque
from dataclasses import dataclass
from pathlib import Path
import shlex
import shutil
import sys
import time
import uuid
from typing import Any, Generator

from .output import JobOutput, OutputRegistry
from .proc import Termination

FEED_LIMIT = 1024 * 1024
STATUS_LIMIT = 8192
MAX_TIMEOUT = 86400.0
STDIN_LIMIT = 64 * 1024 * 1024
ARGV_LIMIT = 1024 * 1024
ENV_LIMIT = 1024 * 1024
_READ_CHUNK = 65536
_EOF = object()


@dataclass(frozen=True)
class JobPolicy:
    active_limit: int = 64
    retained_limit: int = 64

    def __post_init__(self) -> None:
        if isinstance(self.active_limit, bool) or not isinstance(self.active_limit, int) or self.active_limit < 1:
            raise ValueError("active_limit must be a positive integer")
        if isinstance(self.retained_limit, bool) or not isinstance(self.retained_limit, int) or self.retained_limit < 0:
            raise ValueError("retained_limit must be a nonnegative integer")


class Feed:
    """A byte-bounded connection whose broken reader always wakes its writer."""

    def __init__(self, writer: "Job", retained: bytes) -> None:
        self.writer = writer
        self._chunks: deque[bytes] = deque([retained] if retained else [])
        self._bytes = len(retained)
        self._condition = asyncio.Condition()
        self.ended = False
        self.broken = False

    async def connect(self, stream: asyncio.StreamWriter) -> None:
        try:
            while True:
                async with self._condition:
                    await self._condition.wait_for(lambda: self._chunks or self.ended or self.broken)
                    if self.broken:
                        return
                    if not self._chunks:
                        return
                    data = self._chunks.popleft()
                    self._bytes -= len(data)
                    self._condition.notify_all()
                stream.write(data)
                await stream.drain()
        except (BrokenPipeError, ConnectionResetError):
            await self._break()
        finally:
            stream.close()
            try:
                await stream.wait_closed()
            except (BrokenPipeError, ConnectionResetError):
                pass

    async def _break(self) -> None:
        async with self._condition:
            self.broken = True
            self._chunks.clear()
            self._bytes = 0
            self._condition.notify_all()
        self.writer.outlet.reader_broken()

    async def write(self, data: bytes) -> None:
        async with self._condition:
            await self._condition.wait_for(
                lambda: self.broken or self._bytes == 0 or self._bytes + len(data) <= FEED_LIMIT
            )
            if self.broken:
                return
            self._chunks.append(data)
            self._bytes += len(data)
            self._condition.notify_all()

    async def end(self) -> None:
        async with self._condition:
            if not self.broken:
                self.ended = True
                self._condition.notify_all()


class Outlet:
    """Captured stdout fanout, retaining backpressure and shell-like pipe cut."""

    def __init__(self) -> None:
        self.feeds: list[Feed] = []
        self.closed = False
        self.reading: asyncio.Transport | None = None

    async def write(self, data: bytes) -> None:
        for feed in tuple(self.feeds):
            await feed.write(data)

    async def close(self) -> None:
        if not self.closed:
            self.closed = True
            for feed in tuple(self.feeds):
                await feed.end()

    def reader_broken(self) -> None:
        if self.feeds and all(feed.broken for feed in self.feeds):
            if self.reading is not None and not self.reading.is_closing():
                self.reading.close()


@dataclass
class Command:
    """The guardian process transporting one target command."""
    process: asyncio.subprocess.Process
    lifetime: int | None

    def close_lifetime(self, marker: bytes | None = None) -> None:
        fd, self.lifetime = self.lifetime, None
        if fd is None:
            return
        try:
            if marker is not None:
                os.write(fd, marker)
        except OSError:
            pass
        try:
            os.close(fd)
        except OSError:
            pass
    status_path: Path


def _fsync_directory(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | os.O_CLOEXEC)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _create_active_record(directory: Path, id: str) -> Path:
    path = directory / id
    payload = json.dumps({"v": 1, "id": id}, separators=(",", ":"), sort_keys=True).encode() + b"\n"
    fd: int | None = None
    created = False
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC, 0o600)
        created = True
        written = os.write(fd, payload)
        if written != len(payload):
            raise OSError("short active-record write")
        os.fsync(fd)
        os.close(fd); fd = None
        _fsync_directory(directory)
        return path
    except BaseException:
        if fd is not None:
            try: os.close(fd)
            except OSError: pass
        if created:
            try:
                path.unlink()
                _fsync_directory(directory)
            except OSError:
                pass
        raise


class _DefinitiveSpawnError(Exception):
    pass


class _AmbiguousSpawnError(Exception):
    pass


class Job(JobOutput):
    def __init__(self, runtime: "JobRuntime", argv: tuple[str, ...], timeout: float, *, cwd: str,
                 env: dict[str, str], stdin: str | bytes | os.PathLike[str] | "Job" | None) -> None:
        self.runtime = runtime
        self.id = uuid.uuid4().hex
        self.argv = list(argv)
        self.command = shlex.join(argv)
        self.timeout = timeout
        self.cwd = cwd
        self.env = env
        self.source = stdin if isinstance(stdin, Job) else None
        self._sources: tuple[Job, ...] = (() if self.source is None else (*self.source._sources, self.source))
        self._pipeline_text = f"{self.source.pipeline} | {self.command}" if self.source else self.command
        self._stdin = None if self.source is not None else stdin
        self.feed = self.source._reader() if self.source is not None else None
        self.outlet = Outlet()
        self.capture = runtime.output_registry.capture(self.id)
        self.exit_code: int | None = None
        self.duration: float | None = None
        self.timed_out = False
        self.termination: Termination | None = None
        self._read = False
        self._command: Command | None = None
        self._stop_requested = False
        self._unknown_reason: str | None = None
        self._delivery_error: str | None = None
        self._pipeline_error: str | None = None
        self.started = runtime.loop.time()
        self.spawning: asyncio.Task[Command] = runtime.loop.create_task(self._spawn())
        self._execution: asyncio.Task[None] = runtime.loop.create_task(self._execute())
        self._recovery: asyncio.Task[None] | None = None
        self._finalized = False
        self.task: asyncio.Task[Job] = runtime.loop.create_task(self._run())
        self.task.add_done_callback(self._task_done)

    @property
    def pipeline(self) -> str:
        return self._pipeline_text

    def pipe(self, program: object, *args: object, cwd: str | os.PathLike[str] | None = None,
             env: dict[str, object] | None = None, timeout: float = 300) -> "Job":
        return self.runtime.run(program, *args, cwd=cwd, env=env, stdin=self, timeout=timeout)

    def _reader(self) -> Feed:
        if self.capture.seen > len(self.capture.data):
            raise ValueError(f"job {self.id} has incomplete in-memory history; attach pipe before it runs")
        feed = Feed(self, bytes(self.capture.data))
        self.outlet.feeds.append(feed)
        if self.outlet.closed:
            feed.ended = True
        self._read = True
        return feed

    async def _spawn(self) -> Command:
        status = self.runtime.runtime_dir / f"{self.id}.status.json"
        try:
            status.unlink(missing_ok=True)
            lifetime_r, lifetime_w = os.pipe()
        except OSError as error:
            raise _DefinitiveSpawnError(str(error)) from error
        lease: int | None = None
        try:
            os.set_inheritable(lifetime_r, True)
            os.set_inheritable(lifetime_w, False)
            lease = os.open(self.runtime.lock_path, os.O_RDWR | os.O_CREAT | os.O_CLOEXEC, 0o600)
            fcntl.flock(lease, fcntl.LOCK_SH | fcntl.LOCK_NB)
            os.set_inheritable(lease, True)
        except BaseException as error:
            for fd in (lifetime_r, lifetime_w, lease):
                if fd is not None:
                    try: os.close(fd)
                    except OSError: pass
            raise _DefinitiveSpawnError(str(error)) from error
        try:
            active_record = _create_active_record(self.runtime.active_dir, self.id)
        except BaseException as error:
            for fd in (lifetime_r, lifetime_w, lease):
                try: os.close(fd)
                except OSError: pass
            raise _DefinitiveSpawnError(f"active record: {error}") from error
        deadline = time.monotonic() + self.timeout
        guardian = Path(__file__).with_name("guardian.py")
        guardian_argv = (
            sys.executable, "-I", "-u", str(guardian), "--lifetime-fd", str(lifetime_r),
            "--lease-fd", str(lease), "--status", str(status),
            "--active-record", str(active_record), "--deadline", repr(deadline), "--", *self.argv,
        )
        try:
            process = await asyncio.create_subprocess_exec(
                *guardian_argv, stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
                cwd=self.cwd, env=self.env, pass_fds=(lifetime_r, lease), start_new_session=True,
            )
        except BaseException as error:
            try: os.close(lifetime_w)
            except OSError: pass
            raise _AmbiguousSpawnError(str(error)) from error
        finally:
            for fd in (lifetime_r, lease):
                try: os.close(fd)
                except OSError: pass
        return Command(process, lifetime_w, status)

    async def _feed_stdin(self, stream: asyncio.StreamWriter) -> None:
        try:
            if self.feed is not None:
                await self.feed.connect(stream)
                return
            data = self._stdin
            if isinstance(data, (str, bytes)):
                payload = data.encode() if isinstance(data, str) else data
                for offset in range(0, len(payload), _READ_CHUNK):
                    stream.write(payload[offset:offset + _READ_CHUNK]); await stream.drain()
            elif isinstance(data, os.PathLike):
                with open(data, "rb") as source:
                    while chunk := source.read(_READ_CHUNK):
                        stream.write(chunk); await stream.drain()
        except (BrokenPipeError, ConnectionResetError) as error:
            raise RuntimeError("stdin closed before complete delivery") from error
        finally:
            stream.close()
            try: await stream.wait_closed()
            except (BrokenPipeError, ConnectionResetError): pass

    async def _read_output(self, stream: asyncio.StreamReader) -> None:
        self.outlet.reading = getattr(stream, "_transport", None)
        while data := await stream.read(_READ_CHUNK):
            self.capture.write_bytes(data)
            await self.outlet.write(data)

    def _read_status(self, path: Path) -> dict[str, Any]:
        try:
            with path.open("rb") as source:
                raw = source.read(STATUS_LIMIT + 1)
            if not raw or len(raw) > STATUS_LIMIT:
                raise ValueError("status size is invalid")
            value = json.loads(raw)
            if not isinstance(value, dict) or value.get("v") != 1 or value.get("state") != "terminated":
                raise ValueError("guardian did not publish v1 terminal status")
            if isinstance(value.get("pid"), bool) or not isinstance(value.get("pid"), int):
                raise ValueError("pid is invalid")
            if value.get("leader") is not None and not isinstance(value.get("leader"), str):
                raise ValueError("leader is invalid")
            rc = value.get("returncode")
            if rc is not None and (isinstance(rc, bool) or not isinstance(rc, int)):
                raise ValueError("returncode is invalid")
            if not isinstance(value.get("timed_out"), bool) or not isinstance(value.get("reason"), str):
                raise ValueError("terminal facts are invalid")
            term = value.get("termination")
            if not isinstance(term, dict) or term.get("gone") is not True:
                raise ValueError("terminated status lacks exact gone proof")
            pgid = term.get("pgid")
            if pgid is not None and (isinstance(pgid, bool) or not isinstance(pgid, int)):
                raise ValueError("termination pgid is invalid")
            if not isinstance(term.get("signals"), list) or not all(isinstance(x, str) for x in term["signals"]):
                raise ValueError("termination signals are invalid")
            if not isinstance(term.get("failures"), list) or not all(isinstance(x, str) for x in term["failures"]):
                raise ValueError("termination failures are invalid")
            if not isinstance(term.get("note"), str):
                raise ValueError("termination note is invalid")
            return value
        except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
            raise RuntimeError(f"invalid guardian status: {error}") from error

    def _accept_status(self, status: dict[str, Any]) -> None:
        term = status["termination"]
        self.exit_code = status["returncode"]
        self.timed_out = status["timed_out"]
        self.termination = Termination(term["pgid"], tuple(term["signals"]), True,
                                       tuple(term["failures"]), term["note"])

    async def _execute(self) -> None:
        try:
            self._command = await asyncio.shield(self.spawning)
        except _DefinitiveSpawnError as error:
            self.capture.write(f"spawn failed before dispatch: {error}\n")
            self.termination = Termination(None, (), True, (), "spawn failed before dispatch")
            return
        except BaseException as error:
            self.capture.write(f"spawn outcome unknown: {error}\n")
            self._unknown_reason = f"spawn outcome unknown: {error}"
            return
        command = self._command
        if self._stop_requested:
            command.close_lifetime(b"S")
        process = command.process
        assert process.stdout is not None and process.stdin is not None
        stdin_task = self.runtime.loop.create_task(self._feed_stdin(process.stdin))
        output_task = self.runtime.loop.create_task(self._read_output(process.stdout))
        wait_task = self.runtime.loop.create_task(process.wait())
        watching_stdin = True
        while not (output_task.done() and wait_task.done()):
            if watching_stdin and stdin_task.done():
                watching_stdin = False
                if not stdin_task.cancelled() and (error := stdin_task.exception()) is not None:
                    self._delivery_error = f"stdin delivery failed: {type(error).__name__}: {error}"
                    self.capture.write(f"\n[{self._delivery_error}]\n")
                    await self._request_stop()
            watched = {task for task in (output_task, wait_task) if not task.done()}
            if watching_stdin:
                watched.add(stdin_task)
            if watched:
                await asyncio.wait(watched, return_when=asyncio.FIRST_COMPLETED)
        await asyncio.gather(stdin_task, output_task, wait_task, return_exceptions=True)
        if watching_stdin and not stdin_task.cancelled() and (error := stdin_task.exception()) is not None:
            self._delivery_error = f"stdin delivery failed: {type(error).__name__}: {error}"
            self.capture.write(f"\n[{self._delivery_error}]\n")
        try:
            self._accept_status(self._read_status(command.status_path))
        except RuntimeError as error:
            self._unknown_reason = str(error)
            self.capture.write(f"\n[cleanup/status unknown: {error}]\n")
        if self._delivery_error is not None:
            self.exit_code = None

    def _task_done(self, task: asyncio.Task["Job"]) -> None:
        if task.cancelled() and not self._finalized:
            self._recovery = self.runtime.loop.create_task(self._recover_cancelled())
        self.runtime._pipeline_done()

    async def _recover_cancelled(self) -> None:
        await self._request_stop()
        await asyncio.shield(self._execution)
        await self._finalize()

    async def _finalize(self) -> None:
        if self._finalized:
            return
        self._finalized = True
        await self.outlet.close()
        if self._command is not None:
            self._command.close_lifetime()
        self.capture.end_spill()
        if self.termination is not None and self.termination.gone and self._unknown_reason is None:
            self.duration = self.runtime.loop.time() - self.started
        self.runtime._completed(self)
        self.runtime._pipeline_done()

    async def _run(self) -> "Job":
        try:
            await asyncio.shield(self._execution)
        except asyncio.CancelledError:
            # The execution task survives cancellation; adopt its spawn and clean it.
            await self._request_stop()
            await asyncio.shield(self._execution)
        finally:
            await self._finalize()
        return self

    async def _request_stop(self) -> None:
        self._stop_requested = True
        if self._command is None:
            try:
                self._command = await asyncio.shield(self.spawning)
            except BaseException:
                return
        # Do not tear the lifetime pipe out from under guardian bootstrap. Its
        # running record proves it captured identity and authorized the gate.
        while not self._command.status_path.exists() and self._command.process.returncode is None:
            await asyncio.sleep(0.005)
        self._command.close_lifetime(b"S")

    def _members(self) -> tuple["Job", ...]:
        return (*self._sources, self)

    async def stop(self) -> Termination | None:
        members = self._members()
        for job in members: job._read = True
        await asyncio.gather(*(job._request_stop() for job in members), return_exceptions=True)
        await asyncio.gather(*(asyncio.shield(job._execution) for job in members), return_exceptions=True)
        await asyncio.gather(*(job._finalize() for job in members), return_exceptions=True)
        if any(job.termination is None or not job.termination.gone for job in members):
            return None
        return self.termination

    def __await__(self) -> Generator[object, None, "Job"]:
        return self._wait().__await__()

    async def _wait(self) -> "Job":
        members = self._members()
        await asyncio.gather(*(asyncio.shield(job.task) for job in members))
        if self._pipeline_error is not None:
            raise RuntimeError(self._pipeline_error)
        for job in members:
            if job._unknown_reason is not None:
                raise RuntimeError(f"job {job.id} outcome unknown: {job._unknown_reason}")
            if job._delivery_error is not None:
                raise RuntimeError(f"job {job.id} {job._delivery_error}")
            job._read = True
        return self

    def poll(self) -> int | None:
        if self.duration is not None: self._read = True
        return self.exit_code

    @property
    def returncode(self) -> int | None:
        return self.poll()

    def __repr__(self) -> str:
        return (f"Job(id={self.id!r}, exit_code={self.exit_code!r}, timed_out={self.timed_out!r}, "
                f"duration={self.duration!r}, bytes={self.capture.seen})")


class JobRuntime:
    """One incarnation's bounded handles and active work.

    Map/feed/stdin/output bounds prevent history and transport queues from growing
    without limit. They are operational guards, not a trusted-code heap sandbox:
    child programs and ordinary Python objects can still consume host resources.
    """
    def __init__(self, workspace: str | os.PathLike[str], output_registry: OutputRegistry,
                 policy: JobPolicy | None = None) -> None:
        self.workspace = Path(workspace).expanduser().resolve()
        self.workspace.mkdir(parents=True, exist_ok=True)
        self.runtime_dir = self.workspace / ".successor-runtime"
        self.runtime_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.lock_path = self.runtime_dir / "jobs.lock"
        self.lock_path.touch(mode=0o600, exist_ok=True)
        self.active_dir = self.runtime_dir / "active-jobs"
        self.active_dir.mkdir(mode=0o700, exist_ok=True)
        self.output_registry = output_registry
        self.policy = policy or JobPolicy()
        self.loop = asyncio.get_running_loop()
        self.jobs: dict[str, Job] = {}
        self._active: dict[str, Job] = {}
        self._retained: OrderedDict[str, Job] = OrderedDict()
        self._closed = False

    def _marker_capacity_available(self) -> bool:
        # Current handles include pending jobs whose marker does not exist yet.
        # Add only entries not represented by those handles (stranded latches),
        # stopping as soon as refusal is known rather than scanning history.
        used = len(self._active)
        if used >= self.policy.active_limit:
            return False
        with os.scandir(self.active_dir) as entries:
            for entry in entries:
                if entry.name not in self._active:
                    used += 1
                    if used >= self.policy.active_limit:
                        return False
        return True

    @staticmethod
    def _argv(program: object, args: tuple[object, ...]) -> tuple[str, ...]:
        values = (program, *args)
        if not values:
            raise ValueError("program is required")
        argv = tuple(os.fsdecode(os.fspath(value)) if isinstance(value, os.PathLike) else str(value) for value in values)
        if not argv[0] or any("\x00" in value for value in argv):
            raise ValueError("program and arguments must be nonempty/NUL-free")
        if sum(len(os.fsencode(value)) + 1 for value in argv) > ARGV_LIMIT:
            raise ValueError(f"argv exceeds {ARGV_LIMIT} bytes")
        return argv

    @staticmethod
    def _timeout(value: float) -> float:
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise TypeError("timeout must be a finite number")
        result = float(value)
        if not math.isfinite(result) or result <= 0 or result > MAX_TIMEOUT:
            raise ValueError(f"timeout must be finite and in (0, {MAX_TIMEOUT:g}]")
        return result

    def run(self, program: object, *args: object, cwd: str | os.PathLike[str] | None = None,
            env: dict[str, object] | None = None,
            stdin: str | bytes | os.PathLike[str] | Job | None = None,
            timeout: float = 300) -> Job:
        if self._closed:
            raise RuntimeError("job runtime is shut down")
        timeout_value = self._timeout(timeout)
        if len(self._active) >= self.policy.active_limit or not self._marker_capacity_available():
            raise RuntimeError(f"{self.policy.active_limit} jobs are active or latched; reconcile one first")
        if not (stdin is None or isinstance(stdin, (str, bytes, os.PathLike, Job))):
            raise TypeError("stdin must be text, bytes, a path, or a Job")
        if isinstance(stdin, Job) and stdin.runtime is not self:
            raise ValueError("stdin Job belongs to another runtime")
        argv = self._argv(program, args)
        directory = Path.cwd() if cwd is None else Path(cwd).expanduser()
        directory = directory.resolve()
        if not directory.is_dir():
            raise FileNotFoundError(f"cwd is not a directory: {directory}")
        minimal = {key: os.environ[key] for key in ("PATH", "LANG", "LC_ALL", "TMPDIR") if key in os.environ}
        minimal.setdefault("PATH", os.defpath)
        minimal["HOME"] = str(self.workspace)
        if env is not None:
            if not isinstance(env, dict):
                raise TypeError("env must be a dictionary")
            for key, value in env.items():
                k, v = str(key), str(value)
                if not k or "=" in k or "\x00" in k or "\x00" in v:
                    raise ValueError("environment keys/values must be valid and NUL-free")
                minimal[k] = v
        if sum(len(os.fsencode(k)) + len(os.fsencode(v)) + 2 for k, v in minimal.items()) > ENV_LIMIT:
            raise ValueError(f"environment exceeds {ENV_LIMIT} bytes")
        if isinstance(stdin, str):
            if len(stdin) > STDIN_LIMIT:
                raise ValueError(f"stdin exceeds {STDIN_LIMIT} bytes")
            stdin = stdin.encode()
        if isinstance(stdin, bytes) and len(stdin) > STDIN_LIMIT:
            raise ValueError(f"stdin exceeds {STDIN_LIMIT} bytes")
        if os.sep not in argv[0] and shutil.which(argv[0], path=minimal.get("PATH")) is None:
            raise FileNotFoundError(f"{argv[0]}: no such program on PATH")
        if isinstance(stdin, os.PathLike):
            stdin = Path(stdin).expanduser().resolve()
            if not stdin.is_file():
                raise FileNotFoundError(f"stdin is not a file: {stdin}")
        job = Job(self, argv, timeout_value, cwd=str(directory), env=minimal, stdin=stdin)
        self.jobs[job.id] = job
        self._active[job.id] = job
        return job

    def _pipeline_done(self) -> None:
        # Maps are bounded, but source links would otherwise retain arbitrarily old
        # chains outside them. Detach only after every member is proven inactive.
        for job in tuple(self.jobs.values()):
            members = job._members()
            if members and all(member.id not in self._active for member in members):
                errors = [
                    f"job {member.id} outcome unknown: {member._unknown_reason}"
                    if member._unknown_reason else f"job {member.id} {member._delivery_error}"
                    for member in members if member._unknown_reason or member._delivery_error
                ]
                if errors:
                    job._pipeline_error = "; ".join(errors)
                for member in members:
                    member.source = None
                    member.feed = None
                    member.outlet.feeds.clear()
                    member._sources = ()

    def _completed(self, job: Job) -> None:
        # Only checked gone proof releases capacity; unknown remains owned.
        gone = bool(job.termination and job.termination.gone)
        if not gone or self._active.pop(job.id, None) is None:
            return
        self._retained[job.id] = job
        while len(self._retained) > self.policy.retained_limit:
            _, old = self._retained.popitem(last=False)
            if self.jobs.get(old.id) is old:
                del self.jobs[old.id]
            self.output_registry.forget(old.id)

    def forget(self, job: Job) -> None:
        if job.runtime is not self:
            raise ValueError("job belongs to another runtime")
        if job.id in self._active:
            raise RuntimeError("cannot forget active or cleanup-uncertain job")
        if self.jobs.get(job.id) is job:
            del self.jobs[job.id]
        self._retained.pop(job.id, None)
        self.output_registry.forget(job.id)

    async def shutdown(self) -> None:
        self._closed = True
        owned = list(self._active.values())
        await asyncio.gather(*(job._request_stop() for job in owned), return_exceptions=True)
        await asyncio.gather(*(asyncio.shield(job._execution) for job in owned), return_exceptions=True)
        await asyncio.gather(*(job._finalize() for job in owned), return_exceptions=True)
