//// External consumer assertions: native callback APIs cannot be installed by
//// stock HTTP. Actual loop integration lives in context_loop_test.

import albedo/daemon/store
import albedo/harness/compaction
import albedo/harness/extension
import albedo/harness/extensions/lcm/extension as lcm
import albedo/harness/extensions/rolling/extension as rolling
import albedo/harness/extensions/snapcompact/extension as snapcompact
import albedo/harness/request_context as context
import albedo/openai_api/types
import context_fixture as fixture
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() -> Nil {
  gleeunit.main()
}

fn estimate(request: types.Request) -> Int {
  compaction.estimate_pinned(
    option.unwrap(request.instructions, ""),
    request.tools,
  )
  + compaction.estimate_inputs(request.input)
}

fn request() -> types.Request {
  types.Request(
    "fixture",
    Some("static"),
    [types.User("durable")],
    [],
    None,
    types.defaults,
  )
}

fn capture(capacity: Int) -> context.Prepared {
  let assert Ok(ledger) = store.start(":memory:", "")
  let input =
    context.Input(
      ledger,
      "s",
      ["fixture"],
      "q",
      context.Budget(Some(capacity), Some("fixture"), 2, Some(capacity - 2)),
    )
  let assert Ok(prepared) =
    context.prepare(
      [
        #("fixture", fn(_) {
          Ok(
            context.Contribution(
              "revision-1",
              [
                context.Block("required", "mandatory", True),
                context.Block(
                  "optional-instructions",
                  string.repeat("x", 200),
                  False,
                ),
              ],
              [context.Block("optional-data", string.repeat("y", 200), False)],
              ["read-only"],
            ),
          )
        }),
      ],
      input,
    )
  store.close(ledger)
  prepared
}

pub fn whole_optional_blocks_and_actual_price_test() -> Nil {
  let base = request()
  let prepared = capture(80)
  let final = context.reconcile(base, prepared, estimate, 0)
  final.fits |> should.be_true
  final.estimated_tokens |> should.equal(estimate(final.request))
  list.length(final.captured.omissions) |> should.equal(2)
  string.contains(option.unwrap(final.request.instructions, ""), "mandatory")
  |> should.be_true
  string.contains(
    option.unwrap(final.request.instructions, ""),
    "optional-instructions",
  )
  |> should.be_false
  final.request.input |> should.equal(base.input)
  list.length(final.captured.contributions) |> should.equal(1)
}

pub fn static_overflow_with_zero_dynamic_blocks_test() -> Nil {
  let prepared =
    context.Prepared(
      [],
      [],
      [],
      context.Budget(Some(10), Some("configured"), 0, Some(10)),
    )
  let final = context.reconcile(request(), prepared, estimate, 0)
  final.fits |> should.be_false
  final.estimated_tokens |> should.equal(estimate(request()))
}

pub fn unknown_capacity_preserves_whole_values_test() -> Nil {
  let prepared = capture(80)
  let unknown =
    context.Prepared(..prepared, budget: context.Budget(None, None, 2, None))
  let final = context.reconcile(request(), unknown, estimate, 0)
  final.fits |> should.be_true
  final.captured.omissions |> should.equal([])
  list.length(final.request.input) |> should.equal(2)
}

pub fn utf8_recent_query_boundary_test() -> Nil {
  context.query([]) |> should.equal("")
  list.each([4095, 4096, 4097], fn(size) {
    let text = string.repeat("a", size)
    let bounded =
      context.query([
        types.User("old"),
        types.Assistant("answer"),
        types.UserImage(text, []),
      ])
    string.byte_size(bounded)
    |> should.equal(case size > 4096 {
      True -> 4096
      False -> size
    })
  })
  let text = string.repeat("a", 4095) <> "é" <> "end"
  context.query([types.User(text)]) |> should.equal(string.repeat("a", 4095))
  context.query([types.User(string.repeat("é", 2048))])
  |> should.equal(string.repeat("é", 2048))
}

