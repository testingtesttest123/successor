//// Lossless context management: source-backed summaries plus a verbatim tail.
//// All summary nodes are derived views over immutable transcript rows.

import albedo/daemon/conversation
import albedo/daemon/store
import albedo/daemon/tool_results
import albedo/daemon/transcript
import albedo/harness/compaction
import albedo/harness/extension as harness_extension
import albedo/harness/extensions/lcm/formation
import albedo/harness/extensions/lcm/graph
import albedo/harness/extensions/lcm/narration
import albedo/harness/extensions/personality/episodes
import albedo/harness/extensions/rolling/extension as rolling
import albedo/harness/settings
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

const leaf_budget = 6000

const summary_tokens = 768

pub type Config {
  Config(
    context_window_tokens: Option(Int),
    trigger_percent: Int,
    tail_percent: Int,
  )
}

type ModelUnit {
  ModelUnit(items: List(types.Input), tokens: Int)
}

fn default_config() -> Config {
  Config(None, 80, 25)
}

pub fn configured_extension(config: Config) -> harness_extension.Extension {
  bundle(fn() { validate(config) })
}

pub fn extension() -> harness_extension.Extension {
  bundle(fn() {
    use config <- result.try(settings.load("lcm", decoder(), default_config()))
    validate(config)
  })
}

fn bundle(
  resolve: fn() -> Result(Config, String),
) -> harness_extension.Extension {
  harness_extension.Extension(
    "lcm",
    "Source-backed hierarchical summaries with bounded history retrieval",
    ["lcm-memory"],
    [
      harness_extension.CompactionPlugin(strategy_with("lcm", resolve)),
      harness_extension.CleanPlugin(graph.forget_session),
    ],
    graph.initialise,
  )
}

/// Stored LCM folds for another strategy's source history after a strategy
/// change. The graph stays fixed while LCM is inactive, so a strategy's source
/// hashes continue to refer to the same folded prefix as new turns arrive.
pub fn stored_prior(
  ledger: store.Store,
  session: String,
  history: List(types.Input),
) -> Result(compaction.Prior, String) {
  use available <- result.try(graph.storage_available(ledger))
  use frontier <- result.try(case available {
    False -> Ok([])
    True -> graph.frontier(ledger, session)
  })
  case frontier {
    [] -> compaction.no_prior(history)
    _ -> {
      use covered <- result.try(graph.last_seq(ledger, session))
      use snapshot <- result.try(conversation.snapshot(ledger, session))
      use stats <- result.try(conversation.source_stats(
        ledger,
        snapshot,
        covered,
      ))
      Ok(split(frontier, history, stats, None, 0, None, session))
    }
  }
}

fn decoder() -> decode.Decoder(Config) {
  use capacity <- decode.optional_field(
    "contextWindowTokens",
    None,
    decode.optional(decode.int),
  )
  use trigger <- decode.optional_field("triggerPercent", 80, decode.int)
  use tail <- decode.optional_field("tailPercent", 25, decode.int)
  decode.success(Config(capacity, trigger, tail))
}

fn validate(config: Config) -> Result(Config, String) {
  rolling.validate_window(
    "lcm",
    config.context_window_tokens,
    config.trigger_percent,
    config.tail_percent,
  )
  |> result.replace(config)
}

