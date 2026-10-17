"""Actual fixture-app startup/ownership acceptance; no provider turns or kernels.

Uses the host's bounded inspection transport. Each case owns disposable homes
and process handles; failures retain diagnostic files and still reap children.
"""

import atexit
import hashlib
import http.client
import json
import os
import sqlite3
import subprocess
import sys
import time
import unittest
from pathlib import Path

SOURCE = Path(os.environ["P0_SOURCE_ROOT"])
SNAPSHOT = Path(os.environ["P0_SNAPSHOT"])
EVIDENCE = Path(os.environ["P0_TEST_EVIDENCE"])
EVIDENCE.mkdir(parents=True, exist_ok=False)
sys.path.insert(0, str(SOURCE.parent / "albedo/test/e2e"))
from inspect_support import Inspection

LAUNCH = json.loads((SNAPSHOT / "launch.json").read_text())
APPS = []


def record(value):
    with (EVIDENCE / "actions.jsonl").open("a") as file:
        file.write(json.dumps(value) + "\n")


def check_denial(text):
    if any(
        word in text.lower()
        for word in ("operation not permitted", "permission denied", "eperm")
    ):
        raise KeyboardInterrupt(
            "actual environment access denial; stop without workaround: " + text[-3000:]
        )


class App:
    def __init__(self, mode, *, home=None, parent=None):
        self.root = EVIDENCE / f"app-{len(APPS):03d}-{mode}"
        self.root.mkdir()
        self.home = home or self.root / "home"
        self.home.mkdir(exist_ok=True)
        user_home = self.root / "user-home"
        user_home.mkdir()
        self.env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith(("ALBEDO_", "P0_"))
            and key not in ("HOME", "ERL_FLAGS")
            and not key.endswith(("API_KEY", "ACCESS_TOKEN"))
        }
        self.env.update(
            HOME=str(user_home),
            ALBEDO_HOME=str(self.home),
            ALBEDO_NO_BROWSER="1",
            ALBEDO_INSPECT="1",
            ALBEDO_WEBHOOK_PORT="0",
            ERL_FLAGS="",
            ALBEDO_PARENT_PID=str(parent or os.getpid()),
            P0_FIXTURE_MODE=mode,
        )
        if not (self.home / "config.json").exists():
            (self.home / "config.json").write_text('{"providers":{}}\n')
        self.process = None
        self.daemon = self
        self._pid = None
        self.ready = None
        APPS.append(self)

    def log(self):
        path = self.home / "daemon.log"
        return path.read_text(errors="replace") if path.exists() else ""

    def boot(self):
        with (self.home / "daemon.log").open("ab") as log:
            self.process = subprocess.Popen(
                LAUNCH, cwd=self.root, env=self.env, stdout=log, stderr=log
            )
        self._pid = self.process.pid
        record(
            {
                "argv": LAUNCH,
                "cwd": str(self.root),
                "mode": self.env["P0_FIXTURE_MODE"],
                "pid": self._pid,
                "home": str(self.home),
                "providers": "empty",
            }
        )
        self.wait_ready()
        return self

    def wait_ready(self):
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            check_denial(self.log())
            if self.process.poll() is not None:
                raise AssertionError(
                    f"fixture entrypoint exited {self.process.returncode}: {self.log()[-6000:]}"
                )
            try:
                candidate = json.loads((self.home / "daemon.json").read_text())
                if candidate["pid"] == self._pid:
                    self.ready = candidate
                    status, body = self.request("/server")
                    if status == 200 and body["state"] == "ready":
                        record(
                            {
                                "ready": {
                                    k: v for k, v in candidate.items() if k != "token"
                                },
                                "server": body,
                                "pid": self._pid,
                            }
                        )
                        return
            except PermissionError as error:
                raise KeyboardInterrupt("actual access denial: " + str(error))
            except (OSError, ValueError, KeyError, http.client.HTTPException):
                pass
            time.sleep(0.05)
        raise AssertionError(
            "fixture entrypoint failed readiness: " + self.log()[-6000:]
        )

    def request(self, path, *, authenticated=True, body=None):
        connection = http.client.HTTPConnection(
            "127.0.0.1", self.ready["port"], timeout=5
        )
        headers = (
            {"Authorization": "Bearer " + self.ready["token"]} if authenticated else {}
        )
        method = "GET" if body is None else "POST"
        if body is not None:
            headers["Content-Type"] = "application/json"
        try:
            connection.request(
                method, path, json.dumps(body) if body is not None else None, headers
            )
            response = connection.getresponse()
            payload = response.read().decode()
            return response.status, json.loads(payload) if payload else None
        finally:
            connection.close()

    def inspect(self, expression):
        try:
            return Inspection(self).evaluate(expression)
        except (AssertionError, PermissionError) as error:
            check_denial(str(error))
            raise

    def facts(self):
        return json.loads(
            self.inspect(
                "io:put_chars(Call('boundary_fixture@diagnostics', facts, []))"
            )
        )

    def stop(self):
        if self.process is None or self.process.poll() is not None:
            return
        if self.ready:
            try:
                status, info = self.request("/server")
                if status == 200:
                    self.request(
                        "/server/shutdown", body={"instance_id": info["instance_id"]}
                    )
                    self.process.wait(timeout=10)
                    record(
                        {
                            "pid": self._pid,
                            "exit": self.process.returncode,
                            "shutdown": "native",
                        }
                    )
                    return
            except (
                OSError,
                ValueError,
                subprocess.TimeoutExpired,
                http.client.HTTPException,
            ):
                pass
        self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)
        record(
            {
                "pid": self._pid,
                "exit": self.process.returncode,
                "shutdown": "owned cleanup",
            }
        )


