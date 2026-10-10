import gleam/dynamic/decode
import gleam/option.{None, Some}
import sqlight
import successor/db
import successor/ids
import successor/workspace_store
import successor/workspace_types.{
  type AgentWorkspace, Cell, Failed, Intent, OutcomeUnknown, Succeeded,
}

pub fn root_identity_is_stable_and_children_are_independent_test() {
  let assert Ok(conn) = db.open(path: tmp_db())
  let session = ids.new_session_id()
  let assert Ok(_) = db.create_session(conn, id: session, name: "session")
  let assert Ok(root) =
    workspace_store.ensure_root_workspace(conn, session, "root")
  let assert Ok(same) =
    workspace_store.ensure_root_workspace(conn, session, "renamed-ignored")
  assert root.id == same.id
  assert same.name == "root"
  assert root.parent == None

  let assert Ok(first) =
    workspace_store.create_child_workspace(conn, root.id, "duplicate-label")
  let assert Ok(second) =
    workspace_store.create_child_workspace(conn, root.id, "duplicate-label")
  assert first.id != second.id
  assert first.parent == Some(root.id)
  assert second.parent == Some(root.id)
  assert first.session == root.session
  assert second.session == root.session
  db.close(conn)
}

pub fn foreign_keys_are_enabled_and_missing_session_root_is_refused_test() {
  let path = tmp_db()
  let assert Ok(conn) = db.open(path: path)
  assert foreign_keys_enabled(conn)
  let assert Error(_) =
    workspace_store.ensure_root_workspace(
      conn,
      ids.SessionId("missing-session"),
      "orphan",
    )
  db.close(conn)

  let assert Ok(reopened) = db.open(path: path)
  assert foreign_keys_enabled(reopened)
  let assert Error(_) =
    workspace_store.ensure_root_workspace(
      reopened,
      ids.SessionId("still-missing"),
      "orphan",
    )
  db.close(reopened)
}

pub fn begin_and_settle_are_fenced_compare_and_set_test() {
  let assert Ok(conn) = db.open(path: tmp_db())
  let root = root(conn)
  let inc1 = ids.new_agent_incarnation_id()
  let assert Ok(Nil) = workspace_store.activate_workspace(conn, root.id, inc1)
  let intent =
    Cell("cell-1", root.id, inc1, "print('raw')", Intent, "", False, None)
  let assert Ok(Nil) = workspace_store.begin_cell(conn, intent)

  // Globally duplicate id and one-active-intent both refuse without mutation.
  let assert Error(_) = workspace_store.begin_cell(conn, intent)
  let other = Cell("cell-2", root.id, inc1, "2", Intent, "", False, None)
  let assert Error(_) = workspace_store.begin_cell(conn, other)

  // Source is part of the durable dispatch identity.
  let mismatch =
    Cell("cell-1", root.id, inc1, "different", Succeeded, "bad", False, None)
  let assert Error(_) = workspace_store.settle_cell(conn, mismatch)
  let assert Ok(still_intent) = workspace_store.get_cell(conn, "cell-1")
  assert still_intent.state == Intent
  assert still_intent.source == "print('raw')"
  assert still_intent.output == ""

  let settled =
    Cell(
      "cell-1",
      root.id,
      inc1,
      "print('raw')",
      Succeeded,
      "raw\n",
      True,
      None,
    )
  let assert Ok(Nil) = workspace_store.settle_cell(conn, settled)
  // Duplicate acknowledgement ambiguity is inspection-only, never overwrite.
  let duplicate =
    Cell(
      "cell-1",
      root.id,
      inc1,
      "print('raw')",
      Failed,
      "overwrite",
      False,
      Some("x"),
    )
  let assert Error(_) = workspace_store.settle_cell(conn, duplicate)
  let assert Ok(saved) = workspace_store.get_cell(conn, "cell-1")
  assert saved.state == Succeeded
  assert saved.output == "raw\n"
  assert saved.truncated
  assert saved.error == None
  db.close(conn)
}