/// The stored frontier's summary nodes ahead of a verbatim tail, and whether
/// that request reached the trigger.
fn project(
  config: Config,
  context: compaction.Context,
  history: List(types.Input),
) -> Result(compaction.View, String) {
  use Saved(frontier:, stats:, ..) <- result.try(saved(context))
  let window =
    rolling.effective_window(config.context_window_tokens, context, history)
  let current =
    projection(
      frontier,
      history,
      stats,
      tail_budget(config, window),
      1,
      subject(context),
      context.session,
    )
  use current <- result.try(continuity(context, frontier, current, window))
  let estimated = context.pinned_tokens + compaction.estimate_inputs(current)
  case window {
    None ->
      Ok(view(
        current,
        frontier,
        "unknown",
        "estimated; no configured or catalogued context window",
        None,
        estimated,
        config,
        history,
        False,
      ))
    Some(compaction.Capacity(tokens: capacity, source: capacity_source)) -> {
      use _ <- result.try(compaction.fits_pinned(context, capacity))
      Ok(view(
        current,
        frontier,
        case frontier {
          [] -> "not_needed"
          _ -> "compacted"
        },
        "estimated from current request projection; window from "
          <> capacity_source,
        Some(capacity),
        estimated,
        config,
        history,
        compaction.triggered(
          False,
          estimated,
          Some(capacity),
          config.trigger_percent,
        ),
      ))
    }
  }
}

/// Summarizes the complete units after the frontier into leaves, then
/// condenses the frontier until the request fits; answers whether the
/// frontier changed.
fn compact(
  config: Config,
  context: compaction.Context,
  history: List(types.Input),
) -> Result(Bool, String) {
  use expected <- result.try(graph.snapshot(context.store, context.session))
  use Saved(snapshot, covered, frontier, stats) <- result.try(saved(context))
  use _ <- result.try(compaction.require(
    expected.covered == covered
      && expected.frontier_ids == list.map(frontier, fn(node) { node.id })
      && expected.source_through == snapshot.upper,
    "LCM source planning snapshot changed",
  ))
  let window =
    rolling.effective_window(config.context_window_tokens, context, history)
  use compaction.Capacity(tokens: capacity, ..) <- result.try(option.to_result(
    window,
    "no configured or catalogued context window to compact against",
  ))
  use _ <- result.try(compaction.fits_pinned(context, capacity))
  let tail_budget = tail_budget(config, window)
  let previous_frontier = frontier
  use latest_user <- result.try(option.to_result(
    stats.latest_user,
    "LCM needs a user message to retain as its tail",
  ))
  use eligible <- result.try(case covered + 1 < latest_user {
    False -> Ok([])
    True ->
      conversation.fold_sources(
        context.store,
        snapshot,
        covered + 1,
        latest_user - 1,
        [],
        fn(rows, item) { conversation.Continue([item, ..rows]) },
      )
  })
  let eligible =
    list.reverse(eligible)
    |> closed_source_units
    |> list.flat_map(fn(unit) { unit.0 })
  use _ <- result.try(compaction.require(
    eligible != [] || frontier != [],
    "cannot compact without an older complete conversation unit",
  ))
  let summary_limit =
    int.min(
      summary_tokens,
      int.max(32, { capacity - context.pinned_tokens } / 4),
    )
  use leaves <- result.try(summarize_leaves(context, eligible, summary_limit))
  use committed <- result.try(graph.commit_leaves(
    context.store,
    context.session,
    expected,
    leaves,
    commit_guard(context),
  ))
  use _ <- result.try(compaction.require(
    committed || leaves == [],
    "LCM generated result is stale; sources remain unchanged",
  ))
  use frontier <- result.try(graph.frontier(context.store, context.session))
  use covered <- result.try(graph.last_seq(context.store, context.session))
  use stats <- result.try(conversation.source_stats(
    context.store,
    snapshot,
    covered,
  ))
  use frontier <- result.try(condense_until_fit(
    context,
    frontier,
    history,
    stats,
    tail_budget,
    capacity,
    summary_limit,
    0,
  ))
  let next =
    projection(
      frontier,
      history,
      stats,
      tail_budget,
      1,
      subject(context),
      context.session,
    )
  use _ <- result.try(compaction.require(
    context.pinned_tokens + compaction.estimate_inputs(next) < capacity
      || context.force,
    "LCM summaries and the newest conversation/tool unit do not fit the context window",
  ))
  Ok(frontier != previous_frontier)
}

