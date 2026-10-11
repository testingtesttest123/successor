//// Durable selections, separate from archive lineage. Every replacement is CAS.
//// No graph import: shared values and the caller's structural guard keep ownership acyclic.

import albedo/context_cost
import albedo/context_salience
import albedo/daemon/context_source
import albedo/daemon/store
import albedo/harness/extensions/lcm/inventory
import albedo/harness/extensions/lcm/selection_types as selection
import albedo/harness/projection_types
import albedo/openai_api/types
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import sqlight

pub fn initialise_in(db: sqlight.Connection) -> Result(Nil, String) {
  store.exec(
    db,
    "CREATE TABLE IF NOT EXISTS lcm_projection_state(session TEXT PRIMARY KEY REFERENCES sessions(id),generation INTEGER NOT NULL,version INTEGER NOT NULL,scope TEXT NOT NULL,profile TEXT NOT NULL,refs TEXT NOT NULL,salience INTEGER NOT NULL)",
  )
}

pub fn generation_in(
  db: sqlight.Connection,
  session: String,
) -> Result(Int, String) {
  store.one(
    db,
    "SELECT COALESCE((SELECT generation FROM lcm_projection_state WHERE session=?),0)",
    [sqlight.text(session)],
    decode.field(0, decode.int, decode.success),
    "receipt generation unavailable",
  )
}

pub fn capture_in(
  db: sqlight.Connection,
  session: String,
) -> Result(selection.SelectionReceipt, String) {
  use rows <- result.try(
    store.rows(
      db,
      "SELECT generation,version,scope,profile,refs,salience FROM lcm_projection_state WHERE session=?",
      [sqlight.text(session)],
      {
        use generation <- decode.field(0, decode.int)
        use version <- decode.field(1, decode.int)
        use scope <- decode.field(2, decode.string)
        use profile <- decode.field(3, decode.string)
        use refs <- decode.field(4, decode.string)
        use policy <- decode.field(5, decode.int)
        decode.success(#(generation, version, scope, profile, refs, policy))
      },
    ),
  )
  case rows {
    [] -> Ok(selection.empty_receipt(0, None))
    [row] ->
      case row.1 {
        1 -> {
          let parsed = parse_receipt(row.0, row.2, row.3, row.4)
          case parsed {
            Error(_) ->
              Ok(selection.empty_receipt(row.0, Some("corrupt receipt")))
            Ok(receipt) -> {
              let assert Some(scope) = receipt.source
              use current <- result.try(context_source.bound_in(db, session))
              use changed <- result.try(store.one(
                db,
                "SELECT COUNT(*) FROM context_source_change WHERE session=?1 AND revision>?2 AND ((kind='transcript' AND position<=?3) OR (kind='continuation_markers' AND position<=?4))",
                [
                  sqlight.text(session),
                  sqlight.int(scope.revision),
                  sqlight.int(scope.transcript_upper),
                  sqlight.int(scope.continuation_upper),
                ],
                decode.field(0, decode.int, decode.success),
                "receipt scope validation unavailable",
              ))
              use refs_valid <- result.try(references_valid_in(
                db,
                session,
                receipt.refs,
              ))
              let assert Some(saved_profile) = receipt.profile
              let profile_valid =
                list.all(receipt.refs, fn(ref) {
                  case ref {
                    selection.Raw(_, key) | selection.Recall(_, key) ->
                      key.profile_id == context_cost.profile_id(saved_profile)
                  }
                })
              let valid =
                row.5 == context_salience.policy_version
                && profile_valid
                && scope.session == session
                && scope.transcript_upper <= current.transcript_upper
                && scope.continuation_upper <= current.continuation_upper
                && scope.revision <= current.revision
                && scope.configuration_revision
                == current.configuration_revision
                && changed == 0
                && refs_valid
              Ok(case valid {
                True -> receipt
                False ->
                  selection.empty_receipt(
                    row.0,
                    Some("receipt source/render identity changed"),
                  )
              })
            }
          }
        }
        _ ->
          Ok(selection.empty_receipt(row.0, Some("unsupported receipt version")))
      }
    _ -> Error("duplicate receipt identity")
  }
}

fn parse_receipt(
  generation: Int,
  scope: String,
  profile: String,
  refs: String,
) -> Result(selection.SelectionReceipt, Nil) {
  use scope <- result.try(
    json.parse(scope, scope_decoder()) |> result.replace_error(Nil),
  )
  use profile <- result.try(
    json.parse(profile, profile_decoder()) |> result.replace_error(Nil),
  )
  use refs <- result.try(
    json.parse(refs, decode.list(ref_decoder())) |> result.replace_error(Nil),
  )
  Ok(selection.SelectionReceipt(
    1,
    generation,
    Some(scope),
    Some(profile),
    refs,
    None,
  ))
}

pub fn commit(
  ledger: store.Store,
  session: String,
  expected: selection.ProjectionSnapshot,
  validated: selection.ValidatedSelection,
  guard: fn(sqlight.Connection) -> Result(Bool, String),
) -> Result(Bool, String) {
  store.query(ledger, fn(db) {
    store.transaction(db, fn() {
      use source <- result.try(context_source.bound_in(db, session))
      use graph_revision <- result.try(store.one(
        db,
        "SELECT COALESCE((SELECT revision FROM lcm_inventory_state WHERE session=?),0)",
        [sqlight.text(session)],
        decode.field(0, decode.int, decode.success),
        "graph generation unavailable",
      ))
      use generation <- result.try(generation_in(db, session))
      let profile = selection.profile(validated)
      let current =
        selection.ProjectionSnapshot(
          source,
          graph_revision,
          generation,
          context_cost.profile_id(profile),
          profile.identity,
        )
      case
        current == expected
        && selection.snapshot(validated) == expected
        && expected.source.session == session
      {
        False -> Ok(False)
        True -> {
          use allowed <- result.try(guard(db))
          use actual <- result.try(inventory.capture_in(db, session, profile))
          let capture =
            selection.ProjectionCapture(
              actual,
              selection.empty_receipt(generation, None),
              current,
            )
          let valid =
            selection.validate(capture, selection.references(validated))
            |> result.is_ok
          case allowed && valid {
            False -> Ok(False)
            True -> {
              use _ <- result.try(write_in(
                db,
                session,
                generation + 1,
                source,
                profile,
                selection.references(validated),
              ))
              Ok(True)
            }
          }
        }
      }
    })
  })
}

fn write_in(
  db: sqlight.Connection,
  session: String,
  generation: Int,
  scope: projection_types.SourceBound,
  profile: context_cost.CostProfile,
  refs: List(selection.RenderRef),
) -> Result(Nil, String) {
  store.run(
    db,
    "INSERT INTO lcm_projection_state(session,generation,version,scope,profile,refs,salience) VALUES(?,?,1,?,?,?,?) ON CONFLICT(session) DO UPDATE SET generation=excluded.generation,version=excluded.version,scope=excluded.scope,profile=excluded.profile,refs=excluded.refs,salience=excluded.salience",
    [
      sqlight.text(session),
      sqlight.int(generation),
      sqlight.text(json.to_string(scope_json(scope))),
      sqlight.text(json.to_string(profile_json(profile))),
      sqlight.text(json.to_string(json.array(refs, ref_json))),
      sqlight.int(context_salience.policy_version),
    ],
  )
}

fn references_valid_in(
  db: sqlight.Connection,
  session: String,
  refs: List(selection.RenderRef),
) -> Result(Bool, String) {
  use valid <- result.try(
    list.try_map(refs, fn(ref) {
      let #(sql, id, key) = case ref {
        selection.Raw(first, key) -> #(
          "SELECT COUNT(*) FROM context_source_unit WHERE session=?1 AND first_seq=?2 AND content_identity=?3 AND fit_revision=?4 AND error IS NULL",
          first,
          key,
        )
        selection.Recall(id, key) -> #(
          "SELECT COUNT(*) FROM lcm_compaction_node n JOIN lcm_compaction_metadata m ON m.node_id=n.id WHERE n.session=?1 AND n.id=?2 AND m.content_identity=?3 AND ?4=0 AND n.inventory_indexed=1",
          id,
          key,
        )
      }
      store.one(
        db,
        sql,
        [
          sqlight.text(session),
          sqlight.int(id),
          sqlight.text(key.content_identity),
          sqlight.int(key.affected_fit_revision),
        ],
        decode.field(0, decode.int, decode.success),
        "render identity validation unavailable",
      )
      |> result.map(fn(n) { n == 1 })
    }),
  )
  Ok(list.all(valid, fn(v) { v }))
}

