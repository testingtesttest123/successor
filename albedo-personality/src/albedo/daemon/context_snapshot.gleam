//// Bounded, read-only observations of an already prepared provider request.
//// This module never prepares history, invokes tools, or calls a provider.

import albedo/daemon/message_content as events
import albedo/daemon/usage
import albedo/harness/compaction as context_size
import albedo/harness/request_context
import albedo/openai_api/request as provider_request
import albedo/openai_api/types
import gleam/bit_array
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

const page_characters = 8000

const dynamic_page_bytes = 8192

const preview_characters = 180

type InspectionEntry {
  UserText(text: String)
  UserImageText(text: String, images: List(ImageMetadata))
  AssistantText(text: String)
  ToolResult(id: String, output: String, images: List(ImageMetadata))
  ReplayMarker
}

type ImageMetadata {
  ImageMetadata(mime: String, width: Int, height: Int, decoded_bytes: Int)
}

pub type SectionKind {
  Instructions
  History
  Tools
  Other
}

pub type Section {
  Section(
    id: String,
    label: String,
    kind: SectionKind,
    source: String,
    item_count: Int,
    byte_count: Int,
    /// Rendered only when an inspector asks. A snapshot is taken for every
    /// model step and kept by the session, so an eager render would copy the
    /// whole prepared history into a string that is almost never read.
    content: fn() -> String,
    omitted: Option(String),
    /// Dynamic domain sections use a UTF-8 byte cap; legacy history stays scalar-paged.
    page_bytes: Option(Int),
  )
}

pub type CompactionStatus {
  NotConfigured
  NotNeeded
  Compacted
  Unknown
}

pub type Compaction {
  Compaction(
    strategy: Option(String),
    status: CompactionStatus,
    source: Option(String),
    trigger_free_percent: Option(Int),
    input_limit_tokens: Option(Int),
    estimated_input_tokens: Option(Int),
    provider_input_tokens: Option(Int),
    provider_cached_input_tokens: Option(Int),
    estimate_method: Option(String),
    before_items: Option(Int),
    after_items: Option(Int),
  )
}

pub type Snapshot {
  Pending(reason: String)
  Ready(
    id: String,
    captured_at: Option(Int),
    provider: Option(String),
    model: String,
    protocol: Option(String),
    context_window_tokens: Option(Int),
    compaction: Compaction,
    sections: List(Section),
    retained_tool_calls: List(String),
    request_context: request_context.Prepared,
  )
}

fn section(
  id: String,
  label: String,
  kind: SectionKind,
  source: String,
  item_count: Int,
  byte_count: Int,
  content: String,
  omitted: Option(String),
) -> Section {
  lazy_section(
    id,
    label,
    kind,
    source,
    item_count,
    byte_count,
    fn() { content },
    omitted,
  )
}

fn lazy_section(
  id: String,
  label: String,
  kind: SectionKind,
  source: String,
  item_count: Int,
  byte_count: Int,
  content: fn() -> String,
  omitted: Option(String),
) -> Section {
  Section(
    id,
    label,
    kind,
    source,
    int.max(0, item_count),
    int.max(0, byte_count),
    content,
    omitted,
    None,
  )
}

fn compaction(
  strategy: Option(String),
  status: CompactionStatus,
  source: Option(String),
  trigger_free_percent: Option(Int),
  input_limit_tokens: Option(Int),
  estimated_input_tokens: Option(Int),
  estimate_method: Option(String),
  before_items: Option(Int),
  after_items: Option(Int),
) -> Compaction {
  Compaction(
    strategy,
    status,
    source,
    clamp_percent(trigger_free_percent),
    non_negative(input_limit_tokens),
    non_negative(estimated_input_tokens),
    None,
    None,
    estimate_method,
    non_negative(before_items),
    non_negative(after_items),
  )
}

