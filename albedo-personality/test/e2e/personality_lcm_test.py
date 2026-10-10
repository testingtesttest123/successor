"""Native persona-aware LCM calls through the real daemon and scripted provider.

These live assertions are retained even on executors that cannot boot the
AF_UNIX Python kernel; the compiled socket-free suite covers those limits.
"""

import json
import sqlite3
import threading
import unittest

from harness import Albedo, Provider, error, exclusive, text
from personality_context_test import edit, instructions, read
from personality_support import bind, create, inspect


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
    return json.loads(
        prompt.split("<summary-evidence>\n", 1)[1].split("\n</summary-evidence>", 1)[0]
    )


@exclusive
class PersonalityLcmTests(unittest.TestCase):
    def test_automatic_and_forced_lcm_receive_captured_policy_and_real_sources(self):
        for forced in (False, True):
            with self.subTest(forced=forced):
                entered, release = threading.Event(), threading.Event()
                summaries = []

                def reply(request):
                    if "<newly-evicted-history>" in json.dumps(request):
                        summaries.append(request)
                        entered.set()
                        release.wait(30)
                        return text("x")
                    return text("ordinary answer")

                provider = Provider(reply)
                self.addCleanup(provider.close)
                self.addCleanup(release.set)
                with Albedo(
                    provider,
                    protocol="responses",
                    prepare=lambda app: app.write_extensions(
                        {
                            "enabled": {
                                "personality": True,
                                "lcm": True,
                                "rolling": False,
                            },
                            "lcm": {
                                "contextWindowTokens": 200000 if forced else 30000,
                                "triggerPercent": 80,
                                "tailPercent": 25,
                            },
                        }
                    ),
                ) as app:
                    owner, editor = app.session(), app.session()
                    persona = create(app)
                    bind(app, owner, persona["id"])
                    bind(app, editor, persona["id"])
                    before = inspect(app, owner)["persona"]
                    if forced:
                        for prompt in ("older source unit", "latest retained unit"):
                            app.prompt(owner, prompt).close()
                            app.idle(owner)
                        result, failures = [], []

                        # /compact is a POST, so use the real API operation.
                        def compact_post():
                            try:
                                with app.api(
                                    f"/sessions/{owner}/compaction", {"strategy": "lcm"}
                                ) as response:
                                    result.append(json.load(response))
                            except Exception as exc:
                                failures.append(exc)

                        worker = threading.Thread(target=compact_post)
                        worker.start()
                    else:
                        result, failures = [], []

                        def automatic():
                            try:
                                for index in range(100):
                                    app.prompt(
                                        owner, f"unit {index} " + "trusted input " * 300
                                    ).close()
                                    app.idle(owner)
                                    if entered.is_set():
                                        break
                            except Exception as exc:
                                failures.append(exc)

                        worker = threading.Thread(target=automatic)
                        worker.start()
                    self.assertTrue(entered.wait(10), "no native summarizer request")
                    first = envelope(summaries[0])
                    self.assertEqual(
                        first["identity_revision"], before["identity_revision"]
                    )
                    self.assertEqual(first["session"], owner)
                    self.assertIn("persona", instructions(summaries[0]))
                    self.assertEqual(summaries[0].get("tools", []), [])
                    edit(app, editor, "Concurrent edit while summarizer is active")
                    edited = inspect(app, editor)["persona"]
                    release.set()
                    if worker:
                        worker.join(20)
                        self.assertFalse(worker.is_alive())
                        self.assertEqual(failures, [])
                        if forced:
                            self.assertEqual(result[0]["state"], "compacted")
                    app.idle(owner)
                    self.assertEqual(inspect(app, owner)["persona"], edited)
                    with sqlite3.connect(app.home / "albedo.sqlite") as db:
                        leaf_ranges = db.execute(
                            "SELECT first_seq,last_seq FROM lcm_compaction_node WHERE session=? AND depth=0 ORDER BY first_seq",
                            (owner,),
                        ).fetchall()
                        actual_rows = [
                            row[0]
                            for row in db.execute(
                                "SELECT seq FROM transcript WHERE session=? ORDER BY seq",
                                (owner,),
                            )
                        ]
                    received = [envelope(request) for request in summaries]
                    actual_compacted_ranges = sorted(
                        {
                            tuple(bounds)
                            for item in received
                            for bounds in item["source_ranges"]
                        }
                    )
                    self.assertEqual(actual_compacted_ranges, leaf_ranges)
                    for start, end in actual_compacted_ranges:
                        self.assertIn(start, actual_rows)
                        self.assertIn(end, actual_rows)
                    self.assertTrue(
                        any(
                            attr["actor"] == "user_assertion"
                            for item in received
                            for attr in item["attributions"]
                        )
                    )
                    self.assertTrue(
                        all(
                            item["identity_revision"] == before["identity_revision"]
                            for item in received
                        )
                    )
                    snapshot = read(app, f"/sessions/{owner}/context")
                    self.assertEqual(len(snapshot["summary_calls"]), len(summaries))
                    records = read(app, f"/sessions/{owner}/context?view=requests")[
                        "items"
                    ]
                    recorded = [
                        record for record in records if record["kind"] == "summarizer"
                    ]
                    self.assertEqual(len(recorded), len(summaries))
                    self.assertTrue(
                        all(record["projection_hash"] for record in recorded)
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

    def test_failed_forced_summary_retains_captured_attempt_inspection(self):
        summaries = []

        def reply(request):
            if "<newly-evicted-history>" in json.dumps(request):
                summaries.append(request)
                return error(400, "summarizer refused")
            return text("ordinary answer")

        provider = Provider(reply)
        self.addCleanup(provider.close)
        with Albedo(
            provider,
            protocol="responses",
            prepare=lambda app: app.write_extensions(
                {
                    "enabled": {"personality": True, "lcm": True, "rolling": False},
                    "lcm": {
                        "contextWindowTokens": 200000,
                        "triggerPercent": 80,
                        "tailPercent": 25,
                    },
                }
            ),
        ) as app:
            owner = app.session()
            persona = create(app)
            bind(app, owner, persona["id"])
            for prompt in ("older source unit", "retained unit"):
                app.prompt(owner, prompt).close()
                app.idle(owner)
            before = inspect(app, owner)["persona"]
            with app.api(
                f"/sessions/{owner}/compaction", {"strategy": "lcm"}
            ) as response:
                report = json.load(response)
            self.assertEqual(report["state"], "failed")
            self.assertEqual(len(summaries), 1)
            snapshot = read(app, f"/sessions/{owner}/context")
            self.assertEqual(snapshot["summary_calls"][0]["status"], "attempted")
            self.assertIn(
                "ordinary request not admitted", snapshot["compaction"]["source"]
            )
            self.assertEqual(
                snapshot["request_context"][0]["summary_policy"]["identity_revision"],
                before["identity_revision"],
            )
            self.assertEqual(inspect(app, owner)["persona"], before)
            records = read(app, f"/sessions/{owner}/context?view=requests")["items"]
            recorded = [record for record in records if record["kind"] == "summarizer"]
            self.assertEqual(len(recorded), 1)
            self.assertEqual(recorded[0]["outcome"], "failed")
            with sqlite3.connect(app.home / "albedo.sqlite") as db:
                self.assertEqual(
                    db.execute(
                        "SELECT COUNT(*) FROM lcm_compaction_node WHERE session=?",
                        (owner,),
                    ).fetchone()[0],
                    0,
                )
