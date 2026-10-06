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
import gleam/otp/factory_supervisor as factory
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import successor/agent
import successor/config.{type Config}
import successor/db
import successor/ids.{type DeploymentId}
import successor/logging
import successor/operator
import successor/provider
import successor/providers/mock
import successor/registry
import successor/session
import successor/store

pub type Started {
  Started(
    supervisor_pid: Pid,
    store: Subject(store.Msg),
    operator: Subject(operator.Msg),
    /// Turn events from every session (host observer).
    events: Subject(agent.TurnEvent),
    sessions: factory.Supervisor(session.Spec, Subject(session.Msg)),
    registry: Subject(registry.Msg(session.Msg)),
    config: Config,
    deployment: DeploymentId,
  )
}

pub fn start(
  config config: Config,
  events events: Subject(agent.TurnEvent),
) -> Result(Started, String) {
  case config.validate(config) {
    Error(e) -> Error(e)
    Ok(_) -> {
      let store_name = process.new_name(prefix: "successor_store")
      let operator_name = process.new_name(prefix: "successor_operator")
      let sessions_name = process.new_name(prefix: "successor_sessions")
      let registry_name: process.Name(registry.Msg(session.Msg)) =
        process.new_name(prefix: "successor_registry")
      let adapter = provider_from(config)
      let model = "successor-model"

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

      let sessions_child =
        supervision.worker(fn() {
          factory_supervisor_start(sessions_name, fn(spec: session.Spec) {
            session.start(spec: spec)
          })
        })

      let registry_child =
        supervision.worker(fn() { registry_start(registry_name) })

      let tree =
        supervisor.new(supervisor.OneForOne)
        |> supervisor.add(store_child)
        |> supervisor.add(operator_child)
        |> supervisor.add(sessions_child)
        |> supervisor.add(registry_child)
        // Provider supervisor slot (adapter children arrive with Phase 2).
        |> supervisor.add(
          supervision.supervisor(fn() {
            supervisor.new(supervisor.OneForOne) |> supervisor.start
          }),
        )

      start_under_keeper(
        tree,
        store_name,
        operator_name,
        events,
        sessions_name,
        registry_name,
        adapter,
        model,
        config,
      )
    }
  }
}

/// Create a session and start its runtime under the session factory.
/// Returns the durable SessionId: the identity callers hold, never a
/// pid-bound handle. Resolve to a live handle via `session_of`.
pub fn start_session(
  host host: Started,
  name name: String,
) -> Result(ids.SessionId, String) {
  let reply = process.new_subject()
  process.send(host.store, store.CreateSession(name, reply))
  let created = case process.receive(reply, 10_000) {
    Ok(Ok(s)) -> Ok(s)
    Ok(Error(_)) -> Error("session create failed")
    Error(_) -> Error("store did not reply")
  }
  case created {
    Error(e) -> Error(e)
    Ok(s) -> {
      let spec =
        session.Spec(
          session: s.id,
          branch: s.current_branch,
          store: host.store,
          adapter: host_adapter(host),
          model: "successor-model",
          events: host.events,
          registry: host.registry,
        )
      case factory.start_child(host.sessions, spec) {
        Ok(_started) -> Ok(s.id)
        Error(_) -> Error("session runtime failed to start")
      }
    }
  }
}

/// Resolve a session id to its CURRENT runtime handle. Survives restarts of
/// the session runtime: each incarnation registers itself on startup.
pub fn session_of(
  host host: Started,
  session session: ids.SessionId,
) -> Result(Subject(session.Msg), Nil) {
  registry.lookup(host.registry, key: session.value)
}

fn host_adapter(host: Started) -> provider.Adapter {
  host_adapter_of(host.config)
}

fn provider_from(config: Config) -> provider.Adapter {
  host_adapter_of(config)
}

fn host_adapter_of(config: Config) -> provider.Adapter {
  case config.providers {
    [first, ..] -> mock.from_config(first)
    [] -> mock.adapter(settings: mock.default_settings())
  }
}

/// Spawn the keeper (unlinked), which starts the tree linked to itself and
/// traps exit signals from it.
fn start_under_keeper(
  tree: supervisor.Builder,
  store_name: process.Name(store.Msg),
  operator_name: process.Name(operator.Msg),
  events: Subject(agent.TurnEvent),
  sessions_name: process.Name(
    factory.Message(session.Spec, Subject(session.Msg)),
  ),
  registry_name: process.Name(registry.Msg(session.Msg)),
  adapter: provider.Adapter,
  model: String,
  config: Config,
) -> Result(Started, String) {
  let ack = process.new_subject()

  let _keeper =
    spawn_unlinked(fn() {
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
      let _ = adapter
      let _ = model
      let host =
        Started(
          supervisor_pid: supervisor_pid,
          store: process.named_subject(store_name),
          operator: process.named_subject(operator_name),
          events: events,
          sessions: factory.get_by_name(sessions_name),
          registry: process.named_subject(registry_name),
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

@external(erlang, "successor_ffi", "spawn_unlinked")
fn spawn_unlinked(running: fn() -> anything) -> Pid

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

fn registry_start(
  name: process.Name(registry.Msg(session.Msg)),
) -> actor.StartResult(Subject(registry.Msg(session.Msg))) {
  case registry.start(name: name) {
    Ok(started) -> Ok(started)
    Error(e) -> Error(e)
  }
}

fn factory_supervisor_start(
  name: process.Name(factory.Message(session.Spec, Subject(session.Msg))),
  template: fn(session.Spec) -> actor.StartResult(Subject(session.Msg)),
) -> actor.StartResult(factory.Supervisor(session.Spec, Subject(session.Msg))) {
  factory.start(factory.worker_child(template) |> factory.named(name))
}
