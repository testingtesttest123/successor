//// Native actor/monitor/latch ordering and coalescing require controllable
//// provider barriers that HTTP and the unavailable Python kernel cannot expose.

import albedo/daemon/conversation
import albedo/daemon/session
import albedo/daemon/session_memory as memory
import albedo/daemon/store
import albedo/daemon/tool_results
import albedo/daemon/turn
import albedo/harness/compaction
import albedo/harness/extension
import albedo/harness/extension/selection
import albedo/harness/extensions
import albedo/harness/extensions/lcm/extension as lcm
import albedo/harness/extensions/lcm/graph
import albedo/harness/extensions/lcm/memory as lcm_memory
import albedo/harness/extensions/personality/extension as personality
import albedo/harness/extensions/personality/ledger
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import gleeunit/should
import harness/session_fixture

@external(erlang, "albedo_session_memory_test_support", "late_composition")
fn late_composition(runtime_owner: process.Pid, start: fn() -> a) -> a

@external(erlang, "albedo_runtime_test_support", "with_runtime")
fn with_runtime(run: fn() -> Nil) -> Dynamic

@external(erlang, "albedo_runtime_test_support", "start_with_config")
fn fixture_start_runtime(
  path: String,
  config: extensions.Config,
) -> Result(runtime.Runtime, actor.StartError)

@external(erlang, "albedo_runtime_test_support", "start_session")
fn fixture_start_session(
  host: runtime.Runtime,
  info: conversation.Info,
  home: String,
) -> Result(session.Session, actor.StartError)

@external(erlang, "albedo_session_memory_test_support", "fixture_cleanup")
fn fixture_cleanup(
  start: fn() -> #(runtime.Runtime, String, session.Session),
) -> Nil

pub fn background_memory_fixture_assertion_and_timeout_cleanup_test() -> Nil {
  fixture_cleanup(fn() {
    let #(host, home) = native_session_fixture(process.new_subject())
    let assert Ok(info) = conversation.get(runtime.ledger(host), "memory-owner")
    let assert Ok(owner) = fixture_start_session(host, info, home)
    #(host, home, owner)
  })
}

fn ended(job: memory.Job) -> process.Down {
  let assert Ok(down) =
    process.new_selector()
    |> process.select_specific_monitor(job.monitor, fn(down) { down })
    |> process.selector_receive(1000)
  down
}

pub fn memory_job_coalesces_without_occupying_foreground_admission_test() -> Nil {
  let started = process.new_subject()
  let state = memory.new(10)
  let state =
    memory.start(state, fn(_, _) {
      process.spawn_unlinked(fn() {
        let gate = process.new_subject()
        process.send(started, gate)
        let _: Nil = process.receive_forever(gate)
        Nil
      })
    })
  let assert Some(job) = state.job
  let assert Ok(gate) = process.receive(started, 1000)
  let state = memory.notify(state, 12) |> memory.notify(14)
  memory.start(state, fn(_, _) { panic as "a second worker cannot start" })
  |> should.equal(state)
  turn.admit(
    turn.Resting,
    turn.Submission("foreground", "foreground", "", turn.Chat, [], None, None),
    0,
  )
  |> should.equal(turn.Start)
  let state = memory.finished(state, job.generation, job.pid, Ok(False))
  state.job |> should.not_equal(None)
  process.send(gate, Nil)
  let #(state, consider) = memory.down(state, ended(job))
  state.job |> should.equal(None)
  should.be_true(consider)
  should.be_true(memory.needed(state))
}

pub fn memory_progress_yields_but_noop_and_error_stop_the_attempted_watermark_test() -> Nil {
  let outcomes = [Ok(True), Ok(False), Error("provider refused")]
  list.each(outcomes, fn(outcome) {
    let ready = process.new_subject()
    let state =
      memory.start(memory.new(10), fn(_, _) {
        process.spawn_unlinked(fn() {
          let gate = process.new_subject()
          process.send(ready, gate)
          let _: Nil = process.receive_forever(gate)
          Nil
        })
      })
    let assert Some(job) = state.job
    let assert Ok(gate) = process.receive(ready, 1000)
    let state = memory.finished(state, job.generation, job.pid, outcome)
    process.send(gate, Nil)
    let #(state, consider) = memory.down(state, ended(job))
    consider |> should.equal(outcome == Ok(True))
    memory.needed(state) |> should.equal(outcome == Ok(True))
    let next = memory.notify(state, 11)
    memory.needed(next) |> should.be_true
  })
}

