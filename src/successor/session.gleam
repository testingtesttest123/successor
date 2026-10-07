//// SessionRuntime (chapter 23.1A/1F): the durable session's live owner.
////
//// One session runtime per open session (spawned under the keyed session
//// supervisor). It owns its AgentRuntime child and forwards turn events to
//// the host observer. Session state lives in the actor; the session
//// supervisor restarts it (and it re-anchors to the same durable session).

import gleam/erlang/process.{type Monitor, type Subject}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import successor/agent
import successor/db
import successor/ids.{type BranchId, type SessionId}
import successor/logging
import successor/provider.{type Adapter}
import successor/registry
import successor/store

pub type Msg {
  /// A session-actor request.
  SubmitUserText(text: String, reply: Subject(Result(ids.ActivationId, String)))
  /// The agent child's turn events, selected into this mailbox.
  FromAgent(agent.TurnEvent)
  /// Operator capability: which agent owns this session (future cancel /
  /// introspection surfaces address the agent through this).
  GetAgent(reply: Subject(Subject(agent.Msg)))
  /// Reconnect after the registry restarts or is temporarily unavailable.
  ConnectRegistry
  RegistryDown(process.Down)
}

pub type Spec {
  Spec(
    session: SessionId,
    branch: BranchId,
    store: Subject(store.Msg),
    adapter: Adapter,
    model: String,
    /// Host-level turn observer.
    events: Subject(agent.TurnEvent),
    /// Every incarnation registers itself on startup, so identity-based
    /// lookups survive factory restarts.
    registry: Subject(registry.Msg(Msg)),
  )
}

/// Start under the keyed session supervisor. The agent child is spawned in
/// the initialiser, so ownership is: supervisor -> session -> agent.
pub fn start(spec spec: Spec) -> actor.StartResult(Subject(Msg)) {
  let builder =
    actor.new_with_initialiser(10_000, fn(subject) {
      // The session selects its agent child's events into its own mailbox.
      let agent_events = process.new_subject()
      case
        agent.start(spec: agent.Spec(
          session: spec.session,
          branch: spec.branch,
          store: spec.store,
          adapter: spec.adapter,
          events: agent_events,
          model: spec.model,
        ))
      {
        Error(e) -> Error(e)
        Ok(agent_subject) -> {
          let selector =
            process.new_selector()
            |> process.select_map(subject, fn(m: Msg) { m })
            |> process.select_map(agent_events, FromAgent)
            |> process.select_monitors(RegistryDown)
          Ok(
            actor.initialised(
              connect_registry(State(
                self: subject,
                agent: agent_subject,
                session: spec.session,
                events: spec.events,
                registry: spec.registry,
                registry_monitor: None,
                retry_ms: 10,
              )),
            )
            |> actor.selecting(selector)
            |> actor.returning(subject),
          )
        }
      }
    })
    |> actor.on_message(handle)
  actor.start(builder)
}

type State {
  State(
    self: Subject(Msg),
    registry: Subject(registry.Msg(Msg)),
    registry_monitor: Option(Monitor),
    retry_ms: Int,
    agent: Subject(agent.Msg),
    session: SessionId,
    events: Subject(agent.TurnEvent),
  )
}

fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    ConnectRegistry -> actor.continue(connect_registry(state))
    RegistryDown(down) ->
      case down {
        process.ProcessDown(ref, _, _) if state.registry_monitor == Some(ref) ->
          actor.continue(connect_registry(
            State(..state, registry_monitor: None),
          ))
        _ -> actor.continue(state)
      }
    SubmitUserText(text, reply) -> {
      // Straight-through activation: the agent replies to the requester.
      // The completion event arrives via FromAgent.
      process.send(state.agent, agent.Activate(text, reply))
      actor.continue(state)
    }
    GetAgent(reply) -> {
      process.send(reply, state.agent)
      actor.continue(state)
    }
    FromAgent(event) -> {
      // Forward to the host observer; log the outcome.
      case event {
        agent.TurnCompleted(_, _, record) ->
          logging.info(name: "session.turn_completed", fields: [
            logging.field("record", record.id),
            logging.int_field("sequence", record.sequence),
          ])
        agent.TurnFailed(_, _, reason) ->
          logging.warn(name: "session.turn_failed", fields: [
            logging.field("reason", reason),
          ])
        agent.TurnStarted(_, _) -> Nil
      }
      process.send(state.events, event)
      actor.continue(state)
    }
  }
}

/// Operator capability: the session's agent owner.
pub fn agent_subject(sess: Subject(Msg)) -> Subject(agent.Msg) {
  let reply = process.new_subject()
  process.send(sess, GetAgent(reply))
  let assert Ok(subject) = process.receive(reply, 5000)
  subject
}

/// Convenience: submit text and receive the activation outcome.
pub fn submit(
  session: Subject(Msg),
  text text: String,
) -> Result(ids.ActivationId, String) {
  let reply = process.new_subject()
  process.send(session, SubmitUserText(text, reply))
  case process.receive(reply, 15_000) {
    Ok(result) -> result
    Error(_) -> Error("session did not reply")
  }
}

/// Convenience: list a session's canonical records through the store.
pub fn records(
  store: Subject(store.Msg),
  session session: SessionId,
  branch branch: BranchId,
) -> Result(List(db.Record), String) {
  let reply = process.new_subject()
  process.send(
    store,
    store.ListRecords(session: session, branch: branch, reply: reply),
  )
  case process.receive(reply, 10_000) {
    Ok(Ok(records)) -> Ok(records)
    Ok(Error(_)) -> Error("store error")
    Error(_) -> Error("store did not reply")
  }
}

// Monitor the exact incarnation that receives registration. If it dies
// before processing that message, DOWN triggers registration again. A
// capped backoff keeps sessions alive without spinning during an outage.
fn connect_registry(state: State) -> State {
  case state.registry_monitor {
    Some(_) -> state
    None ->
      case registry.connect(state.registry) {
        Ok(endpoint) -> {
          let assert Ok(pid) = process.subject_owner(endpoint)
          let monitor = process.monitor(pid)
          process.send(
            endpoint,
            registry.Register(state.session.value, state.self),
          )
          State(..state, registry_monitor: Some(monitor), retry_ms: 10)
        }
        Error(_) -> {
          let _ =
            process.send_after(state.self, state.retry_ms, ConnectRegistry)
          State(..state, retry_ms: int.min(state.retry_ms * 2, 1000))
        }
      }
  }
}
