//// SQLite adapter for durable agent workspace identity and cell journal.
////
//// The DeploymentStore is the sole production caller and owns the connection.
//// This module deliberately does not import `successor/db`, avoiding a cycle.

import gleam/dynamic/decode
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sqlight
import successor/ids.{
  type AgentId, type AgentIncarnationId, type SessionId, AgentId,
  AgentIncarnationId, SessionId,
}
import successor/logging
import successor/workspace_types.{
  type AgentWorkspace, type Cell, type CellState, AgentWorkspace, Cell, Failed,
  Intent, OutcomeUnknown, Succeeded,
}

pub const schema_ddl =
  "
CREATE TABLE agent_workspaces (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions(id),
  parent_id TEXT REFERENCES agent_workspaces(id),
  name TEXT NOT NULL,
  incarnation_id TEXT,
  created_at_ms INTEGER NOT NULL
);
CREATE UNIQUE INDEX one_root_workspace_per_session
  ON agent_workspaces(session_id) WHERE parent_id IS NULL;
CREATE INDEX agent_workspaces_by_parent ON agent_workspaces(parent_id);
CREATE TABLE workspace_cells (
  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
  id TEXT NOT NULL UNIQUE,
  agent_id TEXT NOT NULL REFERENCES agent_workspaces(id),
  incarnation_id TEXT NOT NULL,
  source TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('intent', 'succeeded', 'failed', 'outcome_unknown')),
  output TEXT NOT NULL,
  truncated INTEGER NOT NULL CHECK (truncated IN (0, 1)),
  error TEXT,
  created_at_ms INTEGER NOT NULL,
  settled_at_ms INTEGER
);
CREATE UNIQUE INDEX one_workspace_intent_per_agent
  ON workspace_cells(agent_id) WHERE state = 'intent';
CREATE INDEX workspace_cells_by_agent_sequence
  ON workspace_cells(agent_id, sequence);
"

/// Add schema-2 tables to a genuine schema-1 connection. The caller owns the
/// version stamp, but this DDL and that stamp must be in the same transaction.
pub fn create_schema(conn: sqlight.Connection) -> Result(Nil, String) {
  sqlight.exec(schema_ddl, on: conn)
  |> result.map_error(describe)
}

/// Recover the journal when the exclusive single-host DeploymentStore starts.
/// No interpreter survives host ownership loss in this tier, so unresolved
/// intents become unknown and every active incarnation fence is cleared before
/// the new host serves inspection. Terminal rows and their source/output are
/// preserved. This assumes only one store process owns the database at a time.
pub fn recover(conn: sqlight.Connection) -> Result(Nil, String) {
  transaction(conn, fn() {
    use _ <- result.try(
      exec(
        conn,
        "UPDATE workspace_cells SET state = 'outcome_unknown', settled_at_ms = ? WHERE state = 'intent'",
        [sqlight.int(logging.now_ms())],
      ),
    )
    exec(conn, "UPDATE agent_workspaces SET incarnation_id = NULL", [])
  })
}

pub fn ensure_root_workspace(
  conn: sqlight.Connection,
  session: SessionId,
  name: String,
) -> Result(AgentWorkspace, String) {
  case name == "" {
    True -> Error("workspace name must not be empty")
    False ->
      case root_for_session(conn, session) {
        Ok(Some(workspace)) -> Ok(workspace)
        Error(e) -> Error(e)
        Ok(None) -> {
          let id = ids.new_agent_id()
          let workspace = AgentWorkspace(id, session, None, name, None)
          case insert_workspace(conn, workspace) {
            Ok(_) -> Ok(workspace)
            Error(e) -> Error(e)
          }
        }
      }
  }
}

pub fn create_child_workspace(
  conn: sqlight.Connection,
  parent: AgentId,
  name: String,
) -> Result(AgentWorkspace, String) {
  case name == "" {
    True -> Error("workspace name must not be empty")
    False ->
      case get_workspace(conn, parent) {
        Error(e) -> Error(e)
        Ok(owner) -> {
          let workspace =
            AgentWorkspace(
              ids.new_agent_id(),
              owner.session,
              Some(parent),
              name,
              None,
            )
          case insert_workspace(conn, workspace) {
            Ok(_) -> Ok(workspace)
            Error(e) -> Error(e)
          }
        }
      }
  }
}