pub fn native_adoption_rearms_failed_watermark_after_retiring_job_test() -> Nil {
  let ready = process.new_subject()
  let state =
    memory.start(memory.new(7), fn(_, _) {
      process.spawn_unlinked(fn() {
        let gate = process.new_subject()
        process.send(ready, gate)
        let _: Nil = process.receive_forever(gate)
        Nil
      })
    })
  let assert Some(job) = state.job
  let assert Ok(gate) = process.receive(ready, 1000)
  let state =
    memory.finished(
      state,
      job.generation,
      job.pid,
      Error("preparation deadline"),
    )
  let state = memory.rearm(state)
  memory.needed(state) |> should.equal(False)
  process.send(gate, Nil)
  let #(state, retry) = memory.down(state, ended(job))
  retry |> should.equal(True)
  memory.needed(state) |> should.equal(True)
  let state = memory.quiet(state)
  memory.needed(state) |> should.equal(False)
  memory.rearm(state) |> memory.needed |> should.equal(True)
}

pub fn invalidated_job_keeps_the_slot_until_matching_termination_test() -> Nil {
  let ready = process.new_subject()
  let state =
    memory.start(memory.new(10), fn(_, _) {
      process.spawn_unlinked(fn() {
        let gate = process.new_subject()
        process.send(ready, gate)
        let _: Nil = process.receive_forever(gate)
        Nil
      })
    })
  let assert Some(job) = state.job
  let assert Ok(gate) = process.receive(ready, 1000)
  let state = memory.invalidate(state)
  turn.raised(job.stop) |> should.be_true
  memory.needed(state) |> should.be_false
  memory.start(state, fn(_, _) { panic as "retiring worker still owns the slot" })
  |> should.equal(state)
  // An old result cannot reactivate this cancelled generation.
  let state = memory.finished(state, job.generation, job.pid, Ok(True))
  process.send(gate, Nil)
  let #(state, consider) = memory.down(state, ended(job))
  state.job |> should.equal(None)
  should.be_true(consider)
  should.be_true(memory.needed(state))
}

@external(erlang, "albedo_runtime_test_support", "temporary_workspace")
fn temporary_workspace() -> String

@external(erlang, "albedo_runtime_test_support", "cleanup_workspace")
fn cleanup_workspace(path: String) -> Nil

@external(erlang, "file", "write_file")
fn write_file(path: String, text: String) -> Dynamic

fn native_session_fixture(
  calls: process.Subject(process.Subject(Nil)),
) -> #(runtime.Runtime, String) {
  native_session_fixture_with(calls, [])
}