/// Attach the completion's measured input usage to the request that produced it.
/// A newer prepared request starts without a measurement; missing provider usage
/// clears this request's measurement rather than reusing an older completion.
pub fn with_usage(snapshot: Snapshot, metadata: usage.Metadata) -> Snapshot {
  case snapshot {
    Ready(model: model, compaction: compaction, ..) if model == metadata.model -> {
      let #(input, cached) = case metadata.tokens {
        Some(usage.Tokens(
          prompt_tokens: prompt,
          cached_prompt_tokens: cached,
          ..,
        )) -> #(non_negative(Some(prompt)), non_negative(cached))
        None -> #(None, None)
      }
      Ready(
        ..snapshot,
        compaction: Compaction(
          ..compaction,
          provider_input_tokens: input,
          provider_cached_input_tokens: cached,
        ),
      )
    }
    _ -> snapshot
  }
}

/// The strategy's own token estimate for the prepared request, when it recorded one.
pub fn estimate(snapshot: Snapshot) -> Option(Int) {
  case snapshot {
    Pending(_) -> None
    Ready(compaction: compaction, ..) -> compaction.estimated_input_tokens
  }
}

pub fn pending(reason: String) -> Snapshot {
  Pending(reason)
}

fn ready(
  captured_at: Option(Int),
  provider: Option(String),
  model: String,
  protocol: Option(String),
  context_window_tokens: Option(Int),
  compaction: Compaction,
  sections: List(Section),
) -> Snapshot {
  Ready(
    new_identity(),
    non_negative(captured_at),
    provider,
    model,
    protocol,
    non_negative(context_window_tokens),
    compaction,
    sections,
    [],
    request_context.no_context(),
  )
}

/// Build a safe inspector view from the exact request value about to be sent.
/// The input order and byte counts remain exact. Image bodies and opaque
/// provider replay objects are represented without copying their payloads.
/// Identity belongs to the immutable prepared request, not to its UI pages.
pub fn identity(snapshot: Snapshot) -> Option(String) {
  case snapshot {
    Pending(_) -> None
    Ready(id: id, ..) -> Some(id)
  }
}

@external(erlang, "albedo_session", "new_generation")
fn new_identity() -> String

pub fn from_request(
  captured_at: Option(Int),
  provider: String,
  protocol_name: String,
  protocol: types.Protocol,
  request: types.Request,
  observation: Option(context_size.Observation),
) -> Snapshot {
  let calls =
    list.filter_map(request.input, fn(input) {
      case input {
        types.ToolOutput(id, _, _) -> Ok(id)
        _ -> Error(Nil)
      }
    })
  let sections =
    [
      instructions_section(request.instructions),
      history_section(request.input, observation),
      tools_section(protocol, request.tools),
    ]
    |> list.filter_map(option.to_result(_, Nil))
  case
    ready(
      captured_at,
      Some(provider),
      request.model,
      Some(protocol_name),
      observation_capacity(observation),
      observation_compaction(observation),
      sections,
    )
  {
    Ready(..) as snapshot -> Ready(..snapshot, retained_tool_calls: calls)
    pending -> pending
  }
}

/// Same immutable request, with dynamic section boundaries captured by its
/// preparation. No callback or ledger read occurs during inspection.
pub fn from_prepared(
  captured_at: Option(Int),
  provider: String,
  protocol_name: String,
  protocol: types.Protocol,
  request: types.Request,
  prepared: context_size.Prepared,
) -> Snapshot {
  let captured = prepared.request_context
  let dynamic_instructions =
    list.flat_map(captured.contributions, fn(contribution) {
      list.map(contribution.instructions, fn(block) {
        "\n\n" <> request_context.render(contribution.snapshot_id, block)
      })
    })
    |> string.concat
  let static =
    option.map(request.instructions, fn(instructions) {
      let bytes = <<instructions:utf8>>
      let size =
        string.byte_size(instructions) - string.byte_size(dynamic_instructions)
      let assert <<prefix:bytes-size(size), _:bytes>> = bytes
      bit_array.to_string(prefix) |> result.unwrap("")
    })
  let instructions =
    list.index_map(captured.contributions, fn(contribution, index) {
      list.index_map(contribution.instructions, fn(block, block_index) {
        dynamic_section(contribution, block, index, block_index, Instructions)
      })
    })
    |> list.flatten
  let data =
    list.index_map(captured.contributions, fn(contribution, index) {
      list.index_map(contribution.data, fn(block, block_index) {
        dynamic_section(contribution, block, index, block_index, Other)
      })
    })
    |> list.flatten
  let sections =
    list.flatten([
      [instructions_section(static)]
        |> list.filter_map(option.to_result(_, Nil)),
      instructions,
      data,
      [history_section(prepared.inputs, prepared.observation)]
        |> list.filter_map(option.to_result(_, Nil)),
      [tools_section(protocol, request.tools)]
        |> list.filter_map(option.to_result(_, Nil)),
      summary_sections(captured),
    ])
  case
    from_request(
      captured_at,
      provider,
      protocol_name,
      protocol,
      request,
      prepared.observation,
    )
  {
    Ready(..) as snapshot ->
      Ready(..snapshot, sections:, request_context: captured)
    pending -> pending
  }
}

