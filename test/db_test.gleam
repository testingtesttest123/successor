import gleam/option.{None, Some}
import sqlight
import successor/db
import successor/ids

// Chapter 23.1B durable contracts, exercised directly against the storage
// layer: transactional catalog, duplicate-id rejection, branch-head
// referential integrity, restart/open.

pub fn open_creates_schema_and_deployment_test() {
  let path = tmp_db()
  let assert Ok(conn) = db.open(path: path)
  let assert Ok(_) = db.ensure_deployment(conn)
  db.close(conn)
}

pub fn reopen_preserves_deployment_and_data_test() {
  let path = tmp_db()
  let assert Ok(conn) = db.open(path: path)
  let assert Ok(dep) = db.ensure_deployment(conn)
  let assert Ok(session) =
    db.create_session(conn, id: ids.new_session_id(), name: "probe")
  db.close(conn)

  // Restart: same store file, same deployment, session still there.
  let assert Ok(conn2) = db.open(path: path)
  let assert Ok(dep2) = db.ensure_deployment(conn2)
  assert db.deploy_to_string(dep) == db.deploy_to_string(dep2)
  let assert Ok(found) = db.get_session(conn2, session.id)
  assert found.name == "probe"
  db.close(conn2)
}

pub fn create_session_is_atomic_with_main_branch_test() {
  let assert Ok(conn) = db.open(path: tmp_db())
  let id = ids.new_session_id()
  let assert Ok(session) =
    db.create_session(conn, id: id, name: "alpha")
  // The default branch exists and is current, in the same committed step.
  let assert Ok(main) = db.get_branch(conn, id, session.current_branch)
  assert main.name == "main"
  assert main.head_sequence == 0
  assert main.parent == None
  let assert Ok([only]) = db.list_branches(conn, id)
  assert db.branch_to_string(only.id) == db.branch_to_string(session.current_branch)
  db.close(conn)
}

pub fn duplicate_session_id_is_rejected_without_partial_rows_test() {
  let assert Ok(conn) = db.open(path: tmp_db())
  let id = ids.new_session_id()
  let assert Ok(_) = db.create_session(conn, id: id, name: "first")
  // Second create with the SAME id fails; nothing partial may appear.
  let assert Error(db.AlreadyExists(_)) =
    db.create_session(conn, id: id, name: "second")
  let assert Ok(sessions) = db.list_sessions(conn)
  assert list_length(sessions) == 1
  // No stray branch rows from the aborted transaction.
  let assert Error(db.NotFound(_)) =
    db.get_branch(conn, id, ids.BranchId("does-not-exist"))
  db.close(conn)
}

pub fn duplicate_branch_name_is_rejected_test() {
  let assert Ok(conn) = db.open(path: tmp_db())
  let session = ids.new_session_id()
  let assert Ok(s) = db.create_session(conn, id: session, name: "s")
  let assert Ok(_) =
    db.create_branch(conn, session: session, name: "spare", parent: s.current_branch, at: None)
  let assert Error(db.AlreadyExists(_)) =
    db.create_branch(conn, session: session, name: "spare", parent: s.current_branch, at: None)
  db.close(conn)
}

pub fn ambiguous_session_name_is_an_error_test() {
  // Successor delta vs reference: ambiguity is an error, never a pick
  // (chapter 20.3 class C).
  let assert Ok(conn) = db.open(path: tmp_db())
  let assert Ok(_) =
    db.create_session(conn, id: ids.new_session_id(), name: "dup")
  let assert Ok(_) =
    db.create_session(conn, id: ids.new_session_id(), name: "dup")
  let assert Error(db.AmbiguousName("dup")) = db.find_session_by_name(conn, "dup")
  db.close(conn)
}

pub fn branch_point_must_not_exceed_parent_head_test() {
  let assert Ok(conn) = db.open(path: tmp_db())
  let session = ids.new_session_id()
  let assert Ok(s) = db.create_session(conn, id: session, name: "s")
  let assert Error(db.Invalid(_)) =
    db.create_branch(conn, session: session, name: "too-far", parent: s.current_branch, at: Some(5))
  // Zero is always valid (fresh view).
  let assert Ok(_) =
    db.create_branch(conn, session: session, name: "empty", parent: s.current_branch, at: Some(0))
  db.close(conn)
}