pub fn activation_marks_unresolved_intent_unknown_and_stale_settle_refuses_test() {
  let assert Ok(conn) = db.open(path: tmp_db())
  let root = root(conn)
  let inc1 = ids.new_agent_incarnation_id()
  let inc2 = ids.new_agent_incarnation_id()
  let assert Ok(Nil) = workspace_store.activate_workspace(conn, root.id, inc1)
  let intent =
    Cell("uncertain", root.id, inc1, "side_effect()", Intent, "", False, None)
  let assert Ok(Nil) = workspace_store.begin_cell(conn, intent)
  let assert Ok(Nil) = workspace_store.activate_workspace(conn, root.id, inc2)

  let assert Ok(unknown) = workspace_store.get_cell(conn, "uncertain")
  assert unknown.state == OutcomeUnknown
  assert unknown.source == "side_effect()"
  assert unknown.output == ""
  let stale =
    Cell(
      "uncertain",
      root.id,
      inc1,
      "side_effect()",
      Succeeded,
      "late",
      False,
      None,
    )
  let assert Error(_) = workspace_store.settle_cell(conn, stale)
  let assert Ok(unchanged) = workspace_store.get_cell(conn, "uncertain")
  assert unchanged.state == OutcomeUnknown
  assert unchanged.output == ""

  let current = Cell("current", root.id, inc2, "3", Intent, "", False, None)
  let assert Ok(Nil) = workspace_store.begin_cell(conn, current)
  let done =
    Cell("current", root.id, inc2, "3", Failed, "trace", False, Some("boom"))
  let assert Ok(Nil) = workspace_store.settle_cell(conn, done)
  let assert Ok([first, second]) = workspace_store.list_cells(conn, root.id)
  assert first.id == "uncertain"
  assert second.id == "current"
  db.close(conn)
}

pub fn startup_recovery_marks_intents_unknown_and_clears_fences_test() {
  let assert Ok(conn) = db.open(path: tmp_db())
  let root = root(conn)
  let incarnation = ids.new_agent_incarnation_id()
  let assert Ok(Nil) =
    workspace_store.activate_workspace(conn, root.id, incarnation)
  let completed_intent =
    Cell(
      "completed",
      root.id,
      incarnation,
      "kept source",
      Intent,
      "",
      False,
      None,
    )
  let assert Ok(Nil) = workspace_store.begin_cell(conn, completed_intent)
  let assert Ok(Nil) =
    workspace_store.settle_cell(
      conn,
      Cell(
        "completed",
        root.id,
        incarnation,
        "kept source",
        Succeeded,
        "kept output",
        False,
        None,
      ),
    )
  let unresolved =
    Cell(
      "unresolved",
      root.id,
      incarnation,
      "never replay",
      Intent,
      "",
      False,
      None,
    )
  let assert Ok(Nil) = workspace_store.begin_cell(conn, unresolved)

  let assert Ok(Nil) = workspace_store.recover(conn)
  let assert Ok(recovered_workspace) =
    workspace_store.get_workspace(conn, root.id)
  assert recovered_workspace.incarnation == None
  let assert Ok(completed) = workspace_store.get_cell(conn, "completed")
  assert completed.state == Succeeded
  assert completed.source == "kept source"
  assert completed.output == "kept output"
  let assert Ok(unknown) = workspace_store.get_cell(conn, "unresolved")
  assert unknown.state == OutcomeUnknown
  assert unknown.source == "never replay"
  assert unknown.output == ""
  // Idempotent on another startup; terminal classifications are preserved.
  let assert Ok(Nil) = workspace_store.recover(conn)
  let assert Ok(still_unknown) = workspace_store.get_cell(conn, "unresolved")
  assert still_unknown.state == OutcomeUnknown
  db.close(conn)
}

pub fn wrong_agent_and_noncurrent_incarnation_are_rejected_test() {
  let assert Ok(conn) = db.open(path: tmp_db())
  let root = root(conn)
  let assert Ok(child) =
    workspace_store.create_child_workspace(conn, root.id, "child")
  let root_inc = ids.new_agent_incarnation_id()
  let child_inc = ids.new_agent_incarnation_id()
  let assert Ok(Nil) =
    workspace_store.activate_workspace(conn, root.id, root_inc)
  let assert Ok(Nil) =
    workspace_store.activate_workspace(conn, child.id, child_inc)
  let assert Error(_) =
    workspace_store.begin_cell(
      conn,
      Cell("wrong-fence", root.id, child_inc, "x", Intent, "", False, None),
    )
  let assert Ok(Nil) =
    workspace_store.begin_cell(
      conn,
      Cell("owned", root.id, root_inc, "x", Intent, "", False, None),
    )
  let assert Error(_) =
    workspace_store.settle_cell(
      conn,
      Cell("owned", child.id, child_inc, "x", Succeeded, "bad", False, None),
    )
  let assert Ok(saved) = workspace_store.get_cell(conn, "owned")
  assert saved.state == Intent
  db.close(conn)
}

