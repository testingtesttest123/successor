//// Deployment/session/branch/record storage over SQLite (chapter 23.1B).
////
//// Pure functions over an open connection, so the durable contracts —
//// transaction interruption, duplicate-id rejection, branch-head referential
//// integrity, restart/open — are testable without the actor around them.
////
//// Ownership model: each record is owned by exactly one branch; a branch's
//// `head_sequence` is the sequence of its last owned record (0 for a fresh
//// view branch). Sequences are branch-local and assigned under a write
//// transaction, so two writers can never interleave a head update.

import gleam/dynamic/decode
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sqlight
import successor/config.{schema_version}
import successor/ids.{
  type BranchId, type DeploymentId, type ProviderAttemptId, type SessionId,
  BranchId, DeploymentId, SessionId,
}
import successor/logging

pub type StoreError {
  /// The database could not be opened or created.
  OpenFailed(String)
  /// The database exists but is not a store we can use (schema version
  /// mismatch, missing tables, unreadable metadata).
  Corrupt(String)
  /// A row with the same identity already exists.
  AlreadyExists(String)
  /// A referenced identity does not exist.
  NotFound(String)
  /// The caller violated a contract (empty name, bad branch point, ...).
  Invalid(String)
  /// Ambiguity is an error, never a silent pick (chapter 20.3 class C).
  AmbiguousName(String)
}

pub type Session {
  Session(
    id: SessionId,
    name: String,
    created_at_ms: Int,
    current_branch: BranchId,
  )
}

pub type Branch {
  Branch(
    id: BranchId,
    session: SessionId,
    name: String,
    parent: Option(BranchId),
    branch_point: Option(Int),
    head_sequence: Int,
  )
}

pub type Record {
  Record(
    id: String,
    session: SessionId,
    branch: BranchId,
    sequence: Int,
    kind: String,
    payload: String,
    created_at_ms: Int,
  )
}