/// The session's saved graph against its transcript: the append boundary,
/// the last row the graph covers, its frontier, and the rows after it.
type Saved {
  Saved(
    snapshot: conversation.Snapshot,
    covered: Int,
    frontier: List(graph.Node),
    stats: conversation.SourceStats,
  )
}

fn saved(context: compaction.Context) -> Result(Saved, String) {
  use snapshot <- result.try(conversation.snapshot(
    context.store,
    context.session,
  ))
  use covered <- result.try(graph.last_seq(context.store, context.session))
  use frontier <- result.try(graph.frontier(context.store, context.session))
  use stats <- result.try(conversation.source_stats(
    context.store,
    snapshot,
    covered,
  ))
  Ok(Saved(snapshot, covered, frontier, stats))
}

/// The verbatim tail's share of the window, when there is one.
fn tail_budget(
  config: Config,
  window: Option(compaction.Capacity),
) -> Option(Int) {
  option.map(window, fn(window) { window.tokens * config.tail_percent / 100 })
}

fn view(
  inputs: List(types.Input),
  frontier: List(graph.Node),
  status: String,
  source: String,
  capacity: Option(Int),
  estimated: Int,
  config: Config,
  original: List(types.Input),
  due: Bool,
) -> compaction.View {
  compaction.View(
    inputs,
    Some(compaction.observation(
      "lcm",
      status,
      source,
      case frontier {
        [] -> "durable transcript without an LCM summary"
        _ ->
          "durable transcript through source-backed LCM nodes + verbatim tail"
      },
      config.trigger_percent,
      capacity,
      estimated,
      list.length(original),
      list.length(inputs),
    )),
    due,
  )
}

fn projection(
  frontier: List(graph.Node),
  history: List(types.Input),
  stats: conversation.SourceStats,
  tail_budget: Option(Int),
  minimum_tail_units: Int,
  current_subject: Option(String),
  session: String,
) -> List(types.Input) {
  let compaction.Prior(folds, rest) =
    split(
      frontier,
      history,
      stats,
      tail_budget,
      minimum_tail_units,
      current_subject,
      session,
    )
  list.append(folds, rest)
}

fn split(
  frontier: List(graph.Node),
  history: List(types.Input),
  stats: conversation.SourceStats,
  tail_budget: Option(Int),
  minimum_tail_units: Int,
  current_subject: Option(String),
  session: String,
) -> compaction.Prior {
  case frontier {
    [] -> compaction.Prior([], history)
    nodes -> {
      // An assistant or tool result can follow the cursor without a user row.
      // Retain its whole projected unit until live source references permit
      // a narrower cut.
      let minimum = case stats.uncovered {
        False -> minimum_tail_units
        True -> int.max(1, minimum_tail_units)
      }
      let tail =
        retain_tail(
          history,
          int.max(minimum, stats.uncovered_users),
          tail_budget,
        )
      compaction.Prior(
        list.flat_map(nodes, fn(node) {
          case current_subject {
            None -> [node_input(node)]
            Some(_) -> narration.render_scoped(node, session, current_subject)
          }
        }),
        tail,
      )
    }
  }
}

fn node_input(node: graph.Node) -> types.Input {
  types.User(
    "[LCM summary node #"
    <> int.to_string(node.id)
    <> "; durable source rows "
    <> int.to_string(node.first_seq)
    <> ".."
    <> int.to_string(node.last_seq)
    <> "; use lcm_grep/lcm_describe/lcm_expand to recover details]\n"
    <> node.summary
    <> "\n[end LCM node #"
    <> int.to_string(node.id)
    <> "]",
  )
}

fn summarize_leaves(
  context: compaction.Context,
  eligible: List(transcript.SourcedEntry),
  summary_limit: Int,
) -> Result(List(graph.Leaf), String) {
  case context.summary_policy {
    Some(policy) -> formation.leaves(context, eligible, summary_limit, policy)
    None -> generic_leaves(context, eligible, summary_limit)
  }
}

