//// Deterministic, request-only selection. No writes, providers or transcript scan.

import albedo/daemon/http_api as api
import albedo/daemon/store
import albedo/harness/extensions/personality/ledger
import albedo/harness/extensions/personality/read_tokens
import albedo/harness/extensions/personality/sources
import albedo/harness/extensions/personality/types as p
import albedo/harness/request_context
import albedo/text_scalars
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import sqlight

pub type Selection {
  Selection(
    records: List(p.Record),
    source_ids: List(String),
    selected_reasons: List(#(String, String)),
    excluded_count: Int,
    rendered_bytes: Int,
  )
}

pub fn snapshot_id(snapshot: p.Snapshot) -> String {
  snapshot.persona.id
  <> ":identity-"
  <> int.to_string(snapshot.persona.identity_revision)
  <> ":aggregate-"
  <> int.to_string(snapshot.persona.revision)
  <> ":binding-"
  <> int.to_string(snapshot.binding.revision)
}

fn matches(record: p.Record, terms: List(String)) -> Bool {
  let text =
    string.lowercase(
      record.memory.text
      <> " "
      <> string.join(record.memory.tags, " ")
      <> " "
      <> record.memory.temporal_scope,
    )
  list.any(terms, fn(term) { string.contains(text, term) })
}

fn flag(value: Bool) -> Int {
  case value {
    True -> 1
    False -> 0
  }
}

fn compare(a: p.Record, b: p.Record, terms: List(String)) -> order.Order {
  int.compare(flag(b.pinned), flag(a.pinned))
  |> order.break_tie(int.compare(
    flag(matches(b, terms)),
    flag(matches(a, terms)),
  ))
  |> order.break_tie(int.compare(b.memory.importance, a.memory.importance))
  |> order.break_tie(int.compare(
    flag(b.open_commitment),
    flag(a.open_commitment),
  ))
  |> order.break_tie(int.compare(flag(b.due), flag(a.due)))
  |> order.break_tie(int.compare(b.memory.event_id, a.memory.event_id))
  |> order.break_tie(string.compare(a.memory.id, b.memory.id))
}

fn reason(record: p.Record, terms: List(String)) -> String {
  [
    case record.pinned {
      True -> ["pinned"]
      False -> []
    },
    case matches(record, terms) {
      True -> ["query_match"]
      False -> []
    },
    ["importance:" <> int.to_string(record.memory.importance)],
    case record.open_commitment {
      True -> ["open_commitment"]
      False -> []
    },
    case record.due {
      True -> ["due"]
      False -> []
    },
    case record.memory.unresolved {
      True -> ["unresolved_evidence"]
      False -> []
    },
    ["recency:" <> int.to_string(record.memory.event_id)],
  ]
  |> list.flatten
  |> string.join(",")
}

pub fn record_json(record: p.Record) -> json.Json {
  let memory = record.memory
  json.object([
    #("id", json.string(memory.id)),
    #("revision", json.int(memory.revision)),
    #("text", json.string(memory.text)),
    #("provenance", json.string(memory.provenance)),
    #("uncertainty", json.string(memory.uncertainty)),
    #("truth_status", json.string("unverified_claim")),
    #(
      "attribution",
      json.string(
        case list.contains(memory.claim.actor_kinds, "user_assertion") {
          True -> "being_told"
          False -> "source_backed_claim"
        },
      ),
    ),
    #("source_origins", json.array(memory.claim.origins, json.string)),
    #("source_actor_kinds", json.array(memory.claim.actor_kinds, json.string)),
    #("evidence_source_ids", json.array(memory.claim.source_ids, json.string)),
    #("tags", json.array(memory.tags, json.string)),
    #("temporal_scope", json.string(memory.temporal_scope)),
    #("unresolved", json.bool(memory.unresolved)),
    #(
      "evidence",
      json.array(memory.sources, fn(link) {
        json.object([
          #("source_id", json.string(link.source.id)),
          #("relation", json.string(link.relation)),
          #("availability", json.string(link.source.availability)),
        ])
      }),
    ),
  ])
}

pub fn content(
  records: List(p.Record),
  reasons: List(#(String, String)),
) -> String {
  json.object([
    #("kind", json.string("curated_untrusted_evidence")),
    #("records", json.array(records, record_json)),
    #(
      "selected_reasons",
      json.array(reasons, fn(item) {
        json.object([
          #("id", json.string(item.0)),
          #("reason", json.string(item.1)),
        ])
      }),
    ),
  ])
  |> json.to_string
}

fn rendered_bytes(
  snapshot: p.Snapshot,
  records: List(p.Record),
  terms: List(String),
) -> Int {
  case records {
    [] -> 0
    _ ->
      request_context.render(
        snapshot_id(snapshot),
        request_context.Block(
          "personality recall",
          content(
            records,
            list.map(records, fn(record) {
              #(record.memory.id, reason(record, terms))
            }),
          ),
          False,
          0,
        ),
      )
      |> string.byte_size
  }
}

