"""Rejected terminal output cannot replace durable sources through either wire.

Plain LCM exercises the shared native summary boundary without automatic persona
formation racing the forced operation. The native persona graph regressions cover
parent formation, long reading, and custom-provider Turn inconsistencies.
"""

import json
import sqlite3
import unittest

from harness import Albedo, Provider, Reply, exclusive, text


def candidate(protocol, kind):
    value = "I remember the verified source."
    if kind == "empty":
        value = ""
    elif kind == "whitespace":
        value = "  \n "
    if protocol == "chat_completions":
        delta = {"role": "assistant", "content": value}
        if kind == "refusal":
            delta["refusal"] = "I cannot supply this memory."
        if kind == "tools":
            delta["tool_calls"] = [
                {
                    "index": 0,
                    "id": "unexpected-call",
                    "type": "function",
                    "function": {"name": "read", "arguments": "{}"},
                }
            ]
        finish = {
            "length": "length",
            "filter": "content_filter",
            "incomplete": "unknown_finish",
            "tools": "tool_calls",
        }.get(kind, "stop")
        events = [
            {"id": "fixture", "choices": [{"index": 0, "delta": delta}]},
            {
                "id": "fixture",
                "choices": [{"index": 0, "delta": {}, "finish_reason": finish}],
            },
            {
                "id": "fixture",
                "choices": [],
                "usage": {"prompt_tokens": 13, "completion_tokens": 7},
            },
        ]
    else:
        content = [{"type": "output_text", "text": value}]
        if kind == "refusal":
            content.append(
                {"type": "refusal", "refusal": "I cannot supply this memory."}
            )
        output = [
            {
                "type": "message",
                "role": "assistant",
                "status": "completed",
                "content": content,
            }
        ]
        if kind == "complete_reasoning":
            output.insert(
                0,
                {
                    "type": "reasoning",
                    "id": "reasoning-fixture",
                    "summary": [],
                    "status": "completed",
                    "content": None,
                },
            )
        if kind == "tools":
            output.append(
                {
                    "type": "function_call",
                    "call_id": "unexpected-call",
                    "name": "read",
                    "arguments": "{}",
                    "status": "completed",
                }
            )
        response = {
            "id": "fixture",
            "status": "completed",
            "output": output,
            "usage": {"input_tokens": 13, "output_tokens": 7},
        }
        event = "response.completed"
        if kind in ("length", "filter", "incomplete"):
            event = "response.incomplete"
            response["status"] = "incomplete"
            reason = {"length": "max_output_tokens", "filter": "content_filter"}
            response["incomplete_details"] = {
                "reason": reason.get(kind, "fixture_incomplete")
            }
        events = [{"type": event, "response": response}]
    return Reply("text", events=events)


@exclusive
class SummaryDispositionTests(unittest.TestCase):
    def check_protocol(self, protocol):
        disposition = ["complete"]
        summaries = []

        def reply(request):
            if "<newly-evicted-history>" in json.dumps(request):
                summaries.append(request)
                return candidate(protocol, disposition[0])
            return text("ordinary verified action")

        provider = Provider(reply)
        self.addCleanup(provider.close)
        with Albedo(
            provider,
            protocol=protocol,
            prepare=lambda app: app.write_extensions(
                {
                    "enabled": {"lcm": True, "rolling": False, "notes": False},
                    "lcm": {
                        "contextWindowTokens": 200000,
                        "triggerPercent": 80,
                        "tailPercent": 25,
                    },
                }
            ),
        ) as app:
            for kind in (
                "length",
                "filter",
                "incomplete",
                "tools",
                "refusal",
                "empty",
                "whitespace",
            ):
                with self.subTest(protocol=protocol, disposition=kind):
                    owner = app.session()
                    for prompt in ("verified older source " * 100, "retained unit"):
                        app.prompt(owner, prompt).close()
                        app.idle(owner)
                    with sqlite3.connect(app.home / "albedo.sqlite") as db:
                        before = db.execute(
                            "SELECT seq,payload FROM transcript WHERE session=? ORDER BY seq",
                            (owner,),
                        ).fetchall()
                    disposition[0] = kind
                    count = len(summaries)
                    with app.api(
                        f"/sessions/{owner}/compaction", {"strategy": "lcm"}
                    ) as response:
                        report = json.load(response)
                    self.assertEqual(report["state"], "failed", report)
                    self.assertEqual(len(summaries), count + 1)
                    with sqlite3.connect(app.home / "albedo.sqlite") as db:
                        self.assertEqual(
                            db.execute(
                                "SELECT COUNT(*) FROM lcm_compaction_node WHERE session=?",
                                (owner,),
                            ).fetchone()[0],
                            0,
                        )
                        self.assertEqual(
                            db.execute(
                                "SELECT seq,payload FROM transcript WHERE session=? ORDER BY seq",
                                (owner,),
                            ).fetchall(),
                            before,
                        )
                        self.assertEqual(
                            db.execute(
                                "SELECT input_tokens,output_tokens,seq,outcome FROM provider_requests WHERE session=? AND kind='summarizer'",
                                (owner,),
                            ).fetchall(),
                            [(13, 7, None, "ok")],
                        )
                    # Nullable reasoning content is valid in a completed
                    # Responses reply and must not block the visible answer.
                    disposition[0] = (
                        "complete_reasoning" if protocol == "responses" else "complete"
                    )
                    with app.api(
                        f"/sessions/{owner}/compaction", {"strategy": "lcm"}
                    ) as response:
                        self.assertEqual(json.load(response)["state"], "compacted")
                    with sqlite3.connect(app.home / "albedo.sqlite") as db:
                        self.assertGreater(
                            db.execute(
                                "SELECT COUNT(*) FROM lcm_compaction_node WHERE session=?",
                                (owner,),
                            ).fetchone()[0],
                            0,
                        )
                    print(f"verified {protocol} rejection and recovery: {kind}")

    def test_responses_rejects_noncanonical_summary_output(self):
        self.check_protocol("responses")

    def test_chat_rejects_noncanonical_summary_output(self):
        self.check_protocol("chat_completions")
