//// Shared foreground/background LCM formation. Provider work precedes graph CAS.
//// Long units commit only after every reading portion and all folds succeed.

import albedo/daemon/conversation
import albedo/daemon/transcript
import albedo/daemon/transcript_attribution
import albedo/harness/compaction
import albedo/harness/extensions/lcm/graph
import albedo/harness/extensions/lcm/narration
import albedo/harness/extensions/lcm/narration_types as n
import albedo/harness/extensions/personality/domain
import albedo/harness/extensions/rolling/extension as rolling
import albedo/harness/request_context
import albedo/openai_api/types
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

type Reflection {
  Reflection(text: Option(String), portions: List(n.Portion))
}

fn budget(context: compaction.Context) -> Int {
  option.map(context.capacity, fn(capacity) {
    int.min(12_000, capacity.tokens - context.pinned_tokens)
  })
  |> option.unwrap(6000)
}

fn who(policy: request_context.SummaryPolicy) -> n.Narrator {
  n.Narrator(
    policy.lineage.subject,
    policy.narrator_name,
    policy.identity_revision,
  )
}

fn source_frame(
  context: compaction.Context,
  rows: List(transcript.SourcedEntry),
  policy: request_context.SummaryPolicy,
) -> n.Frame {
  let actors =
    transcript_attribution.sourced(context.store, rows) |> result.unwrap([])
  let sources =
    list.map(rows, fn(row) {
      let actor =
        list.find(actors, fn(actor) { actor.0 == row.source.seq })
        |> result.map(fn(actor) { actor.1 })
        |> result.unwrap("unknown_origin")
      let perspective = case row.source.seq <= policy.lineage.supplied_through {
        True -> n.Witnessed
        False ->
          case actor {
            "unknown_origin" -> n.Unknown
            "owner_agent" | "user_assertion" -> n.Experienced
            _ -> n.Witnessed
          }
      }
      n.Boundary(
        row.source.session,
        row.source.seq,
        row.source.session,
        row.source.seq,
        perspective,
        actor,
        narration.source_role(row.entry.input),
      )
    })
  n.Frame(
    Some(who(policy)),
    n.combine(list.map(sources, fn(source) { source.perspective })),
    sources,
    [],
  )
}

fn attributions(frame: n.Frame) -> List(compaction.Attribution) {
  list.map(frame.sources, fn(source) {
    let origin = case source.actor, source.perspective {
      "tool_report", _ | "agent_report:" <> _, _ | "external_report:" <> _, _ ->
        "reported"
      _, n.Experienced -> "experienced"
      _, n.Unknown -> "imported"
      _, _ -> "imported"
    }
    compaction.Attribution(source.seq, source.seq, origin, Some(source.actor))
  })
}

fn request(
  context: compaction.Context,
  policy: request_context.SummaryPolicy,
  frame: n.Frame,
  mode: String,
  inputs: List(types.Input),
  portions: List(n.Portion),
  previous: Option(n.Recall),
  evidence: compaction.SummaryEvidence,
  limit: Int,
  source_only: Bool,
) -> compaction.SummaryRequest {
  compaction.SummaryRequest(
    context.model,
    None,
    inputs,
    limit,
    policy.instructions
      <> "\n"
      <> narration.instruction(mode)
      <> case mode {
      "consolidation" ->
        "\nUse the immutable formation frame narrator and actual child perspectives. The current living identity cannot rename a child memory. With unknown/multiple narrators, return attributed evidence."
      _ -> ""
    },
    evidence,
    Some(policy),
    Some(n.Formation(
      frame,
      mode,
      portions,
      previous,
      budget(context),
      source_only,
    )),
  )
}

fn cost(request: compaction.SummaryRequest) -> Result(Int, String) {
  use inputs <- result.map(narration.summary_inputs(request))
  compaction.estimate_pinned(request.instructions, [])
  + compaction.estimate_inputs(inputs)
  + request.max_output_tokens
}