fn native_session_fixture_with(
  calls: process.Subject(process.Subject(Nil)),
  plugins: List(extension.Plugin),
) -> #(runtime.Runtime, String) {
  let home = temporary_workspace()
  let _ =
    write_file(
      home <> "/config.json",
      "{\"active\":\"provider\",\"providers\":{\"provider\":{\"extension\":\"memory-provider\",\"model\":\"model\",\"protocol\":\"responses\"}}}",
    )
  let upstream =
    extension.Upstream(
      "memory-test",
      types.Responses,
      fn(request, _) {
        request.tools |> should.equal([])
        let gate = process.new_subject()
        process.send(calls, gate)
        let _: Nil = process.receive_forever(gate)
        let assert Ok(item) =
          json.parse(
            "{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"I remember my native action.\"}]}",
            types.replay_decoder(types.Responses),
          )
        Ok(
          types.Turn(
            None,
            [item],
            [],
            Some(types.Usage(12, 4, None, None, None, None, None)),
            types.Complete,
            None,
            [],
          ),
        )
      },
      fn(_) { None },
      fn() { None },
      fn(_) { [] },
      types.any_images,
    )
  let provider =
    extension.Extension(
      "memory-provider",
      "native deterministic provider",
      [],
      [
        extension.ModelProviderPlugin(
          extension.ModelProvider("memory-provider", fn(_) {
            Some(Ok(upstream))
          }),
        ),
        ..plugins
      ],
      extension.no_initialise,
    )
  let bundle = personality.extension()
  let bundle =
    extension.Extension(
      ..bundle,
      plugins: list.map(bundle.plugins, fn(plugin) {
        case plugin {
          extension.CompactionPlugin(_) ->
            extension.CompactionPlugin(
              compaction.Strategy("personality", fn(_, reader) {
                lcm.strategy("personality").resolve(
                  Some(compaction.Capacity(20_000, "native test catalog")),
                  reader,
                )
              }),
            )
          _ -> plugin
        }
      }),
    )
  let installed = [bundle, lcm_memory.extension(), provider]
  let assert Ok(host) =
    fixture_start_runtime(
      ":memory:",
      extensions.Config(installed, ["lcm-memory", "memory-provider"]),
    )
  session_fixture.initialise(host)
  session_fixture.create(host, "memory-owner", home)
  let assert Ok(persona) =
    ledger.create(runtime.ledger(host), "Ash", "Living identity", True, False)
  ledger.bind(runtime.ledger(host), "memory-owner", persona.id, 0, 0, installed)
  |> should.be_ok
  conversation.commit_from(
    runtime.ledger(host),
    "memory-owner",
    [
      types.User("older actual task"),
      types.Assistant("older native action"),
      types.User("newest raw unit"),
      types.Assistant("raw latest action"),
    ],
    conversation.Idle,
    None,
  )
  |> should.be_ok
  #(host, home)
}

pub fn actual_session_load_runs_memory_without_kernel_or_foreground_busy_test_() -> Dynamic {
  with_runtime(
    actual_session_load_runs_memory_without_kernel_or_foreground_busy_case,
  )
}

fn actual_session_load_runs_memory_without_kernel_or_foreground_busy_case() -> Nil {
  let calls = process.new_subject()
  let #(host, home) = native_session_fixture(calls)
  let assert Ok(info) = conversation.get(runtime.ledger(host), "memory-owner")
  let assert Ok(owner) = fixture_start_session(host, info, home)
  let first = process.receive(calls, 1000)
  // Load recovery must begin below overflow through the actual session actor.
  first |> should.be_ok
  let assert Ok(gate) = first
  let report = actor.call(owner, 1000, session.Idle)
  report.running |> should.be_false
  report.kernel |> should.equal(None)
  graph.frontier(runtime.ledger(host), "memory-owner") |> should.equal(Ok([]))
  process.send(gate, Nil)
  let graph_ready = process.new_subject()
  process.spawn_unlinked(fn() { await_frontier(host, graph_ready, 100) })
  process.receive(graph_ready, 2000) |> should.equal(Ok(True))
  let assert Ok(rows) =
    conversation.load_sources(runtime.ledger(host), "memory-owner")
  list.length(rows) |> should.equal(4)
  let assert Ok([node]) = graph.frontier(runtime.ledger(host), "memory-owner")
  let assert Ok(second) = list.first(list.drop(rows, 1))
  node.last_seq |> should.equal(second.source.seq)
  session.close(owner)
  runtime.stop(host)
  cleanup_workspace(home)
}

pub fn late_composition_only_success_rearms_quiet_memory_without_new_source_test_() -> Dynamic {
  with_runtime(
    late_composition_only_success_rearms_quiet_memory_without_new_source_case,
  )
}

