"""Owner-contributed schema and image migrations survive real startup and restarts.

Legacy ETF fixtures cannot be written by the current daemon. They are seeded
while the shared daemon is stopped, then exercised through its normal readers.
"""

import base64
import hashlib
import json
import sqlite3
import unittest

from harness import Albedo, Provider, exclusive, python, text


PNG = "iVBORw0KGgoAAAANSUhEUgAAAA0AAAAD"
# term_to_binary({1, {user_image, <<"legacy image">>, Image}}), where Image
# is the legacy {image, <<"image/png">>, Base64, 13, 3, 24} tuple.
LEGACY_TRANSCRIPT = base64.b64decode(
    "g2gCYQFoA3cKdXNlcl9pbWFnZW0AAAAMbGVnYWN5IGltYWdlaAZ3BWltYWdlbQAAAAlp"
    "bWFnZS9wbmdtAAAAIGlWQk9SdzBLR2dvQUFBQU5TVWhFVWdBQUFBMEFBQUFEYQ1hA2EY"
)
# A successful outcome before duration was added, carrying the same inline image.
LEGACY_CELL = base64.b64decode(
    "g2gCYQFoAncCb2toCHcHb3V0Y29tZW0AAAAObGVnYWN5LWNlbGwtMDB3CXN1Y2NlZWRl"
    "ZG0AAAANbGVnYWN5IG91dHB1dG0AAAAIJ2xlZ2FjeSd3BWZhbHNlbAAAAAFoBncFaW1h"
    "Z2VtAAAACWltYWdlL3BuZ20AAAAgaVZCT1J3MEtHZ29BQUFBTlNVaEVVZ0FBQUEwQUFB"
    "QURhDWEDYRhqag=="
)


def legacy_cell(cell_id):
    # Replace only this fixture's ETF binary field, including its length.
    original = b"legacy-cell-00"
    encoded = cell_id.encode()
    return LEGACY_CELL.replace(
        b"m" + len(original).to_bytes(4, "big") + original,
        b"m" + len(encoded).to_bytes(4, "big") + encoded,
    )


