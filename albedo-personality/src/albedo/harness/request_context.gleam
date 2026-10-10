//// Generic read-only request preparation values. No provider or mutation handle.

import albedo/daemon/store
import albedo/harness/protect
import albedo/openai_api/types
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Budget {
  Budget(
    capacity_tokens: Option(Int),
    capacity_source: Option(String),
    static_tokens: Int,
    remaining_tokens: Option(Int),
  )
}

pub type Input {
  Input(
    store: store.Store,
    session: String,
    loaded: List(String),
    query: String,
    budget: Budget,
  )
}

pub type Block {
  Block(name: String, content: String, mandatory: Bool, estimated_tokens: Int)
}

pub type SourceGrant {
  SourceGrant(session: String, first_seq: Int, last_seq: Int, digest: String)
}

pub type Lineage {
  Lineage(
    subject: String,
    binding_revision: Int,
    role: String,
    supplied_through: Int,
    context_id: Option(String),
    grants: List(SourceGrant),
  )
}

pub type SummaryPolicy {
  SummaryPolicy(
    id: String,
    revision: String,
    instructions: String,
    lineage: Lineage,
  )
}

pub type Contribution {
  Contribution(
    snapshot_id: String,
    instructions: List(Block),
    data: List(Block),
    summary_policy: Option(SummaryPolicy),
    diagnostics: List(String),
    selected_ids: List(String),
    candidate_count: Int,
    excluded_count: Int,
  )
}

pub type Prepared {
  Prepared(contributions: List(Contribution), estimated_tokens: Int)
}

pub fn empty(snapshot_id: String) -> Contribution {
  Contribution(snapshot_id, [], [], None, [], [], 0, 0)
}

/// Default for every history-only strategy constructor.
pub fn no_context() -> Prepared {
  Prepared([], 0)
}

/// The recent user/steering excerpt. UTF-8 codepoints are retained whole;
/// callback code never receives more than 4 KiB or the complete transcript.
pub fn query(history: List(types.Input)) -> String {
  history
  |> list.reverse
  |> list.find_map(fn(input) {
    case input {
      types.User(text) | types.UserImage(text, _) -> Ok(text)
      _ -> Error(Nil)
    }
  })
  |> result.unwrap("")
  |> fn(text) { prefix_bytes(<<text:utf8>>, 4096) }
}

fn prefix_bytes(bytes: BitArray, allowance: Int) -> String {
  let size = bounded_size(bytes, allowance, 0)
  let assert <<prefix:bytes-size(size), _:bytes>> = bytes
  bit_array.to_string(prefix) |> result.unwrap("")
}

fn bounded_size(bytes: BitArray, allowance: Int, used: Int) -> Int {
  case bytes {
    <<point:utf8_codepoint, rest:bytes>> -> {
      let size = bit_array.byte_size(<<point:utf8_codepoint>>)
      case size <= allowance {
        True -> bounded_size(rest, allowance - size, used + size)
        False -> used
      }
    }
    _ -> used
  }
}

/// The exact wrapper sent to a provider and shown by the inspector. Snapshot
/// identity is content, so prefix hashes account for metadata as well as text.
pub fn render(snapshot_id: String, block: Block) -> String {
  "[request context: "
  <> block.name
  <> "; snapshot "
  <> snapshot_id
  <> "]\n"
  <> block.content
}

/// One invocation per loaded callback. All captured values are retained; no
/// assembly, inspection, retry or strategy rereads a callback later.
pub fn prepare(
  callbacks: List(fn(Input) -> Result(Contribution, String)),
  input: Input,
) -> Result(Prepared, String) {
  use contributions <- result.try(
    list.try_map(callbacks, fn(callback) {
      protect.guarded(fn() { callback(input) })
    }),
  )
  let policies =
    list.filter_map(contributions, fn(contribution) {
      option.to_result(contribution.summary_policy, Nil)
    })
  use _ <- result.try(case list.length(policies) > 1 {
    True -> Error("conflicting request-context summary policies")
    False -> Ok(Nil)
  })
  let captured =
    list.map(contributions, fn(contribution) {
      let instructions =
        list.map(contribution.instructions, fn(block) {
          Block(
            ..block,
            estimated_tokens: text_tokens(
                "\n\n" <> render(contribution.snapshot_id, block),
              )
              + 1,
          )
        })
      let data =
        list.map(contribution.data, fn(block) {
          Block(
            ..block,
            estimated_tokens: text_tokens(render(
                contribution.snapshot_id,
                block,
              ))
              + 12,
          )
        })
      let diagnostics = case input.budget.capacity_tokens, instructions, data {
        None, [], [] -> contribution.diagnostics
        None, _, _ ->
          list.append(contribution.diagnostics, [
            "context window unknown; byte-based estimate is uncertain",
          ])
        _, _, _ -> contribution.diagnostics
      }
      Contribution(..contribution, instructions:, data:, diagnostics:)
    })
  let blocks =
    list.flat_map(captured, fn(contribution) {
      list.append(contribution.instructions, contribution.data)
    })
  let total =
    list.fold(blocks, 0, fn(total, block) { total + block.estimated_tokens })
  let mandatory =
    list.filter(blocks, fn(block) { block.mandatory })
    |> list.fold(0, fn(total, block) { total + block.estimated_tokens })
  use _ <- result.try(case input.budget.remaining_tokens {
    Some(remaining) if mandatory > 0 && mandatory >= remaining ->
      Error("mandatory request context cannot fit the known context window")
    Some(remaining) if total > 0 && total >= remaining ->
      Error(
        "request context exceeds remaining allowance; omit whole optional blocks",
      )
    _ -> Ok(Nil)
  })
  Ok(Prepared(captured, total))
}

fn text_tokens(text: String) -> Int {
  { string.byte_size(text) + 3 } / 4
}

/// Compose only at the final request boundary, after static pin settlement.
/// Dynamic data is never handed to a strategy as raw history.
pub fn assemble(request: types.Request, prepared: Prepared) -> types.Request {
  let suffix =
    list.flat_map(prepared.contributions, fn(contribution) {
      list.map(contribution.instructions, fn(block) {
        "\n\n" <> render(contribution.snapshot_id, block)
      })
    })
    |> string.concat
  let data =
    list.flat_map(prepared.contributions, fn(contribution) {
      list.map(contribution.data, fn(block) {
        types.User(render(contribution.snapshot_id, block))
      })
    })
  types.Request(
    ..request,
    instructions: case suffix {
      "" -> request.instructions
      _ -> Some(option.unwrap(request.instructions, "") <> suffix)
    },
    input: list.append(data, request.input),
  )
}