fn late_composition_only_success_rearms_quiet_memory_without_new_source_case() -> Nil {
  let calls = process.new_subject()
  let #(host, home) = native_session_fixture(calls)
  let db = runtime.ledger(host)
  let assert Ok(info) = conversation.get(db, "memory-owner")
  let assert Ok(runtime_owner) = process.subject_owner(host.subject)
  let owner =
    late_composition(runtime_owner, fn() {
      let assert Ok(owner) = fixture_start_session(host, info, home)
      owner
    })
  // Actual composition installation happened after the native15s deadline.
  // It must retry the same durable backlog without Python or another commit.
  let call = process.receive(calls, 2000)
  let cursor = graph.last_seq(db, "memory-owner")
  let idle = actor.call(owner, 1000, session.Idle)
  session.close(owner)
  runtime.stop(host)
  cleanup_workspace(home)
  call |> should.be_ok
  cursor |> should.equal(Ok(0))
  idle.running |> should.be_false
  idle.kernel |> should.equal(None)
}

pub fn completion_notifies_actual_adoption_once_but_not_cached_preparation_test_() -> Dynamic {
  with_runtime(
    completion_notifies_actual_adoption_once_but_not_cached_preparation_case,
  )
}

fn completion_notifies_actual_adoption_once_but_not_cached_preparation_case() -> Nil {
  let calls = process.new_subject()
  let adopted = process.new_subject()
  let #(host, home) = native_session_fixture(calls)
  let callback = fn() { process.send(adopted, Nil) }
  runtime.prepare_composition_notify(host, "memory-owner", home, callback)
  |> should.be_ok
  process.receive(adopted, 1000) |> should.equal(Ok(Nil))
  runtime.prepare_composition_notify(host, "memory-owner", home, callback)
  |> should.be_ok
  process.receive(adopted, 50) |> should.equal(Error(Nil))
  process.receive(calls, 0) |> should.equal(Error(Nil))
  runtime.stop(host)
  cleanup_workspace(home)
}

pub fn stale_or_cancelled_completion_cannot_rearm_an_attempted_watermark_test() -> Nil {
  let state = memory.quiet(memory.new(7))
  let stop = turn.latch()
  memory.composition_ready(state, state.generation + 1, stop)
  |> should.equal(state)
  turn.raise(stop)
  memory.composition_ready(state, state.generation, stop) |> should.equal(state)
  memory.needed(state) |> should.be_false
  let valid = memory.composition_ready(state, state.generation, turn.latch())
  memory.needed(valid) |> should.be_true
  memory.quiet(valid) |> memory.needed |> should.be_false
}

pub fn closed_owner_ignores_late_composition_and_has_no_memory_call_test_() -> Dynamic {
  with_runtime(
    closed_owner_ignores_late_composition_and_has_no_memory_call_case,
  )
}

fn closed_owner_ignores_late_composition_and_has_no_memory_call_case() -> Nil {
  let calls = process.new_subject()
  let preparing = process.new_subject()
  let #(host, home) =
    native_session_fixture_with(calls, [
      extension.ContextPlugin(fn(_) {
        let gate = process.new_subject()
        process.send(preparing, gate)
        let _: Nil = process.receive_forever(gate)
        Ok("held native composition")
      }),
    ])
  let assert Ok(info) = conversation.get(runtime.ledger(host), "memory-owner")
  let assert Ok(owner) = fixture_start_session(host, info, home)
  let assert Ok(gate) = process.receive(preparing, 1000)
  let assert Ok(worker) = process.subject_owner(gate)
  let monitor = process.monitor(worker)
  session.close(owner)
  process.send(gate, Nil)
  process.new_selector()
  |> process.select_specific_monitor(monitor, fn(_) { Nil })
  |> process.selector_receive(1000)
  |> should.equal(Ok(Nil))
  process.receive(calls, 100) |> should.equal(Error(Nil))
  graph.last_seq(runtime.ledger(host), "memory-owner") |> should.equal(Ok(0))
  runtime.loaded_sessions(host) |> should.equal([])
  runtime.stop(host)
  cleanup_workspace(home)
}

