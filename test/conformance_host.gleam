//// Test-only, bounded JSONL bridge for Home's shared scenario interpreter.
//// This is not the production operator wire protocol. All writes go through
//// the public app/session APIs; snapshots use a read-only SQLite connection.

import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import sqlight
import successor/agent
import successor/app
import successor/config
import successor/db
import successor/ids
import successor/recipe

pub type Command {
  Start(String, String, String)
  Inspect(String, String)
  Text(String)
  Read(String)
  Stop
}

type Running {
  Running(host: app.Started, session_id: ids.SessionId)
}

pub fn accepts_request(text: String) -> Bool {
  result.is_ok(decode_request(text))
}

pub fn decode_request(text: String) {
  json.parse(text, command_decoder())
}

fn command_decoder() {
  use op <- decode.field("op", decode.string)
  case op {
    "start" ->
      reject_unknown(["op", "dataDir", "recipe", "sessionId"], {
        use dir <- decode.field("dataDir", decode.string)
        use recipe_text <- decode.field("recipe", decode.string)
        use sid <- decode.optional_field("sessionId", "", decode.string)
        decode.success(Start(dir, recipe_text, sid))
      })
    "inspect" ->
      reject_unknown(["op", "dataDir", "sessionId"], {
        use dir <- decode.field("dataDir", decode.string)
        use sid <- decode.field("sessionId", decode.string)
        decode.success(Inspect(dir, sid))
      })
    "text" ->
      reject_unknown(["op", "content"], {
        use content <- decode.field("content", decode.string)
        decode.success(Text(content))
      })
    "snapshot" | "describe" | "readReceipts" ->
      reject_unknown(["op"], decode.success(Read(op)))
    "command" ->
      reject_unknown(["op", "line"], {
        use line <- decode.field("line", decode.string)
        case line {
          "/history" -> decode.success(Read(op))
          _ -> decode.failure(Stop, "only /history is supported")
        }
      })
    "stop" -> reject_unknown(["op"], decode.success(Stop))
    _ -> decode.failure(Stop, "supported conformance operation")
  }
}

pub fn main() {
  loop(None)
}

