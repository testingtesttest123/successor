//// AgentRuntime (chapter 23.1A/1F): executes one turn at a time.
////
//// A turn: durable user record -> ContextPlan -> durable provider-attempt
//// intent -> async provider call -> completion carrying full identity
//// (attempt + activation + generation) -> durable assistant record +
//// attempt completion. Completions that do not match the CURRENT
//// activation/generation are rejected and never settle into history
//// (chapter 23.1F gate). All state lives in this actor — no global mutable
//// maps reconstruct it (chapter 23.1F gate).
////
//// Durability ownership: every durable write goes through the
//// DeploymentStore actor. The agent never touches the database itself.

import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
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
  Active(activation: ActivationId, generation: Int, attempt: ProviderAttemptId)
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
        Some(Active(a, g, _)) -> a != activation || g != generation
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
  }
}

fn start_turn(
  state: State,
  user_text: String,
  reply: Subject(Result(ActivationId, String)),
) -> actor.Next(State, Msg) {
  // 1. Durable user record first (chapter 23.1F required path).
  let user_payload =
    json.to_string(
      json.array([provider.TextBlock(user_text)], encode_block),
    )
  case
    ask_store(state.store, fn(r: Subject(Result(db.Record, db.StoreError))) {
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
      let generation = state.generation + 1
      let activation = ids.new_activation_id()
      let attempt = ids.new_provider_attempt_id()
      // 2. Context plan over the whole tail (passthrough).
      let records_result = ask_store(
        state.store,
        fn(r: Subject(Result(List(db.Record), db.StoreError))) {
          store.ListRecords(session: state.session, branch: state.branch, reply: r)
        },
      )
      let empty: List(db.Record) = []
      let records = result.unwrap(records_result, empty)
      let plan = context.plan(policy: Passthrough, records: records)
      // 3. Durable attempt intent BEFORE the call (chapter 22.7 boundary).
      let _ =
        ask_store(state.store, fn(r: Subject(Result(Nil, db.StoreError))) {
          store.CreateAttempt(
            id: attempt,
            session: state.session,
            activation: activation.value,
            provider_name: state.adapter.id,
            model: state.model,
            reply: r,
          )
        })
      // 4. Async dispatch: the provider runs in its own process; the
      // completion carries attempt + activation + generation.
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
      process.spawn(fn() {
        let result = adapter.complete(request, option_none())
        process.send(self, ProviderDone(attempt, activation, generation, result))
      })
      process.send(reply, Ok(activation))
      emit(state.events, TurnStarted(state.session, activation))
      actor.continue(
        State(..state, generation: generation, active: Some(Active(activation, generation, attempt))),
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
  let cleared = State(..state, active: None)
  case result {
    Ok(response) -> {
      let usage = response.usage
      let _ =
        ask_store(state.store, fn(r: Subject(Result(Nil, db.StoreError))) {
          store.CompleteAttempt(
            id: attempt,
            status: "completed",
            usage_input: Some(usage.input_tokens),
            usage_output: Some(usage.output_tokens),
            reply: r,
          )
        })
      let payload =
        json.to_string(json.array(response.blocks, encode_block))
      case
        ask_store(cleared.store, fn(r: Subject(Result(db.Record, db.StoreError))) {
          store.AppendRecord(
            session: cleared.session,
            branch: cleared.branch,
            kind: "assistant",
            payload: payload,
            reply: r,
          )
        })
      {
        Ok(record) -> {
          emit(cleared.events, TurnCompleted(cleared.session, activation, record))
          actor.continue(cleared)
        }
        Error(e) -> {
          emit(cleared.events, TurnFailed(cleared.session, activation, "assistant record failed: " <> e))
          actor.continue(cleared)
        }
      }
    }
    Error(failure) -> {
      let status = case failure {
        provider.Aborted -> "aborted"
        _ -> "failed"
      }
      let _ =
        ask_store(cleared.store, fn(r: Subject(Result(Nil, db.StoreError))) {
          store.CompleteAttempt(
            id: attempt,
            status: status,
            usage_input: None,
            usage_output: None,
            reply: r,
          )
        })
      emit(cleared.events, TurnFailed(cleared.session, activation, describe_failure(failure)))
      actor.continue(cleared)
    }
  }
}

// --- helpers --------------------------------------------------------------

fn ask_store(
  store: Subject(store.Msg),
  make: fn(Subject(Result(a, db.StoreError))) -> store.Msg,
) -> Result(a, String) {
  let reply = process.new_subject()
  process.send(store, make(reply))
  // The reply carries the store's full Result; flatten both layers into
  // a single Result(a, String) so call sites stay readable.
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

fn option_none() -> Option(Subject(provider.Abort)) {
  None
}