# exclusive: seeds legacy global schema and restarts the daemon
@exclusive
class MigrationsTest(unittest.TestCase):
    def test_installed_extensions_upgrade_legacy_tables_before_their_routes_run(self):
        provider = Provider(
            lambda request: (
                python(
                    "items = await work.list()\n"
                    "assert not items\n"
                    "item = await work.create('new scoped item')\n"
                    "assert (await work.get(item.id)).title == 'new scoped item'\n"
                    "legacy = [v for v in await vents(200) if v['message'] == 'legacy vent']\n"
                    "assert len(legacy) == 1 and legacy[0]['title'] == ''\n"
                    "await vent('bug', 'new vent', title='new title')\n"
                    "assert any(v['title'] == 'new title' for v in await vents())\n"
                    "print('upgraded extension routes usable')"
                )
                if request["messages"][-1].get("role") == "user"
                else text("done")
            )
        )
        self.addCleanup(provider.close)
        with Albedo(provider) as app:
            session = app.session()
            database = app.home / "albedo.sqlite"
            previous_cwds, previous_titles = [], []
            legacy_work = None

            def prepare(_app):
                nonlocal legacy_work
                with sqlite3.connect(database) as db:
                    previous_cwds.extend(db.execute("SELECT cwd,id FROM work"))
                    previous_titles.extend(
                        db.execute("SELECT title,id FROM paperclips")
                    )
                    db.execute("DROP INDEX work_cwd_id")
                    db.execute("ALTER TABLE work DROP COLUMN cwd")
                    db.execute("ALTER TABLE paperclips DROP COLUMN title")
                    legacy_work = db.execute(
                        "INSERT INTO work(title) VALUES('legacy isolated item')"
                    ).lastrowid
                    db.execute(
                        "INSERT INTO paperclips(topic,message,cwd) VALUES('bug','legacy vent',?)",
                        (str(app.workspace),),
                    )
                    # the cwd-scoped era's index, which the scope migration drops
                    db.execute(
                        "CREATE INDEX IF NOT EXISTS paperclips_cwd ON paperclips(cwd)"
                    )
                    assert db.execute(
                        "SELECT name FROM sqlite_master"
                        " WHERE name='paperclips_cwd' AND type='index'"
                    ).fetchone()
                settings_path = app.home / "extensions.json"
                settings = json.loads(settings_path.read_text())
                settings.setdefault("enabled", {}).update(work=False, paperclips=False)
                settings_path.write_text(json.dumps(settings))

            def restore(_app):
                with sqlite3.connect(database) as db:
                    db.executemany("UPDATE work SET cwd=? WHERE id=?", previous_cwds)
                    db.executemany(
                        "UPDATE paperclips SET title=? WHERE id=?", previous_titles
                    )

            try:
                app.restart(prepare=prepare)
                # Installed storage still upgrades when its routes are disabled.
                with sqlite3.connect(database) as db:
                    self.assertEqual(
                        db.execute(
                            "SELECT cwd FROM work WHERE id=?", (legacy_work,)
                        ).fetchone(),
                        ("__albedo_legacy__",),
                    )
                    self.assertIsNotNone(
                        db.execute(
                            "SELECT name FROM sqlite_master WHERE name='work_cwd_id' AND type='index'"
                        ).fetchone()
                    )
                    self.assertIsNone(
                        db.execute(
                            "SELECT name FROM sqlite_master WHERE name='paperclips_cwd' AND type='index'"
                        ).fetchone()
                    )
                with app.api(f"/sessions/{session}?view=configuration") as response:
                    json.load(response)
                    revision = response.headers["ETag"]
                app.api(
                    f"/sessions/{session}?view=configuration",
                    {"selection": {"extensions": {"work": True, "paperclips": True}}},
                    method="PATCH",
                    headers={"If-Match": revision},
                ).close()
                app.restart()
                app.prompt(session, "use the upgraded extension ledgers").close()
                app.idle(session)
                results = [
                    json.loads(part["value"])
                    for entry in app.history(session)["items"]
                    if entry["kind"] == "tool_result"
                    and entry["tool"]["name"] == "python"
                    for part in entry["content"]
                    if part["kind"] == "json" and part["field"] == "result"
                ]
                self.assertEqual(len(results), 1)
                self.assertEqual(results[0]["status"], "ok", results[0])
                self.assertIn("upgraded extension routes usable", results[0]["output"])
            finally:
                # Restore other fixtures' fields erased by the legacy schema seed.
                app.restart(prepare=restore)

    def test_startup_migrates_legacy_images_once_with_a_consistent_backup(self):
        probe = ""

        def reply(request):
            if request["messages"][-1].get("role") == "user" and probe:
                return python(probe)
            return text("done")

        provider = Provider(reply)
        self.addCleanup(provider.close)
        with Albedo(provider) as app:
            session = app.session()
            database = app.home / "albedo.sqlite"
            image_hash = hashlib.sha256(PNG.encode()).hexdigest()
            cell_ids = [f"{session}-legacy-{n}" for n in range(20)]
            seqs = []
            backups_before = set(
                app.home.glob("backups/albedo-before-image-store-*.sqlite")
            )

            def prepare(_app):
                with sqlite3.connect(database) as db:
                    db.execute(
                        "DELETE FROM migrations WHERE name IN ('image_store','cell_images')"
                    )
                    db.execute(
                        "INSERT INTO images(hash,data) VALUES(?,?) "
                        "ON CONFLICT(hash) DO UPDATE SET data=excluded.data",
                        (image_hash, PNG),
                    )
                    for _ in range(20):
                        row = db.execute(
                            "INSERT INTO transcript(session,payload) VALUES(?,?)",
                            (session, LEGACY_TRANSCRIPT),
                        )
                        seqs.append(row.lastrowid)
                    for cell_id in cell_ids:
                        db.execute(
                            "INSERT INTO cells(id,session,source,status,started,payload) "
                            "VALUES(?,?,'legacy source','finished',1,?)",
                            (cell_id, session, legacy_cell(cell_id)),
                        )

            app.restart(prepare=prepare)
            backups = set(app.home.glob("backups/albedo-before-image-store-*.sqlite"))
            created = backups - backups_before
            self.assertEqual(len(created), 1)
            with sqlite3.connect(next(iter(created))) as backup:
                self.assertEqual(
                    backup.execute("PRAGMA integrity_check").fetchone()[0], "ok"
                )
                self.assertEqual(
                    backup.execute(
                        "SELECT data,typeof(data) FROM images WHERE hash=?",
                        (image_hash,),
                    ).fetchone(),
                    (PNG, "text"),
                )
                self.assertEqual(
                    backup.execute(
                        "SELECT payload FROM transcript WHERE seq=?", (seqs[0],)
                    ).fetchone()[0],
                    LEGACY_TRANSCRIPT,
                )
                self.assertEqual(
                    backup.execute(
                        "SELECT payload FROM cells WHERE id=?", (cell_ids[0],)
                    ).fetchone()[0],
                    legacy_cell(cell_ids[0]),
                )

            def migrated_state():
                with sqlite3.connect(database) as db:
                    self.assertEqual(
                        db.execute("PRAGMA integrity_check").fetchone()[0], "ok"
                    )
                    self.assertEqual(
                        db.execute("PRAGMA foreign_key_check").fetchall(), []
                    )
                    self.assertEqual(
                        db.execute(
                            "SELECT data,typeof(data) FROM images WHERE hash=?",
                            (image_hash,),
                        ).fetchone(),
                        (base64.b64decode(PNG), "blob"),
                    )
                    transcript = db.execute(
                        "SELECT seq,payload FROM transcript WHERE session=? ORDER BY seq",
                        (session,),
                    ).fetchall()
                    self.assertEqual([row[0] for row in transcript], seqs)
                    cells = db.execute(
                        "SELECT id,source,payload FROM cells WHERE session=? ORDER BY id",
                        (session,),
                    ).fetchall()
                    self.assertEqual([row[0] for row in cells], sorted(cell_ids))
                    self.assertTrue(all(row[1] == "legacy source" for row in cells))
                    for payload in [row[1] for row in transcript] + [
                        row[2] for row in cells
                    ]:
                        self.assertNotIn(PNG.encode(), payload)
                        self.assertIn(image_hash.encode(), payload)
                    markers = db.execute(
                        "SELECT name,applied_at FROM migrations "
                        "WHERE name IN ('image_store','cell_images') ORDER BY name"
                    ).fetchall()
                    self.assertEqual(
                        [row[0] for row in markers], ["cell_images", "image_store"]
                    )
                    return transcript, cells, markers

            first = migrated_state()
            app.restart()
            self.assertEqual(migrated_state(), first)
            self.assertEqual(
                set(app.home.glob("backups/albedo-before-image-store-*.sqlite")),
                backups,
            )
            # A normal provider request resolves the migrated transcript images.
            probe = (
                f"info = await cells.info({cell_ids[0]!r})\n"
                "assert info['status'] == 'ok' and info['started']\n"
                "assert info['duration'] is None\n"
                f"assert 'legacy source' in await cells.read({cell_ids[0]!r})\n"
                "print('legacy cell readable')"
            )
            app.prompt(session, "read the migrated history and cell").close()
            app.idle(session)
            serialized = json.dumps(provider.requests[-1]["request"])
            self.assertIn("legacy image", serialized)
            self.assertIn(PNG, serialized)
            self.assertIn("legacy cell readable", serialized)

    def test_session_preferences_import_once_without_removing_global_fields(self):
        provider = Provider(lambda _request: text("done"))
        self.addCleanup(provider.close)
        with Albedo(provider) as app:
            session = app.session()
            database = app.home / "albedo.sqlite"
            picker_path = app.home / "picker.json"
            caps_path = app.home / "capabilities.json"
            originals = {}

            def prepare(_app):
                with sqlite3.connect(database) as db:
                    db.execute("DELETE FROM session_preferences_import")
                for path in (picker_path, caps_path):
                    originals[path] = (
                        json.loads(path.read_text()) if path.exists() else {}
                    )
                picker = {
                    **originals[picker_path],
                    "pinned": [session],
                    "archived": [session],
                    "opens": {session: 7},
                }
                caps = {
                    **originals[caps_path],
                    "sessions": {session: {"skills": {"missing-legacy-skill": False}}},
                }
                picker_path.write_text(json.dumps(picker))
                caps_path.write_text(json.dumps(caps))

            app.restart(prepare=prepare)
            with app.api(f"/sessions/{session}") as response:
                preferences = json.load(response)["preferences"]
            self.assertTrue(preferences["pinned"])
            self.assertTrue(preferences["archived"])
            self.assertEqual(preferences["opens"], 7)
            self.assertEqual(
                json.loads(picker_path.read_text()), originals[picker_path]
            )
            self.assertEqual(json.loads(caps_path.read_text()), originals[caps_path])

            def imported_state():
                with sqlite3.connect(database) as db:
                    self.assertEqual(
                        db.execute(
                            "SELECT version FROM session_preferences_import"
                        ).fetchall(),
                        [(1,)],
                    )
                    return db.execute(
                        "SELECT kind,preference_key,enabled FROM session_selection WHERE session=?",
                        (session,),
                    ).fetchall()

            first = imported_state()
            self.assertEqual(first, [("skills", "missing-legacy-skill", 0)])
            app.restart()
            self.assertEqual(imported_state(), first)
            with app.api(f"/sessions/{session}") as response:
                self.assertEqual(json.load(response)["preferences"], preferences)

    def test_failed_preferences_import_keeps_legacy_files_for_retry(self):
        provider = Provider(lambda _request: text("done"))
        self.addCleanup(provider.close)
        with Albedo(provider) as app:
            session = app.session()
            database = app.home / "albedo.sqlite"
            picker_path = app.home / "picker.json"
            original = picker_path.read_bytes() if picker_path.exists() else b"{}"
            legacy = json.dumps({"pinned": [session], "opens": {session: 7}}).encode()

            def prepare(_app):
                with sqlite3.connect(database) as db:
                    db.execute("DELETE FROM session_preferences_import")
                    db.execute(
                        "CREATE TRIGGER reject_preference_import BEFORE UPDATE OF pinned ON sessions BEGIN SELECT RAISE(ABORT, 'import fixture failure'); END"
                    )
                picker_path.write_bytes(legacy)

            def restore(_app):
                with sqlite3.connect(database) as db:
                    db.execute("DROP TRIGGER IF EXISTS reject_preference_import")
                picker_path.write_bytes(original)

            try:
                with self.assertRaises(AssertionError):
                    app.restart(prepare=prepare)
                self.assertEqual(picker_path.read_bytes(), legacy)
                with sqlite3.connect(database) as db:
                    self.assertEqual(
                        db.execute(
                            "SELECT version FROM session_preferences_import"
                        ).fetchall(),
                        [],
                    )
                    self.assertEqual(
                        db.execute(
                            "SELECT pinned,opens FROM sessions WHERE id=?", (session,)
                        ).fetchone(),
                        (0, 0),
                    )
            finally:
                app.restart(prepare=restore)

    def test_personality_fresh_install_creates_schema_without_creating_or_binding_identity(
        self,
    ):
        provider = Provider(lambda _request: text("done"))
        self.addCleanup(provider.close)
        with Albedo(provider) as app:
            session = app.session()
            with sqlite3.connect(app.home / "albedo.sqlite") as db:
                self.assertEqual(
                    db.execute("SELECT COUNT(*) FROM personality_persona").fetchone(),
                    (0,),
                )
                self.assertEqual(
                    db.execute("SELECT COUNT(*) FROM personality_session").fetchone(),
                    (0,),
                )
                self.assertEqual(
                    db.execute(
                        "SELECT COUNT(*) FROM session_requirements WHERE session=?",
                        (session,),
                    ).fetchone(),
                    (0,),
                )

    def test_personality_upgrade_preserves_existing_transcript_bytes_and_lcm_rows(self):
        provider = Provider(lambda _request: text("done"))
        self.addCleanup(provider.close)
        with Albedo(provider) as app:
            session = app.session()
            database = app.home / "albedo.sqlite"
            before = {}

            def prepare(_app):
                with sqlite3.connect(database) as db:
                    seq = db.execute(
                        "INSERT INTO transcript(session,payload,row_class,summary_indexed,calls_indexed) VALUES(?,?,'user',1,1)",
                        (session, LEGACY_TRANSCRIPT),
                    ).lastrowid
                    db.execute(
                        "INSERT INTO lcm_compaction_node(session,depth,first_seq,last_seq,summary) VALUES(?,0,?,?,'existing summary')",
                        (session, seq, seq),
                    )
                    before["transcript"] = db.execute(
                        "SELECT * FROM transcript WHERE session=?", (session,)
                    ).fetchall()
                    before["lcm"] = db.execute(
                        "SELECT * FROM lcm_compaction_node WHERE session=?", (session,)
                    ).fetchall()
                    for table in (
                        "personality_memory_source",
                        "personality_memory_revision",
                        "personality_memory",
                        "personality_source",
                        "personality_tool_receipt",
                        "personality_capacity",
                        "personality_controls",
                        "personality_session",
                        "personality_event",
                        "personality_operation",
                        "personality_default",
                        "personality_revision",
                        "personality_persona",
                    ):
                        db.execute(f"DROP TABLE IF EXISTS {table}")
                    db.execute("DROP TABLE session_requirements")
                    db.execute(
                        "DELETE FROM migrations WHERE name='session_requirements'"
                    )

            app.restart(prepare=prepare)
            with sqlite3.connect(database) as db:
                self.assertEqual(
                    db.execute(
                        "SELECT * FROM transcript WHERE session=?", (session,)
                    ).fetchall(),
                    before["transcript"],
                )
                self.assertEqual(
                    db.execute(
                        "SELECT * FROM lcm_compaction_node WHERE session=?", (session,)
                    ).fetchall(),
                    before["lcm"],
                )
                self.assertEqual(
                    db.execute("SELECT COUNT(*) FROM personality_persona").fetchone(),
                    (0,),
                )
                self.assertEqual(
                    db.execute("SELECT COUNT(*) FROM session_requirements").fetchone(),
                    (0,),
                )

    def test_interrupted_personality_schema_rolls_back_and_retries_without_losing_guard(
        self,
    ):
        provider = Provider(lambda _request: text("done"))
        self.addCleanup(provider.close)
        with Albedo(provider) as app:
            session = app.session()
            database = app.home / "albedo.sqlite"

            def interrupt(_app):
                with sqlite3.connect(database) as db:
                    db.execute(
                        "INSERT INTO session_requirements(session,capability) VALUES(?,'personality')",
                        (session,),
                    )
                    for table in (
                        "personality_memory_source",
                        "personality_memory_revision",
                        "personality_memory",
                        "personality_source",
                        "personality_tool_receipt",
                        "personality_capacity",
                        "personality_controls",
                        "personality_session",
                        "personality_event",
                        "personality_operation",
                        "personality_default",
                        "personality_revision",
                        "personality_persona",
                    ):
                        db.execute(f"DROP TABLE {table}")
                    db.execute(
                        "CREATE VIEW personality_revision AS SELECT 'blocked' AS persona_id"
                    )

            app.restart(prepare=interrupt)
            with sqlite3.connect(database) as db:
                self.assertEqual(
                    db.execute(
                        "SELECT capability FROM session_requirements WHERE session=?",
                        (session,),
                    ).fetchall(),
                    [("personality",)],
                )
                self.assertIsNone(
                    db.execute(
                        "SELECT name FROM sqlite_master WHERE name='personality_persona'"
                    ).fetchone()
                )

            def restore(_app):
                with sqlite3.connect(database) as db:
                    db.execute("DROP VIEW personality_revision")

            app.restart(prepare=restore)
            with sqlite3.connect(database) as db:
                self.assertEqual(
                    db.execute("SELECT COUNT(*) FROM personality_persona").fetchone(),
                    (0,),
                )
                self.assertEqual(
                    db.execute(
                        "SELECT capability FROM session_requirements WHERE session=?",
                        (session,),
                    ).fetchall(),
                    [("personality",)],
                )

    def test_applied_core_admission_missing_on_restart_is_not_recreated_empty(self):
        provider = Provider(lambda _request: text("done"))
        self.addCleanup(provider.close)
        with Albedo(provider) as app:
            session = app.session()
            database = app.home / "albedo.sqlite"
            saved = {}

            def remove_guard(_app):
                with sqlite3.connect(database) as db:
                    saved["schema"] = db.execute(
                        "SELECT sql FROM sqlite_master WHERE name='session_requirements'"
                    ).fetchone()[0]
                    db.execute(
                        "INSERT INTO session_requirements(session,capability) VALUES(?,'personality')",
                        (session,),
                    )
                    saved["rows"] = db.execute(
                        "SELECT session,capability FROM session_requirements"
                    ).fetchall()
                    db.execute("DROP TABLE session_requirements")

            def restore_guard(_app):
                with sqlite3.connect(database) as db:
                    db.execute("DROP TABLE IF EXISTS session_requirements")
                    db.execute(saved["schema"])
                    db.executemany(
                        "INSERT INTO session_requirements(session,capability) VALUES(?,?)",
                        saved["rows"],
                    )

            try:
                with self.assertRaises(AssertionError) as failure:
                    app.restart(prepare=remove_guard)
                self.assertIn("session admission", str(failure.exception))
                with sqlite3.connect(database) as db:
                    self.assertIsNone(
                        db.execute(
                            "SELECT name FROM sqlite_master WHERE name='session_requirements'"
                        ).fetchone()
                    )
            finally:
                app.restart(prepare=restore_guard)
            with sqlite3.connect(database) as db:
                self.assertEqual(
                    db.execute(
                        "SELECT capability FROM session_requirements WHERE session=?",
                        (session,),
                    ).fetchall(),
                    [("personality",)],
                )

    def test_all_personality_tables_and_used_columns_are_required_for_installation(
        self,
    ):
        provider = Provider(lambda _request: text("done"))
        self.addCleanup(provider.close)
        with Albedo(provider) as app:
            session = app.session()
            database = app.home / "albedo.sqlite"
            columns = {
                "personality_persona": "id,name,state,revision,identity_revision,creation_operation,agent_identity_edits,agent_memory_edits",
                "personality_revision": "persona_id,revision,self_description,values_text,communication,instructions,author,origin_session,reason,created_at",
                "personality_default": "singleton,persona_id",
                "personality_session": "session,persona_id,mode,binding_revision,pre_binding_through,authority",
                "personality_event": "id,persona_id,operation_id,actor,origin_session,event_type,base_revision,head_revision,reason,created_at",
                "personality_operation": "operation_id,request,result,created_at",
                "personality_controls": "persona_id,field_locks",
                "personality_capacity": "persona_id,ordinary_bytes,corrective_bytes,ordinary_limit,corrective_limit,memory_bytes,record_limit",
                "personality_memory": "id,persona_id,revision,lifecycle,importance,tags,temporal_scope,unresolved",
                "personality_memory_revision": "persona_id,memory_id,revision,text,provenance,uncertainty,author,origin_session,event_id,reason,lifecycle,importance,tags,temporal_scope,unresolved",
                "personality_source": "id,persona_id,session,first_seq,last_seq,digest,actors,origin,binding_revision,pre_binding_through,lcm_hint,availability",
                "personality_memory_source": "persona_id,memory_id,revision,source_id,relation",
                "personality_tool_receipt": "persona_id,session,call_id,operation_key,result",
            }
            cases = [
                (
                    table,
                    "table",
                    f"CREATE TABLE {table}(wrong TEXT); INSERT INTO {table}(wrong) VALUES('retained')",
                )
                for table in columns
            ]
            cases += [
                (
                    table,
                    "view",
                    f"CREATE VIEW {table} AS SELECT "
                    + ",".join(f"NULL AS {column}" for column in names.split(","))
                    + " WHERE 0",
                )
                for table, names in columns.items()
            ]
            cases.append(
                (
                    "personality_revision",
                    "table",
                    "CREATE TABLE personality_revision(persona_id TEXT,revision INTEGER,self_description TEXT,values_text TEXT,communication TEXT,instructions TEXT,author TEXT,reason TEXT,created_at INTEGER)",
                )
            )
            for table, kind, sql in cases:
                with self.subTest(table=table, kind=kind, definition=sql):

                    def malformed(_app):
                        with sqlite3.connect(database) as db:
                            for owned in (
                                "personality_memory_source",
                                "personality_memory_revision",
                                "personality_memory",
                                "personality_source",
                                "personality_tool_receipt",
                                "personality_capacity",
                                "personality_controls",
                                "personality_session",
                                "personality_event",
                                "personality_operation",
                                "personality_default",
                                "personality_revision",
                                "personality_persona",
                            ):
                                db.execute(f"DROP TABLE IF EXISTS {owned}")
                            db.executescript(sql)
                            db.execute(
                                "INSERT OR IGNORE INTO session_requirements(session,capability) VALUES(?,'personality')",
                                (session,),
                            )

                    def restore(_app):
                        with sqlite3.connect(database) as db:
                            db.execute(f"DROP {kind.upper()} {table}")

                    try:
                        app.restart(prepare=malformed)
                        with app.api(f"/sessions/{session}") as response:
                            quarantine = json.load(response)["composition"][
                                "quarantine"
                            ]
                        self.assertTrue(
                            any(item["id"] == "personality" for item in quarantine),
                            quarantine,
                        )
                        with sqlite3.connect(database) as db:
                            self.assertEqual(
                                db.execute(
                                    "SELECT type FROM sqlite_master WHERE name=?",
                                    (table,),
                                ).fetchone(),
                                (kind,),
                            )
                            self.assertEqual(
                                db.execute(
                                    "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'personality_%' AND name<>?",
                                    (table,),
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
                            if "wrong TEXT" in sql:
                                self.assertEqual(
                                    db.execute(f"SELECT wrong FROM {table}").fetchall(),
                                    [("retained",)],
                                )
                    finally:
                        app.restart(prepare=restore)