fn await_frontier(
  host: runtime.Runtime,
  reply: process.Subject(Bool),
  remaining: Int,
) -> Nil {
  case graph.frontier(runtime.ledger(host), "memory-owner"), remaining {
    Ok([_, ..]), _ -> process.send(reply, True)
    _, 0 -> process.send(reply, False)
    _, _ -> {
      process.sleep(5)
      await_frontier(host, reply, remaining - 1)
    }
  }
}

@external(erlang, "albedo_session_memory_test_support", "queued")
fn queued(owner: process.Pid) -> Bool

type FenceMessage {
  Begin(fn(process.Pid, turn.Latch) -> Nil, process.Subject(Nil))
  CloseFence(process.Subject(Result(Nil, String)))
}

fn fence_owner(db: store.Store) -> process.Subject(FenceMessage) {
  let assert Ok(started) =
    actor.new(memory.new(4))
    |> actor.on_message(fn(state, message) {
      case message {
        Begin(run, ready) -> {
          let owner = process.self()
          let state =
            memory.start(state, fn(_, stop) {
              process.spawn_unlinked(fn() { run(owner, stop) })
            })
          process.send(ready, Nil)
          actor.continue(state)
        }
        CloseFence(reply) -> {
          process.send(reply, memory.close(state, db))
          actor.stop()
        }
      }
    })
    |> actor.start
  started.data
}

pub fn close_fence_covers_queued_and_already_checked_graph_transactions_test_() -> Dynamic {
  with_runtime(
    close_fence_covers_queued_and_already_checked_graph_transactions_case,
  )
}

fn close_fence_covers_queued_and_already_checked_graph_transactions_case() -> Nil {
  list.each([False, True], fn(already_checked) {
    let #(host, home) = native_session_fixture(process.new_subject())
    let db = runtime.ledger(host)
    let assert Ok([a, b, c, d]) = conversation.load_sources(db, "memory-owner")
    let assert Ok(snapshot) = graph.snapshot(db, "memory-owner")
    let held = process.new_subject()
    let ready = process.new_subject()
    let ack = process.new_subject()
    let owner = fence_owner(db)
    case already_checked {
      False -> {
        process.spawn_unlinked(fn() {
          let _ =
            store.query(db, fn(_) {
              let gate = process.new_subject()
              process.send(held, gate)
              let _: Nil = process.receive_forever(gate)
              Ok(Nil)
            })
          Nil
        })
        Nil
      }
      True -> Nil
    }
    let queued_gate = case already_checked {
      False -> Some(process.receive(held, 1000) |> should.be_ok)
      True -> None
    }
    process.send(
      owner,
      Begin(
        fn(owner_pid, stop) {
          let _ =
            graph.commit_leaves(
              db,
              "memory-owner",
              snapshot,
              [
                graph.Leaf(
                  a.source.seq,
                  b.source.seq,
                  "actual older memory",
                  None,
                ),
              ],
              fn(_) {
                let valid = memory.active(owner_pid, stop)
                case already_checked {
                  False -> Nil
                  True -> {
                    let gate = process.new_subject()
                    process.send(held, gate)
                    let _: Nil = process.receive_forever(gate)
                    Nil
                  }
                }
                Ok(valid)
              },
            )
          Nil
        },
        ready,
      ),
    )
    process.receive(ready, 1000) |> should.equal(Ok(Nil))
    let gate = case queued_gate {
      Some(gate) -> {
        queued(store.owner(db)) |> should.be_true
        gate
      }
      None -> process.receive(held, 1000) |> should.be_ok
    }
    process.send(owner, CloseFence(ack))
    // Acknowledgment cannot overtake either native store closure.
    process.receive(ack, 150) |> should.equal(Error(Nil))
    process.send(gate, Nil)
    process.receive(ack, 2000) |> should.equal(Ok(Ok(Nil)))
    let expected = case already_checked {
      True -> b.source.seq
      False -> 0
    }
    graph.last_seq(db, "memory-owner") |> should.equal(Ok(expected))
    conversation.load_sources(db, "memory-owner")
    |> should.equal(Ok([a, b, c, d]))
    runtime.stop(host)
    cleanup_workspace(home)
  })
}

