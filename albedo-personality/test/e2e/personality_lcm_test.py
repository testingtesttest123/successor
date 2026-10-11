"""Native persona-aware LCM calls through the real daemon and scripted provider.

These live assertions are retained even on executors that cannot boot the
AF_UNIX Python kernel; the compiled socket-free suite covers those limits.
"""

import json
import sqlite3
import threading
import unittest

from harness import Albedo, Provider, error, exclusive, text, wait_until
from personality_context_test import edit, read
from personality_support import bind, create, inspect


def evidence(prompt):
    return json.loads(
        prompt.split("<summary-evidence>\n", 1)[1].split("\n</summary-evidence>", 1)[0]
    )


def envelope(request):
    payload = json.dumps(request.get("input", request.get("messages", [])))
    # The prompt is a plain user string on both provider protocols.
    items = request.get("input", request.get("messages", []))
    prompt = next(
        item["content"]
        for item in items
        if isinstance(item.get("content"), str)
        and "<summary-evidence>" in item["content"]
    )
    assert "personality recall" not in payload
    return evidence(prompt)


@exclusive
class PersonalityLcmTests(unittest.TestCase):
    def _app(self, provider):
        return Albedo(
            provider,
            protocol="responses",
            prepare=lambda app: app.write_extensions(
                {
                    "enabled": {"personality": True, "rolling": False},
                    "lcm": {
                        "contextWindowTokens": 200000,
                        "triggerPercent": 80,
                        "tailPercent": 25,
                    },
                }
            ),
        )

    def _seed(self, app, owner):
        for prompt in ("older source unit", "latest retained unit"):
            app.prompt(owner, prompt).close()
            app.idle(owner)

    def _runs(self, app, owner):
        with sqlite3.connect(app.home / "albedo.sqlite") as db:
            return {
                row[0]
                for row in db.execute(
                    "SELECT id FROM input_turns WHERE session=?", (owner,)
                )
            }

    def _forced_record(self, app, owner, earlier_runs):
        forced_runs = self._runs(app, owner) - earlier_runs
        self.assertEqual(len(forced_runs), 1)
        records = read(app, f"/sessions/{owner}/context?view=requests")["items"]
        recorded = [
            record
            for record in records
            if record["kind"] == "summarizer" and record["run_id"] in forced_runs
        ]
        self.assertEqual(len(recorded), 1)
        self.assertTrue(recorded[0]["projection_hash"])
        return recorded[0]

    def _assert_sources(self, app, owner, request, revision):
        captured = envelope(request)
        self.assertEqual(captured["session"], owner)
        self.assertEqual(captured["identity_revision"], revision)
        self.assertEqual(request.get("tools", []), [])
        self.assertTrue(
            any(attr["actor"] == "user_assertion" for attr in captured["attributions"])
        )
        with sqlite3.connect(app.home / "albedo.sqlite") as db:
            leaves = db.execute(
                "SELECT first_seq,last_seq,narration FROM lcm_compaction_node WHERE session=? AND depth=0 ORDER BY first_seq",
                (owner,),
            ).fetchall()
            actual_rows = {
                row[0]
                for row in db.execute(
                    "SELECT seq FROM transcript WHERE session=?", (owner,)
                )
            }
        self.assertEqual(
            [tuple(bounds) for bounds in captured["source_ranges"]],
            [(first, last) for first, last, _ in leaves],
        )
        self.assertEqual(len(leaves), 1)
        for first, last, narration in leaves:
            self.assertIn(first, actual_rows)
            self.assertIn(last, actual_rows)
            self.assertEqual(json.loads(narration)["narrator"]["revision"], revision)

    def _assert_capture(self, app, owner, request, revision):
        snapshot = read(app, f"/sessions/{owner}/context")
        self.assertEqual(len(snapshot["summary_calls"]), 1)
        self.assertEqual(snapshot["summary_calls_omitted"], 0)
        call = snapshot["summary_calls"][0]
        self.assertEqual(call["status"], "attempted")
        self.assertEqual(call["max_output_tokens"], request["max_output_tokens"])
        self.assertGreater(call["evidence_bytes"], 0)
        self.assertGreater(call["instruction_bytes"], 0)
        self.assertEqual(
            snapshot["request_context"][0]["summary_policy"]["identity_revision"],
            revision,
        )
        page = read(
            app,
            f"/sessions/{owner}/context?view=section&snapshot_id={snapshot['snapshot_id']}&section_id={call['section_id']}&page=0",
        )
        self.assertEqual(evidence(page["text"]), envelope(request))
        return snapshot

    def test_automatic_lcm_refreshes_failed_policy_and_preserves_real_sources(self):
        entered, release = threading.Event(), threading.Event()
        summaries = []

        def reply(request):
            if "<summary-evidence>" in json.dumps(request):
                summaries.append(request)
                if len(summaries) == 1:
                    entered.set()
                    release.wait(30)
                    return error(400, "old background fixture refused")
                return text("x")
            return text("ordinary answer")

        provider = Provider(reply)
        self.addCleanup(provider.close)
        self.addCleanup(release.set)
        with self._app(provider) as app:
            owner, editor = app.session(), app.session()
            persona = create(app)
            bind(app, owner, persona["id"])
            bind(app, editor, persona["id"])
            before = inspect(app, owner)["persona"]
            self._seed(app, owner)
            self.assertTrue(entered.wait(10), "no native background summary")
            captured = envelope(summaries[0])
            self.assertEqual(captured["identity_revision"], before["identity_revision"])
            self.assertEqual(captured["session"], owner)
            self.assertEqual(summaries[0].get("tools", []), [])
            self.assertEqual(read(app, f"/sessions/{owner}")["status"]["phase"], "idle")
            # Background preparation records requests without publishing a
            # foreground request snapshot, even while its provider is gated.
            snapshot = read(app, f"/sessions/{owner}/context")
            self.assertEqual(snapshot["summary_calls"], [])
            edit(app, editor, "Concurrent edit while summarizer is active")
            edited = inspect(app, editor)["persona"]
            release.set()

            def committed():
                with sqlite3.connect(app.home / "albedo.sqlite") as db:
                    return db.execute(
                        "SELECT summary FROM lcm_compaction_node WHERE session=?",
                        (owner,),
                    ).fetchall() == [("x",)]

            wait_until(committed, 10, "refreshed background memory did not commit")
            self.assertEqual(len(summaries), 2)
            self.assertEqual(envelope(summaries[0]), captured)
            self._assert_sources(app, owner, summaries[1], edited["identity_revision"])
            self.assertEqual(inspect(app, owner)["persona"], edited)
            records = read(app, f"/sessions/{owner}/context?view=requests")["items"]
            recorded = [record for record in records if record["kind"] == "summarizer"]
            self.assertEqual(len(recorded), len(summaries))
            self.assertEqual(
                sorted(record["outcome"] for record in recorded),
                ["completed", "failed"],
            )
            self.assertTrue(all(record["projection_hash"] for record in recorded))
            self.assertTrue(
                all(
                    record["run_id"] not in self._runs(app, owner)
                    for record in recorded
                )
            )

    def test_forced_lcm_retains_captured_policy_and_real_sources_during_edit(self):
        background_entered, background_release = threading.Event(), threading.Event()
        forced_entered, forced_release = threading.Event(), threading.Event()
        summaries, forced_requests = [], []
        original_revision = []

        def reply(request):
            if "<summary-evidence>" not in json.dumps(request):
                return text("ordinary answer")
            summaries.append(request)
            if len(summaries) == 1:
                background_entered.set()
                background_release.wait(30)
                return error(400, "background fixture released")
            if envelope(request)["identity_revision"] == original_revision[0]:
                forced_requests.append(request)
                forced_entered.set()
                forced_release.wait(30)
                return text("x")
            # The edit may start a fresh background generation. It cannot
            # compete with the forced result in this captured-policy scenario.
            return error(400, "fresh background fixture refused")

        provider = Provider(reply)
        self.addCleanup(provider.close)
        self.addCleanup(background_release.set)
        self.addCleanup(forced_release.set)
        with self._app(provider) as app:
            owner, editor = app.session(), app.session()
            persona = create(app)
            bind(app, owner, persona["id"])
            bind(app, editor, persona["id"])
            before = inspect(app, owner)["persona"]
            original_revision.append(before["identity_revision"])
            self._seed(app, owner)
            self.assertTrue(background_entered.wait(10), "no background slot to hold")
            earlier_runs = self._runs(app, owner)
            result, failures = [], []

            def compact_post():
                try:
                    # The personality strategy is already selected. Keeping
                    # it leaves the occupied memory slot intact.
                    with app.api(f"/sessions/{owner}/compaction", {}) as response:
                        result.append(json.load(response))
                except Exception as exc:
                    failures.append(exc)

            worker = threading.Thread(target=compact_post)

            def finish_worker():
                forced_release.set()
                background_release.set()
                worker.join(20)
                self.assertFalse(worker.is_alive(), "LCM fixture worker did not settle")

            self.addCleanup(finish_worker)
            worker.start()
            self.assertTrue(forced_entered.wait(10), "no native forced summary")
            self.assertEqual(len(forced_requests), 1)
            captured = envelope(forced_requests[0])
            self.assertEqual(captured["identity_revision"], before["identity_revision"])
            edit(app, editor, "Concurrent edit while forced summarizer is active")
            edited = inspect(app, editor)["persona"]
            forced_release.set()
            worker.join(20)
            self.assertFalse(worker.is_alive())
            self.assertEqual(failures, [])
            self.assertEqual(result[0]["state"], "compacted")
            self.assertFalse(result[0]["selection_applied"])
            self.assertEqual(envelope(forced_requests[0]), captured)
            self._assert_sources(
                app, owner, forced_requests[0], before["identity_revision"]
            )
            self._assert_capture(
                app, owner, forced_requests[0], before["identity_revision"]
            )
            self.assertEqual(
                self._forced_record(app, owner, earlier_runs)["outcome"], "completed"
            )
            self.assertEqual(inspect(app, owner)["persona"], edited)
            records = read(app, f"/sessions/{owner}/context?view=requests")["items"]
            background = [
                record
                for record in records
                if record["kind"] == "summarizer"
                and record["run_id"] not in self._runs(app, owner)
            ]
            self.assertTrue(all(record["outcome"] == "failed" for record in background))

    def test_failed_forced_summary_retains_captured_attempt_inspection(self):
        background_entered, background_release = threading.Event(), threading.Event()
        summaries = []

        def reply(request):
            if "<summary-evidence>" in json.dumps(request):
                summaries.append(request)
                if len(summaries) == 1:
                    background_entered.set()
                    background_release.wait(30)
                return error(400, "summarizer refused")
            return text("ordinary answer")

        provider = Provider(reply)
        self.addCleanup(provider.close)
        self.addCleanup(background_release.set)
        with self._app(provider) as app:
            owner = app.session()
            persona = create(app)
            bind(app, owner, persona["id"])
            self._seed(app, owner)
            self.assertTrue(background_entered.wait(10), "no background slot to hold")
            before = inspect(app, owner)["persona"]
            earlier_runs = self._runs(app, owner)
            with app.api(f"/sessions/{owner}/compaction", {}) as response:
                report = json.load(response)
            self.assertEqual(report["state"], "failed")
            self.assertFalse(report["selection_applied"])
            self.assertEqual(len(summaries), 2)
            snapshot = self._assert_capture(
                app, owner, summaries[1], before["identity_revision"]
            )
            self.assertIn(
                "ordinary request not admitted", snapshot["compaction"]["source"]
            )
            self.assertEqual(inspect(app, owner)["persona"], before)
            recorded = self._forced_record(app, owner, earlier_runs)
            self.assertEqual(recorded["outcome"], "failed")
            self.assertEqual(recorded["http_status"], 400)
            with sqlite3.connect(app.home / "albedo.sqlite") as db:
                self.assertEqual(
                    db.execute(
                        "SELECT COUNT(*) FROM lcm_compaction_node WHERE session=?",
                        (owner,),
                    ).fetchone()[0],
                    0,
                )

    def test_unbound_lcm_keeps_baseline_chunks_prompt_and_accounting(self):
        summaries = []

        def reply(request):
            if "<newly-evicted-history>" in json.dumps(request):
                summaries.append(request)
                return text("x")
            return text("ordinary answer")

        provider = Provider(reply)
        self.addCleanup(provider.close)
        with Albedo(
            provider,
            protocol="responses",
            prepare=lambda app: app.write_extensions(
                {
                    "enabled": {"lcm": True, "rolling": False, "notes": False},
                    "lcm": {
                        "contextWindowTokens": 50000,
                        "triggerPercent": 80,
                        "tailPercent": 25,
                    },
                }
            ),
        ) as app:
            owner = app.session()
            for prompt in ("u" * 10000, "v" * 10000, "retained tail"):
                app.prompt(owner, prompt).close()
                app.idle(owner)
            with app.api(
                f"/sessions/{owner}/compaction", {"strategy": "lcm"}
            ) as response:
                self.assertEqual(json.load(response)["state"], "compacted")
            self.assertEqual(len(summaries), 1)
            self.assertNotIn("summary-evidence", json.dumps(summaries[0]))
            records = read(app, f"/sessions/{owner}/context?view=requests")["items"]
            recorded = [record for record in records if record["kind"] == "summarizer"]
            self.assertEqual(len(recorded), 1)
            self.assertIsNone(recorded[0]["projection_hash"])