/// A captured attempt is not proof of provider completion or ordinary-request
/// admission. Retain this view across later failure without rebuilding policy.
pub fn from_summaries(
  captured_at: Option(Int),
  provider: String,
  protocol_name: String,
  model: String,
  captured: request_context.Prepared,
) -> Snapshot {
  let snapshot =
    ready(
      captured_at,
      Some(provider),
      model,
      Some(protocol_name),
      None,
      compaction(
        None,
        Unknown,
        Some(
          "captured native summarizer attempts; ordinary request not admitted",
        ),
        None,
        None,
        None,
        None,
        None,
        None,
      ),
      summary_sections(captured),
    )
  let assert Ready(..) = snapshot
  Ready(..snapshot, request_context: captured)
}

fn summary_sections(captured: request_context.Prepared) -> List(Section) {
  list.index_map(captured.summary_calls, fn(call, index) {
    let content = call.instructions <> "\n\n" <> call.envelope
    Section(
      "summary-" <> int.to_string(index),
      "Captured summarizer instructions and evidence",
      Other,
      "captured native summarizer attempt",
      1,
      string.byte_size(content),
      fn() { content },
      None,
      Some(dynamic_page_bytes),
    )
  })
}

fn dynamic_section(
  contribution: request_context.Contribution,
  block: request_context.Block,
  index: Int,
  block_index: Int,
  kind: SectionKind,
) -> Section {
  let content = case kind {
    Instructions ->
      "\n\n" <> request_context.render(contribution.snapshot_id, block)
    _ -> request_context.render(contribution.snapshot_id, block)
  }
  let category = case kind {
    Instructions -> "instructions"
    _ -> "data"
  }
  Section(
    ..section(
      "request-context-"
        <> int.to_string(index)
        <> "-"
        <> category
        <> "-"
        <> int.to_string(block_index),
      block.name,
      kind,
      "immutable request context; snapshot " <> contribution.snapshot_id,
      1,
      string.byte_size(content),
      content,
      None,
    ),
    page_bytes: Some(dynamic_page_bytes),
  )
}

fn tools_section(
  protocol: types.Protocol,
  tools: List(types.Tool),
) -> Option(Section) {
  case tools {
    [] -> None
    tools -> {
      let content =
        provider_request.encode_tools(protocol, tools) |> json.to_string
      Some(section(
        "tools",
        "tool schemas",
        Tools,
        "enabled extension tool registry; exact provider encoding",
        list.length(tools),
        string.byte_size(content),
        content,
        None,
      ))
    }
  }
}

fn history_section(
  history: List(types.Input),
  observation: Option(context_size.Observation),
) -> Option(Section) {
  case history {
    [] -> None
    history -> {
      let item_count = list.length(history)
      // Replay items carry their JSON, so the exact byte count serializes
      // nothing; the inspection entries drop retained payloads.
      let byte_count = context_size.inputs_bytes(history)
      let omitted = input_omission(history)
      let entries = list.map(history, inspection_entry)
      Some(lazy_section(
        "history",
        "prepared conversation",
        History,
        history_source(observation),
        item_count,
        byte_count,
        fn() { render_entries(entries) },
        omitted,
      ))
    }
  }
}

