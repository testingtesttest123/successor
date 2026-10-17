"""Bounded main identity acceptance through the real daemon and local providers."""

import json
import os
import sqlite3
import threading
import unittest
import urllib.error

from harness import Provider, error, exclusive, operation_id, text, wait_until
from identity_support import (
    app,
    bind,
    captured_identity,
    fork,
    identity,
    inspect,
    instructions,
    read,
    rows,
    select,
    setup,
    spawn,
    value,
    write,
)


class IdentityCases(unittest.TestCase):
    protocol: str

    def fixture(self, reply=None):
        provider = Provider(reply or (lambda _: text("finished")))
        self.addCleanup(provider.close)
        return provider, app(provider, self.protocol)

    def blocked(self, instance, session, provider):
        before = len(provider.requests)
        failed_before = rows(
            instance,
            "SELECT COUNT(*) FROM input_turns WHERE session=? AND state='failed'",
            (session,),
        )[0][0]
        try:
            instance.prompt(session, "must refuse before provider").close()
        except urllib.error.HTTPError as refused:
            self.assertIn(refused.code, (400, 409, 422, 503))
        else:

            def pending_block():
                self.assertEqual(
                    len(provider.requests),
                    before,
                    "refused identity input reached the provider",
                )
                state = read(instance, f"/sessions/{session}?tail=0")
                pending = any(p.get("blocking_reason") for p in state["pending_inputs"])
                failed = (
                    rows(
                        instance,
                        "SELECT COUNT(*) FROM input_turns WHERE session=? AND state='failed'",
                        (session,),
                    )[0][0]
                    > failed_before
                )
                return pending or failed

            wait_until(pending_block, 15, "identity requirement did not block input")
        self.assertEqual(len(provider.requests), before)

    def test_service_requires_daemon_token_before_setup_binding_or_edit(self):
        provider, fixture = self.fixture()
        with fixture as instance:
            session = instance.session()
            for token in ("", "Bearer fixture-key", "Bearer user"):
                with self.assertRaises(urllib.error.HTTPError) as denied:
                    instance.api(
                        f"/extensions/personality/sessions/{session}/setup",
                        {
                            "name": "Denied",
                            "content": "Denied",
                            "retry_key": operation_id(),
                        },
                        headers={"Authorization": token},
                    )
                self.assertEqual(denied.exception.code, 401)
            self.assertEqual(
                rows(instance, "SELECT COUNT(*) FROM personality_persona"), [(0,)]
            )
            setup(instance, session, "Authorized identity")
            other = instance.session()
            before = value(instance, f"/sessions/{session}/document")
            for token in ("", "Bearer fixture-key"):
                for target, body in (
                    (
                        f"{session}/document",
                        {
                            "content": "Denied edit",
                            "expected_revision": before["revision"],
                            "retry_key": operation_id(),
                        },
                    ),
                    (
                        f"{other}/binding",
                        {"expected_generation": 0, "acknowledge_history_through": 0},
                    ),
                ):
                    with self.assertRaises(urllib.error.HTTPError) as denied:
                        instance.api(
                            f"/extensions/personality/sessions/{target}",
                            body,
                            headers={"Authorization": token},
                        )
                    self.assertEqual(denied.exception.code, 401)
            self.assertEqual(value(instance, f"/sessions/{session}/document"), before)
            self.assertIsNone(inspect(instance, other)["binding"])
            self.assertEqual(provider.requests, [])

    def test_required_compare_and_swap_fields_and_removed_routes(self):
        provider, fixture = self.fixture()
        with fixture as instance:
            session = instance.session()
            with self.assertRaises(urllib.error.HTTPError) as missing:
                value(
                    instance,
                    f"/sessions/{session}/setup",
                    {"name": "Missing retry", "content": "initial"},
                )
            self.assertEqual(missing.exception.code, 400)
            setup(instance, session, "Initial document")
            before = value(instance, f"/sessions/{session}/document")
            for body in (
                {"content": "missing CAS", "retry_key": operation_id()},
                {"content": "missing retry", "expected_revision": before["revision"]},
            ):
                with self.assertRaises(urllib.error.HTTPError) as missing:
                    value(instance, f"/sessions/{session}/document", body)
                self.assertEqual(missing.exception.code, 400)
            for route in ("/personas", "/personas/default"):
                with self.assertRaises(urllib.error.HTTPError) as removed:
                    value(
                        instance,
                        route,
                        {
                            "name": "not allowed",
                            "content": "extra",
                            "retry_key": operation_id(),
                        },
                    )
                self.assertEqual(removed.exception.code, 404)
            body = {
                "old_string": "Initial",
                "new_string": "Edited",
                "expected_revision": before["revision"],
                "retry_key": operation_id(),
            }
            first = value(instance, f"/sessions/{session}/edit", body)
            self.assertEqual(value(instance, f"/sessions/{session}/edit", body), first)
            self.assertEqual(
                value(instance, f"/sessions/{session}/document")["text"],
                "Edited document",
            )
            self.assertEqual(
                rows(instance, "SELECT COUNT(*) FROM personality_persona"), [(1,)]
            )
            self.assertEqual(provider.requests, [])

    def test_setup_retry_edit_receipts_and_restart(self):
        provider, fixture = self.fixture()
        with fixture as instance:
            session = instance.session()
            key = operation_id()
            first = setup(instance, session, "FIRST-IDENTITY", retry_key=key)
            self.assertEqual(
                setup(instance, session, "FIRST-IDENTITY", retry_key=key), first
            )
            with self.assertRaises(urllib.error.HTTPError):
                setup(instance, session, "conflicting retry", retry_key=key)
            instance.prompt(session, "first request").close()
            instance.idle(session)
            captured = identity(provider.requests[-1]["request"])[1]
            self.assertEqual(captured["document"], "FIRST-IDENTITY")
            before = value(instance, f"/sessions/{session}/document")
            edit_key = operation_id()
            receipt = write(
                instance,
                session,
                "SECOND-IDENTITY",
                expected_revision=before["revision"],
                retry_key=edit_key,
            )
            self.assertEqual(
                write(
                    instance,
                    session,
                    "SECOND-IDENTITY",
                    expected_revision=before["revision"],
                    retry_key=edit_key,
                ),
                receipt,
            )
            for content, retry in (
                ("conflicting retry", edit_key),
                ("stale", operation_id()),
            ):
                with self.assertRaises(urllib.error.HTTPError):
                    write(
                        instance,
                        session,
                        content,
                        expected_revision=before["revision"],
                        retry_key=retry,
                    )
            instance.restart()
            self.assertEqual(
                inspect(instance, session)["binding"]["persona_id"],
                first["persona"]["id"],
            )
            instance.prompt(session, "after restart").close()
            instance.idle(session)
            self.assertEqual(
                identity(provider.requests[-1]["request"])[1]["document"],
                "SECOND-IDENTITY",
            )
            self.assertEqual(
                rows(instance, "SELECT COUNT(*) FROM personality_persona"), [(1,)]
            )

    def test_retry_uses_one_capture_next_request_refreshes(self):
        entered, release = threading.Event(), threading.Event()
        count = [0]

        def reply(_):
            count[0] += 1
            if count[0] == 1:
                entered.set()
                release.wait(30)
                return error(502)
            return text("finished")

        provider, fixture = self.fixture(reply)
        self.addCleanup(release.set)
        with fixture as instance:
            session = instance.session()
            setup(instance, session, "CAPTURE-ONE")
            instance.prompt(session, "capture then retry").close()
            self.assertTrue(entered.wait(15))
            captured = identity(provider.requests[0]["request"])[1]
            write(instance, session, "CAPTURE-TWO")
            saved = read(instance, f"/sessions/{session}/context?view=summary")
            self.assertEqual(
                captured_identity(saved)["snapshot_id"], captured["snapshot_id"]
            )
            self.assertEqual(len(provider.requests), 1)
            release.set()
            instance.idle(session)
            self.assertEqual(len(provider.requests), 2)
            self.assertEqual(
                provider.requests[0]["request"], provider.requests[1]["request"]
            )
            instance.prompt(session, "next capture").close()
            instance.idle(session)
            latest = identity(provider.requests[-1]["request"])[1]
            self.assertEqual(latest["document"], "CAPTURE-TWO")
            self.assertNotEqual(latest["snapshot_id"], captured["snapshot_id"])

    def test_fresh_client_rebinds_after_unbind_and_restart(self):
        provider, fixture = self.fixture()
        with fixture as instance:
            session = instance.session()
            setup(instance, session, "STATELESS-REBIND-IDENTITY")
            value(
                instance,
                f"/sessions/{session}/unbind",
                {
                    "expected_generation": inspect(instance, session)["binding"][
                        "generation"
                    ]
                },
            )
            instance.restart()

            # No generation from setup/unbind survives in this client. The helper
            # must discover the retained CAS value through a fresh HTTP GET.
            unbound = inspect(instance, session)
            self.assertIsNone(unbound["binding"])
            rebound = bind(instance, session)["binding"]
            self.assertEqual(rebound["generation"], unbound["binding_generation"] + 1)
            current = inspect(instance, session)
            self.assertEqual(current["binding_generation"], rebound["generation"])
            self.assertEqual(current["binding"], rebound)

            # A stale client cannot mutate the new binding or its requirement.
            before = rows(
                instance,
                "SELECT config_revision FROM sessions WHERE id=?",
                (session,),
            )
            for route, body in (
                (
                    "binding",
                    {
                        "expected_generation": unbound["binding_generation"],
                        "acknowledge_history_through": unbound["pre_binding_history"][
                            "through"
                        ],
                    },
                ),
                ("unbind", {"expected_generation": unbound["binding_generation"]}),
            ):
                with self.assertRaises(urllib.error.HTTPError) as refused:
                    value(instance, f"/sessions/{session}/{route}", body)
                self.assertEqual(refused.exception.code, 409)
                self.assertIn("binding_changed", refused.exception.read().decode())
                self.assertEqual(inspect(instance, session), current)
                self.assertEqual(
                    rows(
                        instance,
                        "SELECT config_revision FROM sessions WHERE id=?",
                        (session,),
                    ),
                    before,
                )

            instance.prompt(session, "use rebound identity").close()
            instance.idle(session)
            self.assertEqual(len(provider.requests), 1)
            self.assertEqual(
                identity(provider.requests[0]["request"])[1]["document"],
                "STATELESS-REBIND-IDENTITY",
            )

    def test_cached_stock_binding_refuses_until_explicit_reload(self):
        provider, fixture = self.fixture()
        with fixture as instance:
            owner = instance.session()
            first = setup(instance, owner, "BOUND-CACHED-IDENTITY")
            other = instance.session()
            select(instance, other, personality=False)
            instance.prompt(other, "populate stock kernel").close()
            instance.idle(other)
            self.assertNotIn(
                "[request context: ", instructions(provider.requests[-1]["request"])
            )
            bind(instance, other, first["persona"]["id"])
            self.blocked(instance, other, provider)
            before = len(provider.requests)
            with instance.api(
                f"/sessions/{other}/reload", {"target": "session"}
            ) as response:
                self.assertEqual(json.load(response)["session"]["state"], "applied")
            instance.idle(other)
            instance.prompt(other, "bound identity after explicit reload").close()
            instance.idle(other)
            self.assertGreater(len(provider.requests), before)
            for request in provider.requests[before:]:
                self.assertEqual(
                    identity(request["request"])[1]["document"], "BOUND-CACHED-IDENTITY"
                )

    def test_global_enable_on_cached_stock_requires_setup(self):
        provider = Provider(lambda _: text("stock request"))
        self.addCleanup(provider.close)
        with app(provider, self.protocol, installed=False) as instance:
            session = instance.session()
            self.assertEqual(
                rows(
                    instance,
                    "SELECT enabled FROM session_extensions WHERE session=? AND name='personality'",
                    (session,),
                ),
                [],
            )
            instance.prompt(session, "populate inherited stock kernel").close()
            instance.idle(session)
            self.assertEqual(len(provider.requests), 1)
            instance.write_extensions({"enabled": {"personality": True}})
            self.blocked(instance, session, provider)
            with instance.api(
                f"/sessions/{session}/reload", {"target": "session"}
            ) as response:
                self.assertEqual(json.load(response)["session"]["state"], "applied")
            self.blocked(instance, session, provider)
            self.assertEqual(len(provider.requests), 1)

    def test_busy_binding_and_unbind_selection(self):
        entered, release = threading.Event(), threading.Event()

        def reply(_):
            entered.set()
            release.wait(30)
            return text("finished")

        provider, fixture = self.fixture(reply)
        self.addCleanup(release.set)
        with fixture as instance:
            owner = instance.session()
            first = setup(instance, owner)
            other = instance.session()
            select(instance, other, personality=False)
            instance.prompt(other, "busy stock request").close()
            self.assertTrue(entered.wait(15))
            with self.assertRaises(urllib.error.HTTPError) as busy:
                bind(instance, other, first["persona"]["id"])
            self.assertEqual(busy.exception.code, 409)
            self.assertIsNone(inspect(instance, other)["binding"])
            release.set()
            instance.idle(other)
            bound = bind(instance, other, first["persona"]["id"])["binding"]
            with self.assertRaises(urllib.error.HTTPError):
                value(instance, f"/sessions/{other}/unbind", {"expected_generation": 0})
            value(
                instance,
                f"/sessions/{other}/unbind",
                {"expected_generation": bound["generation"]},
            )
            self.assertEqual(
                rows(
                    instance,
                    "SELECT capability FROM session_requirements WHERE session=?",
                    (other,),
                ),
                [],
            )
            self.blocked(instance, other, provider)
            with instance.api(
                f"/sessions/{other}/reload", {"target": "session"}
            ) as response:
                self.assertEqual(json.load(response)["session"]["state"], "applied")
            self.blocked(instance, other, provider)

    def test_unbound_selected_refuses_stock_unselected_works(self):
        provider, fixture = self.fixture()
        with fixture as instance:
            selected = instance.session()
            self.blocked(instance, selected, provider)
            self.assertEqual(
                rows(
                    instance,
                    "SELECT COUNT(*) FROM transcript WHERE session=? AND row_class='assistant'",
                    (selected,),
                ),
                [(0,)],
            )
            ordinary = instance.session()
            select(instance, ordinary, personality=False)
            instance.prompt(ordinary, "stock request").close()
            instance.idle(ordinary)
            self.assertEqual(len(provider.requests), 1)
            self.assertNotIn(
                "[request context: ", instructions(provider.requests[0]["request"])
            )

    def corrupt_and_block(self, sql, *, restart=False):
        provider, fixture = self.fixture()
        with fixture as instance:
            session = instance.session()
            setup(instance, session)
            with sqlite3.connect(instance.home / "albedo.sqlite") as db:
                db.execute(sql)
            if restart:
                instance.restart()
            self.blocked(instance, session, provider)
            self.assertEqual(provider.requests, [])

    def test_missing_requirement_marker_refuses(self):
        self.corrupt_and_block("DELETE FROM session_requirements")

    def test_missing_identity_table_refuses(self):
        self.corrupt_and_block(
            "ALTER TABLE personality_revision RENAME TO withheld_revision"
        )

    def test_quarantined_identity_refuses_after_restart(self):
        self.corrupt_and_block("UPDATE personality_meta SET version=999", restart=True)

    def test_deselected_identity_refuses(self):
        provider, fixture = self.fixture()
        with fixture as instance:
            session = instance.session()
            setup(instance, session)
            select(instance, session, personality=False)
            self.blocked(instance, session, provider)

    def test_explicit_session_selection_survives_global_default_disable(self):
        provider, fixture = self.fixture()
        with fixture as instance:
            session = instance.session()
            setup(instance, session)
            instance.restart(
                prepare=lambda current: current.write_extensions(
                    {"enabled": {"personality": False}}
                )
            )
            instance.prompt(session, "explicit session selection still applies").close()
            instance.idle(session)
            self.assertEqual(
                identity(provider.requests[-1]["request"])[1]["document"],
                "Initial identity",
            )

    def test_entire_extension_removed_refuses_after_restart(self):
        provider, fixture = self.fixture()
        with fixture as instance:
            session = instance.session()
            setup(instance, session)
            stock = os.environ["ALBEDO_STOCK_TEST_DAEMON"]

            def stock_launcher(current):
                current.env["ALBEDO_DAEMON"] = stock

            instance.restart(prepare=stock_launcher)
            self.blocked(instance, session, provider)

    def test_bound_child_fork_rewind_and_summary_refuse_without_side_effects(self):
        provider, fixture = self.fixture()
        with fixture as instance:
            session = instance.session()
            setup(instance, session)
            instance.prompt(session, "first checkpoint").close()
            instance.idle(session)
            checkpoint = read(
                instance, f"/sessions/{session}/history?view=checkpoints"
            )["items"][0]["checkpoint_id"]
            before = rows(instance, "SELECT id FROM sessions ORDER BY id")
            transcript = rows(instance, "SELECT COUNT(*) FROM transcript")
            calls = len(provider.requests)
            for operation in (
                lambda: spawn(instance, session, "refused-child"),
                lambda: fork(instance, session, checkpoint),
                lambda: instance.api(
                    f"/sessions/{session}/rewind",
                    {"checkpoint_id": checkpoint},
                    method="POST",
                ),
                lambda: instance.api(
                    f"/sessions/{session}/rewind",
                    {
                        "checkpoint_id": checkpoint,
                        "summary": {"instructions": "summarize before rewind"},
                    },
                    method="POST",
                ),
            ):
                with self.assertRaises(urllib.error.HTTPError):
                    operation()
                self.assertEqual(
                    rows(instance, "SELECT id FROM sessions ORDER BY id"), before
                )
                self.assertEqual(
                    rows(instance, "SELECT COUNT(*) FROM transcript"), transcript
                )
                self.assertEqual(len(provider.requests), calls)

    def test_compaction_provider_has_identity_or_explicitly_refuses(self):
        provider, fixture = self.fixture()
        with fixture as instance:
            session = instance.session()
            setup(instance, session, "MANDATORY-SUMMARY-IDENTITY")
            select(instance, session, rolling=True)
            for prompt in ("older", "recent"):
                instance.prompt(session, prompt + " x" * 3000).close()
                instance.idle(session)
            before = len(provider.requests)
            try:
                with instance.api(f"/sessions/{session}/compaction", {}) as response:
                    outcome = json.load(response)
            except urllib.error.HTTPError as refused:
                self.assertIn(refused.code, (400, 409, 422, 503))
                self.assertEqual(len(provider.requests), before)
            else:
                summaries = provider.requests[before:]
                self.assertTrue(
                    summaries
                    or outcome.get("state") in ("refused", "unchanged", "not_needed"),
                    outcome,
                )
                for request in summaries:
                    self.assertEqual(
                        identity(request["request"])[1]["document"],
                        "MANDATORY-SUMMARY-IDENTITY",
                    )


@exclusive
class ResponsesIdentityTest(IdentityCases):
    protocol = "responses"


@exclusive
class ChatIdentityTest(IdentityCases):
    protocol = "chat_completions"


# The shared cases are inherited by concrete protocol suites only.
del IdentityCases
