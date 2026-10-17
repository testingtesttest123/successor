"""Optional simple lessons through the real authenticated service and store."""

import json
import unittest

from harness import Albedo, Provider, exclusive, operation_id, text
from personality_support import value


@exclusive
class PersonalityLessonsTest(unittest.TestCase):
    def test_simple_lesson_needs_only_content_and_tags_and_retains_history(self):
        provider = Provider(lambda _request: text("unused"))
        self.addCleanup(provider.close)
        with Albedo(
            provider,
            prepare=lambda app: app.write_extensions(
                {"enabled": {"personality": True, "personality-lessons": True}}
            ),
        ) as app:
            session = app.session()
            value(
                app,
                f"/sessions/{session}/setup",
                {"name": "identity", "content": "living"},
            )
            root = f"/extensions/personality-lessons/sessions/{session}/lessons"
            body = {
                "content": "Check a source before treating it as fact",
                "tags": ["research"],
                "retry_key": operation_id(),
            }
            with app.api(root, body) as response:
                first = json.load(response)
            with app.api(root, body) as response:
                self.assertEqual(json.load(response), first)
            self.assertEqual(first["confidence"], 0.5)
            self.assertEqual(first["evidence"], [])
            with app.api(
                root + "/" + first["id"],
                {
                    "evidence": ["https://example.org/reference"],
                    "content": "Read the primary source",
                },
            ) as response:
                edited = json.load(response)
            self.assertEqual(edited["evidence"], ["https://example.org/reference"])
            with app.api(
                root + "/" + first["id"] + "/deprecate", {"reason": "superseded"}
            ) as response:
                self.assertTrue(json.load(response)["deprecated"])
            app.restart()
            with app.api(root + "/" + first["id"] + "/history") as response:
                history = json.load(response)["records"]
            self.assertEqual([item["revision"] for item in history], [1, 2, 3])
            self.assertEqual(history[0]["content"], body["content"])
            self.assertEqual(
                value(app, f"/sessions/{session}/document")["text"], "living"
            )
