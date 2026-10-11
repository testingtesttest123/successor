//// Narration transforms captured native evidence into actual participant inputs.
//// Persisted frame values are owned separately to keep the graph acyclic.

import albedo/harness/compaction
import albedo/harness/extensions/lcm/graph
import albedo/harness/extensions/lcm/narration_types as n
import albedo/openai_api/types
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub fn cue(node: graph.Node, session: String) -> String {
  n.recall_cue(session, node.id, node.first_seq, node.last_seq, node.frame)
}

pub fn render(
  node: graph.Node,
  current_subject: Option(String),
) -> List(types.Input) {
  render_scoped(node, "current", current_subject)
}

pub fn render_scoped(
  node: graph.Node,
  session: String,
  current_subject: Option(String),
) -> List(types.Input) {
  n.recall_inputs(
    session,
    node.id,
    node.first_seq,
    node.last_seq,
    node.summary,
    node.frame,
    current_subject,
  )
}

/// Native summary calls are tool-free. Replay text/call descriptions remain
/// assistant source material; tool results become labeled source evidence,
/// avoiding provider-specific or orphan tool-call objects on either protocol.
pub fn text_input(input: types.Input) -> types.Input {
  case input {
    types.User(text) -> types.User(text)
    types.Assistant(text) -> types.Assistant(text)
    types.UserImage(text, images) ->
      types.User(
        text
        <> "\n["
        <> int.to_string(list.length(images))
        <> " source images; binary omitted]",
      )
    types.ToolOutput(id, text, _) ->
      types.User("[tool source output " <> id <> "]\n" <> text)
    types.Replay(item) -> {
      let text = case compaction.assistant_parts(item) {
        Ok(#(text, calls)) ->
          text
          <> string.concat(
            list.map(calls, fn(call) {
              "\n[assistant source call "
              <> call.name
              <> "]\n"
              <> call.arguments
            }),
          )
        Error(_) ->
          "[assistant source item]\n" <> json.to_string(types.replay_json(item))
      }
      types.Assistant(text)
    }
  }
}

pub fn source_role(input: types.Input) -> String {
  case input {
    types.User(_) | types.UserImage(_, _) -> "user"
    types.Assistant(_) | types.Replay(_) -> "assistant"
    types.ToolOutput(_, _, _) -> "tool"
  }
}

pub fn summary_inputs(
  request: compaction.SummaryRequest,
) -> Result(List(types.Input), String) {
  use envelope <- result.try(compaction.summary_envelope(request))
  let previous = case request.formation {
    Some(n.Formation(previous: Some(memory), ..)) -> [
      types.User(memory.cue),
      types.Assistant(memory.text),
    ]
    _ ->
      case request.previous {
        Some(text) -> [
          types.User(
            "[previous generated memory; prior context only, outside this slice]",
          ),
          types.Assistant(text),
        ]
        None -> []
      }
  }
  let mode = case request.formation {
    Some(value) -> value.mode
    _ -> "experienced or witnessed according to trusted source facts"
  }
  let cue =
    types.User(
      "[memory formation notification; "
      <> mode
      <> "; preserve source participant roles and concrete events. Source authors' first person is their own. No tools or external actions.]\n"
      <> envelope,
    )
  Ok(list.append(
    [cue, ..previous],
    list.map(compaction.without_superseded(request.evicted), text_input),
  ))
}

pub fn instruction(mode: String) -> String {
  case mode {
    "reading" ->
      "Reflect in your own voice as the reader of this portion. Attribute the author's first-person claims to that author. Preserve concrete claims, names, corrections, and unresolved questions. Later portions have not yet been read. Return only this portion's reflection."
    "consolidation" ->
      "Consolidate ALL supplied memories and actually supplied deeper sources chronologically. Preserve concrete events, decisions, corrections, open asks and the immutable narrator/source perspectives. First person describes your recollection or reading; never appropriate another participant's acts. Do not claim raw sources were read when source_only is true. Return only the consolidated memory."
    "witnessed" ->
      "Form a memory of this inherited log. Events belong to the recorded participants before your arrival. First person describes reading and carrying their record. Preserve concrete names, decisions, corrections and open questions. Return only the memory."
    _ ->
      "Form an autobiographical memory of exactly this slice. Preserve concrete events, names, decisions, active asks, corrections and unresolved questions. Distinguish witnessed/unknown source facts from your own experienced actions; do not repeat prior memories as new events. Return only the memory."
  }
}

pub fn child(node: graph.Node, session: String) -> n.Child {
  n.Child(
    session,
    node.id,
    node.first_seq,
    node.last_seq,
    option.then(node.frame, fn(frame) { frame.narrator }),
    option.map(node.frame, fn(frame) { frame.perspective })
      |> option.unwrap(n.Unknown),
  )
}

pub fn parent_frame(children: List(graph.Node), session: String) -> n.Frame {
  let facts = list.map(children, child(_, session))
  let subjects =
    list.map(facts, fn(child) {
      option.map(child.narrator, fn(who) { who.subject })
    })
  let narrator = case list.unique(subjects) {
    [Some(_)] ->
      list.last(facts)
      |> result.map(fn(child) { child.narrator })
      |> result.unwrap(None)
    _ -> None
  }
  n.Frame(
    narrator,
    n.combine(list.map(facts, fn(child) { child.perspective })),
    [],
    facts,
  )
}