fn instructions_section(instructions: Option(String)) -> Option(Section) {
  case instructions {
    None -> None
    Some(instructions) ->
      Some(section(
        "instructions",
        "system instructions",
        Instructions,
        "albedo core + enabled extension instructions",
        1,
        string.byte_size(instructions),
        instructions,
        None,
      ))
  }
}

/// Tool calls in the exact prepared request, not in the durable history.
pub fn retained_tool_calls(snapshot: Snapshot) -> Option(List(String)) {
  case snapshot {
    Pending(_) -> None
    Ready(retained_tool_calls: calls, ..) -> Some(calls)
  }
}

fn inspection_entry(input: types.Input) -> InspectionEntry {
  case input {
    types.User(text) -> UserText(text)
    types.UserImage(text, images) ->
      UserImageText(text, list.map(images, image_metadata))
    types.Assistant(text) -> AssistantText(text)
    types.ToolOutput(id, output, images) ->
      ToolResult(id, output, list.map(images, image_metadata))
    types.Replay(_) -> ReplayMarker
  }
}

fn image_metadata(image: types.Image) -> ImageMetadata {
  let #(mime, width, height, bytes) = types.image_meta(image)
  ImageMetadata(mime, width, height, bytes)
}

fn render_entries(entries: List(InspectionEntry)) -> String {
  entries
  |> list.map(render_entry)
  |> string.join(
    "

",
  )
}

fn render_entry(entry: InspectionEntry) -> String {
  case entry {
    UserText(text) -> "[user]
" <> text
    UserImageText(text, images) -> "[user]
" <> text <> string.concat(
        list.map(images, fn(image) { "\n" <> image_label(image) }),
      )
    AssistantText(text) -> "[assistant]
" <> text
    ToolResult(id, output, images) -> "[tool output · " <> id <> "]
" <> output <> string.concat(
        list.map(images, fn(image) { "\n" <> image_label(image) }),
      )
    ReplayMarker -> "[provider replay item · opaque provider payload omitted]"
  }
}

fn image_label(image: ImageMetadata) -> String {
  let ImageMetadata(mime, width, height, bytes) = image
  "[image · "
  <> mime
  <> " · "
  <> int.to_string(width)
  <> "×"
  <> int.to_string(height)
  <> " · "
  <> int.to_string(bytes)
  <> " decoded bytes · payload omitted]"
}

fn input_omission(inputs: List(types.Input)) -> Option(String) {
  let reasons =
    inputs
    |> list.flat_map(fn(input) {
      case input {
        types.UserImage(_, _) | types.ToolOutput(_, _, [_, ..]) -> [
          "image base64 payload",
        ]
        types.Replay(_) -> ["opaque provider replay payload"]
        _ -> []
      }
    })
  case reasons {
    [] -> None
    reasons -> Some(reasons |> list.unique |> string.join("; "))
  }
}

fn observation_capacity(
  observation: Option(context_size.Observation),
) -> Option(Int) {
  option.then(observation, fn(obs) { obs.input_limit_tokens })
}

fn observation_compaction(
  observation: Option(context_size.Observation),
) -> Compaction {
  case observation {
    None ->
      compaction(None, NotConfigured, None, None, None, None, None, None, None)
    Some(obs) ->
      compaction(
        case obs.strategy {
          "" -> None
          name -> Some(name)
        },
        case obs.status {
          "not_configured" -> NotConfigured
          "not_needed" -> NotNeeded
          "compacted" -> Compacted
          _ -> Unknown
        },
        Some(obs.source),
        obs.trigger_free_percent,
        obs.input_limit_tokens,
        obs.estimated_input_tokens,
        obs.estimate_method,
        obs.before_items,
        obs.after_items,
      )
  }
}

fn history_source(observation: Option(context_size.Observation)) -> String {
  case observation {
    Some(value) -> value.history_source
    None -> "durable transcript without a selected compaction strategy"
  }
}