pub fn get_workspace(
  conn: sqlight.Connection,
  agent: AgentId,
) -> Result(AgentWorkspace, String) {
  case
    query_workspaces(
      conn,
      "SELECT id, session_id, parent_id, name, incarnation_id FROM agent_workspaces WHERE id = ?",
      [sqlight.text(agent.value)],
    )
  {
    Ok([workspace]) -> Ok(workspace)
    Ok([]) -> Error("workspace not found: " <> agent.value)
    Ok(_) -> Error("duplicate workspace rows: " <> agent.value)
    Error(e) -> Error(e)
  }
}

/// Move the active incarnation fence. Any unresolved intent belongs to the
/// prior transport outcome and becomes explicitly unknown; source is retained.
pub fn activate_workspace(
  conn: sqlight.Connection,
  agent: AgentId,
  incarnation: AgentIncarnationId,
) -> Result(Nil, String) {
  case get_workspace(conn, agent) {
    Error(e) -> Error(e)
    Ok(workspace) ->
      case workspace.incarnation == Some(incarnation) {
        True -> Error("workspace incarnation is already active")
        False ->
          transaction(conn, fn() {
            use _ <- result.try(
              exec(
                conn,
                "UPDATE workspace_cells SET state = 'outcome_unknown', settled_at_ms = ? WHERE agent_id = ? AND state = 'intent'",
                [sqlight.int(logging.now_ms()), sqlight.text(agent.value)],
              ),
            )
            exec(
              conn,
              "UPDATE agent_workspaces SET incarnation_id = ? WHERE id = ?",
              [sqlight.text(incarnation.value), sqlight.text(agent.value)],
            )
          })
      }
  }
}

/// Persist intent before transport dispatch. The active fence, intent-only
/// state, globally unique id, and one-in-flight-per-agent rule are enforced.
pub fn begin_cell(conn: sqlight.Connection, cell: Cell) -> Result(Nil, String) {
  case cell.state {
    Intent ->
      case get_workspace(conn, cell.agent) {
        Error(e) -> Error(e)
        Ok(workspace) ->
          case workspace.incarnation == Some(cell.incarnation) {
            False -> Error("cell incarnation is not the active workspace fence")
            True ->
              case
                cell.output == ""
                && cell.truncated == False
                && cell.error == None
              {
                False -> Error("intent cell must not contain an outcome")
                True ->
                  query(
                    conn,
                    "INSERT INTO workspace_cells (id, agent_id, incarnation_id, source, state, output, truncated, error, created_at_ms, settled_at_ms) VALUES (?, ?, ?, ?, 'intent', '', 0, NULL, ?, NULL)",
                    [
                      sqlight.text(cell.id),
                      sqlight.text(cell.agent.value),
                      sqlight.text(cell.incarnation.value),
                      sqlight.text(cell.source),
                      sqlight.int(logging.now_ms()),
                    ],
                  )
                  |> result.map_error(fn(e) {
                    "cell intent rejected (duplicate id or active intent): "
                    <> describe(e)
                  })
              }
          }
      }
    _ -> Error("begin cell requires intent state")
  }
}

