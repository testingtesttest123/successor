//// Minimal operator surface (chapter 23.1A): health now; the versioned wire
//// protocol binds to this same actor in 1F/Phase 3. This actor is the single
//// operator authority — surfaces never become a second business-logic layer
//// (chapter 23, Phase 10 rule).

import gleam/erlang/process.{type Name, type Subject}
import gleam/otp/actor
import successor/config.{type Config}

pub type Msg {
  Health(reply: Subject(HealthReport))
}

pub type HealthReport {
  HealthReport(healthy: Bool, providers: Int, schema_version: Int)
}

pub fn start(
  config config: Config,
  name name: Name(Msg),
) -> Result(actor.Started(Subject(Msg)), actor.StartError) {
  let initial =
    HealthReport(
      healthy: True,
      providers: count(config.providers),
      schema_version: config.schema_version,
    )
  actor.new(initial)
  |> actor.named(name)
  |> actor.on_message(fn(state, msg) {
    case msg {
      Health(reply) -> {
        process.send(reply, state)
        actor.continue(state)
      }
    }
  })
  |> actor.start
}

pub fn health(operator: Subject(Msg)) -> HealthReport {
  let reply = process.new_subject()
  process.send(operator, Health(reply))
  let assert Ok(report) = process.receive(reply, 5000)
  report
}

fn count(items: List(a)) -> Int {
  case items {
    [] -> 0
    [_, ..rest] -> 1 + count(rest)
  }
}