fn call(
  context: compaction.Context,
  request: compaction.SummaryRequest,
) -> Result(String, String) {
  use estimate <- result.try(cost(request))
  let assert Some(formation) = request.formation
  use _ <- result.try(compaction.require(
    estimate <= formation.budget,
    "LCM narration mandatory context/source/output exceeds summary budget",
  ))
  use text <- result.try(context.summarize(request))
  let text = string.trim(text)
  use _ <- result.try(compaction.require(
    text != "",
    "LCM summarizer returned an empty summary",
  ))
  Ok(text)
}

fn bounded(
  context: compaction.Context,
  request: compaction.SummaryRequest,
) -> Result(String, String) {
  use first <- result.try(call(context, request))
  let original = compaction.estimate_inputs(request.evicted)
  case
    compaction.estimate_inputs([types.Assistant(first)])
    <= request.max_output_tokens
    && compaction.estimate_inputs([types.Assistant(first)]) < original
  {
    True -> Ok(first)
    False -> {
      use second <- result.map(call(
        context,
        compaction.SummaryRequest(
          ..request,
          max_output_tokens: int.max(32, request.max_output_tokens / 3),
        ),
      ))
      case
        compaction.estimate_inputs([types.Assistant(second)])
        <= request.max_output_tokens
        && compaction.estimate_inputs([types.Assistant(second)]) < original
      {
        True -> second
        False ->
          "I retain a source pointer; the generated memory exceeded its source. Expand the linked rows for details."
      }
    }
  }
}

fn prior(
  context: compaction.Context,
  policy: request_context.SummaryPolicy,
) -> Result(Option(n.Recall), String) {
  use node <- result.map(graph.latest_narrated(
    context.store,
    context.session,
    policy.lineage.subject,
  ))
  case node {
    None -> None
    Some(node) -> {
      let memory = n.Recall(narration.cue(node, context.session), node.summary)
      case
        compaction.estimate_inputs([
          types.User(memory.cue),
          types.Assistant(memory.text),
        ])
        <= 1024
      {
        True -> Some(memory)
        False -> None
      }
    }
  }
}

fn with_optional_prior(
  request: compaction.SummaryRequest,
  previous: Option(n.Recall),
) -> compaction.SummaryRequest {
  let assert Some(formation) = request.formation
  let candidate =
    compaction.SummaryRequest(
      ..request,
      formation: Some(n.Formation(..formation, previous:)),
    )
  case cost(candidate) {
    Ok(cost) if cost + 64 < formation.budget -> candidate
    _ -> request
  }
}

pub fn leaves(
  context: compaction.Context,
  eligible: List(transcript.SourcedEntry),
  limit: Int,
  policy: request_context.SummaryPolicy,
) -> Result(List(graph.Leaf), String) {
  let allowance = budget(context)
  use previous <- result.try(prior(context, policy))
  let units =
    compaction.split_starts(eligible, fn(row) {
      compaction.is_user(row.entry.input)
    })
  // Group only whole ordinary units. Oversized units go through reading, never
  // the generic per-message cutoff. Final requests are measured exactly.
  let overhead =
    compaction.estimate_pinned(policy.instructions, []) + limit + 2400
  let chunks =
    rolling.chunk_units(
      list.map(units, fn(unit) {
        #(
          unit,
          compaction.estimate_inputs(
            list.map(unit, fn(row) { row.entry.input }),
          ),
        )
      }),
      int.max(1, budget(context) - overhead),
    )
  use #(leaves, _) <- result.map(
    list.try_fold(chunks, #([], previous), fn(acc, rows) {
      let frame = source_frame(context, rows, policy)
      let assert [first, ..] = rows
      let assert Ok(last) = list.last(rows)
      let inputs = list.map(rows, fn(row) { row.entry.input })
      let mode = case frame.perspective {
        n.Witnessed -> "witnessed"
        _ -> "experienced"
      }
      let evidence =
        compaction.Leaves(
          context.session,
          [#(first.source.seq, last.source.seq)],
          Some(policy.lineage),
          attributions(frame),
        )
      let base =
        request(
          context,
          policy,
          frame,
          mode,
          inputs,
          [],
          None,
          evidence,
          limit,
          False,
        )
      let candidate = with_optional_prior(base, acc.1)
      use text <- result.try(case cost(candidate) {
        Ok(cost) if cost <= allowance -> bounded(context, candidate)
        _ -> reading_unit(context, rows, frame, policy, acc.1, limit)
      })
      let frame = case cost(candidate) {
        Ok(cost) if cost <= allowance -> frame
        _ -> n.Frame(..frame, perspective: n.Reading)
      }
      let leaf =
        graph.Leaf(first.source.seq, last.source.seq, text, Some(frame))
      let next =
        n.Recall(
          "[preceding successfully formed memory; not yet committed; source rows "
            <> int.to_string(first.source.seq)
            <> ".."
            <> int.to_string(last.source.seq)
            <> "]",
          text,
        )
      Ok(#([leaf, ..acc.0], Some(next)))
    }),
  )
  list.reverse(leaves)
}

