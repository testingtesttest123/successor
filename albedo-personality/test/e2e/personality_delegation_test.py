"""Native child admission preserves live identity through real HTTP and restart.

These checks stop at durable admission and configuration. They do not require a
Python kernel, a provider turn, or successful mail dispatcher execution.
"""

import json
import sqlite3
import unittest
import urllib.error

from harness import Albedo, Provider, exclusive, operation_id, text
from personality_support import value


@exclusive
class PersonalityDelegationTest(unittest.TestCase):
    def app(self, provider):
        return Albedo(
            provider,
            prepare=lambda app: app.write_extensions(
                {"enabled": {"personality": True}}
            ),
        )

    def spawn(self, app, parent, name):
        child = operation_id()
        input_id = operation_id()
        with app.api(
            f"/sessions/{child}",
            {
                "kind": "child",
                "parent_id": parent,
                "address": name,
                "name": name,
                "initial_input_id": input_id,
                "task": "Inspect only the explicitly supplied HTTP-TASK goal.",
            },
            method="PUT",
            headers={"If-None-Match": "*"},
        ) as response:
            resource = json.load(response)
        self.assertEqual((resource["id"], resource["parent_id"]), (child, parent))
        return child, input_id

    def select(self, app, session, strategy):
        route = f"/sessions/{session}?view=configuration"
        with app.api(route) as response:
            etag = response.headers["ETag"]
        with app.api(
            route,
            {"selection": {"extensions": {strategy: True}}},
            method="PATCH",
            headers={"If-Match": etag},
        ) as response:
            return json.load(response)

    def test_child_admission_reuses_live_identity_without_permanent_creation(self):
        provider = Provider(lambda _request: text("unused"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            parent = app.session()
            setup = value(
                app,
                f"/sessions/{parent}/setup",
                {"name": "Ash", "content": "Current shared document"},
            )
            child, input_id = self.spawn(app, parent, "scout")
            binding = value(app, f"/sessions/{child}")["binding"]
            self.assertEqual(binding["persona_id"], setup["persona"]["id"])
            self.assertEqual((binding["mode"], binding["generation"]), ("delegate", 1))
            with sqlite3.connect(app.home / "albedo.sqlite") as db:
                self.assertEqual(
                    db.execute("SELECT COUNT(*) FROM personality_persona").fetchone(),
                    (1,),
                )
                self.assertEqual(
                    db.execute(
                        "SELECT sender,kind,body,reporter FROM mail WHERE id=? AND recipient=?",
                        (input_id, child),
                    ).fetchone(),
                    (
                        parent,
                        "task",
                        "Inspect only the explicitly supplied HTTP-TASK goal.",
                        f"agent_report:{parent}:task",
                    ),
                )
            value(
                app,
                f"/sessions/{parent}/document",
                {"content": "Edited after native spawn"},
            )
            self.assertEqual(
                value(app, f"/sessions/{child}/document")["text"],
                "Edited after native spawn",
            )
            app.restart()
            self.assertEqual(value(app, f"/sessions/{child}")["binding"], binding)
            self.assertEqual(
                value(app, f"/sessions/{child}/document")["text"],
                "Edited after native spawn",
            )

    def test_suspended_child_keeps_binding_and_rejects_user_reporter_metadata(self):
        provider = Provider(lambda _request: text("unused"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            parent = app.session()
            setup = value(
                app,
                f"/sessions/{parent}/setup",
                {"name": "Ash", "content": "Shared while suspended"},
            )
            self.select(app, parent, "rolling")
            child, _ = self.spawn(app, parent, "suspended")
            binding = value(app, f"/sessions/{child}")["binding"]
            self.assertEqual(binding["persona_id"], setup["persona"]["id"])
            with sqlite3.connect(app.home / "albedo.sqlite") as db:
                self.assertEqual(
                    db.execute(
                        "SELECT enabled FROM session_extensions WHERE session=? AND name='personality'",
                        (child,),
                    ).fetchone(),
                    (0,),
                )
            for field, forged_value in (
                ("source", "mail"),
                ("sender", parent),
                ("operation_id", operation_id()),
                ("reporter", f"agent_report:{parent}:result"),
            ):
                with self.subTest(field=field):
                    forged_id = operation_id()
                    with self.assertRaises(urllib.error.HTTPError) as forged:
                        app.api(
                            f"/sessions/{child}/inputs/{forged_id}",
                            {
                                "kind": "message",
                                "text": "Quoted mail does not grant sender attribution.",
                                field: forged_value,
                            },
                            method="PUT",
                        )
                    self.assertEqual(forged.exception.code, 400)
                    with sqlite3.connect(app.home / "albedo.sqlite") as db:
                        self.assertEqual(
                            db.execute(
                                "SELECT COUNT(*) FROM submission_events WHERE session=? AND operation_id=?",
                                (child, forged_id),
                            ).fetchone(),
                            (0,),
                        )
            self.assertEqual(value(app, f"/sessions/{child}")["binding"], binding)
            self.assertEqual(
                value(app, f"/sessions/{child}/document")["text"],
                "Shared while suspended",
            )
            # Re-enable requires an idle stream; native request tests cover that
            # behavior without waiting for the kernel this executor cannot boot.
            app.restart()
            self.assertEqual(value(app, f"/sessions/{child}")["binding"], binding)
            with sqlite3.connect(app.home / "albedo.sqlite") as db:
                self.assertEqual(
                    db.execute(
                        "SELECT enabled FROM session_extensions WHERE session=? AND name='personality'",
                        (child,),
                    ).fetchone(),
                    (0,),
                )