/// Metadata and bounded previews only. Full inspectable text is returned by
/// `page`, one bounded page at a time.
pub fn summary(snapshot: Snapshot) -> json.Json {
  case snapshot {
    Pending(reason) ->
      json.object([
        #("state", json.string("pending")),
        #("reason", json.string(reason)),
      ])
    Ready(
      id,
      captured_at,
      provider,
      model,
      protocol,
      context_window_tokens,
      compacted,
      sections,
      _,
      captured,
    ) ->
      // Optional detail fields lead the wire order; absent ones are omitted.
      json.object(
        list.flatten([
          events.opt("context_window_tokens", context_window_tokens, json.int),
          events.opt("protocol", protocol, json.string),
          events.opt("provider", provider, json.string),
          events.opt("captured_at", captured_at, json.int),
          [
            #("state", json.string("ready")),
            #("snapshot_id", json.string(id)),
            #("model", json.string(model)),
            #("compaction", compaction_json(compacted)),
            #("sections", json.array(sections, section_json)),
            #("request_context", request_context_json(captured)),
            #(
              "summary_calls",
              json.array(
                list.index_map(captured.summary_calls, fn(call, index) {
                  json.object([
                    #(
                      "section_id",
                      json.string("summary-" <> int.to_string(index)),
                    ),
                    #("status", json.string("attempted")),
                    #("max_output_tokens", json.int(call.max_output_tokens)),
                    #(
                      "evidence_bytes",
                      json.int(string.byte_size(call.envelope)),
                    ),
                    #(
                      "instruction_bytes",
                      json.int(string.byte_size(call.instructions)),
                    ),
                  ])
                }),
                fn(value) { value },
              ),
            ),
            #("summary_calls_omitted", json.int(captured.summary_calls_omitted)),
          ],
        ]),
      )
  }
}

/// Metadata shared by the internal and public HTTP inspector encoders.
pub fn request_context_json(captured: request_context.Prepared) -> json.Json {
  json.array(captured.contributions, contribution_json)
}

fn contribution_json(contribution: request_context.Contribution) -> json.Json {
  let blocks = list.append(contribution.instructions, contribution.data)
  json.object([
    #("snapshot_id", json.string(contribution.snapshot_id)),
    #("instructions", json.array(contribution.instructions, block_json)),
    #("data", json.array(contribution.data, block_json)),
    #(
      "estimated_tokens",
      json.int(
        list.fold(blocks, 0, fn(total, block) { total + block.estimated_tokens }),
      ),
    ),
    #("candidate_count", json.int(contribution.candidate_count)),
    #("selected_count", json.int(list.length(contribution.selected_ids))),
    #("selected_ids", json.array(contribution.selected_ids, json.string)),
    #("excluded_count", json.int(contribution.excluded_count)),
    #("diagnostics", json.array(contribution.diagnostics, json.string)),
    #(
      "summary_policy",
      option.map(contribution.summary_policy, fn(policy) {
        json.object([
          #("id", json.string(policy.id)),
          #("revision", json.string(policy.revision)),
          #("identity_revision", json.int(policy.identity_revision)),
        ])
      })
        |> option.unwrap(json.null()),
    ),
  ])
}

fn block_json(block: request_context.Block) -> json.Json {
  json.object([
    #("name", json.string(block.name)),
    #("mandatory", json.bool(block.mandatory)),
    #("estimated_tokens", json.int(block.estimated_tokens)),
  ])
}

pub type SectionPage {
  SectionPage(
    snapshot_id: String,
    section_id: String,
    page: Int,
    page_count: Int,
    text: String,
    omitted: Option(String),
  )
}