fn text(input: types.Input) -> String {
  case narration.text_input(input) {
    types.User(value) | types.Assistant(value) -> value
    _ -> ""
  }
}

fn reading_unit(
  context: compaction.Context,
  rows: List(transcript.SourcedEntry),
  frame: n.Frame,
  policy: request_context.SummaryPolicy,
  previous: Option(n.Recall),
  limit: Int,
) -> Result(String, String) {
  use #(reflections, _) <- result.try(
    list.try_fold(rows, #([], previous), fn(acc, row) {
      let source_text = text(row.entry.input)
      let total = string.byte_size(source_text)
      let row_frame =
        n.Frame(
          ..frame,
          perspective: n.Reading,
          sources: list.filter(frame.sources, fn(source) {
            source.seq == row.source.seq
          }),
        )
      let evidence =
        compaction.Leaves(
          context.session,
          [#(row.source.seq, row.source.seq)],
          Some(policy.lineage),
          attributions(row_frame),
        )
      let base =
        request(
          context,
          policy,
          row_frame,
          "reading",
          [],
          [n.Portion(row.source.session, row.source.seq, 0, 0, total)],
          None,
          evidence,
          limit,
          False,
        )
      let candidate = with_optional_prior(base, acc.1)
      use overhead <- result.try(cost(candidate))
      let allowance = { budget(context) - overhead - 1152 } * 4
      use _ <- result.try(compaction.require(
        allowance >= 4,
        "LCM reading identity/cue/prior/output leaves no source allowance",
      ))
      let slices = split_text(source_text, allowance, 0, [])
      use #(made, last) <- result.map(
        list.try_fold(slices, #(acc.0, acc.1), fn(acc, slice) {
          let portion =
            n.Portion(
              row.source.session,
              row.source.seq,
              slice.0,
              slice.1,
              total,
            )
          let input = case row.entry.input {
            types.Assistant(_) | types.Replay(_) -> types.Assistant(slice.2)
            _ -> types.User(slice.2)
          }
          let call_request =
            request(
              context,
              policy,
              row_frame,
              "reading",
              [input],
              [portion],
              acc.1,
              evidence,
              limit,
              False,
            )
          use summary <- result.map(bounded(context, call_request))
          let recall =
            n.Recall(
              "[preceding reading-portion reflection; source "
                <> row.source.session
                <> ":"
                <> int.to_string(row.source.seq)
                <> "; bytes "
                <> int.to_string(slice.0)
                <> ".."
                <> int.to_string(slice.1)
                <> "; prior context only]",
              summary,
            )
          #([Reflection(Some(summary), [portion]), ..acc.0], Some(recall))
        }),
      )
      let made = case slices {
        [] -> [
          Reflection(None, [
            n.Portion(row.source.session, row.source.seq, 0, 0, 0),
          ]),
          ..made
        ]
        _ -> made
      }
      #(made, last)
    }),
  )
  consolidate_reflections(
    context,
    policy,
    n.Frame(..frame, perspective: n.Reading),
    list.reverse(reflections),
    limit,
  )
}

