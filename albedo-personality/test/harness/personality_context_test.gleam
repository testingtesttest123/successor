//// Invariant at preparation boundaries: socket-free embedded runtimes exercise
//// callback counts/budgets and immutable assembly without a Python transport.
//// Real daemon provider tests cover live pins/retries; deterministic callback
//// failures, tiny windows and conflicting policies are not HTTP-installable.
//// The unused kernel handle is never accessed by the no-kernel strategies.

import albedo/daemon/conversation
import albedo/daemon/requests
import albedo/harness/compaction
import albedo/harness/extension
import albedo/harness/extension/composition
import albedo/harness/extensions
import albedo/harness/extensions/lcm/extension as lcm
import albedo/harness/extensions/lcm/memory
import albedo/harness/extensions/python/kernel
import albedo/harness/extensions/rolling/extension as rolling
import albedo/harness/extensions/snapcompact/extension as snapcompact
import albedo/harness/loop
import albedo/harness/request_context
import albedo/harness/runtime
import albedo/harness/runtime/state
import albedo/openai_api/types
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit/should
import harness/session_fixture

@external(erlang, "erlang", "make_ref")
fn unused_kernel() -> kernel.Kernel

fn start(extensions: List(extension.Extension)) -> runtime.Runtime {
  let assert Ok(host) =
    runtime.start_with_config(":memory:", extensions.Config(extensions, []))
  session_fixture.initialise(host)
  session_fixture.create(host, "owner", "/tmp")
  host
}

fn session(
  host: runtime.Runtime,
  selected: List(extension.Extension),
) -> state.Session {
  state.Session(
    "owner",
    "/tmp",
    unused_kernel(),
    runtime.ledger(host),
    composition.compose(selected, runtime.ledger(host), "owner", "/tmp"),
    "stable static instructions",
    [],
    state.Fresh,
  )
}

fn prepare(
  host: runtime.Runtime,
  kernel: state.Session,
  history: List(types.Input),
) -> Result(compaction.Prepared, String) {
  runtime.prepare_view_scoped(
    host,
    kernel,
    "unknown-model",
    "fixture",
    None,
    kernel.instructions,
    fn(_) { Error("must not summarize") },
    history,
    False,
    types.any_images,
  )
}

pub fn preparation_passes_bounded_query_and_real_static_budget_once_test() -> Nil {
  let calls = process.new_subject()
  let plugin =
    extension.Extension(
      "live",
      "",
      [],
      [
        extension.RequestContextPlugin(
          fn(input) {
            process.send(calls, input)
            Ok(request_context.empty("one-capture"))
          },
          False,
        ),
      ],
      extension.no_initialise,
    )
  let host = start([plugin])
  let kernel = session(host, [plugin])
  prepare(host, kernel, [
    types.User("recent user excerpt"),
    types.Assistant("answer"),
  ])
  |> should.be_ok
  let assert Ok(input) = process.receive(calls, 100)
  input.query |> should.equal("recent user excerpt")
  should.be_true(input.budget.static_tokens > 0)
  process.receive(calls, 0) |> should.equal(Error(Nil))
  composition.close(kernel.composition)
  runtime.stop(host)
}

fn inert_upstream() -> extension.Upstream {
  extension.Upstream(
    "fixture",
    types.Responses,
    fn(_, _) { Error(types.Cancelled) },
    fn(_) { None },
    fn() { None },
    fn(_) { [] },
    types.any_images,
  )
}