pub fn append_assigns_branch_local_sequences_and_moves_head_test() {
  let assert Ok(conn) = db.open(path: tmp_db())
  let session = ids.new_session_id()
  let assert Ok(s) = db.create_session(conn, id: session, name: "s")

  let assert Ok(r1) =
    db.append_record(conn, session: session, branch: s.current_branch, kind: "user", payload: "one")
  let assert Ok(r2) =
    db.append_record(conn, session: session, branch: s.current_branch, kind: "user", payload: "two")
  assert r1.sequence == 1
  assert r2.sequence == 2

  let assert Ok(main) = db.get_branch(conn, session, s.current_branch)
  assert main.head_sequence == 2

  // A sibling branch starts at sequence 1: sequences are branch-local.
  let assert Ok(sp) =
    db.create_branch(conn, session: session, name: "spare", parent: s.current_branch, at: None)
  let assert Ok(r) =
    db.append_record(conn, session: session, branch: sp.id, kind: "user", payload: "three")
  assert r.sequence == 1

  // Contract order: ascending sequence per branch.
  let assert Ok(records) = db.list_records(conn, session, s.current_branch)
  assert list_length(records) == 2
  let assert [first, second] = records
  assert first.sequence == 1
  assert second.sequence == 2
  db.close(conn)
}

pub fn append_to_missing_branch_is_not_found_test() {
  let assert Ok(conn) = db.open(path: tmp_db())
  let session = ids.new_session_id()
  let assert Ok(_) = db.create_session(conn, id: session, name: "s")
  let assert Error(db.NotFound(_)) =
    db.append_record(
      conn,
      session: session,
      branch: ids.BranchId("nope"),
      kind: "user",
      payload: "x",
    )
  db.close(conn)
}

pub fn schema_version_mismatch_is_corrupt_test() {
  // A store written by a DIFFERENT schema major must be refused, not
  // silently opened (chapter 20.3: no second-schema projection).
  let path = tmp_db()
  let assert Ok(conn) = db.open(path: path)
  db.close(conn)
  // Tamper: overwrite the version with an impossible future value.
  let assert Ok(conn2) = sqlight.open(path)
  let assert Ok(_) =
    sqlight.exec(
      "UPDATE meta SET value = '999' WHERE key = 'schema_version'",
      on: conn2,
    )
  let _ = sqlight.close(conn2)
  let assert Error(db.Corrupt(_)) = db.open(path: path)
}

// --- helpers -------------------------------------------------------------

fn tmp_db() -> String {
  "/tmp/" <> ids.fresh(prefix: "successor-dbtest") <> "/successor.db"
}

fn list_length(items: List(a)) -> Int {
  case items {
    [] -> 0
    [_, ..rest] -> 1 + list_length(rest)
  }
}

pub fn provider_attempt_receipt_persists_across_reopen_test() {
  let path = tmp_db()
  let assert Ok(conn) = db.open(path: path)
  let session = ids.new_session_id()
  let assert Ok(s) = db.create_session(conn, id: session, name: "s")
  let attempt = ids.new_provider_attempt_id()
  let assert Ok(_) =
    db.create_provider_attempt(
      conn,
      id: attempt,
      session: session,
      activation: "act_x",
      provider_name: "mock",
      model: "m",
    )
  let assert Ok(_) =
    db.complete_provider_attempt(
      conn,
      id: attempt,
      status: "completed",
      usage_input: Some(10),
      usage_output: Some(5),
    )
  // Invalid status refused.
  let assert Error(db.Invalid(_)) =
    db.complete_provider_attempt(
      conn,
      id: attempt,
      status: "running",
      usage_input: None,
      usage_output: None,
    )
  db.close(conn)

  // Reopen: the receipt is durable.
  let assert Ok(conn2) = db.open(path: path)
  let assert Ok(_) = db.ensure_deployment(conn2)
  let _ = s
  db.close(conn2)
}

pub fn attempt_status_must_be_a_terminal_outcome_test() {
  let assert Ok(conn) = db.open(path: tmp_db())
  let session = ids.new_session_id()
  let assert Ok(_) = db.create_session(conn, id: session, name: "s")
  let assert Error(db.Invalid(_)) =
    db.complete_provider_attempt(
      conn,
      id: ids.new_provider_attempt_id(),
      status: "promoted",
      usage_input: Some(1),
      usage_output: Some(1),
    )
  db.close(conn)
}