fn scope_json(scope: projection_types.SourceBound) -> json.Json {
  json.object([
    #("session", json.string(scope.session)),
    #("upper", json.int(scope.transcript_upper)),
    #("continuations", json.int(scope.continuation_upper)),
    #("revision", json.int(scope.revision)),
    #("configuration", json.int(scope.configuration_revision)),
  ])
}

fn scope_decoder() -> decode.Decoder(projection_types.SourceBound) {
  use session <- decode.field("session", decode.string)
  use upper <- decode.field("upper", decode.int)
  use continuations <- decode.field("continuations", decode.int)
  use revision <- decode.field("revision", decode.int)
  use config <- decode.field("configuration", decode.int)
  decode.success(projection_types.SourceBound(
    session,
    upper,
    continuations,
    revision,
    config,
  ))
}

fn profile_json(profile: context_cost.CostProfile) -> json.Json {
  json.object([
    #("provider", json.string(profile.provider)),
    #("protocol", json.string(types.protocol_name(profile.protocol))),
    #("model", json.string(profile.model)),
    #("max_edge", json.int(profile.image_limits.max_edge)),
    #("max_images", json.nullable(profile.image_limits.max_images, json.int)),
    #("subject", json.nullable(profile.subject, json.string)),
    #("identity", json.string(profile.identity)),
  ])
}