fn related(a: p.Record, b: p.Record) -> Bool {
  list.any(a.memory.claim.source_ids, fn(id) {
    list.contains(b.memory.claim.source_ids, id)
  })
}

fn contradiction_group(
  candidates: List(p.Record),
  group: List(p.Record),
) -> List(p.Record) {
  let additions =
    list.filter(candidates, fn(item) {
      item.memory.unresolved
      && !list.any(group, fn(saved) { saved.memory.id == item.memory.id })
      && list.any(group, fn(saved) { related(saved, item) })
    })
  case additions == [] || list.length(group) > 16 {
    True -> group
    False -> contradiction_group(candidates, list.append(group, additions))
  }
}

pub fn select(
  snapshot: p.Snapshot,
  query: String,
  budget: request_context.Budget,
) -> Selection {
  let terms = ledger.query_terms(query)
  let allowance = case budget.remaining_tokens {
    None -> 8192
    // One input overhead and a strict token of headroom for request preparation.
    Some(tokens) -> int.min(8192, int.max(0, tokens - 13) * 4)
  }
  let candidates =
    snapshot.candidates
    |> list.take(256)
    |> list.filter(fn(record) { record.memory.lifecycle == "active" })
    |> list.sort(fn(a, b) { compare(a, b, terms) })
  let selected =
    list.fold(candidates, [], fn(selected: List(p.Record), record) {
      case list.any(selected, fn(item) { item.memory.id == record.memory.id }) {
        True -> selected
        False -> {
          // Claim and every related unresolved head are one indivisible group.
          // Their complete correction/contradiction labels travel with the text.
          let group = contradiction_group(candidates, [record])
          let next =
            list.append(
              selected,
              list.filter(group, fn(item) {
                !list.any(selected, fn(saved) {
                  saved.memory.id == item.memory.id
                })
              }),
            )
          case
            list.length(next) <= 16
            && list.all(next, fn(item) {
              list.all(item.related_unresolved_ids, fn(id) {
                list.any(next, fn(saved) { saved.memory.id == id })
              })
            })
            && rendered_bytes(snapshot, next, terms) <= allowance
          {
            True -> next
            False -> selected
          }
        }
      }
    })
    |> list.sort(fn(a, b) { compare(a, b, terms) })
  Selection(
    selected,
    list.flat_map(selected, fn(record) { record.memory.claim.source_ids })
      |> list.unique,
    list.map(selected, fn(record) { #(record.memory.id, reason(record, terms)) }),
    int.max(0, snapshot.eligible_count - list.length(selected)),
    rendered_bytes(snapshot, selected, terms),
  )
}

pub fn search(
  db: store.Store,
  session: String,
  query: String,
  cursor: Option(String),
) -> Result(p.Page, p.DomainError) {
  ledger.search(db, session, query, cursor)
}

pub fn episode_page_json(page: p.EpisodePage) -> json.Json {
  json.object([
    #(
      "records",
      json.array(page.records, fn(episode) {
        json.object([
          #("summary", json.string(episode.summary)),
          #("scalar_offset", json.int(episode.scalar_offset)),
          #("evidence_label", json.string("derived_fallible_evidence")),
          #("source", sources.json(episode.source)),
        ])
      }),
    ),
    #("next_cursor", json.nullable(page.next, json.string)),
    #("bytes", json.int(page.bytes)),
  ])
}

pub fn episodes(
  db: store.Store,
  session: String,
  query: String,
  cursor: Option(String),
) -> Result(p.EpisodePage, p.DomainError) {
  use _ <- result.try(ledger.valid_query(query))
  use _ <- result.try(case string.byte_size(option.unwrap(cursor, "")) <= 2048 {
    True -> Ok(Nil)
    False -> Error(p.Invalid("episode cursor exceeds its limit"))
  })
  store.query(db, fn(connection) {
    use binding <- result.try(sources.binding_in(connection, session))
    use head <- result.try(
      store.one(
        connection,
        "SELECT revision FROM personality_persona WHERE id=?",
        [sqlight.text(binding.persona_id)],
        decode.field(0, decode.int, decode.success),
        "persona head unavailable",
      )
      |> result.map_error(p.Storage),
    )
    let scope =
      sources.hash(
        json.to_string(json.array(
          [
            binding.persona_id,
            session,
            int.to_string(binding.revision),
            int.to_string(head),
            query,
          ],
          json.string,
        )),
      )
    use key <- result.try(read_tokens.key(connection))
    use position <- result.try(case cursor {
      None -> {
        use upper <- result.try(
          store.one(
            connection,
            "SELECT COALESCE(MAX(n.id),0) FROM lcm_compaction_node n WHERE "
              <> sources.episode_authority,
            [sqlight.text(binding.persona_id), sqlight.text(binding.persona_id)],
            decode.field(0, decode.int, decode.success),
            "LCM episode index unavailable",
          )
          |> result.map_error(p.Storage),
        )
        Ok(#(upper, 0, 0, False))
      }
      Some(cursor) -> {
        use state <- result.try(
          api.page_state(key, "personality-episodes-v1", cursor)
          |> result.map_error(fn(error) {
            case error {
              "continuation_expired" -> p.Conflict("episode cursor expired")
              _ -> p.Invalid("invalid episode cursor")
            }
          }),
        )
        use parts <- result.try(
          json.parse(state, decode.list(decode.string))
          |> result.replace_error(p.Invalid("invalid episode cursor")),
        )
        case parts {
          [saved, upper, node, offset, matched] if saved == scope -> {
            use upper <- result.try(
              int.parse(upper)
              |> result.replace_error(p.Invalid("invalid episode upper bound")),
            )
            use node <- result.try(
              int.parse(node)
              |> result.replace_error(p.Invalid("invalid episode node")),
            )
            use offset <- result.try(
              int.parse(offset)
              |> result.replace_error(p.Invalid("invalid episode offset")),
            )
            case
              upper >= 0
              && node >= 0
              && node <= upper
              && offset >= 0
              && { matched == "matched" || matched == "searching" }
            {
              True -> Ok(#(upper, node, offset, matched == "matched"))
              False -> Error(p.Invalid("episode cursor outside bounds"))
            }
          }
          _ -> Error(p.Conflict("episode cursor scope or head changed"))
        }
      }
    })
    let terms = ledger.query_terms(query)
    // One bounded summary window, with bounded query-length lookahead for terms
    // spanning a fragment boundary. Unicode matching stays in Gleam, not SQLite
    // ASCII-only lower(). Empty search pages still carry a continuation.
    let lookahead =
      list.fold(terms, 0, fn(size, term) {
        int.max(size, text_scalars.length(term))
      })
    use nodes <- result.try(
      store.rows(
        connection,
        "SELECT n.id,substr(n.summary,?+1,?),length(n.summary) FROM lcm_compaction_node n WHERE n.id>=? AND n.id<=? AND "
          <> sources.episode_authority
          <> " ORDER BY n.id LIMIT 2",
        [
          sqlight.int(position.2),
          sqlight.int(128 + lookahead),
          sqlight.int(position.1),
          sqlight.int(position.0),
          sqlight.text(binding.persona_id),
          sqlight.text(binding.persona_id),
        ],
        {
          use id <- decode.field(0, decode.int)
          use text <- decode.field(1, decode.string)
          use size <- decode.field(2, decode.int)
          decode.success(#(id, text, size))
        },
      )
      |> result.map_error(p.Storage),
    )
    use page <- result.try(case nodes {
      [] ->
        case cursor {
          None -> Ok(p.EpisodePage([], None, 0))
          Some(_) ->
            Error(p.Invalid("episode cursor outside authorized results"))
        }
      [node, ..rest] -> {
        use _ <- result.try(case cursor, node.0 == position.1 {
          Some(_), False ->
            Error(p.SourceUnavailable("episode cursor node unavailable"))
          _, _ -> Ok(Nil)
        })
        use _ <- result.try(
          case position.2 < node.2 || { position.2 == 0 && node.2 == 0 } {
            True -> Ok(Nil)
            False -> Error(p.Invalid("episode fragment outside summary"))
          },
        )
        let chunk = text_scalars.take(node.1, 128)
        let matched =
          position.3
          || terms == []
          || list.any(terms, fn(term) {
            string.contains(string.lowercase(node.1), term)
          })
        let next = case position.2 + text_scalars.length(chunk) < node.2 {
          True ->
            Some(episode_cursor(
              key,
              scope,
              position.0,
              node.0,
              position.2 + 128,
              matched,
            ))
          False ->
            case rest {
              [following, ..] ->
                Some(episode_cursor(
                  key,
                  scope,
                  position.0,
                  following.0,
                  0,
                  False,
                ))
              [] -> None
            }
        }
        use records <- result.try(case matched {
          False -> Ok([])
          True ->
            sources.episode_in(connection, binding, node.0)
            |> result.map(fn(source) { [p.Episode(source, chunk, position.2)] })
        })
        Ok(p.EpisodePage(records, next, 0))
      }
    })
    let bytes = episode_page_json(page) |> json.to_string |> string.byte_size
    let page =
      p.EpisodePage(
        ..page,
        bytes: bytes + string.byte_size(int.to_string(bytes)) - 1,
      )
    case episode_page_json(page) |> json.to_string |> string.byte_size <= 8192 {
      True -> Ok(page)
      False -> Error(p.Invalid("episode page exceeds 8 KiB rendered bytes"))
    }
  })
}

fn episode_cursor(
  key: String,
  scope: String,
  upper: Int,
  node: Int,
  offset: Int,
  matched: Bool,
) -> String {
  let state =
    json.to_string(json.array(
      [
        scope,
        int.to_string(upper),
        int.to_string(node),
        int.to_string(offset),
        case matched {
          True -> "matched"
          False -> "searching"
        },
      ],
      json.string,
    ))
  api.page_token(key, "personality-episodes-v1", state)
}
