//// Native conservative estimator; projection arithmetic is preserved verbatim.

import albedo/openai_api/types
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/string

pub const estimator_version = 1

pub const renderer_version = 1

pub type CostProfile {
  CostProfile(
    provider: String,
    protocol: types.Protocol,
    model: String,
    image_limits: types.ImageLimits,
    subject: Option(String),
    identity: String,
  )
}

pub fn profile_id(profile: CostProfile) -> String {
  fingerprint(#(estimator_version, renderer_version, profile))
}

pub type CostEntryKey {
  CostEntryKey(
    profile_id: String,
    content_identity: String,
    affected_fit_revision: Int,
  )
}

@external(erlang, "albedo_compaction", "fingerprint")
pub fn fingerprint(value: a) -> String

fn estimate_text(text: String) -> Int {
  { string.byte_size(text) + 3 } / 4
}

pub fn input_bytes(input: types.Input) -> Int {
  case input {
    types.User(text) | types.Assistant(text) -> string.byte_size(text)
    types.UserImage(text, images) ->
      string.byte_size(text) + fold_cost(images, types.image_size)
    types.ToolOutput(id, output, images) ->
      string.byte_size(id)
      + string.byte_size(output)
      + fold_cost(images, types.image_size)
    types.Replay(item) -> types.replay_bytes(item)
  }
}

pub fn inputs_bytes(inputs: List(types.Input)) -> Int {
  fold_cost(inputs, input_bytes)
}

/// The total of `cost` over `items`.
fn fold_cost(items: List(a), cost: fn(a) -> Int) -> Int {
  list.fold(items, 0, fn(total, item) { total + cost(item) })
}

pub fn estimate_input(input: types.Input) -> Int {
  // Covers request framing, roles, and content-part keys without pretending
  // to be an exact provider tokenizer. Image payload bytes affect transport
  // size, not vision tokens, so image cost is estimated from dimensions.
  case input {
    types.UserImage(text, images) ->
      estimate_text(text)
      + fold_cost(images, fn(image) { estimate_image(image) + 20 })
    types.ToolOutput(id, output, [_, ..] as images) ->
      estimate_text(id <> output)
      + fold_cost(images, fn(image) { estimate_image(image) + 20 })
      + 12
    _ -> { input_bytes(input) + 3 } / 4 + 12
  }
}

fn estimate_image(image: types.Image) -> Int {
  let #(_, width, height, _) = types.image_meta(image)
  image_tokens(width, height)
}

/// Provider-neutral approximation based on 512px vision tiles. Providers may
/// tokenize images differently; this is only the compaction trigger signal.
pub fn image_tokens(width: Int, height: Int) -> Int {
  85 + 170 * ceiling_div(width, 512) * ceiling_div(height, 512)
}

fn ceiling_div(value: Int, divisor: Int) -> Int {
  { value + divisor - 1 } / divisor
}

pub fn estimate_inputs(inputs: List(types.Input)) -> Int {
  fold_cost(inputs, estimate_input)
}

fn estimate_tools(tools: List(types.Tool)) -> Int {
  fold_cost(tools, fn(tool) {
    estimate_text(tool.name)
    + estimate_text(tool.description)
    + estimate_text(json.to_string(tool.parameters))
    + 20
  })
}

pub fn estimate_pinned(instructions: String, tools: List(types.Tool)) -> Int {
  16 + estimate_text(instructions) + estimate_tools(tools)
}