fn generic_leaves(
  context: compaction.Context,
  eligible: List(transcript.SourcedEntry),
  summary_limit: Int,
) -> Result(List(graph.Leaf), String) {
  let overhead = 0
  let chunks =
    rolling.chunk_units(
      source_units(eligible),
      int.max(1, leaf_budget - overhead),
    )
  use chunk <- list.try_map(chunks)
  case chunk {
    [] -> Error("cannot summarize an empty source chunk")
    [first, ..rest] -> {
      let last = list.fold(rest, first, fn(_, item) { item })
      let inputs = list.map(chunk, fn(item) { item.entry.input })
      let evidence = compaction.NoEvidence
      use summary <- result.try(summarize_bounded(
        context,
        inputs,
        evidence,
        summary_limit,
      ))
      Ok(graph.Leaf(first.source.seq, last.source.seq, summary, None))
    }
  }
}

/// Source rows grouped into conversation units, each with its token cost.
fn source_units(
  sources: List(transcript.SourcedEntry),
) -> List(#(List(transcript.SourcedEntry), Int)) {
  compaction.split_starts(sources, fn(item) {
    compaction.is_user(item.entry.input)
  })
  |> list.map(fn(items) {
    #(
      items,
      items
        |> list.map(fn(item) { item.entry.input })
        |> compaction.estimate_inputs,
    )
  })
}

/// Native result settlement can later move positions of an unanswered call.
/// Never skip such a unit to cover later raw rows in the shared graph.
fn closed_source_units(
  sources: List(transcript.SourcedEntry),
) -> List(#(List(transcript.SourcedEntry), Int)) {
  source_units(sources)
  |> list.take_while(fn(unit) {
    tool_results.closed_unit(list.map(unit.0, fn(row) { row.entry.input }))
  })
}

fn model_units(history: List(types.Input)) -> List(ModelUnit) {
  compaction.split_starts(history, compaction.is_user)
  |> list.map(fn(items) { ModelUnit(items, compaction.estimate_inputs(items)) })
}

fn retain_tail(
  history: List(types.Input),
  required_units: Int,
  budget: Option(Int),
) -> List(types.Input) {
  model_units(history)
  |> list.reverse
  |> compaction.keep_tail(required_units, budget, fn(unit) { unit.tokens })
  |> list.flat_map(fn(unit) { unit.items })
}

fn condense_until_fit(
  context: compaction.Context,
  frontier: List(graph.Node),
  history: List(types.Input),
  stats: conversation.SourceStats,
  tail_budget: Option(Int),
  capacity: Int,
  summary_limit: Int,
  attempts: Int,
) -> Result(List(graph.Node), String) {
  let view =
    projection(
      frontier,
      history,
      stats,
      tail_budget,
      1,
      subject(context),
      context.session,
    )
  let estimated = context.pinned_tokens + compaction.estimate_inputs(view)
  case estimated < capacity || attempts >= 16, frontier {
    False, [_, _, ..] -> {
      let group = case context.summary_policy {
        None -> list.take(frontier, 4)
        Some(_) -> condensation_group(context, frontier)
      }
      use expected <- result.try(graph.snapshot(context.store, context.session))
      use #(summary, frame) <- result.try(case context.summary_policy {
        Some(policy) -> formation.parent(context, group, summary_limit, policy)
        None ->
          summarize_bounded(
            context,
            list.map(group, node_input),
            compaction.NoEvidence,
            summary_limit,
          )
          |> result.map(fn(summary) { #(summary, None) })
      })
      use committed <- result.try(graph.commit_parent(
        context.store,
        context.session,
        expected,
        group,
        summary,
        frame,
        commit_guard(context),
      ))
      use _ <- result.try(compaction.require(
        committed,
        "LCM generated parent is stale; sources remain unchanged",
      ))
      use next <- result.try(graph.frontier(context.store, context.session))
      condense_until_fit(
        context,
        next,
        history,
        stats,
        tail_budget,
        capacity,
        summary_limit,
        attempts + 1,
      )
    }
    _, _ -> Ok(frontier)
  }
}