pub fn genuine_v1_upgrade_preserves_canonical_history_test() {
  let path = tmp_db()
  let assert Ok(conn) = db.open(path: path)
  let session = ids.new_session_id()
  let assert Ok(created) = db.create_session(conn, id: session, name: "kept")
  let assert Ok(record) =
    db.append_record(
      conn,
      session: session,
      branch: created.current_branch,
      kind: "user",
      payload: "canonical payload",
    )
  // Reconstruct the exact pre-workspace schema while retaining all old rows.
  let assert Ok(_) = sqlight.exec("DROP TABLE workspace_cells", on: conn)
  let assert Ok(_) = sqlight.exec("DROP TABLE agent_workspaces", on: conn)
  let assert Ok(_) =
    sqlight.exec(
      "UPDATE meta SET value = '1' WHERE key = 'schema_version'",
      on: conn,
    )
  db.close(conn)

  let assert Ok(upgraded) = db.open(path: path)
  let assert Ok(found) = db.get_session(upgraded, session)
  assert found.name == "kept"
  let assert Ok([kept]) =
    db.list_records(upgraded, session, created.current_branch)
  assert kept.id == record.id
  assert kept.payload == "canonical payload"
  let assert Ok(workspace) =
    workspace_store.ensure_root_workspace(upgraded, session, "root")
  assert workspace.session == session
  db.close(upgraded)
}

pub fn nonempty_database_without_meta_is_refused_byte_for_byte_test() {
  // Raw sqlight.open does not create a parent directory (unlike db.open).
  let path = "/tmp/" <> ids.fresh(prefix: "successor-partial-store") <> ".db"
  let assert Ok(conn) = sqlight.open(path)
  let assert Ok(_) = sqlight.exec("CREATE TABLE partial (bad TEXT)", on: conn)
  let _ = sqlight.close(conn)
  let before = file_bytes(path)
  let assert Error(db.Corrupt(_)) = db.open(path: path)
  assert file_bytes(path) == before
}

pub fn weak_workspace_cells_constraints_are_refused_byte_for_byte_test() {
  let path = tmp_db()
  let assert Ok(conn) = db.open(path: path)
  let assert Ok(_) = sqlight.exec("DROP TABLE workspace_cells", on: conn)
  let assert Ok(_) =
    sqlight.exec(
      "CREATE TABLE workspace_cells (
        sequence INTEGER,
        id TEXT,
        agent_id TEXT,
        incarnation_id TEXT,
        source TEXT,
        state TEXT,
        output TEXT,
        truncated INTEGER,
        error TEXT,
        created_at_ms INTEGER,
        settled_at_ms INTEGER
      );
      CREATE UNIQUE INDEX one_workspace_intent_per_agent
        ON workspace_cells(agent_id) WHERE state = 'intent';
      CREATE INDEX workspace_cells_by_agent_sequence
        ON workspace_cells(agent_id, sequence);",
      on: conn,
    )
  db.close(conn)
  let before = file_bytes(path)
  let assert Error(db.Corrupt(_)) = db.open(path: path)
  assert file_bytes(path) == before
}

pub fn changed_quoted_workspace_state_literal_is_refused_byte_for_byte_test() {
  let path = tmp_db()
  let assert Ok(conn) = db.open(path: path)
  let assert Ok(_) = sqlight.exec("DROP TABLE workspace_cells", on: conn)
  let assert Ok(_) =
    sqlight.exec(
      "CREATE TABLE workspace_cells (
        sequence INTEGER PRIMARY KEY AUTOINCREMENT,
        id TEXT NOT NULL UNIQUE,
        agent_id TEXT NOT NULL REFERENCES agent_workspaces(id),
        incarnation_id TEXT NOT NULL,
        source TEXT NOT NULL,
        state TEXT NOT NULL CHECK (state IN ('Intent', 'succeeded', 'failed', 'outcome_unknown')),
        output TEXT NOT NULL,
        truncated INTEGER NOT NULL CHECK (truncated IN (0, 1)),
        error TEXT,
        created_at_ms INTEGER NOT NULL,
        settled_at_ms INTEGER
      );
      CREATE UNIQUE INDEX one_workspace_intent_per_agent
        ON workspace_cells(agent_id) WHERE state = 'intent';
      CREATE INDEX workspace_cells_by_agent_sequence
        ON workspace_cells(agent_id, sequence);",
      on: conn,
    )
  db.close(conn)
  let before = file_bytes(path)
  let assert Error(db.Corrupt(_)) = db.open(path: path)
  assert file_bytes(path) == before
}