pub fn rolling_resolves_real_capacity_before_force_test() -> Nil {
  let declared =
    rolling.configured_extension(rolling.Config(Some(1234), 80, 25))
  let assert Some(strategy) = extension.compaction([declared])
  let assert Ok(resolved) =
    strategy.resolve(Some(compaction.Capacity(9999, "catalog")), None)
  resolved.capacity
  |> should.equal(
    Some(compaction.Capacity(1234, "configured contextWindowTokens")),
  )
  let assert Some(unknown) =
    extension.compaction([
      rolling.configured_extension(rolling.Config(None, 80, 25)),
    ])
  let assert Ok(resolved) = unknown.resolve(None, None)
  resolved.capacity |> should.equal(None)
}

pub fn stock_configured_capacity_matrix_test() -> Nil {
  list.each([None, Some(1234)], fn(configured) {
    list.each([None, Some(compaction.Capacity(9999, "catalog"))], fn(catalog) {
      list.each(
        [
          rolling.configured_extension(rolling.Config(configured, 80, 25)),
          lcm.configured_extension(lcm.Config(configured, Some(80), 25)),
        ],
        fn(declared) {
          let assert Some(strategy) = extension.compaction([declared])
          let assert Ok(resolved) = strategy.resolve(catalog, None)
          resolved.capacity
          |> should.equal(case configured {
            Some(tokens) ->
              Some(compaction.Capacity(tokens, "configured contextWindowTokens"))
            None -> catalog
          })
        },
      )
    })
  })
}

pub fn snapcompact_visual_and_text_fallback_capacity_matrix_test() -> Nil {
  fixture.with_settings(
    "{\"snapcompact\":{\"contextWindowTokens\":1234},\"rolling\":{\"contextWindowTokens\":777}}",
    fn() {
      let assert Some(strategy) =
        extension.compaction([snapcompact.extension()])
      let catalog = Some(compaction.Capacity(9999, "catalog"))
      list.each(
        [
          None,
          Some(compaction.Reader("fixture", [])),
          Some(compaction.Reader("fixture", ["image", "text"])),
        ],
        fn(reader) {
          let assert Ok(visual) = strategy.resolve(catalog, reader)
          visual.capacity |> should.equal(catalog)
          let assert Ok(fallback) = strategy.resolve(None, reader)
          fallback.capacity
          |> should.equal(
            Some(compaction.Capacity(1234, "configured contextWindowTokens")),
          )
        },
      )
      let assert Ok(text) =
        strategy.resolve(catalog, Some(compaction.Reader("fixture", ["text"])))
      text.capacity
      |> should.equal(
        Some(compaction.Capacity(777, "configured contextWindowTokens")),
      )
    },
  )
}

pub fn collective_optionals_are_omitted_in_reverse_order_test() -> Nil {
  let assert Ok(ledger) = store.start(":memory:", "")
  let input =
    context.Input(
      ledger,
      "s",
      ["first", "second"],
      "query",
      context.Budget(Some(80), Some("fixture"), 0, Some(80)),
    )
  let assert Ok(prepared) =
    context.prepare(
      [
        #("first", fn(_) {
          Ok(
            context.Contribution(
              "one",
              [],
              [context.Block("first", string.repeat("a", 120), False)],
              [],
            ),
          )
        }),
        #("second", fn(_) {
          Ok(
            context.Contribution(
              "two",
              [],
              [context.Block("second", string.repeat("b", 120), False)],
              [],
            ),
          )
        }),
      ],
      input,
    )
  let base = types.Request("fixture", None, [], [], None, types.defaults)
  let final = context.reconcile(base, prepared, estimate, 0)
  final.fits |> should.be_true
  let assert [omitted] = final.captured.omissions
  omitted.owner |> should.equal("second")
  let assert [selected] = final.captured.blocks
  selected.owner |> should.equal("first")
  list.length(final.captured.contributions) |> should.equal(2)
  store.close(ledger)
}