/// Dynamic instruction/data pages are at most 8 KiB of rendered UTF-8 text.
/// Legacy history remains capped at 8,000 scalars / 32,000 UTF-8 bytes.
/// Both retain complete codepoints and exactly reconstruct the section.
pub fn page(
  snapshot: Snapshot,
  section_id: String,
  index: Int,
) -> Result(SectionPage, String) {
  case snapshot {
    Pending(_) -> Error("no request has been prepared")
    Ready(id: id, sections: sections, ..) -> {
      use section <- result.try(
        list.find(sections, fn(section) { section.id == section_id })
        |> result.replace_error("context section not found"),
      )
      let content = section.content()
      let pages = section_page_count(section, content)
      case index >= 0 && index < pages {
        False -> Error("context page not found")
        True ->
          Ok(SectionPage(
            id,
            section.id,
            index,
            pages,
            case section.page_bytes {
              Some(limit) -> byte_page(content, index, limit)
              None -> scalar_page(content, index, page_characters)
            },
            section.omitted,
          ))
      }
    }
  }
}

fn section_json(section: Section) -> json.Json {
  let content = section.content()
  json.object([
    #("id", json.string(section.id)),
    #("label", json.string(section.label)),
    #("kind", json.string(kind_name(section.kind))),
    #("source", json.string(section.source)),
    #("item_count", json.int(section.item_count)),
    #("byte_count", json.int(section.byte_count)),
    #("preview", json.string(preview(content))),
    #("pages", json.int(section_page_count(section, content))),
  ])
}

fn compaction_json(value: Compaction) -> json.Json {
  json.object(
    list.flatten([
      events.opt("after_items", value.after_items, json.int),
      events.opt("before_items", value.before_items, json.int),
      events.opt("estimate_method", value.estimate_method, json.string),
      events.opt(
        "provider_cached_input_tokens",
        value.provider_cached_input_tokens,
        json.int,
      ),
      events.opt("provider_input_tokens", value.provider_input_tokens, json.int),
      events.opt(
        "estimated_input_tokens",
        value.estimated_input_tokens,
        json.int,
      ),
      events.opt("input_limit_tokens", value.input_limit_tokens, json.int),
      events.opt("trigger_free_percent", value.trigger_free_percent, json.int),
      events.opt("source", value.source, json.string),
      events.opt("strategy", value.strategy, json.string),
      [#("status", json.string(status_name(value.status)))],
    ]),
  )
}

fn preview(content: String) -> String {
  let clean =
    content
    |> string.replace(
      "
",
      " ",
    )
    |> string.trim
  let prefix = scalar_page(clean, 0, preview_characters)
  case string.byte_size(prefix) < string.byte_size(clean) {
    True -> scalar_page(clean, 0, preview_characters - 1) <> "…"
    False -> prefix
  }
}

/// Page metadata uses the same bound as section reads. General callers retain
/// the legacy scalar page_count helper below.
pub fn section_page_count(section: Section, content: String) -> Int {
  case section.page_bytes {
    Some(limit) -> byte_page_count(content, limit)
    None -> page_count(content)
  }
}

@external(erlang, "albedo_context_snapshot", "byte_page_count")
fn byte_page_count(content: String, bytes_per_page: Int) -> Int

@external(erlang, "albedo_context_snapshot", "byte_page")
fn byte_page(content: String, index: Int, bytes_per_page: Int) -> String

pub fn page_count(content: String) -> Int {
  scalar_page_count(content, page_characters)
}

@external(erlang, "albedo_context_snapshot", "page_count")
fn scalar_page_count(content: String, scalars_per_page: Int) -> Int

@external(erlang, "albedo_context_snapshot", "page")
fn scalar_page(content: String, index: Int, scalars_per_page: Int) -> String

fn kind_name(kind: SectionKind) -> String {
  case kind {
    Instructions -> "instructions"
    History -> "history"
    Tools -> "tools"
    Other -> "other"
  }
}

fn status_name(status: CompactionStatus) -> String {
  case status {
    NotConfigured -> "not_configured"
    NotNeeded -> "not_needed"
    Compacted -> "compacted"
    Unknown -> "unknown"
  }
}

fn non_negative(value: Option(Int)) -> Option(Int) {
  case value {
    Some(value) if value >= 0 -> Some(value)
    _ -> None
  }
}

fn clamp_percent(value: Option(Int)) -> Option(Int) {
  case non_negative(value) {
    Some(value) if value <= 100 -> Some(value)
    _ -> None
  }
}
