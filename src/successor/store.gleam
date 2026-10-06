//// The DeploymentStore: single writer for the durable session catalog,
//// record log, and branch graph (chapter 23.1A/1B).
////
//// One actor owns the SQLite connection, so every durable transition is
//// serialized through one owner (chapter 23.1 build rule 3). Callers get
//// reply subjects; the actor never shares the connection.

import gleam/erlang/process.{type Name, type Subject}
import gleam/option.{type Option}

import gleam/otp/actor
import successor/db.{
  type Branch, type Record, type Session, type StoreError,
}
import successor/ids.{type BranchId, type SessionId}
import successor/logging
import sqlight

pub type Msg {
  Shutdown(reply: Subject(Nil))
  Deployment(reply: Subject(ids.DeploymentId))
  CreateSession(name: String, reply: Subject(Result(Session, StoreError)))
  GetSession(id: SessionId, reply: Subject(Result(Session, StoreError)))
  FindSessionByName(
    name: String,
    reply: Subject(Result(Session, StoreError)),
  )
  ListSessions(reply: Subject(Result(List(Session), StoreError)))
  CreateBranch(
    session: SessionId,
    name: String,
    parent: BranchId,
    at: Option(Int),
    reply: Subject(Result(Branch, StoreError)),
  )
  ListBranches(
    session: SessionId,
    reply: Subject(Result(List(Branch), StoreError)),
  )
  AppendRecord(
    session: SessionId,
    branch: BranchId,
    kind: String,
    payload: String,
    reply: Subject(Result(Record, StoreError)),
  )
  ListRecords(
    session: SessionId,
    branch: BranchId,
    reply: Subject(Result(List(Record), StoreError)),
  )
  CreateAttempt(
    id: ids.ProviderAttemptId,
    session: SessionId,
    activation: String,
    provider_name: String,
    model: String,
    reply: Subject(Result(Nil, StoreError)),
  )
  CompleteAttempt(
    id: ids.ProviderAttemptId,
    status: String,
    usage_input: Option(Int),
    usage_output: Option(Int),
    reply: Subject(Result(Nil, StoreError)),
  )
}

type State {
  State(conn: sqlight.Connection, deployment: ids.DeploymentId)
}

pub type Started {
  Started(subject: Subject(Msg), pid: process.Pid)
}

/// Start the store actor against `data_dir`/successor.db.
pub fn start(
  data_dir data_dir: String,
  name name: Name(Msg),
) -> Result(Started, String) {
  let builder =
    actor.new_with_initialiser(10_000, fn(subject) {
      case db.open(path: data_dir <> "/successor.db") {
        Error(e) -> Error("store: " <> describe_error(e))
        Ok(conn) ->
          case db.ensure_deployment(conn) {
            Error(e) -> {
              db.close(conn)
              Error("store: " <> describe_error(e))
            }
            Ok(deployment) -> {
              logging.info(name: "store.started", fields: [
                logging.field("data_dir", data_dir),
              ])
              Ok(
                actor.initialised(State(conn: conn, deployment: deployment))
                |> actor.returning(subject),
              )
            }
          }
      }
    })
    |> actor.named(name)
    |> actor.on_message(handle)

  case actor.start(builder) {
    Ok(started) -> Ok(Started(subject: started.data, pid: started.pid))
    Error(e) -> Error(describe_start_error(e))
  }
}

/// Query the durable deployment identity.
pub fn deployment(store: Subject(Msg)) -> ids.DeploymentId {
  let reply = process.new_subject()
  process.send(store, Deployment(reply))
  let assert Ok(id) = process.receive(reply, 5000)
  id
}

/// Ask the store to close its connection and stop.
pub fn shutdown(store: Subject(Msg)) -> Nil {
  let reply = process.new_subject()
  process.send(store, Shutdown(reply))
  let _ = process.receive(reply, 5000)
  Nil
}

fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Shutdown(reply) -> {
      db.close(state.conn)
      process.send(reply, Nil)
      actor.stop()
    }
    Deployment(reply) -> {
      process.send(reply, state.deployment)
      actor.continue(state)
    }
    CreateSession(name, reply) -> {
      let id = ids.new_session_id()
      process.send(reply, db.create_session(state.conn, id: id, name: name))
      actor.continue(state)
    }
    GetSession(id, reply) -> {
      process.send(reply, db.get_session(state.conn, id))
      actor.continue(state)
    }
    FindSessionByName(name, reply) -> {
      process.send(reply, db.find_session_by_name(state.conn, name))
      actor.continue(state)
    }
    ListSessions(reply) -> {
      process.send(reply, db.list_sessions(state.conn))
      actor.continue(state)
    }
    CreateBranch(session, name, parent, at, reply) -> {
      process.send(
        reply,
        db.create_branch(state.conn, session: session, name: name, parent: parent, at: at),
      )
      actor.continue(state)
    }
    ListBranches(session, reply) -> {
      process.send(reply, db.list_branches(state.conn, session))
      actor.continue(state)
    }
    AppendRecord(session, branch, kind, payload, reply) -> {
      process.send(
        reply,
        db.append_record(state.conn, session: session, branch: branch, kind: kind, payload: payload),
      )
      actor.continue(state)
    }
    ListRecords(session, branch, reply) -> {
      process.send(reply, db.list_records(state.conn, session, branch))
      actor.continue(state)
    }
    CreateAttempt(id, session, activation, provider_name, model, reply) -> {
      process.send(
        reply,
        db.create_provider_attempt(
          state.conn,
          id: id,
          session: session,
          activation: activation,
          provider_name: provider_name,
          model: model,
        ),
      )
      actor.continue(state)
    }
    CompleteAttempt(id, status, usage_input, usage_output, reply) -> {
      process.send(
        reply,
        db.complete_provider_attempt(
          state.conn,
          id: id,
          status: status,
          usage_input: usage_input,
          usage_output: usage_output,
        ),
      )
      actor.continue(state)
    }
  }
}

fn describe_error(e: db.StoreError) -> String {
  case e {
    db.OpenFailed(m) -> "open failed: " <> m
    db.Corrupt(m) -> "corrupt: " <> m
    db.AlreadyExists(m) -> "already exists: " <> m
    db.NotFound(m) -> "not found: " <> m
    db.Invalid(m) -> "invalid: " <> m
    db.AmbiguousName(m) -> "ambiguous name: " <> m
  }
}

fn describe_start_error(e: actor.StartError) -> String {
  case e {
    actor.InitTimeout -> "store start timed out"
    actor.InitFailed(m) -> "store init failed: " <> m
    actor.InitExited(_) -> "store init exited"
  }
}