fn split_text(
  value: String,
  allowance: Int,
  offset: Int,
  acc: List(#(Int, Int, String)),
) -> List(#(Int, Int, String)) {
  case value {
    "" -> list.reverse(acc)
    _ -> {
      let prefix = domain.prefix(value, allowance)
      let size = string.byte_size(prefix)
      let assert <<_:bytes-size(size), rest:bytes>> = <<value:utf8>>
      let assert Ok(rest) = bit_array.to_string(rest)
      split_text(rest, allowance, offset + size, [
        #(offset, offset + size, prefix),
        ..acc
      ])
    }
  }
}

fn compact_portions(portions: List(n.Portion)) -> List(n.Portion) {
  list.fold(portions, [], fn(acc: List(n.Portion), portion) {
    case acc {
      [last, ..rest]
        if last.session == portion.session
        && last.seq == portion.seq
        && last.end == portion.start
      -> [n.Portion(..last, end: portion.end), ..rest]
      _ -> [portion, ..acc]
    }
  })
  |> list.reverse
}

fn reflection_inputs(items: List(Reflection)) -> List(types.Input) {
  list.flat_map(items, fn(item) {
    case item.text {
      None -> [
        types.User(
          "[actual source row has no visible text; zero-byte coverage, no generated reading reflection]",
        ),
      ]
      Some(text) -> [
        types.User(
          "[reading reflection; exact supplied portion coverage follows in narration evidence]",
        ),
        types.Assistant(text),
      ]
    }
  })
}

fn reflection_request(
  context: compaction.Context,
  policy: request_context.SummaryPolicy,
  frame: n.Frame,
  items: List(Reflection),
  limit: Int,
) -> compaction.SummaryRequest {
  let portions =
    list.flat_map(items, fn(item) { item.portions }) |> compact_portions
  let ranges = n.coverage_ranges(frame, portions)
  request(
    context,
    policy,
    frame,
    "consolidation",
    reflection_inputs(items),
    portions,
    None,
    compaction.Leaves(
      context.session,
      ranges,
      Some(policy.lineage),
      attributions(frame),
    ),
    limit,
    True,
  )
}

fn consolidate_reflections(
  context: compaction.Context,
  policy: request_context.SummaryPolicy,
  frame: n.Frame,
  items: List(Reflection),
  limit: Int,
) -> Result(String, String) {
  let candidate = reflection_request(context, policy, frame, items, limit)
  let fits = case cost(candidate) {
    Ok(estimate) -> estimate <= budget(context)
    Error(_) -> False
  }
  case fits {
    True -> bounded(context, candidate)
    False -> {
      use groups <- result.try(
        reflection_groups(context, policy, frame, items, limit, [], []),
      )
      use _ <- result.try(compaction.require(
        list.length(groups) < list.length(items),
        "LCM reading consolidation cannot fit two reflections",
      ))
      use folded <- result.try(
        list.try_map(groups, fn(group) {
          let candidate =
            reflection_request(context, policy, frame, group, limit)
          use text <- result.map(bounded(context, candidate))
          Reflection(
            Some(text),
            list.flat_map(group, fn(item) { item.portions }) |> compact_portions,
          )
        }),
      )
      consolidate_reflections(context, policy, frame, folded, limit)
    }
  }
}

fn reflection_groups(
  context: compaction.Context,
  policy: request_context.SummaryPolicy,
  frame: n.Frame,
  rest: List(Reflection),
  limit: Int,
  current: List(Reflection),
  acc: List(List(Reflection)),
) -> Result(List(List(Reflection)), String) {
  case rest {
    [] ->
      Ok(
        list.reverse(case current {
          [] -> acc
          _ -> [list.reverse(current), ..acc]
        }),
      )
    [item, ..rest] -> {
      let candidate =
        reflection_request(
          context,
          policy,
          frame,
          list.reverse([item, ..current]),
          limit,
        )
      let fits = case cost(candidate) {
        Ok(estimate) -> estimate <= budget(context)
        Error(_) -> False
      }
      case fits, current {
        True, _ ->
          reflection_groups(
            context,
            policy,
            frame,
            rest,
            limit,
            [item, ..current],
            acc,
          )
        False, [] ->
          Error("LCM single reading reflection exceeds consolidation allowance")
        False, _ ->
          reflection_groups(context, policy, frame, [item, ..rest], limit, [], [
            list.reverse(current),
            ..acc
          ])
      }
    }
  }
}

pub fn parent(
  context: compaction.Context,
  children: List(graph.Node),
  limit: Int,
  policy: request_context.SummaryPolicy,
) -> Result(#(String, Option(n.Frame)), String) {
  let frame = narration.parent_frame(children, context.session)
  let evidence =
    compaction.Nodes(
      context.session,
      list.map(children, fn(node) { #(node.id, node.first_seq, node.last_seq) }),
      Some(policy.lineage),
      [],
    )
  let direct =
    list.flat_map(children, narration.render_scoped(
      _,
      context.session,
      Some(policy.lineage.subject),
    ))
  use deeper <- result.try(deeper_inputs(context, children, budget(context)))
  let expanded =
    request(
      context,
      policy,
      frame,
      "consolidation",
      deeper,
      [],
      None,
      evidence,
      limit,
      False,
    )
  let fallback =
    request(
      context,
      policy,
      frame,
      "consolidation",
      direct,
      [],
      None,
      evidence,
      limit,
      True,
    )
  let allowance = budget(context)
  let selected = case cost(expanded), deeper {
    Ok(estimate), [_, ..] if estimate <= allowance -> expanded
    _, _ -> fallback
  }
  use summary <- result.map(bounded(context, selected))
  #(summary, Some(frame))
}

fn deeper_inputs(
  context: compaction.Context,
  children: List(graph.Node),
  allowance: Int,
) -> Result(List(types.Input), String) {
  use snapshot <- result.try(conversation.snapshot(
    context.store,
    context.session,
  ))
  use #(inputs, total) <- result.try(
    list.try_fold(children, #([], 0), fn(acc, node) {
      case acc.1 > allowance {
        True -> Ok(acc)
        False -> {
          use next <- result.try(case node.depth {
            0 ->
              conversation.fold_sources(
                context.store,
                snapshot,
                node.first_seq,
                node.last_seq,
                #([], acc.1),
                fn(acc, row) {
                  let cue = deeper_source_cue(node, row)
                  let tokens =
                    acc.1
                    + compaction.estimate_inputs([
                      types.User(cue),
                      narration.text_input(row.entry.input),
                    ])
                  case tokens > allowance {
                    True -> conversation.Stop(#([], tokens))
                    False ->
                      conversation.Continue(#(
                        [row.entry.input, types.User(cue), ..acc.0],
                        tokens,
                      ))
                  }
                },
              )
              |> result.map(fn(value) { #(list.reverse(value.0), value.1) })
            _ -> {
              use ids <- result.try(graph.children(context.store, node.id))
              use nodes <- result.try(
                list.try_map(ids, fn(id) {
                  use node <- result.try(graph.node(
                    context.store,
                    context.session,
                    id,
                  ))
                  option.to_result(node, "LCM deeper child disappeared")
                }),
              )
              let inputs =
                list.flat_map(nodes, narration.render_scoped(
                  _,
                  context.session,
                  option.map(context.summary_policy, fn(policy) {
                    policy.lineage.subject
                  }),
                ))
              Ok(#(inputs, acc.1 + compaction.estimate_inputs(inputs)))
            }
          })
          Ok(#(list.append(acc.0, next.0), next.1))
        }
      }
    }),
  )
  case total <= allowance {
    True -> Ok(inputs)
    False -> Ok([])
  }
}

fn deeper_source_cue(node: graph.Node, row: transcript.SourcedEntry) -> String {
  let facts =
    option.map(node.frame, fn(frame) {
      list.find(frame.sources, fn(source) {
        source.seq == row.source.seq && source.session == row.source.session
      })
      |> option.from_result
    })
    |> option.flatten
  let attribution = case facts {
    Some(source) ->
      n.perspective(source.perspective)
      <> "; actor "
      <> source.actor
      <> "; original source "
      <> source.origin_session
      <> ":"
      <> int.to_string(source.origin_seq)
    None -> "unknown source attribution"
  }
  "[actually reread deeper source; session "
  <> row.source.session
  <> "; row "
  <> int.to_string(row.source.seq)
  <> "; "
  <> attribution
  <> "]"
}