pub fn weak_agent_workspace_constraints_are_refused_byte_for_byte_test() {
  let path = tmp_db()
  let assert Ok(conn) = db.open(path: path)
  let assert Ok(_) = sqlight.exec("PRAGMA foreign_keys = OFF", on: conn)
  let assert Ok(_) = sqlight.exec("DROP TABLE agent_workspaces", on: conn)
  let assert Ok(_) =
    sqlight.exec(
      "CREATE TABLE agent_workspaces (
        id TEXT,
        session_id TEXT,
        parent_id TEXT,
        name TEXT,
        incarnation_id TEXT,
        created_at_ms INTEGER
      );
      CREATE UNIQUE INDEX one_root_workspace_per_session
        ON agent_workspaces(session_id) WHERE parent_id IS NULL;
      CREATE INDEX agent_workspaces_by_parent ON agent_workspaces(parent_id);",
      on: conn,
    )
  db.close(conn)
  let before = file_bytes(path)
  let assert Error(db.Corrupt(_)) = db.open(path: path)
  assert file_bytes(path) == before
}

pub fn weak_valid_column_v1_table_is_refused_byte_for_byte_test() {
  let path = tmp_db()
  let assert Ok(conn) = db.open(path: path)
  let assert Ok(_) = sqlight.exec("DROP TABLE workspace_cells", on: conn)
  let assert Ok(_) = sqlight.exec("DROP TABLE agent_workspaces", on: conn)
  let assert Ok(_) = sqlight.exec("DROP TABLE effects", on: conn)
  let assert Ok(_) =
    sqlight.exec(
      "CREATE TABLE effects (
        id TEXT,
        session_id TEXT,
        tool_call_id TEXT,
        kind TEXT,
        status TEXT,
        receipt TEXT,
        created_at_ms INTEGER
      )",
      on: conn,
    )
  let assert Ok(_) =
    sqlight.exec(
      "UPDATE meta SET value = '1' WHERE key = 'schema_version'",
      on: conn,
    )
  db.close(conn)
  let before = file_bytes(path)
  let assert Error(db.Corrupt(_)) = db.open(path: path)
  assert file_bytes(path) == before
}

pub fn false_root_partial_index_is_refused_byte_for_byte_test() {
  let path = tmp_db()
  let assert Ok(conn) = db.open(path: path)
  let assert Ok(_) =
    sqlight.exec("DROP INDEX one_root_workspace_per_session", on: conn)
  let assert Ok(_) =
    sqlight.exec(
      "CREATE UNIQUE INDEX one_root_workspace_per_session
        ON agent_workspaces(session_id) WHERE parent_id IS NULL AND 0",
      on: conn,
    )
  db.close(conn)
  let before = file_bytes(path)
  let assert Error(db.Corrupt(_)) = db.open(path: path)
  assert file_bytes(path) == before
}

pub fn false_intent_partial_index_is_refused_byte_for_byte_test() {
  let path = tmp_db()
  let assert Ok(conn) = db.open(path: path)
  let assert Ok(_) =
    sqlight.exec("DROP INDEX one_workspace_intent_per_agent", on: conn)
  let assert Ok(_) =
    sqlight.exec(
      "CREATE UNIQUE INDEX one_workspace_intent_per_agent
        ON workspace_cells(agent_id) WHERE state = 'intent' AND 0",
      on: conn,
    )
  db.close(conn)
  let before = file_bytes(path)
  let assert Error(db.Corrupt(_)) = db.open(path: path)
  assert file_bytes(path) == before
}