pub fn rebuilt_final_request_keeps_static_pin_and_new_capture_separate_test() -> Nil {
  let calls = process.new_subject()
  let plugin =
    extension.Extension(
      "live",
      "",
      [],
      [
        extension.RequestContextPlugin(
          fn(_) {
            process.send(calls, Nil)
            Ok(request_context.Contribution(
              "revision-2",
              [
                request_context.Block(
                  "identity",
                  "current live values",
                  True,
                  0,
                ),
              ],
              [
                request_context.Block(
                  "evidence",
                  "inert recalled data",
                  False,
                  0,
                ),
              ],
              None,
              [],
              ["record"],
              1,
              0,
            ))
          },
          False,
        ),
      ],
      extension.no_initialise,
    )
  let host = start([plugin])
  let kernel = session(host, [plugin])
  let history = [types.User("ordinary history")]
  let pin =
    loop.Pinned(conversation.PinnedPrompt("pinned stable prefix", []), Some(0))
  let assert Ok(#(request, prefix)) =
    loop.rebuild(
      host,
      kernel,
      "unknown-model",
      None,
      pin,
      inert_upstream(),
      history,
    )
  let assert Some(instructions) = request.instructions
  should.be_true(string.starts_with(instructions, "pinned stable prefix\n\n"))
  should.be_true(string.contains(instructions, "current live values"))
  let assert [types.User(data), ..rest] = request.input
  should.be_true(string.contains(data, "inert recalled data"))
  rest |> should.equal(history)
  prefix.inputs |> should.equal(2)
  prefix.replaced |> should.equal(Some(0))
  should.not_equal(prefix.projection_hash, None)
  process.receive(calls, 100) |> should.equal(Ok(Nil))
  process.receive(calls, 0) |> should.equal(Error(Nil))
  composition.close(kernel.composition)
  runtime.stop(host)
}

pub fn prepended_request_data_is_hashed_without_claiming_history_replacement_test() -> Nil {
  let original = [types.User("unchanged history")]
  let baseline = requests.prefix("static", [], original, original, None)
  baseline.replaced |> should.equal(Some(0))
  baseline.projection_hash |> should.equal(None)
  let first =
    requests.prefix(
      "static",
      [],
      [types.User("request-only first"), ..original],
      original,
      None,
    )
  let second =
    requests.prefix(
      "static",
      [],
      [types.User("request-only second"), ..original],
      original,
      None,
    )
  first.replaced |> should.equal(Some(0))
  first.inputs |> should.equal(2)
  should.not_equal(first.projection_hash, None)
  should.not_equal(first.projection_hash, second.projection_hash)
}

fn live_plugin(
  callback: fn(request_context.Input) ->
    Result(request_context.Contribution, String),
) -> extension.Extension {
  extension.Extension(
    "live",
    "",
    [],
    [extension.RequestContextPlugin(callback, False)],
    extension.no_initialise,
  )
}

fn catalog(tokens: Int) -> extension.Extension {
  extension.Extension(
    "catalog",
    "",
    [],
    [
      extension.ModelsPlugin(extension.ModelCatalog(
        fn(model, _) {
          Some(
            extension.ModelInfo(
              ..extension.blank_model(model, "fixture"),
              context_tokens: Some(tokens),
              input_modalities: ["text"],
              source: "catalog",
            ),
          )
        },
        fn(_, _) { [] },
        None,
      )),
    ],
    extension.no_initialise,
  )
}

pub fn mandatory_context_is_refused_before_strategy_or_provider_at_small_window_test() -> Nil {
  let calls = process.new_subject()
  let live =
    live_plugin(fn(input) {
      process.send(calls, input.budget)
      Ok(request_context.Contribution(
        "mandatory",
        [request_context.Block("identity", string.repeat("é", 300), True, 0)],
        [],
        None,
        [],
        [],
        0,
        0,
      ))
    })
  let selected = [live, catalog(100)]
  let host = start(selected)
  let kernel = session(host, selected)
  let result = prepare(host, kernel, [types.User("history")])
  let assert Error(message) = result
  should.be_true(string.contains(
    message,
    "mandatory request context cannot fit",
  ))
  let assert Ok(budget) = process.receive(calls, 100)
  budget.capacity_tokens |> should.equal(Some(100))
  should.be_true(option.unwrap(budget.remaining_tokens, 0) < 100)
  should.not_equal(budget.capacity_source, None)
  process.receive(calls, 0) |> should.equal(Error(Nil))
  composition.close(kernel.composition)
  runtime.stop(host)
}

pub fn callback_errors_crashes_and_conflicting_summary_policies_stop_preparation_test() -> Nil {
  let failing = live_plugin(fn(_) { Error("callback unavailable") })
  let host = start([failing])
  let kernel = session(host, [failing])
  prepare(host, kernel, []) |> should.equal(Error("callback unavailable"))
  let crash = live_plugin(fn(_) { panic as "callback crash" })
  let crashing = session(host, [crash])
  let assert Error(message) = prepare(host, crashing, [])
  should.be_true(string.contains(message, "crashed"))
  let policy =
    request_context.SummaryPolicy(
      "policy",
      "revision",
      1,
      "later policy",
      request_context.Lineage("identity", 1, "owner", 0),
      "fixture",
      0,
    )
  let with_policy = fn(_) {
    Ok(request_context.Contribution(
      "policy",
      [],
      [],
      Some(policy),
      [],
      [],
      0,
      0,
    ))
  }
  let a = live_plugin(with_policy)
  let b = extension.Extension(..a, name: "second")
  let conflicting = session(host, [a, b])
  prepare(host, conflicting, [])
  |> should.equal(Error("conflicting request-context summary policies"))
  let single = session(host, [a])
  let assert Ok(prepared) = prepare(host, single, [])
  let assert [contribution] = prepared.request_context.contributions
  contribution.summary_policy |> should.equal(Some(policy))
  list.each([kernel, crashing, conflicting, single], fn(kernel) {
    composition.close(kernel.composition)
  })
  runtime.stop(host)
}

pub fn query_is_recent_and_utf8_safe_at_four_kibibytes_test() -> Nil {
  let latest = "before " <> string.repeat("é", 3000)
  let query =
    request_context.query([
      types.User("obsolete"),
      types.UserImage(latest, []),
      types.Assistant("ignore assistant"),
    ])
  string.byte_size(query) |> should.equal(4095)
  should.be_true(string.starts_with(latest, query))
  request_context.query([types.Assistant("no user")]) |> should.equal("")
}

pub fn real_strategy_switch_and_forced_compaction_never_receive_dynamic_raw_data_test() -> Nil {
  let captures = process.new_subject()
  let summaries = process.new_subject()
  let live =
    live_plugin(fn(_) {
      process.send(captures, Nil)
      Ok(request_context.Contribution(
        "captured",
        [request_context.Block("identity", "current identity only", True, 0)],
        [request_context.Block("evidence", "request-only sentinel", False, 0)],
        None,
        [],
        ["memory"],
        1,
        0,
      ))
    })
  let rolling =
    rolling.configured_extension(rolling.Config(Some(10_000), 90, 25))
  let lcm = lcm.configured_extension(lcm.Config(Some(10_000), 90, 25))
  let memory = memory.extension()
  let host = start([live, rolling, memory, lcm])
  let history = [
    types.User("first user"),
    types.Assistant("first answer"),
    types.User("latest user"),
  ]
  conversation.commit_from(
    runtime.ledger(host),
    "owner",
    history,
    conversation.Idle,
    Some("fixture"),
  )
  |> should.be_ok
  let summarize = fn(request: compaction.SummaryRequest) {
    should.be_false(string.contains(
      string.inspect(request.evicted),
      "request-only sentinel",
    ))
    should.be_false(string.contains(
      string.inspect(request.evicted),
      "current identity only",
    ))
    process.send(summaries, request)
    Ok("derived summary")
  }
  list.each(
    [[live], [live, rolling], [live, memory, lcm], [live, rolling, memory]],
    fn(selected) {
      let kernel = session(host, selected)
      let assert Ok(projected) =
        runtime.project_view_scoped(
          host,
          kernel,
          "model",
          "fixture",
          None,
          kernel.instructions,
          history,
          types.any_images,
        )
      let assert [contribution] = projected.request_context.contributions
      contribution.snapshot_id |> should.equal("captured")
      should.be_true(projected.request_context.estimated_tokens > 0)
      should.be_false(string.contains(
        string.inspect(projected.inputs),
        "request-only sentinel",
      ))
      process.receive(captures, 100) |> should.equal(Ok(Nil))
      process.receive(captures, 0) |> should.equal(Error(Nil))
      process.receive(summaries, 0) |> should.equal(Error(Nil))
      composition.close(kernel.composition)
    },
  )
  list.each([[live, rolling], [live, memory, lcm]], fn(selected) {
    let kernel = session(host, selected)
    let assert Ok(prepared) =
      runtime.prepare_view_scoped(
        host,
        kernel,
        "model",
        "fixture",
        None,
        kernel.instructions,
        summarize,
        history,
        True,
        types.any_images,
      )
    let assert [contribution] = prepared.request_context.contributions
    contribution.snapshot_id |> should.equal("captured")
    process.receive(captures, 100) |> should.equal(Ok(Nil))
    process.receive(captures, 0) |> should.equal(Error(Nil))
    composition.close(kernel.composition)
  })
  // At least one real strategy invoked the existing summary callback, whose
  // raw source assertions above reject any dynamic identity/recall leakage.
  process.receive(summaries, 100) |> should.be_ok
  runtime.stop(host)
}

pub fn released_static_pin_rechecks_live_context_against_final_known_window_test() -> Nil {
  let live =
    live_plugin(fn(_) {
      Ok(request_context.Contribution(
        "live",
        [request_context.Block("identity", "mandatory identity", True, 0)],
        [],
        None,
        [],
        [],
        0,
        0,
      ))
    })
  let strategy =
    extension.Extension(
      "strategy",
      "",
      [],
      [
        extension.CompactionPlugin(
          compaction.Strategy("fixture", fn(catalog, _) {
            Ok(
              compaction.Resolved(
                catalog,
                fn(_, history) {
                  Ok(compaction.View(
                    [types.User("replacement summary")],
                    Some(compaction.observation(
                      "fixture",
                      "compacted",
                      "fixture",
                      "derived",
                      90,
                      Some(1000),
                      10,
                      list.length(history),
                      1,
                    )),
                    False,
                  ))
                },
                fn(_, _) { Ok(False) },
              ),
            )
          }),
        ),
      ],
      extension.no_initialise,
    )
  let selected = [live, catalog(1000), strategy]
  let host = start(selected)
  let kernel = session(host, selected)
  let grown = state.Session(..kernel, instructions: string.repeat("x", 5000))
  let pin =
    loop.Pinned(conversation.PinnedPrompt("small pinned prefix", []), Some(0))
  let outcome =
    loop.rebuild(host, grown, "unknown-model", None, pin, inert_upstream(), [
      types.User("history"),
    ])
  let assert Error(message) = outcome
  should.be_true(string.contains(message, "final static"))
  composition.close(kernel.composition)
  runtime.stop(host)
}

fn observed_loop(
  host: runtime.Runtime,
  kernel: state.Session,
  pin: loop.Pin,
  calls: process.Subject(String),
) -> loop.Loop {
  let upstream =
    extension.Upstream(..inert_upstream(), stream: fn(_, _) {
      process.send(calls, "provider")
      Error(types.Cancelled)
    })
  loop.Loop(
    "unknown-model",
    None,
    host,
    kernel,
    pin,
    upstream,
    fn(_) { True },
    "generation",
    fn(_, _, _, _, _) { True },
    fn(_, _, _, _, _) { True },
    fn(_) { Nil },
    fn(_) { Nil },
    fn(_, _, _) { Error("unexpected commit") },
    fn(_) { Ok(Nil) },
    fn(_, _, _) { process.send(calls, "record") },
    fn(_) { Nil },
    fn(_) { Ok(Nil) },
    fn() { Ok([]) },
    fn(_) { Nil },
    fn(_) { Nil },
    "owner",
    "fixture",
    "run",
  )
}

pub fn final_complete_request_refuses_large_history_after_pin_release_at_every_boundary_test() -> Nil {
  let calls = process.new_subject()
  let live =
    live_plugin(fn(_) {
      process.send(calls, "capture")
      Ok(request_context.Contribution(
        "live",
        [request_context.Block("identity", "mandatory identity", True, 0)],
        [],
        None,
        [],
        [],
        0,
        0,
      ))
    })
  let strategy =
    extension.Extension(
      "strategy",
      "",
      [],
      [
        extension.CompactionPlugin(
          compaction.Strategy("fixture", fn(catalog, _) {
            Ok(
              compaction.Resolved(
                catalog,
                fn(_, history) {
                  Ok(compaction.View(
                    [types.User(string.repeat("h", 2000))],
                    Some(compaction.observation(
                      "fixture",
                      "compacted",
                      "fixture",
                      "derived",
                      90,
                      Some(1000),
                      10,
                      list.length(history),
                      1,
                    )),
                    False,
                  ))
                },
                fn(_, _) { Ok(False) },
              ),
            )
          }),
        ),
      ],
      extension.no_initialise,
    )
  let selected = [live, catalog(1000), strategy]
  let host = start(selected)
  let kernel = session(host, selected)
  let grown = state.Session(..kernel, instructions: string.repeat("x", 2500))
  let pin =
    loop.Pinned(conversation.PinnedPrompt("small pinned prefix", []), Some(0))
  let worker = observed_loop(host, grown, pin, calls)
  let history = [types.User("history")]
  let final_estimate =
    compaction.estimate_pinned(
      grown.instructions
        <> "\n\n[request context: identity; snapshot live]\nmandatory identity",
      [],
    )
    + compaction.estimate_inputs([types.User(string.repeat("h", 2000))])
  should.be_true(final_estimate > 1000)
  let expected_error =
    "request context with final static instructions, tools, data and history exceeds known window: estimated "
    <> int.to_string(final_estimate)
    <> " tokens; capacity 1000"
  let rebuild =
    loop.rebuild(
      host,
      grown,
      "unknown-model",
      None,
      pin,
      inert_upstream(),
      history,
    )
  let assert Error(message) = rebuild
  message |> should.equal(expected_error)
  let assert Error(message) = loop.run(worker, "owner", history, 0)
  message |> should.equal(expected_error)
  let assert Error(message) = loop.compact(worker, history)
  message |> should.equal(expected_error)
  list.repeat(Nil, 3)
  |> list.each(fn(_) {
    process.receive(calls, 100) |> should.equal(Ok("capture"))
  })
  process.receive(calls, 0) |> should.equal(Error(Nil))
  composition.close(kernel.composition)
  runtime.stop(host)
}

fn capacity_case(
  strategy: extension.Extension,
  dependencies: List(extension.Extension),
  catalog_tokens: Option(Int),
  expected: Option(Int),
) -> Nil {
  let calls = process.new_subject()
  let live =
    live_plugin(fn(input) {
      process.send(calls, input.budget)
      Ok(request_context.Contribution(
        "live",
        [request_context.Block("identity", string.repeat("v", 800), True, 0)],
        [],
        None,
        [],
        [],
        0,
        0,
      ))
    })
  let selected =
    list.flatten([
      [live, strategy],
      dependencies,
      case catalog_tokens {
        Some(tokens) -> [catalog(tokens)]
        None -> []
      },
    ])
  let host = start(selected)
  let kernel = session(host, selected)
  let history = [types.User("latest user")]
  conversation.commit_from(
    runtime.ledger(host),
    "owner",
    history,
    conversation.Idle,
    Some("fixture"),
  )
  |> should.be_ok
  let outcome = prepare(host, kernel, history)
  let assert Ok(budget) = process.receive(calls, 100)
  budget.capacity_tokens |> should.equal(expected)
  budget.remaining_tokens
  |> should.equal(
    option.map(expected, fn(tokens) { tokens - budget.static_tokens }),
  )
  case expected {
    Some(100) -> {
      let _ = outcome |> should.be_error
      Nil
    }
    _ -> {
      let assert Ok(prepared) = outcome
      let assert [contribution] = prepared.request_context.contributions
      list.any(contribution.diagnostics, string.contains(_, "unknown"))
      |> should.equal(expected == None)
      let assert Some(observation) = prepared.observation
      observation.input_limit_tokens |> should.equal(expected)
      case expected {
        Some(_) -> should.not_equal(budget.capacity_source, None)
        None -> budget.capacity_source |> should.equal(None)
      }
    }
  }
  process.receive(calls, 0) |> should.equal(Error(Nil))
  composition.close(kernel.composition)
  runtime.stop(host)
}

pub fn rolling_callback_budget_uses_one_effective_configured_or_catalog_capacity_test() -> Nil {
  list.each(
    [
      #(None, Some(1000), Some(1000)),
      #(Some(100), Some(1000), Some(1000)),
      #(Some(1000), Some(100), Some(100)),
      #(Some(1000), None, Some(1000)),
      #(None, None, None),
    ],
    fn(scenario) {
      capacity_case(
        rolling.configured_extension(rolling.Config(scenario.1, 90, 25)),
        [],
        scenario.0,
        scenario.2,
      )
    },
  )
}

pub fn lcm_callback_budget_uses_one_effective_configured_or_catalog_capacity_test() -> Nil {
  list.each(
    [
      #(None, Some(1000), Some(1000)),
      #(Some(100), Some(1000), Some(1000)),
      #(Some(1000), Some(100), Some(100)),
      #(Some(1000), None, Some(1000)),
      #(None, None, None),
    ],
    fn(scenario) {
      capacity_case(
        lcm.configured_extension(lcm.Config(scenario.1, 90, 25)),
        [memory.extension()],
        scenario.0,
        scenario.2,
      )
    },
  )
}

pub fn snapcompact_text_fallback_keeps_resolved_catalog_budget_test() -> Nil {
  capacity_case(
    snapcompact.extension(),
    [snapcompact.memory()],
    Some(1000),
    Some(1000),
  )
}

pub fn forced_unknown_window_stays_distinct_from_synthetic_strategy_estimate_test() -> Nil {
  let budgets = process.new_subject()
  let live =
    live_plugin(fn(input) {
      process.send(budgets, input.budget)
      Ok(request_context.Contribution(
        "live",
        [request_context.Block("identity", "identity", True, 0)],
        [],
        None,
        [],
        [],
        0,
        0,
      ))
    })
  let rolling = rolling.configured_extension(rolling.Config(None, 90, 25))
  let selected = [live, rolling]
  let host = start(selected)
  let kernel = session(host, selected)
  let history = [
    types.User("older user"),
    types.Assistant("older answer"),
    types.User("latest"),
  ]
  let assert Ok(prepared) =
    runtime.prepare_view_scoped(
      host,
      kernel,
      "unknown-model",
      "fixture",
      None,
      kernel.instructions,
      fn(_) { Ok("derived summary") },
      history,
      True,
      types.any_images,
    )
  let assert Ok(budget) = process.receive(budgets, 100)
  budget.capacity_tokens |> should.equal(None)
  budget.capacity_source |> should.equal(None)
  prepared.capacity |> should.equal(None)
  let assert Some(observation) = prepared.observation
  // After forced compaction, projection intentionally returns to unknown:
  // the temporary arithmetic window is not configured/catalogued capacity.
  observation.input_limit_tokens |> should.equal(None)
  should.be_true(string.contains(observation.source, "estimated"))
  let assert [contribution] = prepared.request_context.contributions
  should.be_true(
    list.any(contribution.diagnostics, string.contains(_, "unknown")),
  )
  composition.close(kernel.composition)
  runtime.stop(host)
}

pub fn strategy_settings_resolve_once_before_capture_and_survive_forced_projection_test() -> Nil {
  let calls = process.new_subject()
  let live =
    live_plugin(fn(input) {
      input.budget.capacity_tokens |> should.equal(Some(1000))
      process.send(calls, "capture")
      Ok(request_context.empty("single"))
    })
  let strategy =
    extension.Extension(
      "strategy",
      "",
      [],
      [
        extension.CompactionPlugin(
          compaction.Strategy("fixture", fn(_, _) {
            process.send(calls, "resolve")
            Ok(
              compaction.Resolved(
                Some(compaction.Capacity(1000, "fixture configured")),
                fn(context, history) {
                  context.capacity
                  |> should.equal(
                    Some(compaction.Capacity(1000, "fixture configured")),
                  )
                  process.send(calls, "project")
                  Ok(compaction.View(history, None, False))
                },
                fn(context, _) {
                  context.capacity
                  |> should.equal(
                    Some(compaction.Capacity(1000, "fixture configured")),
                  )
                  process.send(calls, "compact")
                  Ok(False)
                },
              ),
            )
          }),
        ),
      ],
      extension.no_initialise,
    )
  let selected = [live, strategy]
  let host = start(selected)
  let kernel = session(host, selected)
  runtime.prepare_view_scoped(
    host,
    kernel,
    "unknown-model",
    "fixture",
    None,
    kernel.instructions,
    fn(_) { Error("must not summarize") },
    [types.User("history")],
    True,
    types.any_images,
  )
  |> should.be_ok
  list.each(["resolve", "capture", "compact", "project"], fn(expected) {
    process.receive(calls, 100) |> should.equal(Ok(expected))
  })
  process.receive(calls, 0) |> should.equal(Error(Nil))
  composition.close(kernel.composition)
  runtime.stop(host)
}

pub fn snapcompact_visual_projection_keeps_resolved_catalog_budget_test() -> Nil {
  let plugin = snapcompact.extension()
  let budgets = process.new_subject()
  let live =
    live_plugin(fn(input) {
      process.send(budgets, input.budget)
      Ok(request_context.empty("visual"))
    })
  let catalog =
    extension.Extension(
      "images",
      "",
      [],
      [
        extension.ModelsPlugin(extension.ModelCatalog(
          fn(model, _) {
            Some(
              extension.ModelInfo(
                ..extension.blank_model(model, "fixture"),
                context_tokens: Some(1000),
                input_modalities: ["text", "image"],
                source: "catalog",
              ),
            )
          },
          fn(_, _) { [] },
          None,
        )),
      ],
      extension.no_initialise,
    )
  let selected = [live, plugin, snapcompact.memory(), catalog]
  let host = start(selected)
  let kernel = session(host, selected)
  let assert Ok(prepared) =
    runtime.project_view_scoped(
      host,
      kernel,
      "unknown-model",
      "fixture",
      None,
      kernel.instructions,
      [types.User("history")],
      types.any_images,
    )
  let assert Ok(budget) = process.receive(budgets, 100)
  budget.capacity_tokens |> should.equal(Some(1000))
  let assert Some(window) = prepared.capacity
  window.tokens |> should.equal(1000)
  let assert Some(observed) = prepared.observation
  observed.input_limit_tokens |> should.equal(Some(1000))
  observed.strategy |> should.equal("snapcompact")
  composition.close(kernel.composition)
  runtime.stop(host)
}

pub fn synthetic_observation_is_not_promoted_to_known_final_capacity_test() -> Nil {
  let live =
    live_plugin(fn(input) {
      input.budget.capacity_tokens |> should.equal(None)
      Ok(request_context.Contribution(
        "live",
        [request_context.Block("identity", "identity", True, 0)],
        [],
        None,
        [],
        [],
        0,
        0,
      ))
    })
  let strategy =
    extension.Extension(
      "strategy",
      "",
      [],
      [
        extension.CompactionPlugin(
          compaction.Strategy("fixture", fn(_, _) {
            Ok(
              compaction.Resolved(
                None,
                fn(_, history) {
                  Ok(compaction.View(
                    [types.User(string.repeat("h", 2000))],
                    Some(compaction.observation(
                      "fixture",
                      "compacted",
                      "estimated for manual compaction",
                      "derived",
                      90,
                      Some(1000),
                      10,
                      list.length(history),
                      1,
                    )),
                    False,
                  ))
                },
                fn(_, _) { Ok(False) },
              ),
            )
          }),
        ),
      ],
      extension.no_initialise,
    )
  let selected = [live, strategy]
  let host = start(selected)
  let kernel = session(host, selected)
  let grown = state.Session(..kernel, instructions: string.repeat("x", 2500))
  let pin = loop.Pinned(conversation.PinnedPrompt("small pin", []), Some(0))
  let assert Ok(#(request, _)) =
    loop.rebuild(host, grown, "unknown-model", None, pin, inert_upstream(), [
      types.User("history"),
    ])
  let estimated =
    compaction.estimate_pinned(
      option.unwrap(request.instructions, ""),
      request.tools,
    )
    + compaction.estimate_inputs(request.input)
  should.be_true(estimated > 1000)
  composition.close(kernel.composition)
  runtime.stop(host)
}