/// Terminal compare-and-set. Every identity and source field must match the
/// stored intent and the current workspace fence. Refusals never overwrite.
pub fn settle_cell(
  conn: sqlight.Connection,
  cell: Cell,
) -> Result(Nil, String) {
  case is_terminal(cell.state) {
    False -> Error("settle cell requires terminal state")
    True ->
      case get_workspace(conn, cell.agent) {
        Error(e) -> Error(e)
        Ok(workspace) ->
          case workspace.incarnation == Some(cell.incarnation) {
            False -> Error("cell incarnation is not the active workspace fence")
            True ->
              case get_cell(conn, cell.id) {
                Error(e) -> Error(e)
                Ok(existing) ->
                  case
                    existing.state == Intent
                    && existing.agent == cell.agent
                    && existing.incarnation == cell.incarnation
                    && existing.source == cell.source
                  {
                    False ->
                      Error("cell settlement does not match current intent")
                    True ->
                      exec(
                        conn,
                        "UPDATE workspace_cells SET state = ?, output = ?, truncated = ?, error = ?, settled_at_ms = ? WHERE id = ? AND state = 'intent' AND agent_id = ? AND incarnation_id = ? AND source = ?",
                        [
                          sqlight.text(state_to_string(cell.state)),
                          sqlight.text(cell.output),
                          sqlight.int(bool_to_int(cell.truncated)),
                          sqlight.nullable(sqlight.text, cell.error),
                          sqlight.int(logging.now_ms()),
                          sqlight.text(cell.id),
                          sqlight.text(cell.agent.value),
                          sqlight.text(cell.incarnation.value),
                          sqlight.text(cell.source),
                        ],
                      )
                  }
              }
          }
      }
  }
}

pub fn get_cell(conn: sqlight.Connection, id: String) -> Result(Cell, String) {
  case
    query_cells(
      conn,
      "SELECT id, agent_id, incarnation_id, source, state, output, truncated, error FROM workspace_cells WHERE id = ?",
      [sqlight.text(id)],
    )
  {
    Ok([cell]) -> Ok(cell)
    Ok([]) -> Error("cell not found: " <> id)
    Ok(_) -> Error("duplicate cell rows: " <> id)
    Error(e) -> Error(e)
  }
}

/// Explicit inspection API in durable insertion order (the internal sequence,
/// never wall-clock inference). Journal rows are retained without automatic GC;
/// callers must not invoke this history-growing query in a per-turn hot path.
pub fn list_cells(
  conn: sqlight.Connection,
  agent: AgentId,
) -> Result(List(Cell), String) {
  query_cells(
    conn,
    "SELECT id, agent_id, incarnation_id, source, state, output, truncated, error FROM workspace_cells WHERE agent_id = ? ORDER BY sequence",
    [sqlight.text(agent.value)],
  )
}

fn root_for_session(
  conn: sqlight.Connection,
  session: SessionId,
) -> Result(Option(AgentWorkspace), String) {
  case
    query_workspaces(
      conn,
      "SELECT id, session_id, parent_id, name, incarnation_id FROM agent_workspaces WHERE session_id = ? AND parent_id IS NULL",
      [sqlight.text(session.value)],
    )
  {
    Ok([]) -> Ok(None)
    Ok([workspace]) -> Ok(Some(workspace))
    Ok(_) -> Error("duplicate root workspaces for session: " <> session.value)
    Error(e) -> Error(e)
  }
}

fn insert_workspace(
  conn: sqlight.Connection,
  workspace: AgentWorkspace,
) -> Result(Nil, String) {
  query(
    conn,
    "INSERT INTO agent_workspaces (id, session_id, parent_id, name, incarnation_id, created_at_ms) VALUES (?, ?, ?, ?, ?, ?)",
    [
      sqlight.text(workspace.id.value),
      sqlight.text(workspace.session.value),
      sqlight.nullable(
        sqlight.text,
        option.map(workspace.parent, fn(id) { id.value }),
      ),
      sqlight.text(workspace.name),
      sqlight.nullable(
        sqlight.text,
        option.map(workspace.incarnation, fn(id) { id.value }),
      ),
      sqlight.int(logging.now_ms()),
    ],
  )
  |> result.map_error(fn(e) { "workspace insert rejected: " <> describe(e) })
}

fn query_workspaces(
  conn: sqlight.Connection,
  statement: String,
  params: List(sqlight.Value),
) -> Result(List(AgentWorkspace), String) {
  sqlight.query(
    statement,
    on: conn,
    with: params,
    expecting: workspace_decoder(),
  )
  |> result.map_error(describe)
}

fn query_cells(
  conn: sqlight.Connection,
  statement: String,
  params: List(sqlight.Value),
) -> Result(List(Cell), String) {
  sqlight.query(statement, on: conn, with: params, expecting: cell_decoder())
  |> result.map_error(describe)
}

