"""Source-backed memory, corrections and hostile references through the real daemon."""

import hashlib
import json
import sqlite3
import struct
import unittest
import urllib.error

from harness import Albedo, Provider, exclusive, operation_id, text
from personality_support import bind, create, inspect, value


def packed(role, content):
    # Canonical durable ETF fixture: term_to_binary({1,{Role,Utf8Binary}}).
    role = role.encode()
    content = content.encode()
    return (
        b"\x83h\x02a\x01h\x02w"
        + bytes([len(role)])
        + role
        + b"m"
        + struct.pack(">I", len(content))
        + content
    )


def packed_chat_display(content):
    # Offline known-Chat fixture metadata, in the production Display ETF shape.
    # Actual host Note input/commit persistence is exercised without injected
    # metadata by the native production-path regressions.
    def binary(value):
        value = value.encode()
        return b"m" + struct.pack(">I", len(value)) + value

    return (
        b"\x83h\x06w\x07display"
        + binary(content)
        + binary("chat")
        + binary("")
        + b"w\x04nonej"
    )


class MemoryFixture(unittest.TestCase):
    def app(self, provider):
        return Albedo(
            provider,
            prepare=lambda app: app.write_extensions(
                {"enabled": {"personality": True}}
            ),
        )

    def seed(self, app, session, *rows):
        seqs = []

        def prepare(_app):
            with sqlite3.connect(app.home / "albedo.sqlite") as db:
                for role, content in rows:
                    row = db.execute(
                        "INSERT INTO transcript(session,payload,row_class,summary_indexed,calls_indexed) VALUES(?,?,?,1,1)",
                        (
                            session,
                            packed(role, content),
                            "user" if role == "user" else "other",
                        ),
                    )
                    seqs.append(row.lastrowid)
                    if role == "user":
                        db.execute(
                            "INSERT INTO submission_events(session,seq,operation_id,payload) VALUES(?,?,?,?)",
                            (
                                session,
                                row.lastrowid,
                                "host-chat:" + operation_id(),
                                packed_chat_display(content),
                            ),
                        )

        app.restart(prepare=prepare)
        return seqs

    def mutate(self, app, session, memories, *, operation=None):
        persona = inspect(app, session)["persona"]
        return value(
            app,
            f"/sessions/{session}/memories",
            {
                "operation_id": operation or operation_id(),
                "expected_revision": persona["revision"],
                "expected_identity_revision": persona["identity_revision"],
                "reason": "foreground source-backed claim",
                "memories": memories,
            },
        )

    def memory(self, claim, seq, **extra):
        return {
            "text": claim,
            "provenance": "experienced",
            "uncertainty": "unverified_assertion",
            "sources": [{"relation": "supports", "first_seq": seq, "last_seq": seq}],
            **extra,
        }

    def records(self, app, session, record="", *, history=False):
        result = []
        cursor = None
        while True:
            suffix = f"/{record}" if record else ""
            query = f"?history={'true' if history else 'false'}"
            if cursor:
                import urllib.parse

                query += "&cursor=" + urllib.parse.quote(cursor, safe="")
            page = value(app, f"/sessions/{session}/memories{suffix}{query}")
            self.assertLessEqual(
                len(
                    json.dumps(page, ensure_ascii=False, separators=(",", ":")).encode()
                ),
                8192,
            )
            self.assertLessEqual(len(page["records"]), 50)
            result.extend(page["records"])
            cursor = page["next_cursor"]
            if cursor is None:
                return result


