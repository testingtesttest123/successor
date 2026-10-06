//// Restart-stable address book for supervised dynamic children.
////
//// Factory-supervised actors are restarted with fresh pids; any handle a
//// caller held before the restart is dead. The registry gives callers a
//// handle that resolves through durable IDENTITY instead: lookups by key
//// always reach the current incarnation, because each incarnation registers
//// itself on startup. Generic over the handle type — no cycles.

import gleam/dict
import gleam/erlang/process.{type Name, type Subject}
import gleam/otp/actor

pub type Msg(handle) {
  Register(key: String, subject: Subject(handle))
  Lookup(key: String, reply: Subject(Result(Subject(handle), Nil)))
}

type State(handle) {
  State(entries: dict.Dict(String, Subject(handle)))
}

/// Start the registry actor (the app registers it under a stable name).
pub fn start(
  name name: Name(Msg(handle)),
) -> actor.StartResult(Subject(Msg(handle))) {
  actor.new(State(entries: dict.new()))
  |> actor.named(name)
  |> actor.on_message(handle_msg)
  |> actor.start
}

fn handle_msg(
  state: State(handle),
  msg: Msg(handle),
) -> actor.Next(State(handle), Msg(handle)) {
  case msg {
    Register(key, subject) ->
      actor.continue(State(entries: dict.insert(state.entries, key, subject)))
    Lookup(key, reply) -> {
      process.send(reply, dict.get(state.entries, key))
      actor.continue(state)
    }
  }
}

/// Resolve a key to its CURRENT incarnation handle.
pub fn lookup(
  registry: Subject(Msg(handle)),
  key key: String,
) -> Result(Subject(handle), Nil) {
  let reply = process.new_subject()
  process.send(registry, Lookup(key, reply))
  case process.receive(reply, 5000) {
    Ok(result) -> result
    Error(_) -> Error(Nil)
  }
}
