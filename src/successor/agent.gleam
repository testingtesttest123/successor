//// AgentRuntime (chapter 23.1A/1F): executes one turn at a time.
////
//// A turn: durable user record -> history read -> ContextPlan -> durable
//// provider-attempt INTENT (the call may not proceed if the intent cannot
//// be saved) -> provider call in an unlinked monitored process -> completion
//// carrying full identity (attempt + activation + generation) -> durable
//// assistant record -> durable terminal receipt (only a turn whose receipt
//// was saved reports TurnCompleted). Completions that do not match the
//// CURRENT activation/generation are rejected and never settle into history
//// (chapter 23.1F gate). Every failure path reports honestly — a failed
//// history read must never silently become empty model context, and a turn
//// whose receipt was not durably recorded is reported as failed/uncertain,
//// never completed.
////
//// Durability ownership: every durable write goes through the
//// DeploymentStore actor. All state lives in this actor — no global mutable
//// maps reconstruct it.

import gleam/erlang/process.{type Monitor, type Pid, type Subject, ProcessDown}
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import successor/context.{Passthrough}
import successor/db
import successor/ids.{
  type ActivationId, type BranchId, type ProviderAttemptId, type SessionId,
}
import successor/logging
import successor/provider.{type Adapter, type Failure}
import successor/store

pub type Msg {
  /// Begin a turn. Rejected while a turn is in flight: one owner, one
  /// activation at a time.
  Activate(user_text: String, reply: Subject(Result(ActivationId, String)))
  /// Asynchronous provider completion. Carries full identity.
  ProviderDone(
    attempt: ProviderAttemptId,
    activation: ActivationId,
    generation: Int,
    result: Result(provider.Response, Failure),
  )
  /// The dispatch process died without delivering a completion: treat as
  /// outcome-unknown failure for the matching activation only.
  DispatchDown(pid: Pid)
  /// Monitor noise from ports (this host creates none) — ignored.
  DownIgnored
}

/// Turn events delivered to the session/host observer.
pub type TurnEvent {
  TurnStarted(session: SessionId, activation: ActivationId)
  TurnCompleted(
    session: SessionId,
    activation: ActivationId,
    assistant_record: db.Record,
  )
  TurnFailed(session: SessionId, activation: ActivationId, reason: String)
}

type Active {
  Active(
    activation: ActivationId,
    generation: Int,
    attempt: ProviderAttemptId,
    dispatch: Pid,
    monitor: Monitor,
  )
}

type State {
  State(
    self: Subject(Msg),
    session: SessionId,
    branch: BranchId,
    store: Subject(store.Msg),
    adapter: Adapter,
    events: Subject(TurnEvent),
    model: String,
    generation: Int,
    active: Option(Active),
  )
}

pub type Spec {
  Spec(
    session: SessionId,
    branch: BranchId,
    store: Subject(store.Msg),
    adapter: Adapter,
    events: Subject(TurnEvent),
    model: String,
  )
}

/// Start the agent runtime actor.
pub fn start(spec spec: Spec) -> Result(Subject(Msg), String) {
  let builder =
    actor.new_with_initialiser(10_000, fn(subject) {
      // Own-subject + monitor messages: provider dispatches run unlinked, so
      // a crashing adapter cannot kill the agent, and a dead dispatch is
      // observed as a Down, not a silence.
      let selector =
        process.new_selector()
        |> process.select_map(subject, fn(m: Msg) { m })
        |> process.select_monitors(fn(down: process.Down) {
          case down {
            ProcessDown(_, pid, _) -> DispatchDown(pid)
            _ -> DownIgnored
          }
        })
      Ok(
        actor.initialised(State(
          self: subject,
          session: spec.session,
          branch: spec.branch,
          store: spec.store,
          adapter: spec.adapter,
          events: spec.events,
          model: spec.model,
          generation: 0,
          active: None,
        ))
        |> actor.selecting(selector)
        |> actor.returning(subject),
      )
    })
    |> actor.on_message(handle)
  case actor.start(builder) {
    Ok(started) -> Ok(started.data)
    Error(e) ->
      Error(case e {
        actor.InitTimeout -> "agent init timed out"
        actor.InitFailed(m) -> m
        actor.InitExited(_) -> "agent init exited"
      })
  }
}

fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Activate(user_text, reply) ->
      case state.active {
        Some(_) -> {
          process.send(reply, Error("turn already in flight"))
          actor.continue(state)
        }
        None -> start_turn(state, user_text, reply)
      }
    ProviderDone(attempt, activation, generation, result) -> {
      let stale = case state.active {
        Some(Active(a, g, _, _, _)) -> a != activation || g != generation
        None -> True
      }
      case stale {
        True -> {
          // A stale completion must never settle into history.
          logging.warn(name: "agent.stale_completion", fields: [
            logging.field("attempt", db.attempt_to_string(attempt)),
            logging.int_field("generation", generation),
          ])
          actor.continue(state)
        }
        False -> settle(state, attempt, activation, result)
      }
    }
    DownIgnored -> actor.continue(state)
    DispatchDown(pid) -> {
      // Only the CURRENT dispatch's death fails the turn; stale downs are
      // noise from already-settled generations.
      let matches = case state.active {
        Some(Active(_, _, _, dispatch, _)) -> dispatch == pid
        None -> False
      }
      case matches {
        False -> actor.continue(state)
        True -> {
          let assert Some(Active(activation, _, attempt, _, monitor)) =
            state.active
          process.demonitor_process(monitor)
          let cleared = State(..state, active: None)
          let _ =
            ask_store(cleared.store, fn(r) {
              store.CompleteAttempt(
                id: attempt,
                status: "aborted",
                usage_input: None,
                usage_output: None,
                reply: r,
              )
            })
          logging.warn(name: "agent.dispatch_died", fields: [
            logging.field("activation", activation.value),
          ])
          emit(
            cleared.events,
            TurnFailed(
              cleared.session,
              activation,
              "provider dispatch died before completing",
            ),
          )
          actor.continue(cleared)
        }
      }
    }
  }
}

fn start_turn(
  state: State,
  user_text: String,
  reply: Subject(Result(ActivationId, String)),
) -> actor.Next(State, Msg) {
  // 1. Durable user record first (chapter 23.1F required path).
  let user_payload =
    json.to_string(json.array([provider.TextBlock(user_text)], encode_block))
  case
    ask_store(state.store, fn(r) {
      store.AppendRecord(
        session: state.session,
        branch: state.branch,
        kind: "user",
        payload: user_payload,
        reply: r,
      )
    })
  {
    Error(e) -> {
      process.send(reply, Error("user record failed: " <> e))
      actor.continue(state)
    }
    Ok(_user_record) -> {
      // 2. History read. A failed read must NEVER become empty model
      // context: the turn fails here instead.
      case read_history(state) {
        Error(e) -> {
          process.send(reply, Error(e))
          actor.continue(state)
        }
        Ok(records) -> {
          let generation = state.generation + 1
          let activation = ids.new_activation_id()
          let attempt = ids.new_provider_attempt_id()
          dispatch_turn(state, records, generation, activation, attempt, reply)
        }
      }
    }
  }
}

fn read_history(state: State) -> Result(List(db.Record), String) {
  let records_result =
    ask_store(state.store, fn(r) {
      store.ListRecords(session: state.session, branch: state.branch, reply: r)
    })
  case records_result {
    Ok(records) -> Ok(records)
    Error(e) ->
      Error("history read failed, refusing to plan empty context: " <> e)
  }
}

fn dispatch_turn(
  state: State,
  records: List(db.Record),
  generation: Int,
  activation: ActivationId,
  attempt: ProviderAttemptId,
  reply: Subject(Result(ActivationId, String)),
) -> actor.Next(State, Msg) {
  // 3. Context plan over the whole tail (passthrough).
  let plan = context.plan(policy: Passthrough, records: records)
  // 4. Durable attempt intent BEFORE the call. If the intent cannot be
  // saved, the call does not proceed (chapter 22.7 boundary).
  case
    ask_store(state.store, fn(r) {
      store.CreateAttempt(
        id: attempt,
        session: state.session,
        activation: activation.value,
        provider_name: state.adapter.id,
        model: state.model,
        reply: r,
      )
    })
  {
    Error(e) -> {
      process.send(
        reply,
        Error("attempt intent not durable, call not made: " <> e),
      )
      actor.continue(state)
    }
    Ok(_) -> {
      // 5. Unlinked, monitored dispatch: a crashing adapter cannot kill the
      // agent, and a dead dispatch is observed as DispatchDown.
      let request =
        provider.Request(
          model: state.model,
          system: "",
          messages: plan.messages,
          tools: [],
          max_tokens: provider.default_max_tokens,
          attempt: attempt,
          continuation: provider.Fresh,
        )
      let self = state.self
      let adapter = state.adapter
      let dispatch =
        spawn_dispatch(fn() {
          let result = adapter.complete(request, None)
          process.send(
            self,
            ProviderDone(attempt, activation, generation, result),
          )
        })
      let monitor = process.monitor(dispatch)
      process.send(reply, Ok(activation))
      emit(state.events, TurnStarted(state.session, activation))
      actor.continue(
        State(
          ..state,
          generation: generation,
          active: Some(Active(
            activation,
            generation,
            attempt,
            dispatch,
            monitor,
          )),
        ),
      )
    }
  }
}