pub fn actor_load_settles_legacy_rows_before_memory_captures_source_identity_test_() -> Dynamic {
  with_runtime(
    actor_load_settles_legacy_rows_before_memory_captures_source_identity_case,
  )
}

fn actor_load_settles_legacy_rows_before_memory_captures_source_identity_case() -> Nil {
  let calls = process.new_subject()
  let #(host, home) = native_session_fixture(calls)
  let db = runtime.ledger(host)
  let assert Ok(call) =
    json.parse(
      "{\"type\":\"function_call\",\"call_id\":\"legacy-call\",\"name\":\"read_file\",\"arguments\":\"{}\"}",
      types.replay_decoder(types.Responses),
    )
  conversation.commit_from(
    db,
    "memory-owner",
    [
      types.User("legacy older task"),
      types.Replay(call),
      types.ToolOutput("legacy-call", "actual legacy result", []),
      types.Assistant("after result"),
      types.User("newest raw unit"),
      types.Assistant("newest raw answer"),
    ],
    conversation.Idle,
    None,
  )
  |> should.be_ok
  let assert Ok([_, _, _, _, _, _, tool, later, _, _] as settled) =
    conversation.load_sources(db, "memory-owner")
  let assert Ok(before) = conversation.last_seq(db, "memory-owner")
  // Native row moves reproduce the retained legacy out-of-order layout.
  conversation.move_rows(db, "memory-owner", [
    #(tool.source.seq, later.source.seq),
    #(later.source.seq, tool.source.seq),
  ])
  |> should.be_ok
  conversation.load_sources(db, "memory-owner") |> should.not_equal(Ok(settled))
  let assert Ok(info) = conversation.get(db, "memory-owner")
  let assert Ok(owner) = fixture_start_session(host, info, home)
  let assert Ok(_gate) = process.receive(calls, 1000)
  conversation.last_seq(db, "memory-owner") |> should.equal(Ok(before))
  conversation.load_sources(db, "memory-owner") |> should.equal(Ok(settled))
  session.close(owner)
  runtime.stop(host)
  cleanup_workspace(home)
}

pub fn source_notifications_coalesce_and_stale_return_keeps_native_usage_test_() -> Dynamic {
  with_runtime(
    source_notifications_coalesce_and_stale_return_keeps_native_usage_case,
  )
}