fn loop(running: option.Option(Running)) {
  case read_line() {
    Error(_) -> {
      case running {
        Some(state) -> app.stop(state.host)
        None -> Nil
      }
    }
    Ok(line) -> {
      let assert Ok(command) = decode_request(line)
      case command {
        Start(dir, recipe_text, sid) -> {
          let assert None = running
          let assert Ok(loaded) = recipe.read_reference_recipe(recipe_text)
          let cfg = config.Config(..loaded.config, data_dir: dir)
          let assert Ok(host) = app.start(cfg, process.new_subject())
          let session_id = case sid {
            "" -> {
              let assert Ok(created) = app.start_session(host, "Conformance")
              created
            }
            _ -> {
              let assert Ok(opened) = app.open_session(host, ids.SessionId(sid))
              opened
            }
          }
          let state = Running(host, session_id)
          emit("start", [
            #("snapshot", snapshot(dir, session_id)),
            #("recipeWarnings", json.array(loaded.warnings, json.string)),
          ])
          loop(Some(state))
        }
        Inspect(dir, sid) -> {
          let assert None = running
          emit("inspect", [#("snapshot", snapshot(dir, ids.SessionId(sid)))])
          // No host is booted, no writes or provider work can run.
        }
        Text(content) -> {
          let assert Some(state) = running
          let assert Ok(live) = app.session_of(state.host, state.session_id)
          let assert Ok(activation) = session.submit(live, content)
          let assert Ok(agent.TurnStarted(sid, started)) =
            process.receive(state.host.events, 10_000)
          assert sid == state.session_id && started == activation
          let assert Ok(agent.TurnCompleted(sid2, completed, record)) =
            process.receive(state.host.events, 10_000)
          assert sid2 == sid && completed == activation
          emit("text", [
            #("status", json.string("completed")),
            #("activationId", json.string(activation.value)),
            #(
              "events",
              json.array(
                [
                  json.object([
                    #("type", json.string("turn-started")),
                    #("sessionId", json.string(sid.value)),
                    #("activationId", json.string(activation.value)),
                  ]),
                  json.object([
                    #("type", json.string("turn-completed")),
                    #("sessionId", json.string(sid.value)),
                    #("activationId", json.string(activation.value)),
                    #("recordId", json.string(record.id)),
                  ]),
                ],
                fn(v) { v },
              ),
            ),
            #("snapshot", snapshot(state.host.config.data_dir, sid)),
          ])
          loop(running)
        }
        Read(op) -> {
          let assert Some(state) = running
          emit(op, [
            #(
              "snapshot",
              snapshot(state.host.config.data_dir, state.session_id),
            ),
          ])
          loop(running)
        }
        Stop -> {
          let assert Some(state) = running
          app.stop(state.host)
          emit("stop", [#("exitCode", json.int(0))])
        }
      }
    }
  }
}

import successor/session

fn emit(op, fields) {
  json.object([#("op", json.string(op)), #("ok", json.bool(True)), ..fields])
  |> json.to_string
  |> fn(text) { io.println("@@SUCCESSOR@@" <> text) }
}

/// Read-only URIs refuse missing databases, never creating or migrating one.
/// Path encoding prevents '?' or '#' in an authorized local path changing
/// SQLite's URI options. The durable schema/rows come from the real writer.
pub fn snapshot(dir: String, sid: ids.SessionId) -> json.Json {
  let path = dir <> "/successor.db"
  let assert Ok(conn) = sqlight.open("file:" <> uri_path(path) <> "?mode=ro")
  let assert Ok(saved) = db.get_session(conn, sid)
  let assert Ok(branch) = db.get_branch(conn, sid, saved.current_branch)
  let assert Ok(records) = db.list_records(conn, sid, branch.id)
  let assert Ok(catalog) = db.list_sessions(conn)
  let branches =
    list.flat_map(catalog, fn(s) {
      let assert Ok(found) = db.list_branches(conn, s.id)
      found
    })
  let assert Ok(receipts) =
    sqlight.query(
      "SELECT id, session_id, activation_id, provider, model, status, usage_input, usage_output, started_at_ms, finished_at_ms FROM provider_attempts ORDER BY rowid",
      on: conn,
      with: [],
      expecting: receipt_decoder(),
    )
  let assert Ok([deployment]) =
    sqlight.query(
      "SELECT id FROM deployments",
      on: conn,
      with: [],
      expecting: decode.at([0], decode.string),
    )
  let assert Ok(_) = sqlight.close(conn)
  json.object([
    #("processId", json.string(process_id())),
    #("deploymentId", json.string(deployment)),
    #("sessionId", json.string(sid.value)),
    #("branchId", json.string(branch.id.value)),
    #("branchName", json.string(branch.name)),
    #("head", json.int(branch.head_sequence)),
    #(
      "catalog",
      json.array(catalog, fn(s) {
        json.object([
          #("id", json.string(s.id.value)),
          #("name", json.string(s.name)),
          #("currentBranchId", json.string(s.current_branch.value)),
          #("createdAtMs", json.int(s.created_at_ms)),
        ])
      }),
    ),
    #("branches", json.array(branches, branch_json)),
    #("records", json.array(records, record_json)),
    #("receipts", json.array(receipts, fn(r) { r })),
  ])
}

fn branch_json(b: db.Branch) {
  json.object([
    #("id", json.string(b.id.value)),
    #("sessionId", json.string(b.session.value)),
    #("name", json.string(b.name)),
    #("head", json.int(b.head_sequence)),
    #("parentId", case b.parent {
      Some(id) -> json.string(id.value)
      None -> json.null()
    }),
    #("branchPoint", nullable_int(b.branch_point)),
  ])
}

fn record_json(r: db.Record) {
  json.object([
    #("id", json.string(r.id)),
    #("sessionId", json.string(r.session.value)),
    #("branchId", json.string(r.branch.value)),
    #("sequence", json.int(r.sequence)),
    #("createdAtMs", json.int(r.created_at_ms)),
    #("kind", json.string(r.kind)),
    #("payload", json.string(r.payload)),
  ])
}

fn receipt_decoder() {
  use id <- decode.field(0, decode.string)
  use sid <- decode.field(1, decode.string)
  use activation <- decode.field(2, decode.string)
  use provider <- decode.field(3, decode.string)
  use model <- decode.field(4, decode.string)
  use status <- decode.field(5, decode.string)
  use input <- decode.field(6, decode.optional(decode.int))
  use output <- decode.field(7, decode.optional(decode.int))
  use started <- decode.field(8, decode.int)
  use finished <- decode.field(9, decode.optional(decode.int))
  decode.success(
    json.object([
      #("id", json.string(id)),
      #("sessionId", json.string(sid)),
      #("activationId", json.string(activation)),
      #("provider", json.string(provider)),
      #("model", json.string(model)),
      #("status", json.string(status)),
      #("startedAtMs", json.int(started)),
      #("finishedAtMs", nullable_int(finished)),
      #(
        "usage",
        json.object([
          #("inputTokens", nullable_int(input)),
          #("outputTokens", nullable_int(output)),
        ]),
      ),
    ]),
  )
}

fn nullable_int(value) {
  case value {
    Some(value) -> json.int(value)
    None -> json.null()
  }
}

@external(erlang, "conformance_host_ffi", "read_line")
fn read_line() -> Result(String, Nil)

@external(erlang, "conformance_host_ffi", "process_id")
fn process_id() -> String

@external(erlang, "conformance_host_ffi", "uri_path")
fn uri_path(path: String) -> String

fn reject_unknown(
  known: List(String),
  inner: decode.Decoder(t),
) -> decode.Decoder(t) {
  use keys <- decode.then(decode.dict(decode.string, decode.dynamic))
  use value <- decode.then(inner)
  case list.filter(dict.keys(keys), fn(k) { !list.contains(known, k) }) {
    [] -> decode.success(value)
    [first, ..] -> decode.failure(value, "known-field:" <> first)
  }
}