fn settle(
  state: State,
  attempt: ProviderAttemptId,
  activation: ActivationId,
  result: Result(provider.Response, Failure),
) -> actor.Next(State, Msg) {
  let assert Some(Active(_, _, _, _, monitor)) = state.active
  process.demonitor_process(monitor)
  let cleared = State(..state, active: None)
  case result {
    Ok(response) -> {
      // 6. Durable assistant record.
      let payload = json.to_string(json.array(response.blocks, encode_block))
      case
        ask_store(cleared.store, fn(r) {
          store.AppendRecord(
            session: cleared.session,
            branch: cleared.branch,
            kind: "assistant",
            payload: payload,
            reply: r,
          )
        })
      {
        Error(e) -> {
          // Transcript not durable: attempt records an honest failure.
          let _ =
            ask_store(cleared.store, fn(r) {
              store.CompleteAttempt(
                id: attempt,
                status: "failed",
                usage_input: None,
                usage_output: None,
                reply: r,
              )
            })
          emit(
            cleared.events,
            TurnFailed(
              cleared.session,
              activation,
              "assistant record failed: " <> e,
            ),
          )
          actor.continue(cleared)
        }
        Ok(record) -> {
          // 7. Terminal receipt LAST: it is the proof the turn settled. A
          // turn whose receipt could not be saved is reported as failed with
          // outcome-unknown, never as completed.
          let usage = response.usage
          case
            ask_store(cleared.store, fn(r) {
              store.CompleteAttempt(
                id: attempt,
                status: "completed",
                usage_input: Some(usage.input_tokens),
                usage_output: Some(usage.output_tokens),
                reply: r,
              )
            })
          {
            Error(e) -> {
              logging.error(name: "agent.receipt_not_durable", fields: [
                logging.field("reason", e),
              ])
              emit(
                cleared.events,
                TurnFailed(
                  cleared.session,
                  activation,
                  "terminal receipt not durable, outcome uncertain: " <> e,
                ),
              )
              actor.continue(cleared)
            }
            Ok(_) -> {
              emit(
                cleared.events,
                TurnCompleted(cleared.session, activation, record),
              )
              actor.continue(cleared)
            }
          }
        }
      }
    }
    Error(failure) -> {
      let status = case failure {
        provider.Aborted -> "aborted"
        _ -> "failed"
      }
      let _ =
        ask_store(cleared.store, fn(r) {
          store.CompleteAttempt(
            id: attempt,
            status: status,
            usage_input: None,
            usage_output: None,
            reply: r,
          )
        })
      emit(
        cleared.events,
        TurnFailed(cleared.session, activation, describe_failure(failure)),
      )
      actor.continue(cleared)
    }
  }
}

// --- helpers --------------------------------------------------------------

/// The dispatch runs UNLINKED: its death is observed via monitor, and it can
/// never take the agent down with it.
@external(erlang, "successor_ffi", "spawn_unlinked")
fn spawn_dispatch(running: fn() -> anything) -> Pid

fn ask_store(
  store: Subject(store.Msg),
  make: fn(Subject(Result(a, db.StoreError))) -> store.Msg,
) -> Result(a, String) {
  let reply = process.new_subject()
  process.send(store, make(reply))
  case process.receive(reply, 15_000) {
    Ok(Ok(value)) -> Ok(value)
    Ok(Error(e)) -> Error(describe_store_error(e))
    Error(_) -> Error("store did not reply")
  }
}

fn describe_store_error(e: db.StoreError) -> String {
  case e {
    db.OpenFailed(m) -> "open failed: " <> m
    db.Corrupt(m) -> "corrupt: " <> m
    db.AlreadyExists(m) -> "already exists: " <> m
    db.NotFound(m) -> "not found: " <> m
    db.Invalid(m) -> "invalid: " <> m
    db.AmbiguousName(m) -> "ambiguous: " <> m
  }
}

fn describe_failure(f: Failure) -> String {
  case f {
    provider.RateLimited(_) -> "rate limited"
    provider.AuthFailed -> "auth failed"
    provider.ContextTooLarge -> "context too large"
    provider.Network(m) -> "network: " <> m
    provider.Aborted -> "aborted"
    provider.Provider(m) -> "provider: " <> m
  }
}

fn encode_block(b: provider.ContentBlock) -> json.Json {
  case b {
    provider.TextBlock(text) ->
      json.object([#("type", json.string("text")), #("text", json.string(text))])
    provider.ThinkingBlock(thinking) ->
      json.object([
        #("type", json.string("thinking")),
        #("thinking", json.string(thinking)),
      ])
    provider.ToolUseBlock(id, name, input) ->
      json.object([
        #("type", json.string("tool_use")),
        #("id", json.string(id)),
        #("name", json.string(name)),
        #("input", json.string(input)),
      ])
    provider.ToolResultBlock(tool_use_id, content, is_error) ->
      json.object([
        #("type", json.string("tool_result")),
        #("toolUseId", json.string(tool_use_id)),
        #("content", json.string(content)),
        #("isError", json.bool(is_error)),
      ])
  }
}

fn emit(events: Subject(TurnEvent), event: TurnEvent) -> Nil {
  process.send(events, event)
  Nil
}