/// A provider can return a summary longer than its source. Retry with a
/// smaller output cap, then keep a short navigable pointer if both grow.
/// Source rows and child nodes remain intact in every case.
pub fn summarize_bounded(
  context: compaction.Context,
  inputs: List(types.Input),
  evidence: compaction.SummaryEvidence,
  limit: Int,
) -> Result(String, String) {
  let original = compaction.estimate_inputs(inputs)
  use first <- result.try(attempt_summary(context, inputs, evidence, limit))
  case fits_summary(first, original, limit) {
    True -> Ok(first)
    False ->
      attempt_summary(context, inputs, evidence, int.max(32, limit / 3))
      |> result.map(fn(second) {
        case fits_summary(second, original, limit) {
          True -> second
          False -> "Summary exceeded its source; inspect the linked rows."
        }
      })
  }
}

/// One summarizer call: trimmed, non-empty, bounded by `limit` output tokens.
pub fn attempt_summary(
  context: compaction.Context,
  inputs: List(types.Input),
  evidence: compaction.SummaryEvidence,
  limit: Int,
) -> Result(String, String) {
  use summary <- result.try(
    context.summarize(compaction.SummaryRequest(
      context.model,
      None,
      inputs,
      limit,
      summary_instructions(context),
      case context.summary_policy {
        None -> compaction.NoEvidence
        Some(_) -> evidence
      },
      context.summary_policy,
      None,
    )),
  )
  let summary = string.trim(summary)
  use _ <- result.try(compaction.require(
    summary != "",
    "LCM summarizer returned an empty summary",
  ))
  Ok(summary)
}

fn fits_summary(summary: String, original: Int, limit: Int) -> Bool {
  let tokens = compaction.estimate_inputs([types.User(summary)])
  tokens < original && tokens <= limit
}

fn summary_instructions(context: compaction.Context) -> String {
  option.map(context.summary_policy, fn(policy) { policy.instructions })
  |> option.unwrap(compaction.summary_instructions)
}

/// Count the instruction head and full bounded envelope before combining nodes.
/// Two whole nodes are the minimum useful condensation, including oversized
/// historical nodes; their immutable child boundaries are never split.
fn condensation_group(
  context: compaction.Context,
  frontier: List(graph.Node),
) -> List(graph.Node) {
  let budget =
    int.max(
      1,
      leaf_budget
        - compaction.estimate_pinned(summary_instructions(context), [])
        - 1056,
    )
  let candidates = list.take(frontier, 4)
  let chunks =
    rolling.chunk_units(
      list.map(candidates, fn(node) {
        #([node], compaction.estimate_input(node_input(node)))
      }),
      budget,
    )
  case chunks {
    [first, ..] ->
      case list.length(first) >= 2 {
        True -> first
        False -> list.take(candidates, 2)
      }
    _ -> list.take(candidates, 2)
  }
}

/// Native reusable resolver. Another bundle retains the same LCM settings,
/// graph, projection and compaction without installing a second strategy.
pub fn strategy(name: String) -> compaction.Strategy {
  strategy_with(name, fn() {
    use config <- result.try(settings.load("lcm", decoder(), default_config()))
    validate(config)
  })
}

fn strategy_with(
  name: String,
  resolve: fn() -> Result(Config, String),
) -> compaction.Strategy {
  compaction.Strategy(name, fn(catalog, _) {
    use config <- result.map(resolve())
    compaction.Resolved(
      case name {
        "personality" -> Some(prepare_ahead)
        _ -> None
      },
      rolling.configured_capacity(config.context_window_tokens, catalog),
      fn(context, history) { project(config, context, history) },
      fn(context, history) { compact(config, context, history) },
    )
  })
}

fn subject(context: compaction.Context) -> Option(String) {
  option.map(context.summary_policy, fn(policy) { policy.lineage.subject })
}

