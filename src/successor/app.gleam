//// The host: supervision root and lifecycle (chapter 23.1A).
////
//// Tree ownership, one slot per live-resource kind, so ownership boundaries
//// never move as phases add children:
////
////   root (rest_for_one)
////   ├── DeploymentStore worker   (single durable writer)
////   ├── Operator worker          (single operator authority)
////   ├── Session supervisor       (keyed by durable session ID)
////   └── Provider supervisor      (empty until 1D)
////
//// Zero configured providers is a valid, cleanly startable state.
////
//// Link ownership: the supervision root links to a dedicated keeper process,
//// never to the caller of `start`. The keeper traps exits and performs
//// ordered shutdown on request; a crashing tree therefore cannot take the
//// caller with it, and `stop` cannot leak the tree either.

import gleam/erlang/process.{type Pid, type Subject, ExitMessage}
import gleam/list
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import successor/agent
import successor/calls
import successor/config.{type Config}
import successor/db
import successor/ids.{type DeploymentId}
import successor/logging
import successor/operator
import successor/provider
import successor/providers/mock
import successor/python
import successor/registry
import successor/session
import successor/session_supervisor
import successor/store
import successor/workspace_types
import successor/workspaces

pub type Started {
  Started(
    supervisor_pid: Pid,
    store: Subject(store.Msg),
    operator: Subject(operator.Msg),
    /// Turn events from every session (host observer).
    events: Subject(agent.TurnEvent),
    sessions: session_supervisor.Supervisor,
    registry: Subject(registry.Msg(session.Msg)),
    config: Config,
    workspaces: Subject(workspaces.Msg),
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
      let workspaces_name = process.new_name(prefix: "successor_workspaces")
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

      let workspaces_child =
        supervision.worker(fn() {
          workspaces.start(
            process.named_subject(store_name),
            config.data_dir,
            workspaces_name,
          )
        })

      let operator_child =
        supervision.worker(fn() {
          case operator.start(config: config, name: operator_name) {
            Ok(started) -> Ok(started)
            Error(e) -> Error(e)
          }
        })

      let sessions_child =
        supervision.supervisor(fn() { session_supervisor.start(sessions_name) })

      let registry_child =
        supervision.worker(fn() { registry_start(registry_name) })

      let tree =
        supervisor.new(supervisor.RestForOne)
        |> supervisor.add(store_child)
        |> supervisor.add(workspaces_child)
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
        workspaces_name,
        adapter,
        model,
        config,
      )
    }
  }
}

/// Create a session and start its runtime under the session supervisor.
/// Returns the durable SessionId: the identity callers hold, never a
/// pid-bound handle. Resolve to a live handle via `session_of`.
pub fn start_session(
  host host: Started,
  name name: String,
) -> Result(ids.SessionId, String) {
  let created = case
    calls.call(host.store, store.CreateSession(name, _), 10_000)
  {
    Ok(Ok(s)) -> Ok(s)
    Ok(Error(_)) -> Error("session create failed")
    Error(_) -> Error("store did not reply")
  }
  case created {
    Error(e) -> Error(e)
    Ok(saved) ->
      case open_saved_session(host, saved) {
        Ok(id) -> Ok(id)
        Error(_) -> Error("session runtime failed to start")
      }
  }
}

/// Stable resident workspace, independent of project directories and models.
pub fn root_workspace(
  host: Started,
  session: ids.SessionId,
) -> Result(workspace_types.AgentWorkspace, String) {
  workspaces.root(host.workspaces, session, "resident")
}

/// Creates an independent child execution workspace, not a model inference job.
pub fn child_workspace(
  host: Started,
  parent: ids.AgentId,
  name: String,
) -> Result(workspace_types.AgentWorkspace, String) {
  workspaces.child(host.workspaces, parent, name)
}

pub fn execute_python(
  host: Started,
  agent: ids.AgentId,
  source: String,
  limits: python.Limits,
) -> Result(workspace_types.Cell, String) {
  workspaces.execute(host.workspaces, agent, source, limits)
}

pub fn inspect_python(
  host: Started,
  id: String,
) -> Result(workspace_types.Cell, String) {
  workspaces.inspect(host.store, id)
}

pub fn close_python(host: Started, agent: ids.AgentId) -> Result(Nil, String) {
  workspaces.close(host.workspaces, agent)
}

/// Resolve a session id to its CURRENT runtime handle. Survives restarts of
/// the session runtime: each incarnation registers itself on startup.
pub fn session_of(
  host host: Started,
  session session: ids.SessionId,
) -> Result(Subject(session.Msg), Nil) {
  case registry.lookup(host.registry, key: session.value) {
    Error(_) -> Error(Nil)
    Ok(subject) ->
      case process.subject_owner(subject) {
        Ok(pid) ->
          case process.is_alive(pid) {
            True -> Ok(subject)
            False -> Error(Nil)
          }
        Error(_) -> Error(Nil)
      }
  }
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
  sessions_name: process.Name(session_supervisor.Msg),
  registry_name: process.Name(registry.Msg(session.Msg)),
  workspaces_name: process.Name(workspaces.Msg),
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
          sessions: session_supervisor.get_by_name(sessions_name),
          registry: process.named_subject(registry_name),
          config: config,
          workspaces: process.named_subject(workspaces_name),
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

/// Reopen an exact durable session without creating catalog/branch entries
/// or replaying work. The persisted branch selects history; the current
/// host configuration selects the provider. Lookup the live handle through
/// `session_of`, including after later runtime/registry restarts.
pub fn open_session(
  host host: Started,
  session id: ids.SessionId,
) -> Result(ids.SessionId, OpenSessionError) {
  case calls.call(host.store, store.GetSession(id, _), 10_000) {
    Error(_) -> Error(StoreUnavailable)
    Ok(Error(error)) -> Error(DurableStore(error))
    Ok(Ok(saved)) -> open_saved_session(host, saved)
  }
}

pub type OpenSessionError {
  DurableStore(db.StoreError)
  StoreUnavailable
  RuntimeRestarting
  RuntimeUnavailable
  RuntimeFailed(String)
}

fn open_saved_session(host: Started, saved: db.Session) {
  // Preserve main's selected-branch validation before any new durable workspace
  // entry. Session ownership is serialized by the keyed OTP child catalog, not
  // by registry presence: registry loss may not create another live owner.
  case calls.call(host.store, store.ListBranches(saved.id, _), 10_000) {
    Error(_) -> Error(StoreUnavailable)
    Ok(Error(error)) -> Error(DurableStore(error))
    Ok(Ok(branches)) ->
      case
        list.any(branches, fn(branch) { branch.id == saved.current_branch })
      {
        False -> Error(DurableStore(db.Corrupt("selected branch is missing")))
        True ->
          case root_workspace(host, saved.id) {
            Error(reason) -> Error(RuntimeFailed(reason))
            Ok(_) -> {
              let spec =
                session.Spec(
                  session: saved.id,
                  branch: saved.current_branch,
                  store: host.store,
                  adapter: host_adapter(host),
                  model: "successor-model",
                  events: host.events,
                  registry: host.registry,
                )
              case session_supervisor.start_child(host.sessions, spec) {
                Ok(_) -> Ok(saved.id)
                Error(session_supervisor.Restarting) -> Error(RuntimeRestarting)
                Error(session_supervisor.Unavailable) ->
                  Error(RuntimeUnavailable)
                Error(session_supervisor.StartFailed(reason)) ->
                  Error(RuntimeFailed(reason))
              }
            }
          }
      }
  }
}