fn workspace_decoder() -> decode.Decoder(AgentWorkspace) {
  {
    use id <- decode.then(decode.at([0], decode.string))
    use session <- decode.then(decode.at([1], decode.string))
    use parent <- decode.then(nullable_string_at(2))
    use name <- decode.then(decode.at([3], decode.string))
    use incarnation <- decode.then(nullable_string_at(4))
    decode.success(AgentWorkspace(
      AgentId(id),
      SessionId(session),
      option.map(parent, AgentId),
      name,
      option.map(incarnation, AgentIncarnationId),
    ))
  }
}

fn cell_decoder() -> decode.Decoder(Cell) {
  {
    use id <- decode.then(decode.at([0], decode.string))
    use agent <- decode.then(decode.at([1], decode.string))
    use incarnation <- decode.then(decode.at([2], decode.string))
    use source <- decode.then(decode.at([3], decode.string))
    use raw_state <- decode.then(decode.at([4], decode.string))
    use output <- decode.then(decode.at([5], decode.string))
    use truncated <- decode.then(decode.at([6], decode.int))
    use error <- decode.then(nullable_string_at(7))
    case string_to_state(raw_state) {
      Error(e) ->
        decode.failure(
          Cell(
            id,
            AgentId(agent),
            AgentIncarnationId(incarnation),
            source,
            Intent,
            output,
            False,
            error,
          ),
          e,
        )
      Ok(state) ->
        decode.success(Cell(
          id,
          AgentId(agent),
          AgentIncarnationId(incarnation),
          source,
          state,
          output,
          truncated == 1,
          error,
        ))
    }
  }
}

fn nullable_string_at(index: Int) -> decode.Decoder(Option(String)) {
  decode.one_of(decode.map(decode.at([index], decode.string), Some), or: [
    decode.success(None),
  ])
}

fn is_terminal(state: CellState) -> Bool {
  case state {
    Succeeded | Failed | OutcomeUnknown -> True
    Intent -> False
  }
}

fn state_to_string(state: CellState) -> String {
  case state {
    Intent -> "intent"
    Succeeded -> "succeeded"
    Failed -> "failed"
    OutcomeUnknown -> "outcome_unknown"
  }
}

fn string_to_state(state: String) -> Result(CellState, String) {
  case state {
    "intent" -> Ok(Intent)
    "succeeded" -> Ok(Succeeded)
    "failed" -> Ok(Failed)
    "outcome_unknown" -> Ok(OutcomeUnknown)
    other -> Error("invalid workspace cell state: " <> other)
  }
}

fn bool_to_int(value: Bool) -> Int {
  case value {
    True -> 1
    False -> 0
  }
}

fn transaction(
  conn: sqlight.Connection,
  body: fn() -> Result(Nil, String),
) -> Result(Nil, String) {
  case exec(conn, "BEGIN IMMEDIATE", []) {
    Error(e) -> Error(e)
    Ok(_) ->
      case body() {
        Error(e) -> {
          let _ = exec(conn, "ROLLBACK", [])
          Error(e)
        }
        Ok(_) ->
          case exec(conn, "COMMIT", []) {
            Ok(_) -> Ok(Nil)
            Error(e) -> {
              let _ = exec(conn, "ROLLBACK", [])
              Error(e)
            }
          }
      }
  }
}

fn exec(
  conn: sqlight.Connection,
  statement: String,
  params: List(sqlight.Value),
) -> Result(Nil, String) {
  query(conn, statement, params) |> result.map_error(describe)
}

fn query(
  conn: sqlight.Connection,
  statement: String,
  params: List(sqlight.Value),
) -> Result(Nil, sqlight.Error) {
  sqlight.query(statement, on: conn, with: params, expecting: decode.dynamic)
  |> result.map(fn(_) { Nil })
}

fn describe(e: sqlight.Error) -> String {
  let sqlight.SqlightError(code, message, _) = e
  string.inspect(code) <> ": " <> message
}