@exclusive
class PersonalityMemoryTest(MemoryFixture):
    def test_memory_survives_restart_with_exact_sources(self):
        provider = Provider(lambda _request: text("done"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            persona = create(app, default=True)
            session = app.session()
            bind(app, session)
            seq = self.seed(app, session, ("user", "The release is Tuesday"))[0]
            receipt = self.mutate(
                app, session, [self.memory("I was told Tuesday", seq)]
            )
            memory_id = receipt["records"][0]["id"]
            self.assertEqual(receipt["identity_revision"], persona["identity_revision"])
            app.restart()
            other = app.session()
            bind(app, other)
            records = self.records(app, other, memory_id)
            self.assertEqual({r["id"] for r in records}, {memory_id})
            self.assertEqual({r["revision"] for r in records}, {1})
            source = next(r["sources"][0]["source"] for r in records if r["sources"])
            self.assertEqual(source["session"], session)
            self.assertEqual((source["first_seq"], source["last_seq"]), (seq, seq))
            self.assertEqual(source["actors"], ["user_assertion"])
            self.assertEqual(source["origin"], "experienced")
            expected = hashlib.sha256(
                json.dumps(
                    [
                        [
                            seq,
                            packed("user", "The release is Tuesday").hex(),
                            "user_assertion",
                        ]
                    ],
                    separators=(",", ":"),
                ).encode()
            ).hexdigest()
            self.assertEqual(source["digest"], expected)
            expanded = value(app, f"/sessions/{other}/sources/{source['id']}")
            self.assertIn("The release is Tuesday", expanded["text"])
            self.assertEqual(expanded["source"]["digest"], expected)
            self.assertEqual(len(provider.requests), 0)

    def test_correction_displaces_old_claim_but_keeps_history(self):
        provider = Provider(lambda _request: text("done"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            create(app, default=True)
            session = app.session()
            before = self.seed(app, session, ("user", "Tuesday"))[0]
            bind(app, session)
            old = self.mutate(app, session, [self.memory("I was told Tuesday", before)])
            memory_id = old["records"][0]["id"]
            after = self.seed(app, session, ("user", "Correction: Wednesday"))[0]
            corrected = self.mutate(
                app,
                session,
                [
                    self.memory(
                        "I was told Wednesday",
                        after,
                        id=memory_id,
                        expected_revision=1,
                        action="correct",
                    )
                ],
            )
            self.assertEqual(corrected["records"], [{"id": memory_id, "revision": 2}])
            current = self.records(app, session, memory_id)
            self.assertEqual({r["revision"] for r in current}, {2})
            self.assertNotIn("Tuesday", "".join(r["text"] for r in current))
            origins = {
                link["source"]["origin"] for r in current for link in r["sources"]
            }
            self.assertEqual(origins, {"imported", "experienced"})
            self.assertIn(
                "corrects", {link["relation"] for r in current for link in r["sources"]}
            )
            history = self.records(app, session, memory_id, history=True)
            self.assertEqual({r["revision"] for r in history}, {1, 2})
            self.assertIn("Tuesday", "".join(r["text"] for r in history))
            self.mutate(
                app,
                session,
                [
                    {
                        "id": memory_id,
                        "expected_revision": 2,
                        "action": "retract",
                        "text": "withdrawn",
                        "provenance": "inferred",
                        "uncertainty": "retracted",
                    }
                ],
            )
            self.assertEqual(self.records(app, session), [])
            self.assertEqual(
                {
                    r["revision"]
                    for r in self.records(app, session, memory_id, history=True)
                },
                {1, 2, 3},
            )

    def test_long_user_claim_keeps_stable_attribution_on_every_fragment(self):
        provider = Provider(lambda _request: text("done"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            create(app, default=True)
            session = app.session()
            bind(app, session)
            seq = self.seed(app, session, ("user", "a user told me this"))[0]
            claim = "claim " * 400
            receipt = self.mutate(app, session, [self.memory(claim, seq)])
            fragments = self.records(app, session, receipt["records"][0]["id"])
            self.assertGreater(len(fragments), 1)
            self.assertEqual("".join(r["text"] for r in fragments), claim)
            self.assertEqual({r["attribution"] for r in fragments}, {"being_told"})
            for fragment in fragments:
                self.assertEqual(fragment["attribution"], "being_told")
                self.assertEqual(fragment["source_origins"], ["experienced"])
                self.assertEqual(fragment["source_actor_kinds"], ["user_assertion"])
                self.assertEqual(len(fragment["evidence_source_ids"]), 1)

    def test_mixed_origin_claim_keeps_complete_attribution_across_pages(self):
        provider = Provider(lambda _request: text("done"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            create(app, default=True)
            session = app.session()
            before = self.seed(app, session, ("assistant", "supplied history"))[0]
            bind(app, session)
            after = self.seed(app, session, ("user", "a new user assertion"))[0]
            claim = "mixed evidence " * 180
            change = self.memory(claim, after)
            change["sources"].append(
                {"relation": "contradicts", "first_seq": before, "last_seq": before}
            )
            receipt = self.mutate(app, session, [change])
            fragments = self.records(app, session, receipt["records"][0]["id"])
            self.assertGreater(len(fragments), 2)
            self.assertEqual("".join(r["text"] for r in fragments), claim)
            self.assertEqual({r["attribution"] for r in fragments}, {"being_told"})
            for fragment in fragments:
                self.assertEqual(fragment["attribution"], "being_told")
                self.assertEqual(
                    set(fragment["source_origins"]), {"experienced", "imported"}
                )
                self.assertEqual(
                    set(fragment["source_actor_kinds"]),
                    {"user_assertion", "owner_agent"},
                )
                self.assertEqual(len(fragment["evidence_source_ids"]), 2)
            sources = [s["source"] for r in fragments for s in r["sources"]]
            self.assertEqual(
                {s["id"] for s in sources}, set(fragments[0]["evidence_source_ids"])
            )

    def test_source_scope_and_provenance_cannot_be_spoofed(self):
        provider = Provider(lambda _request: text("done"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            persona = create(app)
            owner = app.session()
            foreign = app.session()
            seq = self.seed(app, owner, ("user", "supplied historical assertion"))[0]
            other_seq = self.seed(app, foreign, ("user", "private foreign evidence"))[0]
            bind(app, owner, persona["id"])
            receipt = self.mutate(
                app, owner, [self.memory("Historical assertion", seq)]
            )
            record = self.records(app, owner, receipt["records"][0]["id"])[0]
            self.assertEqual(record["provenance"], "imported")
            source = record["sources"][0]["source"]
            for evidence in (
                {"relation": "supports", "first_seq": other_seq, "last_seq": other_seq},
                {
                    "relation": "supports",
                    "session": foreign,
                    "first_seq": other_seq,
                    "last_seq": other_seq,
                },
                {
                    "relation": "supports",
                    "first_seq": seq,
                    "last_seq": seq,
                    "actors": ["user"],
                    "origin": "experienced",
                },
                {
                    "relation": "supports",
                    "first_seq": seq,
                    "last_seq": seq,
                    "digest": "0" * 64,
                },
            ):
                with self.assertRaises(urllib.error.HTTPError):
                    self.mutate(
                        app,
                        owner,
                        [{**self.memory("hostile", seq), "sources": [evidence]}],
                    )
            other_persona = create(app)
            bound_foreign = app.session()
            bind(app, bound_foreign, other_persona["id"])
            with self.assertRaises(urllib.error.HTTPError) as denied:
                value(app, f"/sessions/{bound_foreign}/sources/{source['id']}")
            self.assertEqual(denied.exception.code, 404)
            with self.assertRaises(urllib.error.HTTPError):
                self.mutate(
                    app,
                    bound_foreign,
                    [
                        {
                            **self.memory("steal", seq),
                            "sources": [
                                {"relation": "supports", "source_id": source["id"]}
                            ],
                        }
                    ],
                )

    def test_missing_hint_falls_back_but_changed_rows_never_substitute(self):
        provider = Provider(lambda _request: text("done"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            create(app, default=True)
            session = app.session()
            bind(app, session)
            first, last = self.seed(
                app,
                session,
                ("user", "first assertion"),
                ("assistant", "second assertion"),
            )
            change = self.memory("Two rows", first)
            change["sources"][0].update(last_seq=last, lcm_hint="missing-node")
            persona = inspect(app, session)["persona"]
            body = {
                "operation_id": operation_id(),
                "expected_revision": persona["revision"],
                "expected_identity_revision": persona["identity_revision"],
                "reason": "source witness",
                "memories": [change],
            }
            receipt = value(app, f"/sessions/{session}/memories", body)
            source = self.records(app, session, receipt["records"][0]["id"])[0][
                "sources"
            ][0]["source"]
            page = value(app, f"/sessions/{session}/sources/{source['id']}")
            self.assertIn("first assertion", page["text"])
            self.assertIn("second assertion", page["text"])
            self.assertEqual(source["actors"], ["user_assertion", "owner_agent"])

            def reorder(_app):
                with sqlite3.connect(app.home / "albedo.sqlite") as db:
                    db.execute(
                        "UPDATE transcript SET payload=? WHERE seq=?",
                        (packed("assistant", "second assertion"), first),
                    )
                    db.execute(
                        "UPDATE transcript SET payload=? WHERE seq=?",
                        (packed("user", "first assertion"), last),
                    )

            app.restart(prepare=reorder)
            with self.assertRaises(urllib.error.HTTPError) as changed:
                value(app, f"/sessions/{session}/sources/{source['id']}")
            self.assertEqual(json.load(changed.exception)["code"], "source_unavailable")
            self.assertEqual(value(app, f"/sessions/{session}/memories", body), receipt)

    def test_deleted_session_marks_surviving_sources_unavailable(self):
        provider = Provider(lambda _request: text("done"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            create(app, default=True)
            session = app.session()
            bind(app, session)
            seq = self.seed(app, session, ("user", "retained claim, deleted evidence"))[
                0
            ]
            receipt = self.mutate(
                app, session, [self.memory("I received a claim", seq)]
            )
            other = app.session()
            bind(app, other)
            record_id = receipt["records"][0]["id"]
            route = f"/sessions/{session}?view=configuration"
            with app.api(route) as response:
                response.read()
                revision = response.headers["ETag"]
            app.api(route, method="DELETE", headers={"If-Match": revision}).close()
            records = self.records(app, other, record_id)
            source = records[0]["sources"][0]["source"]
            self.assertEqual(source["availability"], "unavailable")
            with self.assertRaises(urllib.error.HTTPError) as unavailable:
                value(app, f"/sessions/{other}/sources/{source['id']}")
            self.assertEqual(
                json.load(unavailable.exception)["code"], "source_unavailable"
            )

    def test_rendered_inspection_keeps_exact_boundary_text_and_origin_labels(self):
        provider = Provider(lambda _request: text("done"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            create(app, default=True)
            session = app.session()
            bind(app, session)
            seqs = self.seed(
                app, session, *[("user", f"source {index}") for index in range(16)]
            )
            claim = "\x01" * 4096
            tags = [str(index) + "\x02" * 126 for index in range(16)]
            change = self.memory(
                claim,
                seqs[0],
                tags=tags,
                uncertainty="\x03" * 128,
                temporal_scope="\x04" * 128,
            )
            change["sources"] = [
                {
                    "relation": "supports",
                    "first_seq": seq,
                    "last_seq": seq,
                    "lcm_hint": "missing",
                }
                for seq in seqs
            ]
            persona = inspect(app, session)["persona"]
            receipt = value(
                app,
                f"/sessions/{session}/memories",
                {
                    "operation_id": operation_id(),
                    "expected_revision": persona["revision"],
                    "expected_identity_revision": persona["identity_revision"],
                    "reason": "\x06" * 2048 + "r" * 2048,
                    "memories": [change],
                },
            )
            records = self.records(app, session, receipt["records"][0]["id"])
            self.assertEqual("".join(r["text"] for r in records), claim)
            self.assertEqual(
                "".join(r["reason"] for r in records), "\x06" * 2048 + "r" * 2048
            )
            self.assertEqual([tag for r in records for tag in r["tags"]], tags)
            links = [link for r in records for link in r["sources"]]
            self.assertEqual(len(links), 16)
            self.assertTrue(
                all(link["source"]["origin"] == "experienced" for link in links)
            )
            self.assertTrue(
                all(link["source"]["actors"] == ["user_assertion"] for link in links)
            )

    def test_limits_and_stale_record_heads_leave_domain_state_unchanged(self):
        provider = Provider(lambda _request: text("done"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            create(app, default=True)
            session = app.session()
            bind(app, session)
            seq = self.seed(app, session, ("user", "limits evidence"))[0]
            receipt = self.mutate(
                app,
                session,
                [
                    self.memory(
                        "é" * 2048, seq, tags=[str(index) for index in range(16)]
                    )
                ],
            )
            memory_id = receipt["records"][0]["id"]
            before = inspect(app, session)
            for change in (
                self.memory("é" * 2049, seq),
                self.memory(
                    "too many tags", seq, tags=[str(index) for index in range(17)]
                ),
                {
                    **self.memory("too many links", seq),
                    "sources": self.memory("", seq)["sources"] * 17,
                },
            ):
                with self.assertRaises(urllib.error.HTTPError) as invalid:
                    self.mutate(app, session, [change])
                self.assertEqual(invalid.exception.code, 400)
                self.assertEqual(
                    inspect(app, session)["persona"]["revision"],
                    before["persona"]["revision"],
                )
            with self.assertRaises(urllib.error.HTTPError) as stale:
                self.mutate(
                    app,
                    session,
                    [
                        self.memory(
                            "stale correction",
                            seq,
                            id=memory_id,
                            expected_revision=2,
                            action="correct",
                        )
                    ],
                )
            problem = json.load(stale.exception)
            self.assertEqual(
                problem["current_heads"]["records"], [{"id": memory_id, "revision": 1}]
            )
            self.assertEqual(
                inspect(app, session)["persona"]["revision"],
                before["persona"]["revision"],
            )

    def test_legacy_identity_receipt_replays_after_memory_upgrade(self):
        provider = Provider(lambda _request: text("done"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            create(app, default=True)
            session = app.session()
            bind(app, session)
            persona = inspect(app, session)["persona"]
            body = {
                "operation_id": operation_id(),
                "expected_revision": persona["revision"],
                "expected_identity_revision": persona["identity_revision"],
                "changes": {"values": "legacy receipt"},
                "reason": "existing foreground edit",
            }
            receipt = value(app, f"/sessions/{session}/identity", body)

            def old_receipt(_app):
                with sqlite3.connect(app.home / "albedo.sqlite") as db:
                    key, request, result = db.execute(
                        "SELECT operation_id,request,result FROM personality_operation WHERE result LIKE ?",
                        (f'%"operation_id":"{body["operation_id"]}"%',),
                    ).fetchone()
                    request = json.loads(request)
                    request["kind"] = "identity_edit"
                    request.pop("memories", None)
                    result = json.loads(result)
                    result.pop("records", None)
                    db.execute(
                        "UPDATE personality_operation SET request=?,result=? WHERE operation_id=?",
                        (
                            json.dumps(request, separators=(",", ":")),
                            json.dumps(result, separators=(",", ":")),
                            key,
                        ),
                    )

            app.restart(prepare=old_receipt)
            replay = value(app, f"/sessions/{session}/identity", body)
            self.assertEqual(
                {k: v for k, v in replay.items() if k != "records"},
                {k: v for k, v in receipt.items() if k != "records"},
            )
            self.assertEqual(
                inspect(app, session)["persona"]["identity_revision"],
                receipt["identity_revision"],
            )

    def test_explicit_contradiction_retains_origins_until_a_correction_resolves_it(
        self,
    ):
        provider = Provider(lambda _request: text("done"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            create(app, default=True)
            session = app.session()
            bind(app, session)
            first, second = self.seed(
                app,
                session,
                ("user", "Tuesday"),
                ("assistant", "Wednesday is an inference"),
            )
            receipt = self.mutate(
                app, session, [self.memory("I was told Tuesday", first)]
            )
            memory_id = receipt["records"][0]["id"]
            conflicting = self.memory(
                "Tuesday or Wednesday remains unresolved",
                second,
                id=memory_id,
                expected_revision=1,
                action="contradict",
                provenance="inferred",
            )
            conflicting["sources"][0]["relation"] = "contradicts"
            self.mutate(app, session, [conflicting])
            current = self.records(app, session, memory_id)
            self.assertTrue(all(r["unresolved"] for r in current))
            self.assertEqual(
                {link["relation"] for r in current for link in r["sources"]},
                {"supports", "contradicts"},
            )
            self.mutate(
                app,
                session,
                [
                    self.memory(
                        "Correction: Tuesday",
                        first,
                        id=memory_id,
                        expected_revision=2,
                        action="correct",
                    )
                ],
            )
            corrected = self.records(app, session, memory_id)
            self.assertTrue(all(not r["unresolved"] for r in corrected))
            self.assertEqual(
                {
                    link["source"]["actors"][0]
                    for r in corrected
                    for link in r["sources"]
                },
                {"user_assertion", "owner_agent"},
            )

    def test_ordinary_capacity_and_record_guard_keep_corrections_available(self):
        provider = Provider(lambda _request: text("done"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            create(app, default=True)
            session = app.session()
            bind(app, session)
            seq = self.seed(app, session, ("user", "capacity evidence"))[0]
            receipt = self.mutate(app, session, [self.memory("original", seq)])
            memory_id = receipt["records"][0]["id"]

            def fill(_app):
                with sqlite3.connect(app.home / "albedo.sqlite") as db:
                    db.execute(
                        "UPDATE personality_capacity SET ordinary_limit=ordinary_bytes"
                    )

            app.restart(prepare=fill)
            before = inspect(app, session)
            with self.assertRaises(urllib.error.HTTPError) as full:
                self.mutate(app, session, [self.memory("new record refused", seq)])
            self.assertEqual(json.load(full.exception)["code"], "capacity_exceeded")
            self.assertEqual(
                inspect(app, session)["persona"]["revision"],
                before["persona"]["revision"],
            )
            corrected = self.mutate(
                app,
                session,
                [
                    self.memory(
                        "correction still applies",
                        seq,
                        id=memory_id,
                        expected_revision=1,
                        action="correct",
                    )
                ],
            )
            self.assertEqual(corrected["records"], [{"id": memory_id, "revision": 2}])
            after = inspect(app, session)
            self.assertEqual(
                before["editing"]["ordinary_bytes"], after["editing"]["ordinary_bytes"]
            )
            self.assertGreater(
                after["editing"]["corrective_bytes"],
                before["editing"]["corrective_bytes"],
            )

            def reserve_full(_app):
                with sqlite3.connect(app.home / "albedo.sqlite") as db:
                    db.execute(
                        "UPDATE personality_capacity SET corrective_limit=corrective_bytes"
                    )

            app.restart(prepare=reserve_full)
            with self.assertRaises(urllib.error.HTTPError) as exhausted:
                self.mutate(
                    app,
                    session,
                    [
                        {
                            "id": memory_id,
                            "expected_revision": 2,
                            "action": "retract",
                            "text": "must not pretend applied",
                            "provenance": "inferred",
                            "uncertainty": "retracted",
                        }
                    ],
                )
            self.assertEqual(
                json.load(exhausted.exception)["code"], "capacity_exceeded"
            )
            self.assertEqual(
                {r["revision"] for r in self.records(app, session, memory_id)}, {2}
            )

    def test_mutation_source_prevalidation_has_one_total_bounded_read_budget(self):
        provider = Provider(lambda _request: text("done"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            create(app, default=True)
            session = app.session()
            bind(app, session)
            seqs = self.seed(
                app, session, ("user", "a" * 150_000), ("user", "b" * 150_000)
            )
            before = inspect(app, session)
            with self.assertRaises(urllib.error.HTTPError) as too_large:
                self.mutate(
                    app,
                    session,
                    [self.memory("one", seqs[0]), self.memory("two", seqs[1])],
                )
            self.assertEqual(json.load(too_large.exception)["code"], "invalid_request")
            self.assertEqual(
                inspect(app, session)["persona"]["revision"],
                before["persona"]["revision"],
            )

    def test_pages_report_exact_rendered_bytes_and_bound_the_cursor_scope(self):
        provider = Provider(lambda _request: text("done"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            create(app, default=True)
            session = app.session()
            bind(app, session)
            seq = self.seed(app, session, ("user", "é" * 4000))[0]
            receipt = self.mutate(app, session, [self.memory("é" * 2048, seq)])
            record = receipt["records"][0]["id"]
            page = value(app, f"/sessions/{session}/memories/{record}")
            encoded = json.dumps(
                page, ensure_ascii=False, separators=(",", ":")
            ).encode()
            self.assertEqual(page["bytes"], len(encoded))
            self.assertEqual(
                "".join(r["text"] for r in self.records(app, session, record)),
                "é" * 2048,
            )
            source = page["records"][0]["sources"][0]["source"]
            expanded = value(app, f"/sessions/{session}/sources/{source['id']}")
            self.assertEqual(
                expanded["bytes"],
                len(
                    json.dumps(
                        expanded, ensure_ascii=False, separators=(",", ":")
                    ).encode()
                ),
            )
            self.assertIsNotNone(page["next_cursor"])
            import urllib.parse

            other = app.session()
            bind(app, other)
            with self.assertRaises(urllib.error.HTTPError) as scope:
                value(
                    app,
                    f"/sessions/{other}/memories/{record}?cursor="
                    + urllib.parse.quote(page["next_cursor"], safe=""),
                )
            self.assertEqual(scope.exception.code, 409)
            with self.assertRaises(urllib.error.HTTPError):
                value(
                    app,
                    f"/sessions/{session}/sources/{source['id']}?cursor="
                    + urllib.parse.quote(page["next_cursor"], safe=""),
                )

    def test_record_slot_guard_keeps_existing_corrections_writable(self):
        provider = Provider(lambda _request: text("done"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            create(app, default=True)
            session = app.session()
            bind(app, session)
            seq = self.seed(app, session, ("user", "record capacity evidence"))[0]
            receipt = self.mutate(app, session, [self.memory("original", seq)])
            memory_id = receipt["records"][0]["id"]

            def lower(_app):
                with sqlite3.connect(app.home / "albedo.sqlite") as db:
                    db.execute("UPDATE personality_capacity SET record_limit=0")

            app.restart(prepare=lower)
            before = inspect(app, session)
            self.assertEqual(before["editing"]["current_records"], 1)
            self.assertEqual(before["editing"]["record_limit"], 0)
            with self.assertRaises(urllib.error.HTTPError) as refused:
                self.mutate(app, session, [self.memory("new slot refused", seq)])
            self.assertEqual(json.load(refused.exception)["code"], "capacity_exceeded")
            corrected = self.mutate(
                app,
                session,
                [
                    self.memory(
                        "correction adds no slot",
                        seq,
                        id=memory_id,
                        expected_revision=1,
                        action="correct",
                    )
                ],
            )
            self.assertEqual(corrected["records"], [{"id": memory_id, "revision": 2}])
            self.assertEqual(inspect(app, session)["editing"]["current_records"], 1)

    def test_mixed_new_record_and_correction_cannot_use_the_corrective_reserve(self):
        provider = Provider(lambda _request: text("done"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            create(app, default=True)
            session = app.session()
            bind(app, session)
            seq = self.seed(app, session, ("user", "mixed capacity evidence"))[0]
            receipt = self.mutate(app, session, [self.memory("original", seq)])
            memory_id = receipt["records"][0]["id"]

            def fill(_app):
                with sqlite3.connect(app.home / "albedo.sqlite") as db:
                    db.execute(
                        "UPDATE personality_capacity SET ordinary_limit=ordinary_bytes"
                    )

            app.restart(prepare=fill)
            before = inspect(app, session)
            with self.assertRaises(urllib.error.HTTPError) as mixed:
                self.mutate(
                    app,
                    session,
                    [
                        self.memory(
                            "correction",
                            seq,
                            id=memory_id,
                            expected_revision=1,
                            action="correct",
                        ),
                        self.memory("new record", seq),
                    ],
                )
            self.assertEqual(json.load(mixed.exception)["code"], "capacity_exceeded")
            after = inspect(app, session)
            self.assertEqual(before["editing"], after["editing"])
            self.assertEqual(
                before["persona"]["revision"], after["persona"]["revision"]
            )
            self.assertEqual(
                {r["revision"] for r in self.records(app, session, memory_id)}, {1}
            )

    def test_record_batch_and_retained_link_limits_preserve_complete_history(self):
        provider = Provider(lambda _request: text("done"))
        self.addCleanup(provider.close)
        with self.app(provider) as app:
            create(app, default=True)
            session = app.session()
            bind(app, session)
            seqs = self.seed(
                app, session, *[("user", f"evidence {index}") for index in range(17)]
            )
            change = self.memory("sixteen sources retained", seqs[0])
            change["sources"] = [
                {"relation": "supports", "first_seq": seq, "last_seq": seq}
                for seq in seqs[:16]
            ]
            receipt = self.mutate(app, session, [change])
            memory_id = receipt["records"][0]["id"]
            before = inspect(app, session)
            with self.assertRaises(urllib.error.HTTPError) as too_many:
                self.mutate(
                    app,
                    session,
                    [
                        self.memory(
                            "would add seventeenth origin",
                            seqs[-1],
                            id=memory_id,
                            expected_revision=1,
                            action="correct",
                        )
                    ],
                )
            self.assertEqual(too_many.exception.code, 400)
            self.assertEqual(
                inspect(app, session)["persona"]["revision"],
                before["persona"]["revision"],
            )
            with self.assertRaises(urllib.error.HTTPError) as batch:
                self.mutate(
                    app,
                    session,
                    [self.memory(f"record {index}", seqs[0]) for index in range(33)],
                )
            self.assertEqual(batch.exception.code, 400)
            for prefix in ("first", "second"):
                accepted = self.mutate(
                    app,
                    session,
                    [
                        self.memory(f"{prefix} record {index}", seqs[0])
                        for index in range(32)
                    ],
                )
                self.assertEqual(len(accepted["records"]), 32)
            records = self.records(app, session)
            self.assertEqual(len({r["id"] for r in records}), 65)
            self.assertEqual(
                len(
                    [
                        link
                        for r in records
                        if r["id"] == memory_id
                        for link in r["sources"]
                    ]
                ),
                16,
            )


@exclusive
class PersonalityMemoryProviderTest(MemoryFixture):
    """Retained real native-tool provider lane; needs the ordinary Python kernel."""

    def test_native_memory_correction_and_source_recovery_through_both_protocols(self):
        from harness import Reply

        for protocol in ("responses", "chat_completions"):
            with self.subTest(protocol=protocol):
                observed, bodies = [], {}

                def outputs(request):
                    if "input" in request:
                        return [
                            item["output"]
                            for item in request["input"]
                            if item.get("type") == "function_call_output"
                        ]
                    return [
                        message["content"]
                        for message in request["messages"]
                        if message.get("role") == "tool"
                    ]

                def reply(request):
                    results = outputs(request)
                    if not results:
                        return Reply(
                            "python",
                            tool_name="persona_edit",
                            tool_arguments=bodies["remember"],
                        )
                    latest = json.loads(results[-1])
                    observed.append(latest)
                    if len(observed) == 1:
                        bodies["correct"].update(expected_revision=latest["revision"])
                        bodies["correct"]["memories"][0].update(
                            id=latest["records"][0]["id"], expected_revision=1
                        )
                        return Reply(
                            "python",
                            tool_name="persona_edit",
                            tool_arguments=bodies["correct"],
                        )
                    if len(observed) == 2:
                        return Reply(
                            "python",
                            tool_name="persona_inspect",
                            tool_arguments={"view": "memories"},
                        )
                    if len(observed) == 3:
                        source = latest["records"][0]["sources"][0]["source"]
                        return Reply(
                            "python",
                            tool_name="persona_source",
                            tool_arguments={"source_id": source["id"]},
                        )
                    return text("finished")

                provider = Provider(reply)
                self.addCleanup(provider.close)
                with Albedo(
                    provider,
                    protocol=protocol,
                    prepare=lambda app: app.write_extensions(
                        {"enabled": {"personality": True}}
                    ),
                ) as app:
                    create(app, default=True)
                    session = app.session()
                    bind(app, session)
                    first, second = self.seed(
                        app,
                        session,
                        ("user", "Tuesday"),
                        ("user", "Correction: Wednesday"),
                    )
                    persona = inspect(app, session)["persona"]
                    base = {
                        "expected_revision": persona["revision"],
                        "expected_identity_revision": persona["identity_revision"],
                        "reason": "foreground native memory",
                    }
                    bodies["remember"] = {
                        **base,
                        "operation_id": operation_id(),
                        "memories": [self.memory("I was told Tuesday", first)],
                    }
                    bodies["correct"] = {
                        **base,
                        "operation_id": operation_id(),
                        "memories": [
                            self.memory(
                                "I was told Wednesday", second, action="correct"
                            )
                        ],
                    }
                    app.prompt(
                        session, "Remember and correct this source-backed assertion"
                    ).close()
                    app.idle(session)
                    self.assertEqual(len(observed), 4)
                    self.assertEqual(observed[0]["actor"], "owner_agent")
                    self.assertEqual(observed[1]["records"][0]["revision"], 2)
                    self.assertEqual(
                        observed[1]["identity_revision"], persona["identity_revision"]
                    )
                    self.assertEqual(
                        observed[2]["records"][0]["text"], "I was told Wednesday"
                    )
                    self.assertNotIn(
                        "Tuesday", "".join(r["text"] for r in observed[2]["records"])
                    )
                    self.assertIn(observed[3]["source"]["first_seq"], (first, second))
                    self.assertEqual(
                        observed[3]["source"]["actors"], ["user_assertion"]
                    )
                    with sqlite3.connect(app.home / "albedo.sqlite") as db:
                        saved = db.execute(
                            "SELECT result FROM personality_tool_receipt WHERE session=? ORDER BY call_id",
                            (session,),
                        ).fetchall()
                        self.assertEqual(
                            [json.loads(row[0]) for row in saved], observed[:2]
                        )
                    app.restart()
                    memory_id = observed[0]["records"][0]["id"]
                    records = self.records(app, session, memory_id)
                    self.assertEqual({r["revision"] for r in records}, {2})
