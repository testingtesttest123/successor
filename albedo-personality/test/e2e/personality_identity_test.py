"""Human setup and durable admission through the real daemon, never a mock ledger."""

import json
import sqlite3
import threading
import unittest
import urllib.error

from harness import Albedo, Provider, Reply, exclusive, operation_id, python, text
from personality_support import bind, create, enable, inspect, value


@exclusive
class PersonalityIdentityTest(unittest.TestCase):
    def app(self, provider):
        return Albedo(
            provider,
            prepare=lambda app: app.write_extensions(
                {"enabled": {"personality": True}}
            ),
        )

    def test_human_setup_creates_one_default_and_binding_survives_restart(self):
        provider = Provider(lambda _request: text("hello"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            operation = operation_id()
            persona = create(app, default=True, operation=operation)
            self.assertEqual(create(app, default=True, operation=operation), persona)
            first = app.session()
            other_workspace = app.workspace / "other"
            other_workspace.mkdir()
            second = app.session(other_workspace)
            for session in (first, second):
                bound = bind(app, session)
                self.assertEqual(bound["binding"]["persona_id"], persona["id"])
                self.assertEqual(bound["binding"]["revision"], 1)
                self.assertEqual(bound["binding"]["mode"], "owner")
            app.restart()
            for session in (first, second):
                self.assertEqual(
                    inspect(app, session)["binding"]["persona_id"], persona["id"]
                )
            with sqlite3.connect(app.home / "albedo.sqlite") as db:
                self.assertEqual(
                    db.execute("SELECT COUNT(*) FROM personality_persona").fetchone()[
                        0
                    ],
                    1,
                )
                self.assertEqual(
                    db.execute(
                        "SELECT session,capability FROM session_requirements ORDER BY session"
                    ).fetchall(),
                    sorted([(first, "personality"), (second, "personality")]),
                )
            third = app.session()
            self.assertIsNone(inspect(app, third)["binding"])
            self.assertEqual(bind(app, third)["binding"]["persona_id"], persona["id"])

    def test_enabled_unbound_and_quarantined_bound_sessions_send_no_request(self):
        provider = Provider(lambda _request: text("ordinary answer"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            unbound = app.session()
            self.assertEqual(inspect(app, unbound)["state"], "setup_required")
            app.prompt(unbound, "must not reach provider").close()
            app.idle(unbound)
            self.assertEqual(len(provider.requests), 0)
            bound = app.session()
            persona = create(app)
            bind(app, bound, persona["id"])

            def break_schema(_app):
                with sqlite3.connect(app.home / "albedo.sqlite") as db:
                    db.execute(
                        "ALTER TABLE personality_persona RENAME TO personality_persona_saved"
                    )
                    db.execute(
                        "CREATE VIEW personality_persona AS SELECT id FROM personality_persona_saved"
                    )

            app.restart(prepare=break_schema)
            app.prompt(bound, "must remain fail closed in quarantine").close()
            app.idle(bound)
            self.assertEqual(len(provider.requests), 0)
            ordinary = app.session()
            enable(app, ordinary, False)
            app.prompt(ordinary, "ordinary remains available").close()
            app.idle(ordinary)
            self.assertEqual(len(provider.requests), 1)

    def test_binding_requires_current_history_disclosure_and_idle_session(self):
        entered = threading.Event()
        release = threading.Event()

        def reply(_request):
            entered.set()
            release.wait(30)
            return text("finished")

        provider = Provider(reply)
        self.addCleanup(provider.close)
        self.addCleanup(release.set)
        with self.app(provider) as app:
            session = app.session()
            first = create(app)
            second = create(app)
            enable(app, session, False)
            app.prompt(session, "history before explicit binding").close()
            self.assertTrue(entered.wait(10))
            with self.assertRaises(urllib.error.HTTPError) as busy:
                bind(app, session, first["id"])
            self.assertEqual(busy.exception.code, 409)
            release.set()
            app.idle(session)
            disclosure = inspect(app, session)["pre_binding_history"]
            self.assertGreater(disclosure["through"], 0)
            self.assertEqual(disclosure["provenance"], "pre_binding")
            with self.assertRaises(urllib.error.HTTPError) as stale:
                value(
                    app,
                    f"/sessions/{session}/binding",
                    {
                        "operation_id": operation_id(),
                        "persona_id": first["id"],
                        "expected_binding_revision": 0,
                        "acknowledge_history_through": 0,
                    },
                )
            self.assertEqual(stale.exception.code, 409)
            enable(app, session)
            bound = bind(app, session, first["id"])
            self.assertEqual(
                bound["binding"]["pre_binding_through"], disclosure["through"]
            )
            entered.clear()
            release.clear()
            app.prompt(session, "hold an already bound session for rebind").close()
            self.assertTrue(entered.wait(10))
            with self.assertRaises(urllib.error.HTTPError) as busy_rebind:
                bind(app, session, second["id"])
            self.assertEqual(busy_rebind.exception.code, 409)
            release.set()
            app.idle(session)
            self.assertEqual(bind(app, session, second["id"])["binding"]["revision"], 2)
            value(
                app,
                f"/sessions/{session}/binding",
                {"operation_id": operation_id(), "expected_binding_revision": 2},
                method="DELETE",
            )
            self.assertIsNone(inspect(app, session)["binding"])

    def test_additional_human_creation_is_empty_and_archive_refuses_live_binding(self):
        provider = Provider(lambda _request: text("hello"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            first = create(
                app, default=True, agent_identity_edits=False, agent_memory_edits=False
            )
            second = create(app)
            self.assertNotEqual(first["id"], second["id"])
            self.assertEqual(
                second["identity"],
                {
                    "self_description": "",
                    "values": "",
                    "communication": "",
                    "instructions": "",
                },
            )
            self.assertTrue(second["agent_identity_edits"])
            session = app.session()
            bind(app, session, first["id"])
            current = inspect(app, session)["persona"]
            with self.assertRaises(urllib.error.HTTPError) as active:
                value(
                    app,
                    f"/personas/{first['id']}/archive",
                    {
                        "operation_id": operation_id(),
                        "expected_revision": current["revision"],
                    },
                )
            self.assertEqual(active.exception.code, 409)
            self.assertEqual(json.load(active.exception)["detail"], "active_bindings")
            retained = inspect(app, session)
            self.assertEqual(retained["persona"]["state"], "active")
            self.assertEqual(retained["persona"]["revision"], current["revision"])
            self.assertEqual(retained["binding"]["persona_id"], first["id"])
            archived = value(
                app,
                f"/personas/{second['id']}/archive",
                {
                    "operation_id": operation_id(),
                    "expected_revision": second["revision"],
                },
            )
            self.assertEqual(archived["state"], "archived")
            with self.assertRaises(urllib.error.HTTPError):
                bind(app, app.session(), second["id"])

    def test_model_commands_cannot_create_identity_or_change_binding_authority(self):
        provider = Provider(
            lambda request: (
                python(
                    "catalog = await commands.catalog()\nassert not any(c['name'] == '/persona_create' and c['modelCallable'] for c in catalog)\ntry:\n    await commands.invoke('/persona_create', {})\n    assert False, 'human-only creation must refuse'\nexcept Exception as error:\n    assert not isinstance(error, AssertionError), error\nprint('human only')"
                )
                if request["messages"][-1].get("role") == "user"
                else text("done")
            )
        )
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            persona = create(app, default=True)
            session = app.session()
            bind(app, session)
            app.prompt(session, "try human creation from model").close()
            app.idle(session)
            with sqlite3.connect(app.home / "albedo.sqlite") as db:
                self.assertEqual(
                    db.execute("SELECT COUNT(*) FROM personality_persona").fetchone()[
                        0
                    ],
                    1,
                )
            self.assertEqual(
                inspect(app, session)["binding"]["persona_id"], persona["id"]
            )
            self.assertEqual(len(provider.requests), 2)

    def test_binding_store_unavailable_keeps_core_requirement(self):
        provider = Provider(lambda _request: text("must not send"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            session = app.session()
            bind(app, session, create(app)["id"])
            with sqlite3.connect(app.home / "albedo.sqlite") as db:
                db.execute("DROP TABLE personality_session")
            app.prompt(session, "binding unreadable").close()
            app.idle(session)
            self.assertEqual(len(provider.requests), 0)
            with sqlite3.connect(app.home / "albedo.sqlite") as db:
                self.assertEqual(
                    db.execute(
                        "SELECT capability FROM session_requirements WHERE session=?",
                        (session,),
                    ).fetchall(),
                    [("personality",)],
                )

    def test_binding_and_core_requirement_rollback_together(self):
        provider = Provider(lambda _request: text("hello"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            session = app.session()
            persona = create(app)
            with sqlite3.connect(app.home / "albedo.sqlite") as db:
                db.execute(
                    "CREATE TRIGGER reject_personality_requirement BEFORE INSERT ON session_requirements BEGIN SELECT RAISE(ABORT,'guard failure'); END"
                )
            with self.assertRaises(urllib.error.HTTPError):
                bind(app, session, persona["id"])
            self.assertIsNone(inspect(app, session)["binding"])

    def test_human_selects_an_existing_default_without_creating_or_copying_identity(
        self,
    ):
        provider = Provider(lambda _request: text("hello"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            first = create(app, default=True)
            second = create(app)
            value(
                app,
                "/default",
                {
                    "operation_id": operation_id(),
                    "persona_id": second["id"],
                    "expected_revision": second["revision"],
                },
            )
            session = app.session()
            self.assertEqual(bind(app, session)["binding"]["persona_id"], second["id"])
            self.assertNotEqual(first["id"], second["id"])
            with sqlite3.connect(app.home / "albedo.sqlite") as db:
                self.assertEqual(
                    db.execute("SELECT COUNT(*) FROM personality_persona").fetchone(),
                    (2,),
                )

    def test_human_binding_discloses_existing_rows_without_rewriting_transcript(self):
        import base64

        provider = Provider(lambda _request: text("hello"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            session = app.session()
            persona = create(app)
            payload = base64.b64decode("g2gCYQFoAncEdXNlcm0AAAAOYmVmb3JlIGJpbmRpbmc=")

            def seed(_app):
                with sqlite3.connect(app.home / "albedo.sqlite") as db:
                    db.execute(
                        "INSERT INTO transcript(session,payload,row_class,summary_indexed,calls_indexed) VALUES(?,?,'user',1,1)",
                        (session, payload),
                    )

            app.restart(prepare=seed)
            disclosure = inspect(app, session)["pre_binding_history"]
            self.assertEqual(disclosure["records"], 1)
            self.assertEqual(disclosure["provenance"], "pre_binding")
            with self.assertRaises(urllib.error.HTTPError) as stale:
                value(
                    app,
                    f"/sessions/{session}/binding",
                    {
                        "operation_id": operation_id(),
                        "persona_id": persona["id"],
                        "expected_binding_revision": 0,
                        "acknowledge_history_through": 0,
                    },
                )
            self.assertEqual(stale.exception.code, 409)
            self.assertEqual(
                bind(app, session, persona["id"])["binding"]["pre_binding_through"],
                disclosure["through"],
            )
            with sqlite3.connect(app.home / "albedo.sqlite") as db:
                self.assertEqual(
                    db.execute(
                        "SELECT payload FROM transcript WHERE session=?", (session,)
                    ).fetchall(),
                    [(payload,)],
                )

    def test_user_settings_reject_untrusted_author_and_authority_fields(self):
        provider = Provider(lambda _request: text("hello"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            with self.assertRaises(urllib.error.HTTPError) as author:
                create(app, author="user")
            self.assertEqual(author.exception.code, 400)
            persona = create(app)
            session = app.session()
            through = inspect(app, session)["pre_binding_history"]["through"]
            with self.assertRaises(urllib.error.HTTPError) as authority:
                value(
                    app,
                    f"/sessions/{session}/binding",
                    {
                        "operation_id": operation_id(),
                        "persona_id": persona["id"],
                        "expected_binding_revision": 0,
                        "acknowledge_history_through": through,
                        "mode": "owner",
                        "author": "user",
                    },
                )
            self.assertEqual(authority.exception.code, 400)
            self.assertIsNone(inspect(app, session)["binding"])

    def test_human_page_sets_up_default_then_unbinds_without_creating_another_identity(
        self,
    ):
        from personality_support import page_action

        provider = Provider(lambda _request: text("hello"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            session = app.session()
            persona = page_action(
                app, session, "persona_create", {"name": "Default identity"}
            )
            self.assertEqual(inspect(app, session)["default_persona_id"], persona["id"])
            bound = page_action(app, session, "bind_default")
            self.assertEqual(bound["binding"]["persona_id"], persona["id"])
            self.assertEqual(bound["binding"]["revision"], 1)
            page_action(app, session, "unbind")
            self.assertIsNone(inspect(app, session)["binding"])
            self.assertEqual(inspect(app, session)["binding_revision"], 2)
            self.assertEqual(bind(app, session)["binding"]["revision"], 3)
            with sqlite3.connect(app.home / "albedo.sqlite") as db:
                self.assertEqual(
                    db.execute("SELECT COUNT(*) FROM personality_persona").fetchone(),
                    (1,),
                )
                self.assertEqual(
                    db.execute(
                        "SELECT capability FROM session_requirements WHERE session=?",
                        (session,),
                    ).fetchall(),
                    [("personality",)],
                )

    def test_ordinary_extension_reload_preserves_explicit_binding_without_new_identity(
        self,
    ):
        provider = Provider(lambda _request: text("hello"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            session = app.session()
            persona = create(app, default=True)
            bind(app, session)
            app.prompt(session, "before ordinary reload").close()
            app.idle(session)
            app.api(f"/sessions/{session}/reload", {"target": "session"}).close()
            app.prompt(session, "after ordinary reload").close()
            app.idle(session)
            self.assertEqual(
                inspect(app, session)["binding"]["persona_id"], persona["id"]
            )
            self.assertEqual(inspect(app, session)["binding"]["revision"], 1)
            with sqlite3.connect(app.home / "albedo.sqlite") as db:
                self.assertEqual(
                    db.execute("SELECT COUNT(*) FROM personality_persona").fetchone(),
                    (1,),
                )
            self.assertEqual(len(provider.requests), 2)

    def test_cross_persona_rebind_audits_both_heads_once_and_replay_is_stable(self):
        provider = Provider(lambda _request: text("hello"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            first = create(app)
            second = create(app)
            session = app.session()
            bind(app, session, first["id"])
            operation = operation_id()
            body = {
                "operation_id": operation,
                "persona_id": second["id"],
                "expected_binding_revision": 1,
                "acknowledge_history_through": inspect(app, session)[
                    "pre_binding_history"
                ]["through"],
            }
            bound = value(app, f"/sessions/{session}/binding", body)
            self.assertEqual(bound["binding"]["revision"], 2)
            with sqlite3.connect(app.home / "albedo.sqlite") as db:
                heads = dict(db.execute("SELECT id,revision FROM personality_persona"))
                self.assertEqual(heads[first["id"]], 3)
                self.assertEqual(heads[second["id"]], 2)
                events = db.execute(
                    "SELECT persona_id,event_type,base_revision,head_revision FROM personality_event WHERE operation_id=? ORDER BY id",
                    (operation,),
                ).fetchall()
                self.assertEqual(
                    events,
                    [(first["id"], "unbound", 2, 3), (second["id"], "bound", 1, 2)],
                )
            self.assertEqual(value(app, f"/sessions/{session}/binding", body), bound)
            with sqlite3.connect(app.home / "albedo.sqlite") as db:
                self.assertEqual(
                    dict(db.execute("SELECT id,revision FROM personality_persona")),
                    heads,
                )
                self.assertEqual(
                    db.execute(
                        "SELECT persona_id,event_type,base_revision,head_revision FROM personality_event WHERE operation_id=? ORDER BY id",
                        (operation,),
                    ).fetchall(),
                    events,
                )
            same_operation = operation_id()
            same = {
                **body,
                "operation_id": same_operation,
                "expected_binding_revision": 2,
            }
            same_bound = value(app, f"/sessions/{session}/binding", same)
            self.assertEqual(same_bound["binding"]["revision"], 3)
            self.assertEqual(
                value(app, f"/sessions/{session}/binding", same), same_bound
            )
            with sqlite3.connect(app.home / "albedo.sqlite") as db:
                current_heads = dict(
                    db.execute("SELECT id,revision FROM personality_persona")
                )
                self.assertEqual(current_heads[first["id"]], 3)
                self.assertEqual(current_heads[second["id"]], 3)
                self.assertEqual(
                    db.execute(
                        "SELECT persona_id,event_type,base_revision,head_revision FROM personality_event WHERE operation_id=?",
                        (same_operation,),
                    ).fetchall(),
                    [(second["id"], "bound", 2, 3)],
                )

    def test_failed_rebind_rolls_back_both_persona_heads_events_binding_and_receipt(
        self,
    ):
        provider = Provider(lambda _request: text("hello"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            first = create(app)
            second = create(app)
            session = app.session()
            bind(app, session, first["id"])
            operation = operation_id()
            body = {
                "operation_id": operation,
                "persona_id": second["id"],
                "expected_binding_revision": 1,
                "acknowledge_history_through": inspect(app, session)[
                    "pre_binding_history"
                ]["through"],
            }
            with sqlite3.connect(app.home / "albedo.sqlite") as db:
                heads = dict(db.execute("SELECT id,revision FROM personality_persona"))
                db.execute(
                    "CREATE TRIGGER reject_rebind_event BEFORE INSERT ON personality_event WHEN NEW.event_type='bound' AND EXISTS(SELECT 1 FROM personality_session WHERE session=NEW.origin_session AND binding_revision=2) BEGIN SELECT RAISE(ABORT,'rebind event failure'); END"
                )
            with self.assertRaises(urllib.error.HTTPError) as failure:
                value(app, f"/sessions/{session}/binding", body)
            self.assertEqual(failure.exception.code, 503)
            self.assertEqual(
                inspect(app, session)["binding"]["persona_id"], first["id"]
            )
            self.assertEqual(inspect(app, session)["binding"]["revision"], 1)
            with sqlite3.connect(app.home / "albedo.sqlite") as db:
                self.assertEqual(
                    dict(db.execute("SELECT id,revision FROM personality_persona")),
                    heads,
                )
                self.assertEqual(
                    db.execute(
                        "SELECT id FROM personality_event WHERE operation_id=?",
                        (operation,),
                    ).fetchall(),
                    [],
                )
                self.assertEqual(
                    db.execute(
                        "SELECT operation_id FROM personality_operation WHERE operation_id=?",
                        (operation,),
                    ).fetchall(),
                    [],
                )
                self.assertEqual(
                    db.execute(
                        "SELECT capability FROM session_requirements WHERE session=?",
                        (session,),
                    ).fetchall(),
                    [("personality",)],
                )
                db.execute("DROP TRIGGER reject_rebind_event")
            self.assertEqual(
                value(app, f"/sessions/{session}/binding", body)["binding"][
                    "persona_id"
                ],
                second["id"],
            )

    def edit(
        self, app, session, *, changes=None, controls=None, operation=None, head=None
    ):
        persona = inspect(app, session)["persona"]
        body = {
            "operation_id": operation or operation_id(),
            "expected_revision": (head or persona)["revision"],
            "expected_identity_revision": (head or persona)["identity_revision"],
            "reason": "explicit identity revision",
            "changes": changes or {},
        }
        if controls is not None:
            body["controls"] = controls
        return value(app, f"/sessions/{session}/identity", body)

    def test_identity_edit_is_atomic_revisioned_and_idempotent(self):
        provider = Provider(lambda _request: text("unused"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            session = app.session()
            persona = create(app)
            bind(app, session, persona["id"])
            head = inspect(app, session)["persona"]
            operation = operation_id()
            receipt = self.edit(
                app,
                session,
                changes={"values": "Be candid"},
                operation=operation,
                head=head,
            )
            self.assertEqual(receipt["revision"], head["revision"] + 1)
            self.assertEqual(
                receipt["identity_revision"], head["identity_revision"] + 1
            )
            self.assertEqual(receipt["actor"], "user")
            self.assertIsNone(receipt["origin_call_id"])
            self.assertEqual(
                self.edit(
                    app,
                    session,
                    changes={"values": "Be candid"},
                    operation=operation,
                    head=head,
                ),
                receipt,
            )
            self.assertEqual(
                value(app, f"/sessions/{session}/receipts/{operation}"), receipt
            )
            with self.assertRaises(urllib.error.HTTPError) as reused:
                self.edit(
                    app,
                    session,
                    changes={"values": "different"},
                    operation=operation,
                    head=head,
                )
            self.assertEqual(json.load(reused.exception)["code"], "operation_id_reused")
            with self.assertRaises(urllib.error.HTTPError) as stale:
                self.edit(app, session, changes={"values": "stale"}, head=head)
            conflict = json.load(stale.exception)
            self.assertEqual(conflict["code"], "conflict")
            self.assertEqual(conflict["status"], 409)
            self.assertEqual(
                stale.exception.headers["content-type"], "application/problem+json"
            )
            self.assertEqual(
                conflict["current_heads"],
                {
                    "revision": receipt["revision"],
                    "identity_revision": receipt["identity_revision"],
                },
            )
            with sqlite3.connect(app.home / "albedo.sqlite") as db:
                self.assertEqual(
                    db.execute(
                        "SELECT COUNT(*) FROM personality_event WHERE operation_id=?",
                        (operation,),
                    ).fetchone(),
                    (1,),
                )
                self.assertEqual(
                    db.execute(
                        "SELECT COUNT(*) FROM personality_revision WHERE persona_id=?",
                        (persona["id"],),
                    ).fetchone(),
                    (2,),
                )
            app.restart()
            self.assertEqual(
                value(app, f"/sessions/{session}/receipts/{operation}"), receipt
            )
            self.assertEqual(
                inspect(app, session)["persona"]["identity"]["values"], "Be candid"
            )

    def test_identity_utf8_limits_and_control_changes_preserve_identity_head(self):
        provider = Provider(lambda _request: text("unused"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            session = app.session()
            persona = create(app)
            bind(app, session, persona["id"])
            full = {
                "self_description": "é" * 2048,
                "values": "v" * 4096,
                "communication": "c" * 4096,
            }
            receipt = self.edit(app, session, changes=full)
            before = inspect(app, session)["persona"]
            for changes in (
                {"instructions": "x"},
                {"self_description": "é" * 2048 + "x"},
            ):
                with self.assertRaises(urllib.error.HTTPError) as limit:
                    self.edit(app, session, changes=changes)
                self.assertEqual(json.load(limit.exception)["code"], "invalid_request")
                self.assertEqual(inspect(app, session)["persona"], before)
            controls = self.edit(
                app,
                session,
                controls={"field_locks": ["values"], "agent_identity_edits": False},
            )
            self.assertEqual(
                controls["identity_revision"], receipt["identity_revision"]
            )
            self.assertEqual(controls["revision"], receipt["revision"] + 1)
            self.assertEqual(
                inspect(app, session)["editing"]["field_locks"], ["values"]
            )
            self.assertFalse(inspect(app, session)["persona"]["agent_identity_edits"])
            # Authenticated users can revise locked fields through the same domain path.
            self.edit(app, session, changes={"values": "user correction"})

    def test_identity_failed_commit_rolls_back_heads_events_revision_and_receipt(self):
        provider = Provider(lambda _request: text("unused"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            session = app.session()
            persona = create(app)
            bind(app, session, persona["id"])
            head = inspect(app, session)["persona"]
            operation = operation_id()
            with sqlite3.connect(app.home / "albedo.sqlite") as db:
                db.execute(
                    "CREATE TRIGGER reject_identity_receipt BEFORE INSERT ON personality_operation WHEN NEW.operation_id LIKE 'identity:%' BEGIN SELECT RAISE(ABORT,'receipt failure'); END"
                )
            with self.assertRaises(urllib.error.HTTPError) as failed:
                self.edit(
                    app,
                    session,
                    changes={"values": "must roll back"},
                    operation=operation,
                    head=head,
                )
            self.assertEqual(failed.exception.code, 503)
            self.assertEqual(inspect(app, session)["persona"], head)
            with sqlite3.connect(app.home / "albedo.sqlite") as db:
                self.assertEqual(
                    db.execute(
                        "SELECT COUNT(*) FROM personality_revision WHERE persona_id=?",
                        (persona["id"],),
                    ).fetchone(),
                    (1,),
                )
                self.assertEqual(
                    db.execute(
                        "SELECT COUNT(*) FROM personality_event WHERE operation_id=?",
                        (operation,),
                    ).fetchone(),
                    (0,),
                )
                db.execute("DROP TRIGGER reject_identity_receipt")
            self.assertEqual(
                self.edit(
                    app,
                    session,
                    changes={"values": "must roll back"},
                    operation=operation,
                    head=head,
                )["revision"],
                head["revision"] + 1,
            )

    def test_identity_receipts_are_scoped_to_current_persona_and_origin_session(self):
        provider = Provider(lambda _request: text("unused"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            first, second = app.session(), app.session()
            persona = create(app)
            bind(app, first, persona["id"])
            bind(app, second, persona["id"])
            operation = operation_id()
            self.edit(
                app, first, changes={"values": "origin scoped"}, operation=operation
            )
            with self.assertRaises(urllib.error.HTTPError) as other:
                value(app, f"/sessions/{second}/receipts/{operation}")
            self.assertEqual(other.exception.code, 404)
            replacement = create(app)
            bind(app, first, replacement["id"])
            with self.assertRaises(urllib.error.HTTPError) as rebound:
                value(app, f"/sessions/{first}/receipts/{operation}")
            self.assertEqual(rebound.exception.code, 404)

    def test_identity_two_owner_http_edits_race_on_one_aggregate_head(self):
        provider = Provider(lambda _request: text("unused"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            sessions = [app.session(), app.session()]
            persona = create(app)
            for session in sessions:
                bind(app, session, persona["id"])
            head = inspect(app, sessions[0])["persona"]
            barrier = threading.Barrier(2)
            outcomes, errors = [], []

            def revise(session):
                try:
                    barrier.wait(timeout=10)
                    self.edit(app, session, changes={"values": session}, head=head)
                    outcomes.append("ok")
                except urllib.error.HTTPError as error:
                    outcomes.append(json.load(error)["code"])
                except Exception as error:
                    errors.append(error)

            threads = [
                threading.Thread(target=revise, args=(session,)) for session in sessions
            ]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join(timeout=15)
                self.assertFalse(thread.is_alive())
            self.assertEqual(errors, [])
            self.assertEqual(sorted(outcomes), ["conflict", "ok"])
            self.assertEqual(
                inspect(app, sessions[0])["persona"]["revision"], head["revision"] + 1
            )

    def test_identity_corrective_reserve_counts_receipts_and_rolls_back_at_capacity(
        self,
    ):
        provider = Provider(lambda _request: text("unused"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            session = app.session()
            persona = create(app)
            bind(app, session, persona["id"])
            before = inspect(app, session)
            self.edit(app, session, changes={"values": "a"})
            current = inspect(app, session)
            self.assertGreater(current["editing"]["corrective_bytes"], 1)
            self.assertEqual(current["editing"]["ordinary_limit"], 100 * 1024 * 1024)
            self.assertEqual(current["editing"]["corrective_limit"], 10 * 1024 * 1024)
            # Ordinary admission can be exhausted while corrective writes remain available.
            with sqlite3.connect(app.home / "albedo.sqlite") as db:
                db.execute(
                    "UPDATE personality_capacity SET ordinary_limit=0 WHERE persona_id=?",
                    (persona["id"],),
                )
            self.edit(app, session, changes={"values": "correction"})
            head = inspect(app, session)
            with sqlite3.connect(app.home / "albedo.sqlite") as db:
                db.execute(
                    "UPDATE personality_capacity SET corrective_limit=corrective_bytes WHERE persona_id=?",
                    (persona["id"],),
                )
            operation = operation_id()
            with self.assertRaises(urllib.error.HTTPError) as exhausted:
                self.edit(
                    app,
                    session,
                    changes={"values": "must not persist"},
                    operation=operation,
                )
            self.assertEqual(
                json.load(exhausted.exception)["code"], "capacity_exceeded"
            )
            self.assertEqual(inspect(app, session)["persona"], head["persona"])
            with sqlite3.connect(app.home / "albedo.sqlite") as db:
                self.assertEqual(
                    db.execute(
                        "SELECT id FROM personality_event WHERE operation_id=?",
                        (operation,),
                    ).fetchall(),
                    [],
                )
            self.assertLess(
                before["editing"]["corrective_bytes"],
                current["editing"]["corrective_bytes"],
            )

    def test_identity_edit_rejects_untrusted_authority_and_unknown_nested_fields(self):
        provider = Provider(lambda _request: text("unused"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            session = app.session()
            persona = create(app)
            bind(app, session, persona["id"])
            head = inspect(app, session)["persona"]
            common = {
                "operation_id": operation_id(),
                "expected_revision": head["revision"],
                "expected_identity_revision": head["identity_revision"],
                "reason": "data",
                "changes": {"values": "data"},
            }
            for extra in (
                {"actor": "user"},
                {"persona_id": persona["id"]},
                {"binding": "owner"},
                {"permissions": {"all": True}},
                {"changes": {"unknown": "x"}},
                {"controls": {"owner": True}},
            ):
                with self.assertRaises(urllib.error.HTTPError) as invalid:
                    value(app, f"/sessions/{session}/identity", {**common, **extra})
                self.assertEqual(invalid.exception.code, 400)
            self.assertEqual(inspect(app, session)["persona"], head)

    def test_identity_additive_tables_are_validated_before_bundle_admission(self):
        provider = Provider(lambda _request: text("unused"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            for table in (
                "personality_controls",
                "personality_capacity",
                "personality_tool_receipt",
            ):
                with self.subTest(table=table):

                    def break_table(_app):
                        with sqlite3.connect(app.home / "albedo.sqlite") as db:
                            db.execute(f"ALTER TABLE {table} RENAME TO saved_{table}")
                            db.execute(
                                f"CREATE VIEW {table} AS SELECT * FROM saved_{table}"
                            )

                    app.restart(prepare=break_table)
                    with self.assertRaises(urllib.error.HTTPError) as unavailable:
                        create(app)
                    self.assertEqual(unavailable.exception.code, 404)

                    def restore(_app):
                        with sqlite3.connect(app.home / "albedo.sqlite") as db:
                            db.execute(f"DROP VIEW {table}")
                            db.execute(f"ALTER TABLE saved_{table} RENAME TO {table}")

                    app.restart(prepare=restore)
            self.assertIsNotNone(create(app)["id"])

    def test_identity_inspection_does_not_write_or_require_a_writable_budget(self):
        provider = Provider(lambda _request: text("unused"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            session = app.session()
            persona = create(app)
            bind(app, session, persona["id"])
            with sqlite3.connect(app.home / "albedo.sqlite") as db:
                db.execute(
                    "CREATE TRIGGER no_budget_insert BEFORE INSERT ON personality_capacity BEGIN SELECT RAISE(ABORT,'inspection must not write'); END"
                )
                db.execute(
                    "CREATE TRIGGER no_budget_update BEFORE UPDATE ON personality_capacity BEGIN SELECT RAISE(ABORT,'inspection must not write'); END"
                )
            self.assertEqual(inspect(app, session)["persona"]["id"], persona["id"])

    def test_native_identity_edit_replays_exact_receipt_and_exposes_structured_conflicts(
        self,
    ):
        operation = operation_id()
        observed, body = [], {}

        def reply(request):
            outputs = [
                item
                for item in request["input"]
                if item.get("type") == "function_call_output"
            ]
            if not outputs:
                return Reply(
                    "python", tool_name="persona_inspect", tool_arguments={"cursor": 0}
                )
            result = json.loads(outputs[-1]["output"])
            observed.append(result)
            if len(observed) == 1:
                body.update(
                    operation_id=operation,
                    expected_revision=result["revision"],
                    expected_identity_revision=result["identity_revision"],
                    reason="foreground self revision",
                    changes={"values": "Candid"},
                )
                return Reply(
                    "python", tool_name="persona_edit", tool_arguments=dict(body)
                )
            if len(observed) == 2:
                return Reply(
                    "python", tool_name="persona_edit", tool_arguments=dict(body)
                )
            if len(observed) == 3:
                return Reply(
                    "python",
                    tool_name="persona_edit",
                    tool_arguments={**body, "changes": {"values": "changed reuse"}},
                )
            if len(observed) == 4:
                return Reply(
                    "python",
                    tool_name="persona_edit",
                    tool_arguments={**body, "operation_id": operation_id()},
                )
            return text("finished")

        provider = Provider(reply)
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            session = app.session()
            persona = create(app)
            bind(app, session, persona["id"])
            app.prompt(session, "revise identity with native tools").close()
            app.idle(session)
            self.assertEqual(len(observed), 5)
            self.assertEqual(observed[1], observed[2])
            self.assertEqual(observed[1]["actor"], "owner_agent")
            self.assertEqual(observed[3]["code"], "operation_id_reused")
            self.assertEqual(observed[4]["code"], "conflict")
            self.assertEqual(
                observed[4]["current_heads"]["revision"], observed[1]["revision"]
            )
            tool_names = [
                tool["name"] for tool in provider.requests[0]["request"]["tools"]
            ]
            self.assertIn("persona_inspect", tool_names)
            self.assertIn("persona_edit", tool_names)
            self.assertNotIn("persona_create", tool_names)
            with sqlite3.connect(app.home / "albedo.sqlite") as db:
                self.assertEqual(
                    db.execute(
                        "SELECT COUNT(*) FROM personality_event WHERE operation_id=?",
                        (operation,),
                    ).fetchone(),
                    (1,),
                )
                calls = db.execute(
                    "SELECT call_id,result FROM personality_tool_receipt WHERE session=? ORDER BY call_id",
                    (session,),
                ).fetchall()
                self.assertEqual(len(calls), 2)
                self.assertTrue(
                    all(json.loads(saved) == observed[1] for _, saved in calls)
                )
                self.assertIn(
                    observed[1]["origin_call_id"], [call for call, _ in calls]
                )

    def test_native_identity_edit_refuses_locks_flags_and_actor_spoofing(self):
        observed, body = [], {}

        def reply(request):
            outputs = [
                item
                for item in request["input"]
                if item.get("type") == "function_call_output"
            ]
            if request["input"][-1].get("type") == "function_call_output":
                observed.append(json.loads(outputs[-1]["output"]))
                return text("finished")
            return Reply("python", tool_name="persona_edit", tool_arguments=dict(body))

        provider = Provider(reply)
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            session = app.session()
            persona = create(app)
            bind(app, session, persona["id"])
            self.edit(app, session, controls={"field_locks": ["values"]})
            for index, (changes, extra, expected) in enumerate(
                (
                    ({"values": "locked"}, {}, "forbidden"),
                    (
                        {"instructions": "actor spoof"},
                        {"actor": "user"},
                        "invalid_request",
                    ),
                    (
                        {"instructions": "controls spoof"},
                        {"controls": {"field_locks": []}},
                        "invalid_request",
                    ),
                    ({"instructions": "disabled"}, {}, "forbidden"),
                )
            ):
                if index == 3:
                    self.edit(app, session, controls={"agent_identity_edits": False})
                head = inspect(app, session)["persona"]
                body.clear()
                body.update(
                    operation_id=operation_id(),
                    expected_revision=head["revision"],
                    expected_identity_revision=head["identity_revision"],
                    reason="attempt",
                    changes=changes,
                    **extra,
                )
                app.prompt(session, f"attempt {index}").close()
                app.idle(session)
                self.assertEqual(observed[-1]["code"], expected)
                self.assertEqual(inspect(app, session)["persona"], head)

    def test_native_owner_edits_race_with_provider_barriers(self):
        barrier = threading.Barrier(2)
        outcomes, head = [], {}

        def reply(request):
            outputs = [
                item
                for item in request["input"]
                if item.get("type") == "function_call_output"
            ]
            if outputs:
                outcome = json.loads(outputs[-1]["output"])
                outcomes.append(outcome.get("code", "ok"))
                return text("finished")
            barrier.wait(timeout=15)
            return Reply(
                "python",
                tool_name="persona_edit",
                tool_arguments={
                    "operation_id": operation_id(),
                    "expected_revision": head["revision"],
                    "expected_identity_revision": head["identity_revision"],
                    "reason": "owner race",
                    "changes": {"values": operation_id()},
                },
            )

        provider = Provider(reply)
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            sessions = [app.session(), app.session()]
            persona = create(app)
            for session in sessions:
                bind(app, session, persona["id"])
            head.update(inspect(app, sessions[0])["persona"])
            for session in sessions:
                app.prompt(session, "race native identity edit").close()
            for session in sessions:
                app.idle(session)
            self.assertEqual(sorted(outcomes), ["conflict", "ok"])
            self.assertEqual(
                inspect(app, sessions[0])["persona"]["revision"], head["revision"] + 1
            )

    def test_cancel_after_native_identity_commit_retains_revision_and_receipt(self):
        committed, release = threading.Event(), threading.Event()
        body, receipt = {}, {}

        def reply(request):
            outputs = [
                item
                for item in request["input"]
                if item.get("type") == "function_call_output"
            ]
            if outputs:
                receipt.update(json.loads(outputs[-1]["output"]))
                committed.set()
                release.wait(30)
                return text("cancelled turn")
            return Reply("python", tool_name="persona_edit", tool_arguments=dict(body))

        provider = Provider(reply)
        self.addCleanup(provider.close)
        self.addCleanup(release.set)
        with self.app(provider) as app:
            session = app.session()
            persona = create(app)
            bind(app, session, persona["id"])
            head = inspect(app, session)["persona"]
            body.update(
                operation_id=operation_id(),
                expected_revision=head["revision"],
                expected_identity_revision=head["identity_revision"],
                reason="completed before cancel",
                changes={"values": "durably committed"},
            )
            app.prompt(session, "commit then interrupt generation").close()
            self.assertTrue(committed.wait(15))
            with app.api(f"/sessions/{session}?tail=0") as response:
                state = json.load(response)
            app.api(
                f"/sessions/{session}/interrupt",
                {
                    "run_id": state["status"]["run_id"],
                    "through_input_order": state["input_order"],
                },
            ).close()
            release.set()
            app.idle(session)
            self.assertEqual(
                value(app, f"/sessions/{session}/receipts/{body['operation_id']}"),
                receipt,
            )
            self.assertEqual(
                inspect(app, session)["persona"]["identity"]["values"],
                "durably committed",
            )
            app.restart()
            self.assertEqual(
                value(app, f"/sessions/{session}/receipts/{body['operation_id']}"),
                receipt,
            )

    def test_native_identity_inspection_pages_preserve_utf8_and_escaped_text_within_budget(
        self,
    ):
        pages = []

        def reply(request):
            if request["input"][-1].get("type") == "function_call_output":
                output = request["input"][-1]["output"]
                self.assertLessEqual(len(output.encode("utf-8")), 8192)
                page = json.loads(output)
                pages.append(page)
                self.assertLessEqual(len(page["records"]), 50)
                if page["next_cursor"] is None:
                    return text("finished")
                return Reply(
                    "python",
                    tool_name="persona_inspect",
                    tool_arguments={"cursor": page["next_cursor"]},
                )
            return Reply(
                "python", tool_name="persona_inspect", tool_arguments={"cursor": 0}
            )

        provider = Provider(reply)
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            session = app.session()
            persona = create(app)
            bind(app, session, persona["id"])
            fields = self.escaped_identity()
            self.edit(app, session, changes=fields)
            app.prompt(session, "inspect all identity pages").close()
            app.idle(session)
            rebuilt = {field: "" for field in fields}
            for page in pages:
                for record in page["records"]:
                    self.assertEqual(
                        record["scalar_offset"], len(rebuilt[record["field"]])
                    )
                    rebuilt[record["field"]] += record["text"]
            self.assertEqual(rebuilt, fields)

    def test_identity_additive_upgrade_preserves_setup_rows_and_rolls_back_partial_schema(
        self,
    ):
        provider = Provider(lambda _request: text("unused"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            session = app.session()
            persona = create(app)
            bind(app, session, persona["id"])
            originals = (
                "personality_persona",
                "personality_revision",
                "personality_default",
                "personality_session",
                "personality_event",
                "personality_operation",
            )
            with sqlite3.connect(app.home / "albedo.sqlite") as db:
                saved = {
                    table: db.execute(f"SELECT * FROM {table}").fetchall()
                    for table in originals
                }

            def partial(_app):
                with sqlite3.connect(app.home / "albedo.sqlite") as db:
                    db.execute("DROP TABLE personality_controls")
                    db.execute("DROP TABLE personality_capacity")
                    db.execute(
                        "ALTER TABLE personality_tool_receipt RENAME TO saved_tool_receipt"
                    )
                    db.execute(
                        "CREATE VIEW personality_tool_receipt AS SELECT * FROM saved_tool_receipt"
                    )

            app.restart(prepare=partial)
            with sqlite3.connect(app.home / "albedo.sqlite") as db:
                self.assertEqual(
                    db.execute(
                        "SELECT name FROM sqlite_master WHERE name IN ('personality_controls','personality_capacity')"
                    ).fetchall(),
                    [],
                )
                for table in originals:
                    self.assertEqual(
                        db.execute(f"SELECT * FROM {table}").fetchall(), saved[table]
                    )

            def repair(_app):
                with sqlite3.connect(app.home / "albedo.sqlite") as db:
                    db.execute("DROP VIEW personality_tool_receipt")
                    db.execute("DROP TABLE saved_tool_receipt")

            app.restart(prepare=repair)
            with sqlite3.connect(app.home / "albedo.sqlite") as db:
                for table in originals:
                    self.assertEqual(
                        db.execute(f"SELECT * FROM {table}").fetchall(), saved[table]
                    )
            current = inspect(app, session)
            self.assertEqual(current["editing"]["field_locks"], [])
            self.assertGreater(current["editing"]["ordinary_bytes"], 0)
            self.assertEqual(current["binding"]["persona_id"], persona["id"])
            self.edit(app, session, changes={"values": "first edit after upgrade"})

    def test_human_inspection_captures_heads_flags_locks_and_usage_consistently(self):
        provider = Provider(lambda _request: text("unused"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            session = app.session()
            persona = create(app)
            bind(app, session, persona["id"])
            initial = inspect(app, session)
            head = initial["persona"]
            usage_by_revision = {
                head["revision"]: initial["editing"]["corrective_bytes"]
            }
            observations = []
            start = threading.Barrier(2)
            stop = threading.Event()
            errors = []

            def toggle_controls():
                revision = head["revision"]
                try:
                    start.wait(timeout=10)
                    for index in range(250):
                        if stop.is_set():
                            break
                        enabled = bool(index % 2)
                        receipt = value(
                            app,
                            f"/sessions/{session}/identity",
                            {
                                "operation_id": operation_id(),
                                "expected_revision": revision,
                                "expected_identity_revision": head["identity_revision"],
                                "reason": "paired control invariant",
                                "controls": {
                                    "agent_identity_edits": enabled,
                                    "field_locks": [] if enabled else ["values"],
                                },
                            },
                        )
                        revision = receipt["revision"]
                        committed = inspect(app, session)
                        usage_by_revision[revision] = committed["editing"][
                            "corrective_bytes"
                        ]
                except Exception as error:
                    errors.append(error)

            writer = threading.Thread(target=toggle_controls)
            writer.start()
            try:
                start.wait(timeout=10)
                for _ in range(400):
                    current = inspect(app, session)
                    observations.append(
                        (
                            current["persona"]["revision"],
                            current["editing"]["corrective_bytes"],
                        )
                    )
                    self.assertEqual(
                        current["persona"]["agent_identity_edits"],
                        not bool(current["editing"]["field_locks"]),
                        current,
                    )
                    self.assertEqual(
                        current["persona"]["id"], current["binding"]["persona_id"]
                    )
            finally:
                stop.set()
                writer.join(timeout=20)
            self.assertFalse(writer.is_alive())
            self.assertEqual(errors, [])
            self.assertGreater(
                len(usage_by_revision), 1, "writer exercised control changes"
            )
            self.assertGreater(
                len({revision for revision, _ in observations}),
                1,
                "inspection observed changing heads",
            )
            for revision, usage in observations:
                self.assertEqual(
                    usage, usage_by_revision[revision], f"usage for head {revision}"
                )

    def escaped_identity(self):
        fields = {
            "self_description": "\x00" * 4096,
            "values": "é" * 2048,
            "communication": "c" * 4096,
            "instructions": "",
        }
        self.assertEqual(
            [len(value.encode("utf-8")) for value in fields.values()],
            [4096, 4096, 4096, 0],
        )
        self.assertEqual(
            sum(len(value.encode("utf-8")) for value in fields.values()), 12 * 1024
        )
        return fields

    def test_human_identity_accepts_escaped_utf8_boundary_fixture_before_native_paging(
        self,
    ):
        provider = Provider(lambda _request: text("unused"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            session = app.session()
            persona = create(app)
            bind(app, session, persona["id"])
            fields = self.escaped_identity()
            self.edit(app, session, changes=fields)
            self.assertEqual(inspect(app, session)["persona"]["identity"], fields)