pub fn malformed_v1_columns_are_refused_byte_for_byte_test() {
  let path = tmp_db()
  let assert Ok(conn) = db.open(path: path)
  let assert Ok(_) = sqlight.exec("DROP TABLE deployments", on: conn)
  let assert Ok(_) =
    sqlight.exec("CREATE TABLE deployments (bad TEXT)", on: conn)
  let assert Ok(_) =
    sqlight.exec(
      "UPDATE meta SET value = '1' WHERE key = 'schema_version'",
      on: conn,
    )
  db.close(conn)
  let before = file_bytes(path)
  let assert Error(db.Corrupt(_)) = db.open(path: path)
  assert file_bytes(path) == before
}

pub fn malformed_v2_workspace_table_is_refused_byte_for_byte_test() {
  let path = tmp_db()
  let assert Ok(conn) = db.open(path: path)
  let assert Ok(_) = sqlight.exec("DROP TABLE workspace_cells", on: conn)
  db.close(conn)
  let before = file_bytes(path)
  let assert Error(db.Corrupt(_)) = db.open(path: path)
  assert file_bytes(path) == before
}

pub fn missing_v2_workspace_index_is_refused_byte_for_byte_test() {
  let path = tmp_db()
  let assert Ok(conn) = db.open(path: path)
  let assert Ok(_) =
    sqlight.exec("DROP INDEX workspace_cells_by_agent_sequence", on: conn)
  db.close(conn)
  let before = file_bytes(path)
  let assert Error(db.Corrupt(_)) = db.open(path: path)
  assert file_bytes(path) == before
}

pub fn failed_v1_migration_rolls_back_version_test() {
  let path = tmp_db()
  let assert Ok(conn) = db.open(path: path)
  // A conflicting table makes schema creation fail after BEGIN IMMEDIATE.
  let assert Ok(_) = sqlight.exec("DROP TABLE workspace_cells", on: conn)
  let assert Ok(_) = sqlight.exec("DROP TABLE agent_workspaces", on: conn)
  let assert Ok(_) =
    sqlight.exec("CREATE TABLE agent_workspaces (bad TEXT)", on: conn)
  let assert Ok(_) =
    sqlight.exec(
      "UPDATE meta SET value = '1' WHERE key = 'schema_version'",
      on: conn,
    )
  db.close(conn)
  let assert Error(db.Corrupt(_)) = db.open(path: path)

  let assert Ok(inspect) = sqlight.open(path)
  let assert Ok([version]) =
    sqlight.query(
      "SELECT value FROM meta WHERE key = 'schema_version'",
      on: inspect,
      with: [],
      expecting: decode.at([0], decode.string),
    )
  assert version == "1"
  let _ = sqlight.close(inspect)
}

pub fn future_schema_refuses_before_mutation_test() {
  let path = tmp_db()
  let assert Ok(conn) = db.open(path: path)
  let assert Ok(_) =
    sqlight.exec(
      "UPDATE meta SET value = '3' WHERE key = 'schema_version'",
      on: conn,
    )
  db.close(conn)
  let before = file_bytes(path)
  let assert Error(db.Corrupt(_)) = db.open(path: path)
  assert file_bytes(path) == before
  let assert Ok(inspect) = sqlight.open(path)
  let assert Ok([version]) =
    sqlight.query(
      "SELECT value FROM meta WHERE key = 'schema_version'",
      on: inspect,
      with: [],
      expecting: decode.at([0], decode.string),
    )
  assert version == "3"
  let _ = sqlight.close(inspect)
}

fn root(conn: sqlight.Connection) -> AgentWorkspace {
  let session = ids.new_session_id()
  let assert Ok(_) = db.create_session(conn, id: session, name: "session")
  let assert Ok(workspace) =
    workspace_store.ensure_root_workspace(conn, session, "root")
  workspace
}

fn foreign_keys_enabled(conn: sqlight.Connection) -> Bool {
  let assert Ok([enabled]) =
    sqlight.query(
      "PRAGMA foreign_keys",
      on: conn,
      with: [],
      expecting: decode.at([0], decode.int),
    )
  enabled == 1
}

fn file_bytes(path: String) -> BitArray {
  let assert Ok(bytes) = read_file(path)
  bytes
}

@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(BitArray, Nil)

fn tmp_db() -> String {
  "/tmp/" <> ids.fresh(prefix: "successor-workspace-test") <> "/successor.db"
}
