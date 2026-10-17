"""Free-form human identity operations through real HTTP admission and storage.

These scenarios deliberately avoid Python preparation. Compiled native suites
cover prepared request values and recovery, where AF_UNIX is unavailable.
"""

import sqlite3
import json
import unittest
import urllib.error

from harness import Albedo, Provider, exclusive, operation_id, text
from personality_support import value


@exclusive
class PersonalityIdentityTest(unittest.TestCase):
    def app(self, provider):
        return Albedo(
            provider,
            prepare=lambda app: app.write_extensions(
                {"enabled": {"personality": True}}
            ),
        )

    def test_setup_accepts_freeform_document_and_retries_without_new_identity(self):
        provider = Provider(lambda _request: text("unused"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            session = app.session()
            content = "Unconventional identity:\n" + '𐍈\t"自由"\\\n' * 2048
            body = {"name": "Albedo", "content": content, "retry_key": operation_id()}
            first = value(app, f"/sessions/{session}/setup", body)
            self.assertEqual(value(app, f"/sessions/{session}/setup", body), first)
            page = value(app, f"/sessions/{session}/document")
            self.assertEqual(page["text"], content[: len(page["text"])])
            with sqlite3.connect(app.home / "albedo.sqlite") as db:
                self.assertEqual(
                    db.execute("SELECT COUNT(*) FROM personality_persona").fetchone(),
                    (1,),
                )
                self.assertEqual(
                    db.execute("SELECT COUNT(*) FROM transcript").fetchone(), (0,)
                )
            app.restart()
            self.assertEqual(
                value(app, f"/sessions/{session}")["binding"]["persona_id"],
                first["persona"]["id"],
            )

    def test_one_mib_escaped_multibyte_document_is_admitted_and_oversize_is_atomic(
        self,
    ):
        provider = Provider(lambda _request: text("unused"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            session = app.session()
            # JSON escapes expand the body well beyond the stored UTF-8 bound.
            content = ('\x01"\\𐍈' * 149796) + "a" * 4
            self.assertEqual(len(content.encode()), 1048576)
            value(
                app,
                f"/sessions/{session}/setup",
                {"name": "Albedo", "content": content},
            )
            before = value(app, f"/sessions/{session}/document")
            with self.assertRaises(urllib.error.HTTPError) as oversized:
                value(app, f"/sessions/{session}/document", {"content": content + "é"})
            self.assertEqual(oversized.exception.code, 400)
            self.assertEqual(value(app, f"/sessions/{session}/document"), before)
            old = before["revision"]
            value(app, f"/sessions/{session}/document", {"content": "new document"})
            chunks = []
            offset = 0
            while True:
                page = value(
                    app, f"/sessions/{session}/document?revision={old}&offset={offset}"
                )
                self.assertLessEqual(len(page["text"].encode()), 32768)
                chunks.append(page["text"])
                if page["next_offset"] is None:
                    break
                self.assertGreater(page["next_offset"], offset)
                offset = page["next_offset"]
            self.assertEqual("".join(chunks), content)
            self.assertEqual(
                value(app, f"/sessions/{session}/document")["text"], "new document"
            )
            with sqlite3.connect(app.home / "albedo.sqlite") as db:
                self.assertEqual(
                    db.execute("SELECT COUNT(*) FROM personality_revision").fetchone(),
                    (2,),
                )
                self.assertEqual(
                    db.execute("SELECT COUNT(*) FROM transcript").fetchone(), (0,)
                )

    def test_model_authority_fields_and_removed_ledger_routes_are_refused(self):
        provider = Provider(lambda _request: text("unused"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            session = app.session()
            value(
                app,
                f"/sessions/{session}/setup",
                {"name": "Albedo", "content": "living"},
            )
            with self.assertRaises(urllib.error.HTTPError) as spoof:
                value(
                    app,
                    f"/sessions/{session}/document",
                    {"content": "spoofed", "actor": "user"},
                )
            self.assertEqual(spoof.exception.code, 400)
            for suffix in ("memories", "recall", "sources/anything"):
                with self.assertRaises(urllib.error.HTTPError) as removed:
                    value(app, f"/sessions/{session}/{suffix}")
                self.assertEqual(removed.exception.code, 404)
            self.assertEqual(
                value(app, f"/sessions/{session}/document")["text"], "living"
            )

    def test_oversized_replacement_refuses_without_revision_or_receipt(self):
        provider = Provider(lambda _request: text("unused"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            session = app.session()
            content = "a" * 1024
            value(
                app,
                f"/sessions/{session}/setup",
                {"name": "default", "content": content},
            )
            before = value(app, f"/sessions/{session}/document")
            with self.assertRaises(urllib.error.HTTPError) as amplified:
                value(
                    app,
                    f"/sessions/{session}/edit",
                    {
                        "old_string": "a",
                        "new_string": "é" * 1024,
                        "replace_all": True,
                    },
                )
            self.assertEqual(amplified.exception.code, 400)
            self.assertEqual(value(app, f"/sessions/{session}/document"), before)
            with sqlite3.connect(app.home / "albedo.sqlite") as db:
                self.assertEqual(
                    db.execute("SELECT COUNT(*) FROM personality_revision").fetchone(),
                    (1,),
                )
                self.assertEqual(
                    db.execute(
                        "SELECT COUNT(*) FROM personality_tool_receipt"
                    ).fetchone(),
                    (0,),
                )
            value(
                app,
                f"/sessions/{session}/edit",
                {"old_string": "aa", "new_string": "é", "replace_all": True},
            )
            self.assertEqual(
                value(app, f"/sessions/{session}/document")["text"], "é" * 512
            )

    def test_additional_creation_retry_returns_one_identity(self):
        provider = Provider(lambda _request: text("unused"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            session = app.session()
            value(
                app,
                f"/sessions/{session}/setup",
                {"name": "default", "content": "initial"},
            )
            body = {
                "name": "deliberate additional",
                "content": "separate",
                "retry_key": operation_id(),
            }
            created = value(app, "/personas", body)
            self.assertEqual(value(app, "/personas", body), created)
            with sqlite3.connect(app.home / "albedo.sqlite") as db:
                self.assertEqual(
                    db.execute("SELECT COUNT(*) FROM personality_persona").fetchone(),
                    (2,),
                )

    def test_explicit_strategy_conflict_refuses_setup_and_binding_atomically(self):
        provider = Provider(lambda _request: text("unused"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            session = app.session()

            def select(owner, strategy):
                route = f"/sessions/{owner}?view=configuration"
                with app.api(route) as response:
                    etag = response.headers["ETag"]
                with app.api(
                    route,
                    {"selection": {"extensions": {strategy: True}}},
                    method="PATCH",
                    headers={"If-Match": etag},
                ) as response:
                    return json.load(response)

            select(session, "rolling")
            with self.assertRaises(urllib.error.HTTPError) as conflict:
                value(
                    app,
                    f"/sessions/{session}/setup",
                    {"name": "default", "content": "living"},
                )
            self.assertEqual(conflict.exception.code, 409)
            with sqlite3.connect(app.home / "albedo.sqlite") as db:
                for table in (
                    "personality_persona",
                    "personality_default",
                    "personality_session",
                    "personality_binding_revision",
                    "personality_setup_receipt",
                ):
                    self.assertEqual(
                        db.execute(f"SELECT COUNT(*) FROM {table}").fetchone(), (0,)
                    )
                self.assertEqual(
                    db.execute(
                        "SELECT name,enabled FROM session_extensions WHERE session=?",
                        (session,),
                    ).fetchall(),
                    [("rolling", 1)],
                )
            select(session, "personality")
            created = value(
                app,
                f"/sessions/{session}/setup",
                {"name": "default", "content": "living"},
            )
            select(session, "rolling")
            before = value(app, f"/sessions/{session}")["binding"]
            with self.assertRaises(urllib.error.HTTPError) as conflict:
                value(
                    app,
                    f"/sessions/{session}/binding",
                    {
                        "persona_id": created["persona"]["id"],
                        "expected_generation": before["generation"],
                        "acknowledge_history_through": 0,
                    },
                )
            self.assertEqual(conflict.exception.code, 409)
            self.assertEqual(value(app, f"/sessions/{session}")["binding"], before)
            with sqlite3.connect(app.home / "albedo.sqlite") as db:
                self.assertEqual(
                    db.execute(
                        "SELECT name,enabled FROM session_extensions WHERE session=?",
                        (session,),
                    ).fetchall(),
                    [("rolling", 1)],
                )
                self.assertEqual(
                    db.execute(
                        "SELECT COUNT(*) FROM personality_binding_revision"
                    ).fetchone(),
                    (1,),
                )

    def test_page_setup_select_and_edit_hide_transport_ids_and_render_document(self):
        provider = Provider(lambda _request: text("unused"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            session = app.session()

            def execute(action_id, form):
                page = value(app, f"/sessions/{session}")["page"]
                action = next(
                    item for item in page["actions"] if item["id"] == action_id
                )
                operation = action["operation"]
                body = {}
                for pointer, binding in operation["body"].items():
                    if binding["source"] == "literal":
                        body[pointer[1:]] = binding["value"]
                    else:
                        self.assertEqual(binding["source"], "form")
                        body[pointer[1:]] = form[binding["pointer"][1:]]
                with app.api(
                    operation["path_template"], body, method=operation["method"]
                ) as response:
                    self.assertEqual(response.status, operation["success_status"])
                    return json.load(response)

            first = execute(
                "setup",
                {"name": "default", "content": "first paragraph\nsecond paragraph"},
            )
            page = value(app, f"/sessions/{session}")["page"]
            self.assertIn(
                "first paragraph",
                "\n".join(row.get("detail") or "" for row in page["rows"]),
            )
            select = next(item for item in page["actions"] if item["id"] == "select")
            self.assertEqual(select["fields"][0]["type"], "choice")
            self.assertEqual(
                select["fields"][0]["choices"],
                [{"value": first["persona"]["id"], "label": "default"}],
            )
            self.assertTrue(
                all(
                    field["name"] != "retry_key"
                    for action in page["actions"]
                    for field in action["fields"]
                )
            )
            execute(
                "edit",
                {"old_string": "second paragraph", "new_string": "revised paragraph"},
            )
            self.assertEqual(
                value(app, f"/sessions/{session}/document")["text"],
                "first paragraph\nrevised paragraph",
            )