fn profile_decoder() -> decode.Decoder(context_cost.CostProfile) {
  use provider <- decode.field("provider", decode.string)
  use protocol <- decode.field("protocol", decode.string)
  use model <- decode.field("model", decode.string)
  use edge <- decode.field("max_edge", decode.int)
  use images <- decode.field("max_images", decode.optional(decode.int))
  use subject <- decode.field("subject", decode.optional(decode.string))
  use identity <- decode.field("identity", decode.string)
  let protocol = case protocol {
    "responses" -> types.Responses
    _ -> types.ChatCompletions
  }
  decode.success(context_cost.CostProfile(
    provider,
    protocol,
    model,
    types.ImageLimits(edge, images),
    subject,
    identity,
  ))
}

fn ref_json(ref: selection.RenderRef) -> json.Json {
  let #(kind, id, key) = case ref {
    selection.Raw(id, key) -> #("raw", id, key)
    selection.Recall(id, key) -> #("recall", id, key)
  }
  json.object([
    #("kind", json.string(kind)),
    #("id", json.int(id)),
    #("profile", json.string(key.profile_id)),
    #("content", json.string(key.content_identity)),
    #("fit", json.int(key.affected_fit_revision)),
  ])
}

fn ref_decoder() -> decode.Decoder(selection.RenderRef) {
  use kind <- decode.field("kind", decode.string)
  use id <- decode.field("id", decode.int)
  use profile <- decode.field("profile", decode.string)
  use content <- decode.field("content", decode.string)
  use fit <- decode.field("fit", decode.int)
  let key = context_cost.CostEntryKey(profile, content, fit)
  case kind {
    "raw" -> decode.success(selection.Raw(id, key))
    "recall" -> decode.success(selection.Recall(id, key))
    _ -> decode.failure(selection.Raw(0, key), "known render reference")
  }
}

pub fn forget_in(
  db: sqlight.Connection,
  session: String,
) -> Result(Nil, String) {
  store.forget_session(db, ["lcm_projection_state"], session)
}

/// Called after source/node/frame/identity copying in the existing fork transaction.
/// Crossing recalls reset the prior; whole surviving references acquire branch-local keys.
pub fn inherit_fork_in(
  db: sqlight.Connection,
  source: String,
  branch: String,
  checkpoint: Int,
  source_seqs: List(Int),
) -> Result(Nil, String) {
  use previous <- result.try(capture_in(db, source))
  case previous.source, previous.profile {
    Some(_), Some(profile) -> {
      use branch_seqs <- result.try(store.rows(
        db,
        "SELECT seq FROM transcript WHERE session=? ORDER BY seq LIMIT ?",
        [sqlight.text(branch), sqlight.int(list.length(source_seqs))],
        decode.field(0, decode.int, decode.success),
      ))
      let mapping = dict.from_list(list.zip(source_seqs, branch_seqs))
      use actual <- result.try(inventory.capture_in(db, branch, profile))
      let remapped =
        list.try_fold(previous.refs, [], fn(refs, ref) {
          case ref {
            selection.Raw(first, _) ->
              case dict.get(mapping, first) {
                Error(_) -> Ok(refs)
                Ok(first) -> {
                  use unit <- result.try(
                    list.find(actual.units, fn(u) { u.first_seq == first })
                    |> result.replace_error("fork raw range unavailable"),
                  )
                  Ok([selection.Raw(first, unit.cost_key), ..refs])
                }
              }
            selection.Recall(id, _) -> {
              use original <- result.try(store.one(
                db,
                "SELECT first_seq,last_seq,COALESCE(formation_id,id) FROM lcm_compaction_node WHERE session=? AND id=?",
                [sqlight.text(source), sqlight.int(id)],
                {
                  use first <- decode.field(0, decode.int)
                  use last <- decode.field(1, decode.int)
                  use formed <- decode.field(2, decode.int)
                  decode.success(#(first, last, formed))
                },
                "fork source recall missing",
              ))
              case original.0 > checkpoint, original.1 > checkpoint {
                True, _ -> Ok(refs)
                _, True -> Error("fork crosses selected recall")
                _, _ -> {
                  use first <- result.try(
                    dict.get(mapping, original.0)
                    |> result.replace_error("fork recall start missing"),
                  )
                  use last <- result.try(
                    dict.get(mapping, original.1)
                    |> result.replace_error("fork recall end missing"),
                  )
                  use node <- result.try(
                    list.find(actual.nodes, fn(n) {
                      n.range.first_seq == first
                      && n.range.last_seq == last
                      && n.formation_id == Some(original.2)
                    })
                    |> result.replace_error("fork recall identity missing"),
                  )
                  Ok([selection.Recall(node.id, node.cost_key), ..refs])
                }
              }
            }
          }
        })
      let expected =
        selection.ProjectionSnapshot(
          actual.source,
          actual.graph_revision,
          0,
          context_cost.profile_id(profile),
          profile.identity,
        )
      let capture =
        selection.ProjectionCapture(
          actual,
          selection.empty_receipt(0, None),
          expected,
        )
      case
        remapped
        |> result.try(fn(refs) {
          selection.validate(capture, list.reverse(refs))
        })
      {
        Error(_) -> Ok(Nil)
        Ok(validated) ->
          write_in(
            db,
            branch,
            1,
            actual.source,
            profile,
            selection.references(validated),
          )
      }
    }
    _, _ -> Ok(Nil)
  }
}
