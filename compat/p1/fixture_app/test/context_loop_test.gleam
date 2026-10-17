//// Actual embedded loop/runtime tests: native external callbacks and controlled
//// pin/settings changes cannot be installed via stock HTTP configuration.

import albedo/daemon/context_snapshot
import albedo/daemon/conversation
import albedo/daemon/requests
import albedo/daemon/session_configuration
import albedo/daemon/session_requirements
import albedo/daemon/store
import albedo/harness/compaction
import albedo/harness/extension
import albedo/harness/extension/composition
import albedo/harness/extension/selection
import albedo/harness/extensions
import albedo/harness/extensions/rolling/extension as rolling
import albedo/harness/loop
import albedo/harness/request_context as context
import albedo/harness/runtime
import albedo/openai_api/types
import context_fixture as fixture
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

fn retry(protocol: types.Protocol) -> Nil {
  let captures = fixture.counter()
  let calls = fixture.counter()
  let drains = fixture.counter()
  let inputs = process.new_subject()
  let sent = process.new_subject()
  let saved = process.new_subject()
  let #(host, kernel) =
    fixture.start([
      fixture.declaration(captures, inputs, []),
      fixture.catalog(Some(100_000)),
      fixture.static_tool(),
    ])
  fixture.read(captures) |> should.equal(0)
  let provider =
    fixture.upstream(protocol, fn(request, _) {
      process.send(sent, request)
      case fixture.next(calls) {
        1 -> {
          fixture.change(runtime.ledger(host))
          Error(types.UnexpectedEnd)
        }
        _ -> Ok(fixture.complete())
      }
    })
  let state =
    fixture.worker(
      host,
      kernel,
      provider,
      saved,
      fn() {
        case fixture.next(drains) {
          1 -> Ok([types.User("next steering")])
          _ -> Ok([])
        }
      },
      loop.Unpinned,
    )
  loop.run(state, "run", [types.User("first query")], 0)
  |> should.equal(Ok(Nil))
  let first = fixture.receive(sent)
  let retried = fixture.receive(sent)
  let next = fixture.receive(sent)
  first |> should.equal(retried)
  first.tools |> should.equal(next.tools)
  list.length(first.tools) |> should.equal(1)
  string.contains(option.unwrap(first.instructions, ""), "revision-1")
  |> should.be_true
  string.contains(option.unwrap(next.instructions, ""), "revision-2")
  |> should.be_true
  let old = fixture.receive(saved)
  let newer = fixture.receive(saved)
  let assert context_snapshot.Ready(request_context: Some(facts), ..) = old
  facts.estimated_tokens |> should.equal(runtime.request_estimate(first))
  facts.captured.budget.capacity_source
  |> should.equal(Some("fixture arbitrary fixture provenance"))
  let assert Ok(page) = context_snapshot.page(old, "instructions", 0)
  string.contains(page.text, "revision-1") |> should.be_true
  string.contains(context_snapshot.summary(old) |> json.to_string, "revision-1")
  |> should.be_true
  let assert Ok(page) = context_snapshot.page(newer, "instructions", 0)
  string.contains(page.text, "revision-2") |> should.be_true
  fixture.read(captures) |> should.equal(2)
  fixture.receive(inputs).query |> should.equal("first query")
  fixture.receive(inputs).query |> should.equal("next steering")
  loop.rebuild(host, kernel, "model", None, loop.Unpinned, provider, [
    types.User("first query"),
  ])
  |> should.be_error
  fixture.read(captures) |> should.equal(2)
  fixture.revision(runtime.ledger(host)) |> should.equal("revision-2")
  runtime.stop(host)
}

pub fn responses_retry_and_saved_inspection_test() -> Nil {
  retry(types.Responses)
}

pub fn chat_retry_and_saved_inspection_test() -> Nil {
  retry(types.ChatCompletions)
}

