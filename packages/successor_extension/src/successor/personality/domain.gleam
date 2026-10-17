//// Per-document bounds and ordinary substring editing. No claim policy.

import gleam/bit_array
import gleam/crypto
import gleam/int
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import successor/personality/types as p

pub const document_limit = 1_048_576

pub const read_limit = 32_768

// JSON can encode one stored byte as six ASCII bytes; allow two edit strings.
pub const body_limit = 12_648_448

pub fn validate_document(content: String) -> Result(Nil, p.DomainError) {
  case string.byte_size(content) <= document_limit {
    True -> Ok(Nil)
    False -> Error(p.Invalid("document exceeds 1 MiB UTF-8 write limit"))
  }
}

pub fn actor_name(actor: p.Actor) -> String {
  case actor {
    p.User(_) -> "user"
    p.OwnerAgent(_) -> "owner_agent"
  }
}

pub fn call_id(actor: p.Actor) -> String {
  case actor {
    p.User(key) -> "human:" <> key
    p.OwnerAgent(key) -> key
  }
}

pub fn hash(content: String) -> String {
  crypto.hash(crypto.Sha256, <<content:utf8>>)
  |> bit_array.base16_encode
  |> string.lowercase
}

pub fn edit(
  document: String,
  old_string: String,
  new_string: String,
  replace_all: Bool,
) -> Result(String, p.DomainError) {
  use _ <- result.try(case old_string == "" {
    True -> Error(p.Invalid("old_string must be nonempty"))
    False -> Ok(Nil)
  })
  let matches = match_count(document, old_string, 0)
  use _ <- result.try(case matches {
    0 -> Error(p.Conflict("old_string not found"))
    1 -> Ok(Nil)
    _ if replace_all -> Ok(Nil)
    _ ->
      Error(p.Conflict(
        "old_string is ambiguous; supply more context or replace_all",
      ))
  })
  // Non-overlapping matches remove at most the input's byte size, so this
  // product cannot overflow. Divide the remaining allowance before multiplying
  // replacement bytes: permitted arguments must never allocate their product.
  let retained =
    string.byte_size(document) - matches * string.byte_size(old_string)
  let allowance = document_limit - retained
  use _ <- result.try(
    case allowance >= 0 && string.byte_size(new_string) <= allowance / matches {
      True -> Ok(Nil)
      False -> Error(p.Invalid("document exceeds 1 MiB UTF-8 write limit"))
    },
  )
  let edited = string.replace(document, old_string, new_string)
  use _ <- result.map(validate_document(edited))
  edited
}

// Advance past each literal match without retaining a whole list of fragments.
fn match_count(document: String, old_string: String, count: Int) -> Int {
  case string.split_once(document, old_string) {
    Ok(#(_, rest)) -> match_count(rest, old_string, count + 1)
    Error(_) -> count
  }
}

/// Copy a whole-codepoint UTF-8 prefix without a whole-document scalar list.
pub fn prefix(content: String, limit: Int) -> String {
  let bytes = <<content:utf8>>
  let size = bounded(bytes, int.max(0, limit), 0)
  let assert <<text:bytes-size(size), _:bytes>> = bytes
  copied_text(text)
}

fn bounded(bytes: BitArray, allowance: Int, used: Int) -> Int {
  case bytes {
    <<point:utf8_codepoint, rest:bytes>> -> {
      let size = bit_array.byte_size(<<point:utf8_codepoint>>)
      case size <= allowance {
        True -> bounded(rest, allowance - size, used + size)
        False -> used
      }
    }
    _ -> used
  }
}

@external(erlang, "binary", "copy")
fn copied_text(bytes: BitArray) -> String

pub fn page(
  document: String,
  revision: Int,
  offset: Int,
  limit: Int,
) -> Result(p.DocumentPage, p.DomainError) {
  use _ <- result.try(
    case
      offset >= 0
      && offset <= string.byte_size(document)
      && limit > 0
      && limit <= read_limit
    {
      True -> Ok(Nil)
      False -> Error(p.Invalid("offset or page limit outside document bounds"))
    },
  )
  let assert <<_:bytes-size(offset), rest:bytes>> = <<document:utf8>>
  use rest <- result.try(
    bit_array.to_string(rest)
    |> result.replace_error(p.Invalid(
      "offset must be a UTF-8 codepoint boundary",
    )),
  )
  let text = prefix(rest, limit)
  use _ <- result.try(case rest != "" && text == "" {
    True -> Error(p.Invalid("page limit cannot fit the next UTF-8 codepoint"))
    False -> Ok(Nil)
  })
  let next = offset + string.byte_size(text)
  Ok(
    p.DocumentPage(revision, text, case next < string.byte_size(document) {
      True -> Some(next)
      False -> None
    }),
  )
}
