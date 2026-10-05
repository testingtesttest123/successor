//// The host: supervision root and lifecycle (chapter 23.1A).
////
//// Tree ownership, one slot per live-resource kind, so ownership boundaries
//// never move as phases add children:
////
////   root (one_for_one)
////   ├── DeploymentStore worker   (single durable writer)
////   ├── Operator worker          (single operator authority)
////   ├── Session supervisor       (empty until 1F)
////   └── Provider supervisor      (empty until 1D)
////
//// Zero configured providers is a valid, cleanly startable state.
////
//// Link ownership: the supervision root links to a dedicated keeper process,
//// never to the caller of `start`. The keeper traps exits and performs
//// ordered shutdown on request; a crashing tree therefore cannot take the
//// caller with it, and `stop` cannot leak the tree either.

import gleam/erlang/process.{type Pid, type Subject, ExitMessage}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import successor/config.{type Config}
import successor/db
import successor/ids.{type DeploymentId}
import successor/logging
import successor/operator
import successor/store

pub type Started {
  Started(
    supervisor_pid: Pid,
    store: Subject(store.Msg),
    operator: Subject(operator.Msg),
    config: Config,
    deployment: DeploymentId,
  )
}

pub fn start(config config: Config) -> Result(Started, String) {
  case config.validate(config) {
    Error(e) -> Error(e)
    Ok(_) -> {
      let store_name = process.new_name(prefix: "successor_store")
      let operator_name = process.new_name(prefix: "successor_operator")

      let store_child =
        supervision.worker(fn() {
          case store.start(config.data_dir, store_name) {
            Ok(started) ->
              Ok(actor.Started(pid: started.pid, data: started.subject))
            Error(e) -> Error(actor.InitFailed(e))
          }
        })

      let operator_child =
        supervision.worker(fn() {
          case operator.start(config: config, name: operator_name) {
            Ok(started) -> Ok(started)
            Error(e) -> Error(e)
          }
        })

      let tree =
        supervisor.new(supervisor.OneForOne)
        |> supervisor.add(store_child)
        |> supervisor.add(operator_child)
        // Session and provider supervisors join the tree with their first
        // real children (1D/1F); the slots exist from day one so ownership
        // boundaries never move.
        |> supervisor.add(supervision.supervisor(fn() {
          supervisor.new(supervisor.OneForOne) |> supervisor.start
        }))
        |> supervisor.add(supervision.supervisor(fn() {
          supervisor.new(supervisor.OneForOne) |> supervisor.start
        }))

      start_under_keeper(tree, store_name, operator_name, config)
    }
  }
}

/// Spawn the keeper (unlinked), which starts the tree linked to itself and
/// traps exit signals from it.
fn start_under_keeper(
  tree: supervisor.Builder,
  store_name: process.Name(store.Msg),
  operator_name: process.Name(operator.Msg),
  config: Config,
) -> Result(Started, String) {
  let ack = process.new_subject()

  let _keeper =
    process.spawn(fn() {
      // Trap BEFORE starting the tree: the supervisor's exit arrives as a
      // message instead of killing this process.
      process.trap_exits(True)
      case supervisor.start(tree) {
        Error(_) -> process.send(ack, Error("supervisor start failed"))
        Ok(started) -> {
          process.send(ack, Ok(started.pid))
          keeper_loop(started.pid)
        }
      }
    })

  case process.receive(ack, 10_000) {
    Error(_) -> Error("keeper did not report supervisor startup")
    Ok(Error(e)) -> Error(e)
    Ok(Ok(supervisor_pid)) -> {
      let host =
        Started(
          supervisor_pid: supervisor_pid,
          store: process.named_subject(store_name),
          operator: process.named_subject(operator_name),
          config: config,
          deployment: store.deployment(process.named_subject(store_name)),
        )
      logging.info(name: "host.started", fields: [
        logging.field("deployment", db.deploy_to_string(host.deployment)),
        logging.int_field("providers", operator_provider_count(host)),
      ])
      Ok(host)
    }
  }
}

/// Keeper loop: its whole job is owning the supervisor link. When the tree
/// dies (any reason — including the ordered termination driven by `stop`),
/// the keeper logs and ends; nothing else owns that link.
fn keeper_loop(_supervisor_pid: Pid) -> Nil {
  let selector =
    process.new_selector()
    |> process.select_trapped_exits(fn(exit_msg) { exit_msg })
  let ExitMessage(_, reason) = process.selector_receive_forever(selector)
  logging.info(name: "host.tree_exited", fields: [
    logging.field("reason", describe_reason(reason)),
  ])
  Nil
}

/// Stop the host. `gen_server:stop` is the ordered-termination request for
/// gleam_otp supervisors: it is synchronous, terminates children in reverse
/// start order, and does not propagate exit signals to the caller. Returns
/// only once the tree is confirmed dead. (The store's SQLite connection is
/// closed at process teardown — durability across process death is a
/// storage-engine contract; the graceful-close path belongs to the Phase-3
/// host lifecycle state machine.)
pub fn stop(host host: Started) -> Nil {
  stop_gen_server(host.supervisor_pid)
  logging.info(name: "host.stopped", fields: [])
  Nil
}

@external(erlang, "successor_ffi", "stop_gen_server")
fn stop_gen_server(pid: Pid) -> Nil

fn operator_provider_count(host: Started) -> Int {
  let operator.HealthReport(_, providers, _) = operator.health(host.operator)
  providers
}

fn describe_reason(reason: process.ExitReason) -> String {
  case reason {
    process.Normal -> "normal"
    process.Killed -> "killed"
    process.Abnormal(_) -> "shutdown/abnormal"
  }
}