fn tool_continuation(protocol: types.Protocol, with_image: Bool) -> Nil {
  let captures = fixture.counter()
  let providers = fixture.counter()
  let inputs = process.new_subject()
  let saved = process.new_subject()
  let sent = process.new_subject()
  let #(host, kernel) =
    fixture.start([
      fixture.declaration(captures, inputs, []),
      fixture.catalog(Some(100_000)),
      fixture.static_tool(),
    ])
  let wire = case protocol {
    types.Responses ->
      "{\"type\":\"function_call\",\"id\":\"item\",\"call_id\":\"call\",\"name\":\"fixture_read\",\"arguments\":\"{}\"}"
    types.ChatCompletions ->
      "{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"call\",\"type\":\"function\",\"function\":{\"name\":\"fixture_read\",\"arguments\":\"{}\"}}]}"
  }
  let assert Ok(replay) = json.parse(wire, types.replay_decoder(protocol))
  let provider =
    fixture.upstream(protocol, fn(request, _) {
      process.send(sent, request)
      case fixture.next(providers) {
        1 -> {
          fixture.change(runtime.ledger(host))
          Ok(
            types.Turn(
              None,
              [replay],
              [types.ToolCall("call", "fixture_read", "{}")],
              None,
              types.Complete,
              None,
              [#("call", 0)],
            ),
          )
        }
        _ -> Ok(fixture.complete())
      }
    })
  let provider =
    extension.Upstream(..provider, images: case with_image {
      True -> types.ImageLimits(16, None)
      False -> types.any_images
    })
  let worker =
    fixture.worker(
      host,
      kernel,
      provider,
      saved,
      fn() { Ok([]) },
      loop.Unpinned,
    )
  loop.run(
    worker,
    "run",
    [
      case with_image {
        True -> types.UserImage("query", [fixture.image()])
        False -> types.User("query")
      },
    ],
    0,
  )
  |> should.equal(Ok(Nil))
  let first = fixture.receive(sent)
  let next = fixture.receive(sent)
  case with_image {
    True ->
      list.any(first.input, fn(input) {
        case input {
          types.UserImage(_, [image, ..]) -> {
            let #(_, width, height, _) = types.image_meta(image)
            width == 16 && height == 16
          }
          _ -> False
        }
      })
      |> should.be_true
    False -> Nil
  }
  string.contains(option.unwrap(first.instructions, ""), "revision-1")
  |> should.be_true
  string.contains(option.unwrap(next.instructions, ""), "revision-2")
  |> should.be_true
  list.any(next.input, fn(input) {
    input == types.ToolOutput("call", "fixture result", [])
  })
  |> should.be_true
  first.tools |> should.equal(next.tools)
  fixture.receive(inputs).query |> should.equal("query")
  fixture.receive(inputs).query |> should.equal("query")
  fixture.read(captures) |> should.equal(2)
  fixture.read(providers) |> should.equal(2)
  runtime.stop(host)
}

pub fn responses_tool_continuation_captures_next_revision_test() -> Nil {
  tool_continuation(types.Responses, False)
}

pub fn chat_tool_continuation_captures_next_revision_test() -> Nil {
  tool_continuation(types.ChatCompletions, False)
}

pub fn responses_scaled_image_keeps_query_through_tool_continuation_test() -> Nil {
  tool_continuation(types.Responses, True)
}

pub fn chat_scaled_image_keeps_query_through_tool_continuation_test() -> Nil {
  tool_continuation(types.ChatCompletions, True)
}

pub fn mandatory_overflow_prevents_any_provider_or_compaction_test() -> Nil {
  let captures = fixture.counter()
  let providers = fixture.counter()
  let resolutions = fixture.counter()
  let projects = fixture.counter()
  let input = process.new_subject()
  let saved = process.new_subject()
  let strategy =
    extension.Extension(
      "budget",
      "generic resolver",
      [],
      [
        extension.CompactionPlugin(
          compaction.Strategy("renamed", fn(_, _) {
            let _ = fixture.next(resolutions)
            Ok(
              compaction.Resolved(
                Some(compaction.Capacity(10, "does not encode strategy")),
                fn(_, history) {
                  let _ = fixture.next(projects)
                  Ok(compaction.View(history, None, True))
                },
                fn(_, _) {
                  let _ = fixture.next(providers)
                  Ok(True)
                },
              ),
            )
          }),
        ),
      ],
      extension.no_initialise,
    )
  let #(host, kernel) =
    fixture.start([fixture.declaration(captures, input, []), strategy])
  let provider =
    fixture.upstream(types.Responses, fn(_, _) {
      let _ = fixture.next(providers)
      Ok(fixture.complete())
    })
  let worker =
    fixture.worker(
      host,
      kernel,
      provider,
      saved,
      fn() { Ok([]) },
      loop.Unpinned,
    )
  loop.run(worker, "run", [types.User("history")], 0) |> should.be_error
  fixture.read(providers) |> should.equal(0)
  fixture.read(projects) |> should.equal(0)
  fixture.read(resolutions) |> should.equal(1)
  fixture.read(captures) |> should.equal(1)
  let assert context_snapshot.Ready(request_context: Some(facts), ..) =
    fixture.receive(saved)
  facts.fits |> should.be_false
  facts.captured.budget.capacity_tokens |> should.equal(Some(10))
  runtime.stop(host)
}

pub fn settings_resolve_once_across_project_compact_project_test() -> Nil {
  let captures = fixture.counter()
  let resolutions = fixture.counter()
  let projects = fixture.counter()
  let compacts = fixture.counter()
  let input = process.new_subject()
  let observed = process.new_subject()
  let strategy =
    extension.Extension(
      "strategy",
      "captured settings",
      [],
      [
        extension.CompactionPlugin(
          compaction.Strategy("arbitrary-name", fn(_, _) {
            let revision = fixture.next(resolutions)
            let capacity =
              Some(compaction.Capacity(100_000 + revision, "arbitrary-source"))
            Ok(
              compaction.Resolved(
                capacity,
                fn(context, history) {
                  process.send(observed, context.capacity)
                  let _ = fixture.next(projects)
                  Ok(compaction.View(history, None, True))
                },
                fn(context, _) {
                  process.send(observed, context.capacity)
                  let _ = fixture.next(compacts)
                  Ok(True)
                },
              ),
            )
          }),
        ),
      ],
      extension.no_initialise,
    )
  let #(host, kernel) =
    fixture.start([fixture.declaration(captures, input, []), strategy])
  let prepare = fn(force) {
    runtime.prepare_request_scoped(
      host,
      kernel,
      "model",
      "source",
      None,
      runtime.instructions(kernel),
      fn(_, _) { Error("unexpected summarizer") },
      [types.User("history")],
      force,
      types.any_images,
      None,
      fn() { Nil },
      compaction.unprojected,
      source_query: "fixture source query",
    )
  }
  let assert Ok(first) = prepare(False)
  first.captured.budget.capacity_tokens |> should.equal(Some(100_001))
  list.each(list.repeat(Nil, 3), fn(_) {
    fixture.receive(observed)
    |> should.equal(Some(compaction.Capacity(100_001, "arbitrary-source")))
  })
  fixture.read(resolutions) |> should.equal(1)
  fixture.read(captures) |> should.equal(1)
  fixture.read(projects) |> should.equal(2)
  fixture.read(compacts) |> should.equal(1)
  let assert Ok(second) = prepare(True)
  second.captured.budget.capacity_tokens |> should.equal(Some(100_002))
  list.each(list.repeat(Nil, 2), fn(_) {
    fixture.receive(observed)
    |> should.equal(Some(compaction.Capacity(100_002, "arbitrary-source")))
  })
  fixture.read(resolutions) |> should.equal(2)
  fixture.read(captures) |> should.equal(2)
  runtime.stop(host)
}

pub fn unavailable_whole_bundle_and_required_guard_test() -> Nil {
  let calls = fixture.counter()
  let inputs = process.new_subject()
  let declared = fixture.declaration(calls, inputs, [])
  let optional =
    extension.Extension(..declared, plugins: [
      extension.ContextPlugin(fn(_) { Error("fixture refused static load") }),
      extension.RequestContextPlugin(
        fn(_) {
          let _ = fixture.next(calls)
          Ok(context.Contribution("x", [], [], []))
        },
        False,
      ),
      extension.ToolPlugin(
        "must not leak",
        [
          extension.Tool(
            types.Tool("leak", "leak", json.object([]), False),
            fn(_, _) { Ok(extension.text("leak")) },
            fn(_) { None },
          ),
        ],
        [],
        [],
      ),
    ])
  let assert Ok(ledger) = store.start(":memory:", "")
  let composition = composition.compose([optional], ledger, "s", "/tmp")
  composition.extensions(composition) |> should.equal([])
  composition.tools(composition) |> should.equal([])
  composition.request_contributors(composition) |> should.equal(Ok([]))
  let required =
    extension.Extension(..optional, plugins: [
      extension.ContextPlugin(fn(_) { Error("unavailable") }),
      extension.RequestContextPlugin(fn(_) { panic as "must not capture" }, True),
    ])
  let composition = composition.compose([required], ledger, "s", "/tmp")
  composition.request_contributors(composition) |> should.be_error
  fixture.read(calls) |> should.equal(0)
  store.close(ledger)
}

fn pin_case(released: Bool, overflow: Bool) -> Nil {
  let captures = fixture.counter()
  let providers = fixture.counter()
  let capacity = fixture.counter()
  let inputs = process.new_subject()
  let saved = process.new_subject()
  let sent = process.new_subject()
  let strategy =
    extension.Extension(
      "projection",
      "controlled pin release",
      [],
      [
        extension.CompactionPlugin(
          compaction.Strategy("projection", fn(_, _) {
            Ok(
              compaction.Resolved(
                Some(compaction.Capacity(fixture.read(capacity), "fixture")),
                fn(_, history) {
                  Ok(compaction.View(
                    case released {
                      True -> list.drop(history, 1)
                      False -> history
                    },
                    None,
                    False,
                  ))
                },
                fn(_, _) { panic as "unexpected compaction" },
              ),
            )
          }),
        ),
      ],
      extension.no_initialise,
    )
  let #(host, kernel) =
    fixture.start([
      fixture.declaration(captures, inputs, [
        context.Block("optional", string.repeat("optional", 300), False),
      ]),
      extension.Extension(
        "static",
        "explicit current static prefix",
        [],
        [
          extension.ToolPlugin(string.repeat("large", 1000), [], [], []),
        ],
        extension.no_initialise,
      ),
      strategy,
    ])
  let actual_static =
    compaction.estimate_pinned(
      runtime.instructions(kernel),
      runtime.tools(kernel),
    )
  fixture.set(capacity, case overflow {
    True -> 100
    False -> actual_static + 150
  })
  let provider =
    fixture.upstream(types.Responses, fn(request, _) {
      let _ = fixture.next(providers)
      process.send(sent, request)
      Ok(fixture.complete())
    })
  let pin =
    loop.Pinned(conversation.PinnedPrompt("short pinned prefix", []), Some(0))
  let worker =
    fixture.worker(host, kernel, provider, saved, fn() { Ok([]) }, pin)
  let result =
    loop.run(worker, "run", [types.User("new"), types.User("old")], 0)
  let assert context_snapshot.Ready(request_context: Some(facts), ..) =
    fixture.receive(saved)
  fixture.read(captures) |> should.equal(1)
  case overflow {
    True -> {
      result |> should.be_error
      fixture.read(providers) |> should.equal(0)
      facts.fits |> should.be_false
      list.length(facts.captured.omissions) |> should.equal(1)
    }
    False -> {
      result |> should.equal(Ok(Nil))
      let request = fixture.receive(sent)
      facts.estimated_tokens |> should.equal(runtime.request_estimate(request))
      string.contains(
        option.unwrap(request.instructions, ""),
        "short pinned prefix",
      )
      |> should.equal(!released)
      case released {
        True -> list.length(facts.captured.omissions) |> should.equal(1)
        False -> Nil
      }
    }
  }
  runtime.stop(host)
}

pub fn retained_pin_uses_one_capture_test() -> Nil {
  pin_case(False, False)
}

pub fn released_pin_reconciles_optionals_without_recapture_test() -> Nil {
  pin_case(True, False)
}

pub fn released_pin_mandatory_overflow_saves_capture_test() -> Nil {
  pin_case(True, True)
}

pub fn forced_unknown_capacity_keeps_inspection_unknown_test() -> Nil {
  let captures = fixture.counter()
  let summaries = fixture.counter()
  let inputs = process.new_subject()
  let #(host, kernel) =
    fixture.start([
      fixture.declaration(captures, inputs, []),
      rolling.configured_extension(rolling.Config(None, 80, 25)),
    ])
  let original = [
    types.User(string.repeat("old", 200)),
    types.Assistant("answer"),
    types.User("new"),
  ]
  let assert Ok(prepared) =
    runtime.prepare_request_scoped(
      host,
      kernel,
      "model",
      "source",
      None,
      runtime.instructions(kernel),
      fn(_, _) {
        let _ = fixture.next(summaries)
        Ok("saved facts")
      },
      original,
      True,
      types.any_images,
      None,
      fn() { Nil },
      compaction.unprojected,
      source_query: "fixture source query",
    )
  fixture.receive(inputs).budget.capacity_tokens |> should.equal(None)
  prepared.captured.budget.capacity_source |> should.equal(None)
  fixture.read(summaries) |> should.equal(1)
  let final =
    context.reconcile(
      types.Request(
        "model",
        Some(runtime.instructions(kernel)),
        prepared.history.inputs,
        runtime.tools(kernel),
        None,
        types.defaults,
      ),
      prepared.captured,
      runtime.request_estimate,
      0,
    )
  let snapshot =
    context_snapshot.from_request(
      None,
      "fixture",
      "responses",
      types.Responses,
      final.request,
      prepared.history.observation,
    )
    |> context_snapshot.with_request_context(final)
  let assert context_snapshot.Ready(
    context_window_tokens: window,
    request_context: Some(facts),
    ..,
  ) = snapshot
  window |> should.equal(None)
  facts.captured.budget.capacity_tokens |> should.equal(None)
  fixture.read(captures) |> should.equal(1)
  runtime.stop(host)
}

pub fn callback_error_and_exception_refuse_preparation_test() -> Nil {
  let inputs = process.new_subject()
  let declared = fixture.declaration(fixture.counter(), inputs, [])
  list.each([False, True], fn(raise) {
    let failing =
      extension.Extension(..declared, plugins: [
        extension.RequestContextPlugin(
          fn(_) {
            case raise {
              True -> panic as "controlled fixture exception"
              False -> Error("controlled refusal")
            }
          },
          True,
        ),
      ])
    let #(host, kernel) = fixture.start([failing])
    runtime.prepare_request_scoped(
      host,
      kernel,
      "model",
      "source",
      None,
      runtime.instructions(kernel),
      fn(_, _) { panic as "must not summarize" },
      [types.User("query")],
      False,
      types.any_images,
      None,
      fn() { Nil },
      compaction.unprojected,
      source_query: "fixture source query",
    )
    |> should.be_error
    runtime.stop(host)
  })
}

pub fn static_only_restart_restoration_keeps_prefix_comparison_path_test() -> Nil {
  let declared =
    extension.Extension("static", "static fixture", [], [], fixture.initialise)
  let #(host, kernel) = fixture.start([declared])
  let provider =
    fixture.upstream(types.Responses, fn(_, _) {
      panic as "rebuild must not call provider"
    })
  loop.rebuild(host, kernel, "model", None, loop.Unpinned, provider, [
    types.User("query"),
  ])
  |> should.be_ok
  runtime.stop(host)
}

fn early_refusal_keeps_pin(force: Bool) -> Nil {
  let inputs = process.new_subject()
  let snapshots = process.new_subject()
  let pins = process.new_subject()
  let strategy =
    extension.Extension(
      "tiny",
      "early refusal",
      [],
      [
        extension.CompactionPlugin(
          compaction.Strategy("tiny", fn(_, _) {
            Ok(
              compaction.Resolved(
                Some(compaction.Capacity(10, "fixture")),
                fn(_, _) { panic as "must not project" },
                fn(_, _) { panic as "must not compact" },
              ),
            )
          }),
        ),
      ],
      extension.no_initialise,
    )
  let #(host, kernel) =
    fixture.start([fixture.declaration(fixture.counter(), inputs, []), strategy])
  let provider =
    fixture.upstream(types.Responses, fn(_, _) {
      panic as "must not call provider"
    })
  let worker =
    fixture.worker(
      host,
      kernel,
      provider,
      snapshots,
      fn() { Ok([]) },
      loop.Pinned(conversation.PinnedPrompt("old pinned prefix", []), Some(5)),
    )
  let worker =
    loop.Loop(..worker, report_pin: fn(head) { process.send(pins, head) })
  case force {
    True -> loop.compact(worker, [types.User("history")])
    False -> loop.run(worker, "run", [types.User("history")], 0)
  }
  |> should.be_error
  process.receive(pins, 0) |> should.equal(Error(Nil))
  runtime.stop(host)
}

pub fn early_turn_refusal_preserves_existing_pin_test() -> Nil {
  early_refusal_keeps_pin(False)
}

pub fn early_compact_refusal_preserves_existing_pin_test() -> Nil {
  early_refusal_keeps_pin(True)
}

pub fn later_callback_failure_saves_earlier_capture_test() -> Nil {
  let inputs = process.new_subject()
  let snapshots = process.new_subject()
  let captures = fixture.counter()
  let bad =
    extension.Extension(
      "bad",
      "later callback refuses",
      [],
      [
        extension.RequestContextPlugin(
          fn(_) { Error("controlled later refusal") },
          True,
        ),
      ],
      extension.no_initialise,
    )
  let #(host, kernel) =
    fixture.start([fixture.declaration(captures, inputs, []), bad])
  let provider =
    fixture.upstream(types.Responses, fn(_, _) {
      panic as "must not call provider"
    })
  let worker =
    fixture.worker(
      host,
      kernel,
      provider,
      snapshots,
      fn() { Ok([]) },
      loop.Unpinned,
    )
  loop.run(worker, "run", [types.User("query")], 0) |> should.be_error
  let assert Ok(snapshot) = process.receive(snapshots, 100)
  let assert context_snapshot.Ready(request_context: Some(facts), ..) = snapshot
  list.length(facts.captured.contributions) |> should.equal(1)
  facts.fits |> should.be_false
  facts.failure
  |> should.equal(Some("request context bad: controlled later refusal"))
  fixture.read(captures) |> should.equal(1)
  runtime.stop(host)
}

pub fn optional_context_never_forces_indivisible_tail_compaction_test() -> Nil {
  let inputs = process.new_subject()
  let captures = fixture.counter()
  let summaries = fixture.counter()
  let capacity = fixture.counter()
  fixture.set(capacity, 1)
  let optional = context.Block("optional", string.repeat("x", 3600), False)
  let catalog =
    extension.Extension(
      "catalog",
      "controlled genuine capacity",
      [],
      [
        extension.ModelsPlugin(extension.ModelCatalog(
          fn(model, _) {
            Some(
              extension.ModelInfo(
                ..extension.blank_model(model, "fixture"),
                context_tokens: Some(fixture.read(capacity)),
                source: "fixture",
              ),
            )
          },
          fn(_, _) { ["model"] },
          None,
        )),
      ],
      extension.no_initialise,
    )
  let #(host, kernel) =
    fixture.start([
      fixture.declaration(captures, inputs, [optional]),
      catalog,
      rolling.configured_extension(rolling.Config(None, 80, 25)),
    ])
  let all =
    context.Prepared(
      [],
      [
        context.Selected(
          "fixture",
          "revision-1",
          context.Instructions,
          context.Block("source", "revision-1", True),
        ),
        context.Selected("fixture", "revision-1", context.Data, optional),
      ],
      [],
      context.Budget(None, None, 0, None),
    )
  let empty =
    types.Request(
      "model",
      Some(runtime.instructions(kernel)),
      [],
      runtime.tools(kernel),
      None,
      types.defaults,
    )
  fixture.set(
    capacity,
    runtime.request_estimate(context.assemble(empty, all)) + 1,
  )
  let assert Ok(prepared) =
    runtime.prepare_request_scoped(
      host,
      kernel,
      "model",
      "source",
      None,
      runtime.instructions(kernel),
      fn(_, _) {
        let _ = fixture.next(summaries)
        Ok("summary")
      },
      [types.User(string.repeat("history", 100))],
      False,
      types.any_images,
      None,
      fn() { Nil },
      compaction.unprojected,
      source_query: "fixture source query",
    )
  let final =
    context.reconcile(
      types.Request(
        "model",
        Some(runtime.instructions(kernel)),
        prepared.history.inputs,
        runtime.tools(kernel),
        None,
        types.defaults,
      ),
      prepared.captured,
      runtime.request_estimate,
      0,
    )
  final.fits |> should.be_true
  list.length(final.captured.omissions) |> should.equal(1)
  fixture.read(summaries) |> should.equal(0)
  fixture.read(captures) |> should.equal(1)
  runtime.stop(host)
}

// Current host session overrides must reach capture even without a strategy.
pub fn session_capacity_precedes_catalog_and_strategy_test() -> Nil {
  list.each(
    [[], [rolling.configured_extension(rolling.Config(Some(30_000), 80, 25))]],
    fn(strategies) {
      let inputs = process.new_subject()
      let #(host, kernel) =
        fixture.start(list.append(
          [
            fixture.declaration(fixture.counter(), inputs, []),
            fixture.catalog(Some(50_000)),
          ],
          strategies,
        ))
      let assert Ok(_) =
        store.query(runtime.ledger(host), fn(db) {
          session_configuration.save_context_window_in(db, "s", Some(40_000))
        })
      let assert Ok(prepared) =
        runtime.prepare_request_scoped(
          host,
          kernel,
          "model",
          "source",
          None,
          runtime.instructions(kernel),
          fn(_, _) { Error("must not summarize") },
          [types.User("hello")],
          False,
          types.any_images,
          None,
          fn() { Nil },
          compaction.unprojected,
          source_query: "hello",
        )
      prepared.captured.budget.capacity_tokens |> should.equal(Some(40_000))
      fixture.receive(inputs).budget.capacity_tokens
      |> should.equal(Some(40_000))
      runtime.stop(host)
    },
  )
}

pub fn forced_summary_uses_same_captured_revision_test() -> Nil {
  let captures = fixture.counter()
  let inputs = process.new_subject()
  let sent = process.new_subject()
  let saved = process.new_subject()
  let #(host, kernel) =
    fixture.start([
      fixture.declaration(captures, inputs, []),
      rolling.configured_extension(rolling.Config(None, 80, 25)),
    ])
  let provider =
    fixture.upstream(types.Responses, fn(request, _) {
      process.send(sent, request)
      fixture.change(runtime.ledger(host))
      Ok(fixture.complete())
    })
  let worker =
    fixture.worker(
      host,
      kernel,
      provider,
      saved,
      fn() { Ok([]) },
      loop.Unpinned,
    )
  loop.compact(worker, [
    types.User("new"),
    types.Assistant("answer"),
    types.User(string.repeat("older facts", 200)),
  ])
  |> should.be_ok
  let summary = fixture.receive(sent)
  option.unwrap(summary.instructions, "")
  |> string.contains("revision-1")
  |> should.be_true
  option.unwrap(summary.instructions, "")
  |> string.contains("revision-2")
  |> should.be_false
  let assert context_snapshot.Ready(request_context: Some(facts), ..) =
    fixture.receive(saved)
  list.first(facts.captured.contributions)
  |> should.equal(
    Ok(context.Captured(
      "fixture",
      context.Contribution(
        "revision-1",
        [context.Block("source", "revision-1", True)],
        [],
        ["coherent fixture read"],
      ),
    )),
  )
  fixture.read(captures) |> should.equal(1)
  runtime.stop(host)
}

pub fn summary_final_assembly_overflow_refuses_provider_test() -> Nil {
  let captures = fixture.counter()
  let calls = fixture.counter()
  let inputs = process.new_subject()
  let saved = process.new_subject()
  let strategy =
    extension.Extension(
      "summary-budget",
      "scripted final summary request",
      [],
      [
        extension.CompactionPlugin(
          compaction.Strategy("summary-budget", fn(catalog, _) {
            Ok(
              compaction.Resolved(
                catalog,
                fn(_, history) { Ok(compaction.View(history, None, False)) },
                fn(context, _) {
                  case
                    context.summarize(compaction.SummaryRequest(
                      "model",
                      None,
                      [types.User(string.repeat("oversized", 100_000))],
                      100,
                      compaction.summary_instructions,
                    ))
                  {
                    Ok(_) -> Ok(True)
                    Error(reason) -> Error(reason)
                  }
                },
              ),
            )
          }),
        ),
      ],
      extension.no_initialise,
    )
  let #(host, kernel) =
    fixture.start([
      fixture.declaration(captures, inputs, []),
      fixture.catalog(Some(50_000)),
      strategy,
    ])
  let provider =
    fixture.upstream(types.Responses, fn(_, _) {
      let _ = fixture.next(calls)
      Ok(fixture.complete())
    })
  let worker =
    fixture.worker(
      host,
      kernel,
      provider,
      saved,
      fn() { Ok([]) },
      loop.Unpinned,
    )
  let assert Error(reason) = loop.compact(worker, [types.User("hello")])
  string.contains(reason, "mandatory request content") |> should.be_true
  fixture.read(calls) |> should.equal(0)
  fixture.read(captures) |> should.equal(1)
  let assert context_snapshot.Ready(request_context: Some(facts), ..) =
    fixture.receive(saved)
  facts.fits |> should.be_false
  runtime.stop(host)
}

pub fn quarantined_required_owner_refuses_retained_composition_test() -> Nil {
  let required =
    extension.Extension(
      "missing",
      "unavailable required callback",
      [],
      [
        extension.RequestContextPlugin(
          fn(_) { panic as "must not capture" },
          True,
        ),
      ],
      fn(_) { Error("unavailable") },
    )
  let host = fixture.start_host(extensions.Config([required], []))
  let assert Ok(kernel) = runtime.open_session(host, "s", "/tmp")
  let assert Ok(_) =
    selection.record(
      runtime.ledger(host),
      "s",
      selection.SetSession("missing", True),
    )
  let outcome =
    runtime.prepare_request_scoped(
      host,
      kernel,
      "model",
      "source",
      None,
      "static",
      fn(_, _) { panic as "must not summarize" },
      [types.User("hi")],
      False,
      types.any_images,
      None,
      fn() { Nil },
      compaction.unprojected,
      source_query: "hi",
    )
  let assert Error(failure) = outcome
  string.contains(failure.reason, "required request context missing")
  |> should.be_true
  runtime.stop(host)
}

pub fn absent_persistent_owner_refuses_foreground_and_background_test() -> Nil {
  let calls = fixture.counter()
  let #(host, kernel) = fixture.start([])
  let ledger = runtime.ledger(host)
  let assert Ok(_) =
    store.query(ledger, fn(db) {
      session_requirements.require_in(db, "s", "removed-owner")
    })
  let provider =
    fixture.upstream(types.Responses, fn(_, _) {
      let _ = fixture.next(calls)
      Ok(fixture.complete())
    })
  let worker =
    fixture.worker(
      host,
      kernel,
      provider,
      process.new_subject(),
      fn() { Ok([]) },
      loop.Unpinned,
    )
  loop.run(worker, "s", [types.User("hello")], 0) |> should.be_error
  loop.compact(worker, [types.User("hello")]) |> should.be_error
  let request =
    types.Request(
      "model",
      Some("saved"),
      [types.User("hello")],
      [],
      None,
      types.defaults,
    )
  loop.background(
    loop.CallContext(ledger, provider, "s", "fixture", "warm", None, fn() {
      runtime.admit(host, kernel)
    }),
    request,
    requests.direct_prefix("saved", [], request.input),
  )
  |> should.be_error
  fixture.read(calls) |> should.equal(0)
  runtime.stop(host)
}

pub fn retry_rechecks_deselected_persistent_owner_without_recapture_test() -> Nil {
  let captures = fixture.counter()
  let providers = fixture.counter()
  let #(host, kernel) =
    fixture.start([fixture.declaration(captures, process.new_subject(), [])])
  let ledger = runtime.ledger(host)
  let assert Ok(_) =
    store.query(ledger, fn(db) {
      session_requirements.require_in(db, "s", "fixture")
    })
  let provider =
    fixture.upstream(types.Responses, fn(_, _) {
      let _ = fixture.next(providers)
      let assert Ok(_) =
        selection.record(ledger, "s", selection.SetSession("fixture", False))
      Error(types.UnexpectedEnd)
    })
  let worker =
    fixture.worker(
      host,
      kernel,
      provider,
      process.new_subject(),
      fn() { Ok([]) },
      loop.Unpinned,
    )
  loop.run(worker, "s", [types.User("hello")], 0) |> should.be_error
  fixture.read(captures) |> should.equal(1)
  fixture.read(providers) |> should.equal(1)
  runtime.stop(host)
}