const ddl = "
CREATE TABLE IF NOT EXISTS meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS deployments (
  id TEXT PRIMARY KEY,
  created_at_ms INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS sessions (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  created_at_ms INTEGER NOT NULL,
  current_branch_id TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS branches (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions(id),
  name TEXT NOT NULL,
  parent_id TEXT REFERENCES branches(id),
  branch_point INTEGER,
  head_sequence INTEGER NOT NULL DEFAULT 0,
  created_at_ms INTEGER NOT NULL,
  UNIQUE (session_id, name)
);
CREATE TABLE IF NOT EXISTS records (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions(id),
  branch_id TEXT NOT NULL REFERENCES branches(id),
  sequence INTEGER NOT NULL,
  kind TEXT NOT NULL,
  payload TEXT NOT NULL,
  created_at_ms INTEGER NOT NULL,
  UNIQUE (session_id, branch_id, sequence)
);
CREATE TABLE IF NOT EXISTS namespaced_state (
  session_id TEXT NOT NULL REFERENCES sessions(id),
  namespace TEXT NOT NULL,
  key TEXT NOT NULL,
  value TEXT NOT NULL,
  PRIMARY KEY (session_id, namespace, key)
);
CREATE TABLE IF NOT EXISTS provider_attempts (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions(id),
  activation_id TEXT NOT NULL,
  provider TEXT NOT NULL,
  model TEXT NOT NULL,
  status TEXT NOT NULL,
  usage_input INTEGER,
  usage_output INTEGER,
  started_at_ms INTEGER NOT NULL,
  finished_at_ms INTEGER
);
CREATE TABLE IF NOT EXISTS effects (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions(id),
  tool_call_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  status TEXT NOT NULL,
  receipt TEXT,
  created_at_ms INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS blobs (
  hash TEXT PRIMARY KEY,
  content BLOB NOT NULL
);
"

/// Open (creating if needed) the store at `path` and prepare the schema.
/// Reopening an existing store must yield the identical durable view.
pub fn open(path path: String) -> Result(sqlight.Connection, StoreError) {
  ensure_parent_dir(path)
  use conn <- result.try(
    sqlight.open(path) |> result.map_error(fn(e) { OpenFailed(describe(e)) }),
  )
  case sqlight.exec(ddl, on: conn) {
    Error(e) -> {
      let _ = sqlight.close(conn)
      Error(OpenFailed(describe(e)))
    }
    Ok(_) ->
      case check_and_set_schema_version(conn) {
        Ok(_) ->
          case ensure_deployment(conn) {
            Ok(deployment) -> {
              logging.info(
                name: "store.open",
                fields: [
                  logging.field("path", path),
                  logging.field("deployment", deploy_to_string(deployment)),
                ],
              )
              Ok(conn)
            }
            Error(e) -> {
              let _ = sqlight.close(conn)
              Error(e)
            }
          }
        Error(e) -> {
          let _ = sqlight.close(conn)
          Error(e)
        }
      }
  }
}

pub fn close(conn: sqlight.Connection) -> Nil {
  let _ = sqlight.close(conn)
  Nil
}

fn check_and_set_schema_version(
  conn: sqlight.Connection,
) -> Result(Nil, StoreError) {
  let found =
    sqlight.query(
      "SELECT value FROM meta WHERE key = 'schema_version'",
      on: conn,
      with: [],
      expecting: decode.at([0], decode.string),
    )
  case found {
    Ok([v]) ->
      case v == int.to_string(schema_version) {
        True -> Ok(Nil)
        False ->
          Error(Corrupt(
            "schema version " <> v <> ", expected "
            <> int.to_string(schema_version),
          ))
      }
    Ok([]) ->
      case
        sqlight.exec(
          "INSERT INTO meta (key, value) VALUES ('schema_version', '"
          <> int.to_string(schema_version)
          <> "')",
          on: conn,
        )
      {
        Ok(_) -> Ok(Nil)
        Error(e) -> Error(Corrupt(describe(e)))
      }
    Ok(_) -> Error(Corrupt("duplicate schema_version rows"))
    Error(e) -> Error(Corrupt(describe(e)))
  }
}

/// Exactly one deployment per host (chapter 20.8). Created on first boot and
/// durable afterwards: a restart must report the same deployment identity.
pub fn ensure_deployment(
  conn: sqlight.Connection,
) -> Result(DeploymentId, StoreError) {
  let existing =
    sqlight.query(
      "SELECT id FROM deployments ORDER BY created_at_ms LIMIT 2",
      on: conn,
      with: [],
      expecting: decode.at([0], decode.string),
    )
  case existing {
    Ok([id]) -> Ok(DeploymentId(id))
    Ok([]) -> {
      let id = ids.new_deployment_id()
      insert_deployment(conn, id)
    }
    Ok(_) -> Error(Corrupt("more than one deployment row"))
    Error(e) -> Error(OpenFailed(describe(e)))
  }
}

pub fn insert_deployment(
  conn: sqlight.Connection,
  id: DeploymentId,
) -> Result(DeploymentId, StoreError) {
  case
    sqlight.query(
      "INSERT INTO deployments (id, created_at_ms) VALUES (?, ?)",
      on: conn,
      with: [sqlight.text(deploy_to_string(id)), sqlight.int(logging.now_ms())],
      expecting: decode.dynamic,
    )
  {
    Ok(_) -> Ok(id)
    Error(e) -> Error(map_insert_error(e, "deployment"))
  }
}

/// Create a session and its default `main` branch in ONE transaction:
/// the catalog is never observable half-made (chapter 23.1B).
pub fn create_session(
  conn: sqlight.Connection,
  id id: SessionId,
  name name: String,
) -> Result(Session, StoreError) {
  case name {
    "" -> Error(Invalid("session name must not be empty"))
    _ -> {
      case tx_begin(conn) {
        Error(e) -> Error(e)
        Ok(_) -> {
          let created = logging.now_ms()
          let branch_id = ids.new_branch_id()
          case
            insert_session_tx(conn, id, name, created)
            |> result.try(fn(_) {
              insert_branch_tx(
                conn,
                Branch(
                  id: branch_id,
                  session: id,
                  name: "main",
                  parent: None,
                  branch_point: None,
                  head_sequence: 0,
                ),
              )
            })
            |> result.try(fn(_) { set_current_branch_tx(conn, id, branch_id) })
          {
            Ok(_) ->
              case tx_commit(conn) {
                Ok(_) ->
                  Ok(Session(
                    id: id,
                    name: name,
                    created_at_ms: created,
                    current_branch: branch_id,
                  ))
                Error(e) -> {
                  rollback(conn)
                  Error(e)
                }
              }
            Error(e) -> {
              rollback(conn)
              Error(e)
            }
          }
        }
      }
    }
  }
}

/// Create a branch. `at` is the branch point in the PARENT's numbering; the
/// new branch's head equals the branch point (inherited view) or 0 for an
/// empty root. The parent must exist and the point must not exceed its head.
pub fn create_branch(
  conn: sqlight.Connection,
  session session: SessionId,
  name name: String,
  parent parent: BranchId,
  at at: Option(Int),
) -> Result(Branch, StoreError) {
  case name {
    "" -> Error(Invalid("branch name must not be empty"))
    _ ->
      case get_branch(conn, session, parent) {
        Error(e) -> Error(e)
        Ok(parent_branch) ->
          case validate_branch_point(parent_branch, at) {
            Error(e) -> Error(e)
            Ok(head) -> {
              let id = ids.new_branch_id()
              insert_branch(
                conn,
                Branch(
                  id: id,
                  session: session,
                  name: name,
                  parent: Some(parent),
                  branch_point: at,
                  head_sequence: head,
                ),
              )
            }
          }
      }
  }
}

/// A branch point beyond the parent's head would reference a record that does
/// not exist: branch-head referential integrity (chapter 23.1B).
fn validate_branch_point(
  parent: Branch,
  at: Option(Int),
) -> Result(Int, StoreError) {
  case at {
    None -> Ok(0)
    Some(point) ->
      case point >= 0 && point <= parent.head_sequence {
        True -> Ok(point)
        False ->
          Error(Invalid(
            "branch point " <> int.to_string(point)
            <> " exceeds parent head "
            <> int.to_string(parent.head_sequence),
          ))
      }
  }
}

/// Append a record to a branch and move that branch's head in the same
/// transaction. The sequence is branch-local and assigned here, so a crash
/// between the append and the head update is impossible by construction.
pub fn append_record(
  conn: sqlight.Connection,
  session session: SessionId,
  branch branch: BranchId,
  kind kind: String,
  payload payload: String,
) -> Result(Record, StoreError) {
  case tx_begin(conn) {
    Error(e) -> Error(e)
    Ok(_) ->
      case append_record_tx(conn, session, branch, kind, payload) {
        Ok(record) ->
          case tx_commit(conn) {
            Ok(_) -> Ok(record)
            Error(e) -> {
              rollback(conn)
              Error(e)
            }
          }
        Error(e) -> {
          rollback(conn)
          Error(e)
        }
      }
  }
}

fn append_record_tx(
  conn: sqlight.Connection,
  session: SessionId,
  branch: BranchId,
  kind: String,
  payload: String,
) -> Result(Record, StoreError) {
  case get_branch(conn, session, branch) {
    Error(e) -> Error(e)
    Ok(b) -> {
      let sequence = b.head_sequence + 1
      let id = ids.fresh(prefix: "rec")
      let created = logging.now_ms()
      case
        sqlight.query(
          "INSERT INTO records (id, session_id, branch_id, sequence, kind, payload, created_at_ms)
           VALUES (?, ?, ?, ?, ?, ?, ?)",
          on: conn,
          with: [
            sqlight.text(id),
            sqlight.text(session_to_string(session)),
            sqlight.text(branch_to_string(branch)),
            sqlight.int(sequence),
            sqlight.text(kind),
            sqlight.text(payload),
            sqlight.int(created),
          ],
          expecting: decode.dynamic,
        )
      {
        Error(e) -> Error(map_insert_error(e, "record"))
        Ok(_) ->
          case
            sqlight.query(
              "UPDATE branches SET head_sequence = ? WHERE id = ? AND session_id = ?",
              on: conn,
              with: [
                sqlight.int(sequence),
                sqlight.text(branch_to_string(branch)),
                sqlight.text(session_to_string(session)),
              ],
              expecting: decode.dynamic,
            )
          {
            Ok(_) ->
              Ok(Record(
                id: id,
                session: session,
                branch: branch,
                sequence: sequence,
                kind: kind,
                payload: payload,
                created_at_ms: created,
              ))
            Error(e) -> Error(OpenFailed(describe(e)))
          }
      }
    }
  }
}

pub fn get_session(
  conn: sqlight.Connection,
  id: SessionId,
) -> Result(Session, StoreError) {
  let rows =
    sqlight.query(
      "SELECT id, name, created_at_ms, current_branch_id FROM sessions WHERE id = ?",
      on: conn,
      with: [sqlight.text(session_to_string(id))],
      expecting: session_decoder(),
    )
  case rows {
    Ok([session]) -> Ok(session)
    Ok([]) -> Error(NotFound("session " <> session_to_string(id)))
    Ok(_) -> Error(Corrupt("duplicate session rows"))
    Error(e) -> Error(OpenFailed(describe(e)))
  }
}

/// Exact-name lookup. Multiple matches are an error — ambiguous lookup must
/// never silently pick the first entry (chapter 20.3 class C).
pub fn find_session_by_name(
  conn: sqlight.Connection,
  name: String,
) -> Result(Session, StoreError) {
  let rows =
    sqlight.query(
      "SELECT id, name, created_at_ms, current_branch_id FROM sessions WHERE name = ? ORDER BY created_at_ms",
      on: conn,
      with: [sqlight.text(name)],
      expecting: session_decoder(),
    )
  case rows {
    Ok([session]) -> Ok(session)
    Ok([]) -> Error(NotFound("session named " <> name))
    Ok(_) -> Error(AmbiguousName(name))
    Error(e) -> Error(OpenFailed(describe(e)))
  }
}

pub fn list_sessions(conn: sqlight.Connection) -> Result(List(Session), StoreError) {
  case
    sqlight.query(
      "SELECT id, name, created_at_ms, current_branch_id FROM sessions ORDER BY created_at_ms",
      on: conn,
      with: [],
      expecting: session_decoder(),
    )
  {
    Ok(rows) -> Ok(rows)
    Error(e) -> Error(OpenFailed(describe(e)))
  }
}

pub fn get_branch(
  conn: sqlight.Connection,
  session: SessionId,
  id: BranchId,
) -> Result(Branch, StoreError) {
  let rows =
    sqlight.query(
      "SELECT id, session_id, name, parent_id, branch_point, head_sequence
       FROM branches WHERE id = ? AND session_id = ?",
      on: conn,
      with: [
        sqlight.text(branch_to_string(id)),
        sqlight.text(session_to_string(session)),
      ],
      expecting: branch_decoder(),
    )
  case rows {
    Ok([branch]) -> Ok(branch)
    Ok([]) -> Error(NotFound("branch " <> branch_to_string(id)))
    Ok(_) -> Error(Corrupt("duplicate branch rows"))
    Error(e) -> Error(OpenFailed(describe(e)))
  }
}

pub fn list_branches(
  conn: sqlight.Connection,
  session: SessionId,
) -> Result(List(Branch), StoreError) {
  case
    sqlight.query(
      "SELECT id, session_id, name, parent_id, branch_point, head_sequence
       FROM branches WHERE session_id = ? ORDER BY created_at_ms",
      on: conn,
      with: [sqlight.text(session_to_string(session))],
      expecting: branch_decoder(),
    )
  {
    Ok(rows) -> Ok(rows)
    Error(e) -> Error(OpenFailed(describe(e)))
  }
}

/// Records of a branch in contract order. Ordering is contractual
/// (chapter 22.5): ascending branch-local sequence.
pub fn list_records(
  conn: sqlight.Connection,
  session: SessionId,
  branch: BranchId,
) -> Result(List(Record), StoreError) {
  case
    sqlight.query(
      "SELECT id, session_id, branch_id, sequence, kind, payload, created_at_ms
       FROM records WHERE session_id = ? AND branch_id = ? ORDER BY sequence",
      on: conn,
      with: [
        sqlight.text(session_to_string(session)),
        sqlight.text(branch_to_string(branch)),
      ],
      expecting: record_decoder(),
    )
  {
    Ok(rows) -> Ok(rows)
    Error(e) -> Error(OpenFailed(describe(e)))
  }
}

// --- provider attempt receipts -------------------------------------------

/// Record the durable INTENT to call a provider (chapter 22.7 boundary:
/// intent exists before the call). Status starts 'running'.
pub fn create_provider_attempt(
  conn: sqlight.Connection,
  id id: ProviderAttemptId,
  session session: SessionId,
  activation activation: String,
  provider_name provider_name: String,
  model model: String,
) -> Result(Nil, StoreError) {
  case
    sqlight.query(
      "INSERT INTO provider_attempts (id, session_id, activation_id, provider, model, status, started_at_ms)
       VALUES (?, ?, ?, ?, ?, 'running', ?)",
      on: conn,
      with: [
        sqlight.text(attempt_to_string(id)),
        sqlight.text(session_to_string(session)),
        sqlight.text(activation),
        sqlight.text(provider_name),
        sqlight.text(model),
        sqlight.int(logging.now_ms()),
      ],
      expecting: decode.dynamic,
    )
  {
    Ok(_) -> Ok(Nil)
    Error(e) -> Error(map_insert_error(e, "provider_attempt"))
  }
}

/// Complete an attempt with its outcome. Usage stays nil on failure —
/// a failed attempt must never be promoted to accepted state (chapter 22.6).
pub fn complete_provider_attempt(
  conn: sqlight.Connection,
  id id: ProviderAttemptId,
  status status: String,
  usage_input usage_input: Option(Int),
  usage_output usage_output: Option(Int),
) -> Result(Nil, StoreError) {
  case status {
    "completed" | "failed" | "aborted" ->
      case
        sqlight.query(
          "UPDATE provider_attempts SET status = ?, usage_input = ?, usage_output = ?, finished_at_ms = ?
           WHERE id = ?",
          on: conn,
          with: [
            sqlight.text(status),
            sqlight.nullable(sqlight.int, usage_input),
            sqlight.nullable(sqlight.int, usage_output),
            sqlight.int(logging.now_ms()),
            sqlight.text(attempt_to_string(id)),
          ],
          expecting: decode.dynamic,
        )
      {
        Ok(_) -> Ok(Nil)
        Error(e) -> Error(OpenFailed(describe(e)))
      }
    _ -> Error(Invalid("attempt status must be completed|failed|aborted"))
  }
}

// --- transaction helpers -------------------------------------------------

fn tx_begin(conn: sqlight.Connection) -> Result(Nil, StoreError) {
  sqlight.exec("BEGIN IMMEDIATE", on: conn)
  |> result.map_error(fn(e) { OpenFailed(describe(e)) })
}

fn tx_commit(conn: sqlight.Connection) -> Result(Nil, StoreError) {
  sqlight.exec("COMMIT", on: conn)
  |> result.map_error(fn(e) { OpenFailed(describe(e)) })
}

fn rollback(conn: sqlight.Connection) -> Nil {
  let _ = sqlight.exec("ROLLBACK", on: conn)
  Nil
}

// --- insert helpers ------------------------------------------------------

fn insert_session_tx(
  conn: sqlight.Connection,
  id: SessionId,
  name: String,
  created: Int,
) -> Result(Nil, StoreError) {
  case
    sqlight.query(
      "INSERT INTO sessions (id, name, created_at_ms, current_branch_id) VALUES (?, ?, ?, '')",
      on: conn,
      with: [
        sqlight.text(session_to_string(id)),
        sqlight.text(name),
        sqlight.int(created),
      ],
      expecting: decode.dynamic,
    )
  {
    Ok(_) -> Ok(Nil)
    Error(e) -> Error(map_insert_error(e, "session"))
  }
}

fn insert_branch(
  conn: sqlight.Connection,
  branch: Branch,
) -> Result(Branch, StoreError) {
  case tx_begin(conn) {
    Error(e) -> Error(e)
    Ok(_) ->
      case insert_branch_tx(conn, branch) {
        Ok(_) ->
          case tx_commit(conn) {
            Ok(_) -> Ok(branch)
            Error(e) -> {
              rollback(conn)
              Error(e)
            }
          }
        Error(e) -> {
          rollback(conn)
          Error(e)
        }
      }
  }
}

fn insert_branch_tx(
  conn: sqlight.Connection,
  branch: Branch,
) -> Result(Nil, StoreError) {
  case
    sqlight.query(
      "INSERT INTO branches (id, session_id, name, parent_id, branch_point, head_sequence, created_at_ms)
       VALUES (?, ?, ?, ?, ?, ?, ?)",
      on: conn,
      with: [
        sqlight.text(branch_to_string(branch.id)),
        sqlight.text(session_to_string(branch.session)),
        sqlight.text(branch.name),
        sqlight.nullable(sqlight.text, option.map(branch.parent, branch_to_string)),
        sqlight.nullable(sqlight.int, branch.branch_point),
        sqlight.int(branch.head_sequence),
        sqlight.int(logging.now_ms()),
      ],
      expecting: decode.dynamic,
    )
  {
    Ok(_) -> Ok(Nil)
    Error(e) -> Error(map_insert_error(e, "branch"))
  }
}

fn set_current_branch_tx(
  conn: sqlight.Connection,
  session: SessionId,
  branch: BranchId,
) -> Result(Nil, StoreError) {
  case
    sqlight.query(
      "UPDATE sessions SET current_branch_id = ? WHERE id = ?",
      on: conn,
      with: [
        sqlight.text(branch_to_string(branch)),
        sqlight.text(session_to_string(session)),
      ],
      expecting: decode.dynamic,
    )
  {
    Ok(_) -> Ok(Nil)
    Error(e) -> Error(OpenFailed(describe(e)))
  }
}

// --- decoders ------------------------------------------------------------

fn session_decoder() -> decode.Decoder(Session) {
  {
    use id <- decode.then(decode.at([0], decode.string))
    use name <- decode.then(decode.at([1], decode.string))
    use created <- decode.then(decode.at([2], decode.int))
    use current <- decode.then(decode.at([3], decode.string))
    decode.success(Session(
      id: SessionId(id),
      name: name,
      created_at_ms: created,
      current_branch: BranchId(current),
    ))
  }
}

fn branch_decoder() -> decode.Decoder(Branch) {
  let nullable_string_at = fn(i: Int) {
    decode.one_of(
      decode.map(decode.at([i], decode.string), Some),
      or: [decode.success(None)],
    )
  }
  let nullable_int_at = fn(i: Int) {
    decode.one_of(
      decode.map(decode.at([i], decode.int), Some),
      or: [decode.success(None)],
    )
  }
  {
    use id <- decode.then(decode.at([0], decode.string))
    use session <- decode.then(decode.at([1], decode.string))
    use name <- decode.then(decode.at([2], decode.string))
    use parent <- decode.then(nullable_string_at(3))
    use point <- decode.then(nullable_int_at(4))
    use head <- decode.then(decode.at([5], decode.int))
    decode.success(Branch(
      id: BranchId(id),
      session: SessionId(session),
      name: name,
      parent: option.map(parent, BranchId),
      branch_point: point,
      head_sequence: head,
    ))
  }
}

fn record_decoder() -> decode.Decoder(Record) {
  {
    use id <- decode.then(decode.at([0], decode.string))
    use session <- decode.then(decode.at([1], decode.string))
    use branch <- decode.then(decode.at([2], decode.string))
    use sequence <- decode.then(decode.at([3], decode.int))
    use kind <- decode.then(decode.at([4], decode.string))
    use payload <- decode.then(decode.at([5], decode.string))
    use created <- decode.then(decode.at([6], decode.int))
    decode.success(Record(
      id: id,
      session: SessionId(session),
      branch: BranchId(branch),
      sequence: sequence,
      kind: kind,
      payload: payload,
      created_at_ms: created,
    ))
  }
}

// --- misc ----------------------------------------------------------------

pub fn session_to_string(id: SessionId) -> String {
  id.value
}

pub fn branch_to_string(id: BranchId) -> String {
  id.value
}

pub fn deploy_to_string(id: DeploymentId) -> String {
  id.value
}

pub fn attempt_to_string(id: ProviderAttemptId) -> String {
  id.value
}

/// Map an SQLite failure to a store error, preserving the message. Constraint
/// violations surface as AlreadyExists with the offending identity named.
fn map_insert_error(e: sqlight.Error, what: String) -> StoreError {
  let described = describe(e)
  case e {
    sqlight.SqlightError(code, _, _) ->
      // SQLite returns EXTENDED constraint codes (ConstraintPrimarykey,
      // ConstraintUnique, ...): every Constraint* variant means a duplicate.
      case is_constraint(code) {
        True -> AlreadyExists(what <> ": " <> described)
        False -> OpenFailed(described)
      }
  }
}

fn is_constraint(code: sqlight.ErrorCode) -> Bool {
  case code {
    sqlight.Constraint -> True
    sqlight.ConstraintNotnull -> True
    sqlight.ConstraintPrimarykey -> True
    sqlight.ConstraintRowid -> True
    sqlight.ConstraintTrigger -> True
    sqlight.ConstraintUnique -> True
    sqlight.ConstraintCheck -> True
    sqlight.ConstraintForeignkey -> True
    sqlight.ConstraintCommithook -> True
    sqlight.ConstraintDatatype -> True
    sqlight.ConstraintFunction -> True
    sqlight.ConstraintVtab -> True
    sqlight.ConstraintPinned -> True
    _ -> False
  }
}

fn describe(e: sqlight.Error) -> String {
  let sqlight.SqlightError(code, message, _) = e
  string.inspect(code) <> ": " <> message
}

@external(erlang, "successor_ffi", "ensure_parent_dir")
fn ensure_parent_dir(path: String) -> Nil