fn commit_guard(context: compaction.Context) -> graph.CommitGuard {
  let policy = case context.summary_policy {
    None -> graph.unguarded
    Some(policy) -> episodes.guard(policy, context.session)
  }
  fn(db) {
    case context.active() {
      False -> Ok(False)
      True -> policy(db)
    }
  }
}

/// One native background step. Complete older source units form first;
/// otherwise a pending frontier merge may still make progress. No overflow
/// trigger, synthetic window or permanent background quota is involved.
fn prepare_ahead(context: compaction.Context) -> Result(Bool, String) {
  use _ <- result.try(compaction.require(
    context.summary_policy != None,
    "autobiographical preparation requires captured personality context",
  ))
  case context.active() {
    False -> Ok(False)
    True -> {
      use expected <- result.try(graph.snapshot(context.store, context.session))
      use snapshot <- result.try(conversation.snapshot(
        context.store,
        context.session,
      ))
      use covered <- result.try(graph.last_seq(context.store, context.session))
      use frontier <- result.try(graph.frontier(context.store, context.session))
      use _ <- result.try(compaction.require(
        expected.covered == covered
          && expected.frontier_ids == list.map(frontier, fn(node) { node.id })
          && expected.source_through == snapshot.upper,
        "LCM source planning snapshot changed",
      ))
      use window <- result.try(option.to_result(
        context.capacity,
        "no configured or catalogued context window for autobiographical preparation",
      ))
      use _ <- result.try(compaction.fits_pinned(context, window.tokens))
      let limit =
        int.min(
          summary_tokens,
          int.max(32, { window.tokens - context.pinned_tokens } / 4),
        )
      use first <- result.try(conversation.first_source_unit(
        context.store,
        snapshot,
        covered,
      ))
      use rows <- result.try(case first {
        Some(#(first, last)) ->
          conversation.fold_sources(
            context.store,
            snapshot,
            first,
            last,
            [],
            fn(rows, row) { conversation.Continue([row, ..rows]) },
          )
          |> result.map(list.reverse)
        None -> Ok([])
      })
      let next_unit = case closed_source_units(rows) {
        [#(unit, _), ..] -> Some(unit)
        _ -> None
      }
      case next_unit, frontier {
        Some(unit), _ -> {
          use leaves <- result.try(summarize_leaves(context, unit, limit))
          graph.commit_leaves(
            context.store,
            context.session,
            expected,
            leaves,
            commit_guard(context),
          )
        }
        None, [_, _, ..] -> {
          let group = condensation_group(context, frontier)
          let assert Some(policy) = context.summary_policy
          use #(summary, frame) <- result.try(formation.parent(
            context,
            group,
            limit,
            policy,
          ))
          graph.commit_parent(
            context.store,
            context.session,
            expected,
            group,
            summary,
            frame,
            commit_guard(context),
          )
        }
        _, _ -> Ok(False)
      }
    }
  }
}

fn continuity(
  context: compaction.Context,
  frontier: List(graph.Node),
  current: List(types.Input),
  capacity: Option(compaction.Capacity),
) -> Result(List(types.Input), String) {
  case frontier, context.summary_policy {
    [], Some(policy) -> {
      use previous <- result.map(episodes.latest(
        context.store,
        context.session,
        policy,
      ))
      case previous {
        None -> current
        Some(#(session, node)) -> {
          let pair =
            narration.render_scoped(node, session, Some(policy.lineage.subject))
          let allowance =
            option.map(capacity, fn(capacity) {
              capacity.tokens
              - context.pinned_tokens
              - compaction.estimate_inputs(current)
              - 256
            })
            |> option.unwrap(1024)
          case compaction.estimate_inputs(pair) <= int.min(1024, allowance) {
            True -> list.append(pair, current)
            False -> current
          }
        }
      }
    }
    _, _ -> Ok(current)
  }
}
