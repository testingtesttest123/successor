"""Live request snapshots through the real daemon and both scripted providers."""

import json
import re
import threading
import unittest

from harness import (
    Albedo,
    Provider,
    Reply,
    error,
    exclusive,
    operation_id,
    python,
    text,
)
from personality_support import bind, create, inspect, value


def instructions(request):
    if "instructions" in request:
        return request["instructions"]
    return "\n\n".join(
        message["content"]
        for message in request["messages"]
        if message.get("role") == "system"
    )


def identity(request):
    prefix, block = instructions(request).split("\n\n[request context: ", 1)
    payload = block.split("\n", 1)[1]
    return prefix, json.loads(payload)


def read(app, route):
    with app.api(route) as response:
        return json.load(response)


def edit(app, session, values):
    head = inspect(app, session)["persona"]
    return value(
        app,
        f"/sessions/{session}/identity",
        {
            "operation_id": operation_id(),
            "expected_revision": head["revision"],
            "expected_identity_revision": head["identity_revision"],
            "reason": "foreground identity change",
            "changes": {"values": values},
        },
    )


@exclusive
class PersonalityContextTest(unittest.TestCase):
    def app(self, provider, protocol):
        return Albedo(
            provider,
            protocol=protocol,
            prepare=lambda app: app.write_extensions(
                {"enabled": {"personality": True}}
            ),
        )

    def test_tool_edit_refreshes_next_request_with_static_pin_intact(self):
        for protocol in ("responses", "chat_completions"):
            with self.subTest(protocol=protocol):
                body, step = {}, [0]

                def reply(_request):
                    current = step[0]
                    step[0] += 1
                    if current in (0, 2):
                        return python(
                            "import os\nprint('context-kernel-pid', os.getpid())"
                        )
                    if current == 1:
                        return Reply(
                            "python", tool_name="persona_edit", tool_arguments=body
                        )
                    return text("finished")

                provider = Provider(reply)
                self.addCleanup(provider.close)
                with self.app(provider, protocol) as app:
                    session = app.session()
                    persona = create(app)
                    bind(app, session, persona["id"])
                    head = inspect(app, session)["persona"]
                    body.update(
                        operation_id=operation_id(),
                        expected_revision=head["revision"],
                        expected_identity_revision=head["identity_revision"],
                        reason="native live projection test",
                        changes={"values": "Careful curiosity"},
                    )
                    app.prompt(session, "edit the live persona").close()
                    app.idle(session)
                    sent = [item["request"] for item in provider.requests]
                    self.assertEqual(len(sent), 4)
                    old_prefix, old = identity(sent[0])
                    new_prefix, new = identity(sent[2])
                    self.assertEqual(old_prefix, new_prefix)
                    self.assertEqual(old["persona_id"], new["persona_id"])
                    self.assertEqual(new["identity"]["values"], "Careful curiosity")
                    self.assertEqual(
                        new["identity_revision"], old["identity_revision"] + 1
                    )
                    self.assertGreater(
                        new["aggregate_revision"], old["aggregate_revision"]
                    )
                    records = read(app, f"/sessions/{session}/context?view=requests")[
                        "records"
                    ]
                    self.assertNotEqual(
                        records[0]["head_hash"], records[2]["head_hash"]
                    )
                    pids = re.findall(r"context-kernel-pid (\d+)", json.dumps(sent[-1]))
                    self.assertEqual(len(pids), 2, sent[-1])
                    self.assertEqual(pids[0], pids[1])
                    durable = read(app, f"/sessions/{session}?tail=100")["history"]
                    self.assertNotIn("[request context: ", json.dumps(durable))
                    summary = read(app, f"/sessions/{session}/context?view=summary")
                    self.assertEqual(
                        summary["request_context"][0]["snapshot_id"], new["snapshot_id"]
                    )
                    before = len(provider.requests)
                    read(app, f"/sessions/{session}/context?view=summary")
                    self.assertEqual(len(provider.requests), before)

    def test_automatic_recall_is_request_only_and_preserves_static_pin(self):
        for protocol in ("responses", "chat_completions"):
            with self.subTest(protocol=protocol):
                provider = Provider(lambda _request: text("source-backed turn"))
                self.addCleanup(provider.close)
                with self.app(provider, protocol) as app:
                    session = app.session()
                    bind(app, session, create(app)["id"])
                    app.prompt(session, "needle asserted source").close()
                    app.idle(session)
                    transcript = read(app, f"/sessions/{session}/history?limit=100")[
                        "entries"
                    ]
                    seq = next(
                        row["position"] for row in transcript if row["kind"] == "user"
                    )
                    head = inspect(app, session)["persona"]
                    receipt = value(
                        app,
                        f"/sessions/{session}/memories",
                        {
                            "operation_id": operation_id(),
                            "expected_revision": head["revision"],
                            "expected_identity_revision": head["identity_revision"],
                            "reason": "explicit foreground curation",
                            "memories": [
                                {
                                    "text": "I was told the needle assertion",
                                    "provenance": "experienced",
                                    "uncertainty": "unverified",
                                    "tags": ["pinned"],
                                    "sources": [
                                        {
                                            "relation": "supports",
                                            "first_seq": seq,
                                            "last_seq": seq,
                                        }
                                    ],
                                }
                            ],
                        },
                    )
                    app.prompt(session, "needle follow-up").close()
                    app.idle(session)
                    sent = [item["request"] for item in provider.requests]
                    self.assertEqual(identity(sent[0])[0], identity(sent[-1])[0])
                    self.assertIn(
                        "[request context: personality recall", json.dumps(sent[-1])
                    )
                    summary = read(app, f"/sessions/{session}/context?view=summary")
                    recalled = summary["request_context"][0]
                    self.assertIn(receipt["records"][0]["id"], recalled["selected_ids"])
                    self.assertLessEqual(recalled["candidate_count"], 256)
                    self.assertLessEqual(recalled["selected_count"], 16)
                    durable = read(app, f"/sessions/{session}?tail=100")["history"]
                    self.assertNotIn("[request context:", json.dumps(durable))

    def test_gateway_retry_reuses_snapshot_then_next_preparation_refreshes(self):
        for protocol in ("responses", "chat_completions"):
            with self.subTest(protocol=protocol):
                entered, release = threading.Event(), threading.Event()
                count = [0]

                def reply(_request):
                    count[0] += 1
                    if count[0] == 1:
                        entered.set()
                        release.wait(30)
                        return error(502)
                    return text("finished")

                provider = Provider(reply)
                self.addCleanup(provider.close)
                self.addCleanup(release.set)
                with self.app(provider, protocol) as app:
                    session = app.session()
                    bind(app, session, create(app)["id"])
                    app.prompt(session, "first prepared request").close()
                    self.assertTrue(entered.wait(15))
                    edit(app, session, "changed during retry")
                    release.set()
                    app.idle(session)
                    self.assertEqual(
                        provider.requests[0]["request"], provider.requests[1]["request"]
                    )
                    app.prompt(session, "next preparation").close()
                    app.idle(session)
                    _, latest = identity(provider.requests[-1]["request"])
                    self.assertEqual(
                        latest["identity"]["values"], "changed during retry"
                    )
                    app.restart()
                    app.prompt(session, "after restart").close()
                    app.idle(session)
                    _, restarted = identity(provider.requests[-1]["request"])
                    self.assertEqual(restarted["snapshot_id"], latest["snapshot_id"])

    def test_steering_continuation_prepares_the_new_identity(self):
        for protocol in ("responses", "chat_completions"):
            with self.subTest(protocol=protocol):
                entered, release = threading.Event(), threading.Event()
                count = [0]

                def reply(_request):
                    count[0] += 1
                    if count[0] == 1:
                        entered.set()
                        release.wait(30)
                        return python("print('continuation barrier')")
                    return text("finished")

                provider = Provider(reply)
                self.addCleanup(provider.close)
                self.addCleanup(release.set)
                with self.app(provider, protocol) as app:
                    session = app.session()
                    bind(app, session, create(app)["id"])
                    app.prompt(session, "initial turn").close()
                    self.assertTrue(entered.wait(15))
                    edit(app, session, "changed before steering")
                    app.prompt(session, "steering excerpt").close()
                    release.set()
                    app.idle(session)
                    self.assertGreaterEqual(len(provider.requests), 2)
                    _, next_identity = identity(provider.requests[1]["request"])
                    self.assertEqual(
                        next_identity["identity"]["values"], "changed before steering"
                    )
                    self.assertIn(
                        "steering excerpt", json.dumps(provider.requests[-1]["request"])
                    )

    def test_pending_inspector_reads_do_not_prepare_identity_or_call_provider(self):
        provider = Provider(lambda _request: text("unused"))
        self.addCleanup(provider.close)
        with self.app(provider, "responses") as app:
            session = app.session()
            bind(app, session, create(app)["id"])
            edit(app, session, "current but never prepared")
            initial = inspect(app, session)["persona"]
            for _ in range(3):
                pending = read(app, f"/sessions/{session}/context?view=summary")
                self.assertEqual(pending["state"], "pending")
                self.assertEqual(pending["request_context"], [])
            self.assertEqual(inspect(app, session)["persona"], initial)
            self.assertEqual(provider.requests, [])