atexit.register(lambda: [app.stop() for app in reversed(APPS)])


def stop_parent(parent):
    if parent.poll() is None:
        parent.kill()
    parent.wait(timeout=5)


class Composition(unittest.TestCase):
    def app(self, mode, **options):
        app = App(mode, **options)
        self.addCleanup(app.stop)
        return app.boot()

    def assert_unavailable(self, app):
        status, _ = app.request("/extensions/boundary-fixture/ping")
        self.assertEqual(status, 404)

    def test_stock_and_configured_defaults_have_identical_catalog_and_selection(self):
        stock = self.app("stock").facts()
        configured = self.app("defaults").facts()
        self.assertEqual(stock["defaults"], configured["defaults"])
        self.assertEqual(stock["summaries"], configured["summaries"])

    def test_external_enabled_fixture_initializes_and_serves_authenticated_http(self):
        app = self.app("enabled")
        self.assertEqual(
            app.request("/extensions/boundary-fixture/ping"),
            (200, {"pong": True, "starts": 1}),
        )
        self.assertEqual(
            app.request("/extensions/boundary-fixture/ping", authenticated=False)[0],
            401,
        )
        facts = app.facts()
        self.assertEqual(facts["defaults"][-1], "boundary-fixture")
        self.assertTrue(facts["summaries"][-1]["enabled"])

    def test_disabled_fixture_installs_but_has_no_global_service(self):
        app = self.app("disabled")
        self.assert_unavailable(app)
        with sqlite3.connect(app.home / "albedo.sqlite") as db:
            self.assertEqual(
                db.execute(
                    "SELECT COUNT(*) FROM sqlite_master WHERE name='boundary_fixture' AND type='table'"
                ).fetchone(),
                (1,),
            )
            self.assertEqual(
                db.execute("SELECT starts FROM boundary_fixture").fetchone(), (1,)
            )
        self.assertFalse(app.facts()["summaries"][-1]["global_enabled"])

    def test_failed_fixture_is_quarantined_without_stopping_stock_startup(self):
        app = self.app("quarantined")
        self.assert_unavailable(app)
        summaries = app.facts()["summaries"]
        self.assertIn("boundary-fixture", [item["name"] for item in summaries])
        summary = next(item for item in summaries if item["name"] == "boundary-fixture")
        self.assertIn("intentional fixture install failure", summary["quarantined"])
        self.assertFalse(summary["enabled"])

    def test_custom_home_ownership_prevents_effects_and_can_be_reclaimed(self):
        first = self.app("enabled")
        second = App("enabled", home=first.home)
        self.addCleanup(second.stop)
        completed = subprocess.run(
            LAUNCH,
            cwd=second.root,
            env=second.env,
            capture_output=True,
            timeout=20,
            check=False,
        )
        check_denial(completed.stderr.decode(errors="replace"))
        (second.root / "refusal.stdout").write_bytes(completed.stdout)
        (second.root / "refusal.stderr").write_bytes(completed.stderr)
        self.assertEqual(completed.returncode, 75)
        self.assertEqual(
            first.request("/extensions/boundary-fixture/ping"),
            (200, {"pong": True, "starts": 1}),
        )
        self.assertEqual(
            json.loads((first.home / "daemon.json").read_text())["pid"], first._pid
        )
        first.stop()
        self.assertEqual(first.process.returncode, 0)
        third = self.app("enabled", home=first.home)
        self.assertEqual(
            third.request("/extensions/boundary-fixture/ping"),
            (200, {"pong": True, "starts": 2}),
        )

    def helper(self, arguments, *, home, input_text=None):
        app = App("poison", home=home)
        result = subprocess.run(
            LAUNCH + arguments,
            cwd=app.root,
            env=app.env,
            input=input_text,
            capture_output=True,
            text=True,
            timeout=25,
            check=False,
        )
        check_denial(result.stderr)
        (app.root / "helper.stdout").write_text(result.stdout)
        (app.root / "helper.stderr").write_text(result.stderr)
        record(
            {"argv": LAUNCH + arguments, "mode": "poison", "exit": result.returncode}
        )
        self.assertNotIn("invalid test composition", result.stderr)
        self.assertFalse((home / "daemon.json").exists())
        return result

    def test_storage_inspect_dispatches_before_composition_with_json_stdout(self):
        app = self.app("stock")
        app.stop()
        home = EVIDENCE / "inspect-helper-home"
        home.mkdir()
        scratch = EVIDENCE / "inspect-scratch"
        scratch.mkdir()
        result = self.helper(
            ["storage", "inspect", str(app.home / "albedo.sqlite"), str(scratch)],
            home=home,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsInstance(json.loads(result.stdout), dict)

    def test_storage_maintenance_eof_preserves_candidates_and_releases_home(self):
        home = EVIDENCE / "maintenance-helper-home"
        home.mkdir()
        sentinel = home / "candidate"
        sentinel.write_bytes(b"preserve candidate")
        for _ in range(2):
            result = self.helper(
                ["storage", "maintain", str(home)],
                home=home,
                input_text=json.dumps({"paths": [str(sentinel)]}) + "\n",
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(json.loads(result.stdout.splitlines()[0])["ready"])
            self.assertTrue(
                all(
                    isinstance(json.loads(line), dict)
                    for line in result.stdout.splitlines()
                )
            )
            self.assertEqual(sentinel.read_bytes(), b"preserve candidate")

    def test_registry_restart_keeps_runtime_store_and_fixture_initialization(self):
        app = self.app("enabled")
        before = app.facts()
        app.inspect(
            '[Name] = [N || N <- Call(erlang, registered, []), lists:prefix("albedo_registry$", atom_to_list(N))], true = Call(erlang, exit, [Call(erlang, whereis, [Name]), kill])'
        )
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                after = app.facts()
                if after["registry"] != before["registry"]:
                    break
            except AssertionError:
                pass
            time.sleep(0.05)
        else:
            self.fail("registry did not recover")
        self.assertEqual(
            (after["runtime"], after["store"]), (before["runtime"], before["store"])
        )
        self.assertEqual(
            app.request("/extensions/boundary-fixture/ping"),
            (200, {"pong": True, "starts": 1}),
        )

    def test_listener_restart_keeps_the_published_port_and_process(self):
        app = self.app("enabled")
        record_before = {k: v for k, v in app.ready.items() if k != "token"}
        app.inspect(
            '[Keeper] = Call(lists, filter, [fun(P) -> case catch proc_lib:get_label(P) of {albedo_listener, <<"'
            + str(app.ready["port"])
            + '">>} -> true; _ -> false end end, Call(erlang, processes, [])]), {links, Links} = Call(erlang, process_info, [Keeper, links]), [Listener] = Call(lists, filter, [fun(P) -> proc_lib:initial_call(P) =/= false end, Links]), true = Call(erlang, exit, [Listener, kill])'
        )
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            try:
                if app.request("/extensions/boundary-fixture/ping")[0] == 200:
                    break
            except (OSError, http.client.HTTPException):
                pass
            time.sleep(0.05)
        else:
            self.fail("listener failed to return on its published port")
        now = json.loads((app.home / "daemon.json").read_text())
        self.assertEqual({k: v for k, v in now.items() if k != "token"}, record_before)

    def test_parent_death_stops_the_actual_fixture_entrypoint(self):
        parent = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(40)"])
        self.addCleanup(stop_parent, parent)
        app = self.app("enabled", parent=parent.pid)
        parent.terminate()
        parent.wait(timeout=5)
        app.process.wait(timeout=15)
        self.assertEqual(app.process.returncode, 0)

    def test_storage_failure_does_not_publish_readiness(self):
        app = App("enabled")
        self.addCleanup(app.stop)
        with sqlite3.connect(app.home / "albedo.sqlite") as db:
            db.execute("CREATE TABLE sessions(broken TEXT)")
        result = subprocess.run(
            LAUNCH,
            cwd=app.root,
            env=app.env,
            capture_output=True,
            timeout=25,
            check=False,
        )
        check_denial(result.stderr.decode(errors="replace"))
        (app.root / "failed-start.stderr").write_bytes(result.stderr)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((app.home / "daemon.json").exists())

    def test_launcher_resolves_dependency_assets_and_vm_defaults(self):
        app = self.app("defaults")
        output = app.inspect(
            'io:put_chars(Call(unicode, characters_to_binary, [Call(code, priv_dir, [albedo])])), io:put_chars("\\n"), io:format("~w~n", [Call(erlang, system_info, [schedulers])]), io:put_chars(Call(unicode, characters_to_binary, [Call(code, which, [\'albedo@daemon@server\'])]))'
        )
        priv, schedulers, module = output.splitlines()
        self.assertEqual(Path(priv).resolve(), (SNAPSHOT / "albedo/priv").resolve())
        self.assertEqual(schedulers, "2")
        self.assertEqual(
            Path(module).resolve(),
            (SNAPSHOT / "albedo/ebin/albedo@daemon@server.beam").resolve(),
        )
        # Compare the distributed Git-tracked assets, not mutable bytecode/lint caches.
        host = SOURCE.parent / "albedo"
        tracked = subprocess.check_output(
            ["git", "-C", str(host), "ls-files", "-z", "--", "priv"], text=True
        ).split("\0")
        relative = [Path(name).relative_to("priv") for name in tracked if name]
        self.assertTrue(relative)
        expected = {
            str(name): hashlib.sha256((host / "priv" / name).read_bytes()).hexdigest()
            for name in relative
        }
        actual = {
            str(name): hashlib.sha256((Path(priv) / name).read_bytes()).hexdigest()
            for name in relative
        }
        self.assertEqual(actual, expected)