fn source_notifications_coalesce_and_stale_return_keeps_native_usage_case() -> Nil {
  let calls = process.new_subject()
  let #(host, home) = native_session_fixture(calls)
  let db = runtime.ledger(host)
  let assert Ok(info) = conversation.get(db, "memory-owner")
  let assert Ok(owner) = fixture_start_session(host, info, home)
  let assert Ok(first) = process.receive(calls, 1000)
  conversation.commit_from(
    db,
    "memory-owner",
    [
      types.User("foreground durable append"),
      types.Assistant("foreground completion"),
    ],
    conversation.Idle,
    None,
  )
  |> should.be_ok
  // The private host notification has no supplied ID, prose or watermark.
  process.send(owner, session.MemoryConsider)
  process.send(owner, session.MemoryConsider)
  process.receive(calls, 50) |> should.equal(Error(Nil))
  actor.call(owner, 1000, session.Idle).running |> should.be_false
  process.send(first, Nil)
  let assert Ok(second) = process.receive(calls, 2000)
  // The first returned provider result cannot advance its stale source cut.
  graph.last_seq(db, "memory-owner") |> should.equal(Ok(0))
  store.read(
    db,
    "SELECT kind,input_tokens,output_tokens,seq FROM provider_requests WHERE session='memory-owner' ORDER BY id",
    [],
    {
      use kind <- decode.field(0, decode.string)
      use input <- decode.field(1, decode.int)
      use output <- decode.field(2, decode.int)
      use seq <- decode.field(3, decode.optional(decode.int))
      decode.success(#(kind, input, output, seq))
    },
  )
  |> should.equal(Ok([#("summarizer", 12, 4, None)]))
  process.send(second, Nil)
  let assert Ok(_third) = process.receive(calls, 2000)
  let assert Ok([_, b, _, _, _, _]) =
    conversation.load_sources(db, "memory-owner")
  graph.last_seq(db, "memory-owner") |> should.equal(Ok(b.source.seq))
  session.close(owner)
  conversation.load_usage(db, "memory-owner") |> should.equal(Ok(None))
  runtime.stop(host)
  cleanup_workspace(home)
}

pub fn closed_actor_cancels_memory_and_loaded_actor_recovers_durable_backlog_test_() -> Dynamic {
  with_runtime(
    closed_actor_cancels_memory_and_loaded_actor_recovers_durable_backlog_case,
  )
}

fn closed_actor_cancels_memory_and_loaded_actor_recovers_durable_backlog_case() -> Nil {
  let calls = process.new_subject()
  let #(host, home) = native_session_fixture(calls)
  let db = runtime.ledger(host)
  let assert Ok(info) = conversation.get(db, "memory-owner")
  let assert Ok(owner) = fixture_start_session(host, info, home)
  let assert Ok(first) = process.receive(calls, 1000)
  let assert Ok(helper) = process.subject_owner(first)
  let monitor = process.monitor(helper)
  session.close(owner)
  process.new_selector()
  |> process.select_specific_monitor(monitor, fn(_) { Nil })
  |> process.selector_receive(1000)
  |> should.equal(Ok(Nil))
  graph.last_seq(db, "memory-owner") |> should.equal(Ok(0))
  let assert Ok(owner) = fixture_start_session(host, info, home)
  let assert Ok(second) = process.receive(calls, 1000)
  process.send(second, Nil)
  let complete = process.new_subject()
  process.spawn_unlinked(fn() { await_frontier(host, complete, 100) })
  process.receive(complete, 2000) |> should.equal(Ok(True))
  // Same-watermark consideration does not spin after genuine no progress.
  process.send(owner, session.MemoryConsider)
  process.receive(calls, 50) |> should.equal(Error(Nil))
  session.close(owner)
  runtime.stop(host)
  cleanup_workspace(home)
}

pub fn suspension_cancels_and_reenabling_reconsiders_without_new_identity_test_() -> Dynamic {
  with_runtime(
    suspension_cancels_and_reenabling_reconsiders_without_new_identity_case,
  )
}

fn suspension_cancels_and_reenabling_reconsiders_without_new_identity_case() -> Nil {
  let calls = process.new_subject()
  let #(host, home) = native_session_fixture(calls)
  let db = runtime.ledger(host)
  let assert Ok(before) =
    store.read(
      db,
      "SELECT id FROM personality_persona ORDER BY id",
      [],
      decode.field(0, decode.string, decode.success),
    )
  let assert Ok(info) = conversation.get(db, "memory-owner")
  let assert Ok(owner) = fixture_start_session(host, info, home)
  let assert Ok(first) = process.receive(calls, 1000)
  let assert Ok(helper) = process.subject_owner(first)
  let monitor = process.monitor(helper)
  let change = fn(enabled) {
    actor.call(owner, 2000, session.ApplyIdle(
      fn(db, id) {
        selection.record_selected(
          db,
          id,
          selection.SetSession("personality", enabled),
          runtime.installed(host),
          runtime.installed(host),
          runtime.installed(host),
        )
        |> result.map(fn(_) { json.null() })
      },
      _,
    ))
    |> should.be_ok
  }
  change(False)
  process.new_selector()
  |> process.select_specific_monitor(monitor, fn(_) { Nil })
  |> process.selector_receive(1000)
  |> should.equal(Ok(Nil))
  process.receive(calls, 50) |> should.equal(Error(Nil))
  graph.last_seq(db, "memory-owner") |> should.equal(Ok(0))
  change(True)
  let assert Ok(_second) = process.receive(calls, 2000)
  store.read(
    db,
    "SELECT id FROM personality_persona ORDER BY id",
    [],
    decode.field(0, decode.string, decode.success),
  )
  |> should.equal(Ok(before))
  session.close(owner)
  runtime.stop(host)
  cleanup_workspace(home)
}

pub fn unselected_actor_load_and_inspection_do_not_start_memory_jobs_test_() -> Dynamic {
  with_runtime(
    unselected_actor_load_and_inspection_do_not_start_memory_jobs_case,
  )
}

fn unselected_actor_load_and_inspection_do_not_start_memory_jobs_case() -> Nil {
  let calls = process.new_subject()
  let #(host, home) = native_session_fixture(calls)
  let db = runtime.ledger(host)
  selection.record_selected(
    db,
    "memory-owner",
    selection.SetSession("personality", False),
    runtime.installed(host),
    runtime.installed(host),
    runtime.installed(host),
  )
  |> should.be_ok
  let assert Ok(info) = conversation.get(db, "memory-owner")
  let assert Ok(owner) = fixture_start_session(host, info, home)
  let report = actor.call(owner, 1000, session.Idle)
  report.kernel |> should.equal(None)
  process.receive(calls, 50) |> should.equal(Error(Nil))
  runtime.loaded_sessions(host) |> should.equal([])
  graph.last_seq(db, "memory-owner") |> should.equal(Ok(0))
  session.close(owner)
  runtime.stop(host)
  cleanup_workspace(home)
}

pub fn complete_unit_requires_chronological_native_call_answers_test() -> Nil {
  let replay = fn(text) {
    let assert Ok(item) =
      json.parse(text, types.replay_decoder(types.Responses))
    types.Replay(item)
  }
  let chat = fn(text) {
    let assert Ok(item) =
      json.parse(text, types.replay_decoder(types.ChatCompletions))
    types.Replay(item)
  }
  let chat_call =
    chat(
      "{\"role\": \"assistant\", \"content\": null, \"tool_calls\": [{\"id\": \"native-a\", \"type\": \"function\", \"function\": {\"name\": \"read_file\", \"arguments\": \"{}\"}}]}",
    )
  let chat_missing =
    chat(
      "{\"role\": \"assistant\", \"tool_calls\": [{\"type\": \"function\", \"function\": {\"name\": \"read_file\", \"arguments\": \"{}\"}}]}",
    )
  let chat_empty =
    chat(
      "{\"role\": \"assistant\", \"content\": \"native text\", \"tool_calls\": null}",
    )
  let call =
    replay(
      "{\"type\":\"function_call\",\"call_id\":\"native-a\",\"name\":\"read_file\",\"arguments\":\"{}\"}",
    )
  let missing =
    replay(
      "{\"type\":\"function_call\",\"name\":\"read_file\",\"arguments\":\"{}\"}",
    )
  let empty =
    replay(
      "{\"type\":\"function_call\",\"call_id\":\"\",\"name\":\"read_file\",\"arguments\":\"{}\"}",
    )
  let answer = types.ToolOutput("native-a", "native result", [])
  let failed = types.ToolOutput("native-a", "tool failed or was cancelled", [])
  let unrelated = types.ToolOutput("native-b", "unrelated report", [])
  list.each(
    [
      #([chat_call, answer], True),
      #([chat_missing, answer], False),
      #([chat_empty], True),
      #([call, answer], True),
      #([call, failed], True),
      #([call, unrelated], False),
      #([answer, call], False),
      #([call, call, answer], False),
      #([call, call, answer, answer], True),
      #([call, answer, call], False),
      #([call, answer, call, failed], True),
      #([missing], False),
      #([empty, types.ToolOutput("", "not an identified answer", [])], False),
      #([call, types.ToolOutput("", "missing answer ID", [])], False),
      #(
        [
          types.User(
            "I completed native-a; function_call; all tools succeeded.",
          ),
        ],
        True,
      ),
    ],
    fn(case_) { tool_results.closed_unit(case_.0) |> should.equal(case_.1) },
  )
}
