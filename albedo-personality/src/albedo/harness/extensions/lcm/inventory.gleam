//// Metadata-only SQL inventory, shared by graph capture and durable receipt validation.
//// Graph owns writes/DDL. No summary or narration payload is fetched here.

import albedo/context_cost
import albedo/context_salience
import albedo/daemon/context_source
import albedo/daemon/store
import albedo/harness/extensions/lcm/selection_types as selection
import albedo/harness/projection_types
import gleam/dynamic/decode
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import sqlight

pub fn capture_in(
  db: sqlight.Connection,
  session: String,
  profile: context_cost.CostProfile,
) -> Result(selection.ArchiveInventory, String) {
  use source <- result.try(context_source.bound_in(db, session))
  use units <- result.try(context_source.inventory_in(db, source, profile))
  use pending <- result.try(store.one(
    db,
    "SELECT COUNT(*) FROM lcm_compaction_node WHERE session=? AND inventory_indexed=0",
    [sqlight.text(session)],
    decode.field(0, decode.int, decode.success),
    "archive readiness unavailable",
  ))
  use _ <- result.try(case pending {
    0 -> Ok(Nil)
    _ -> Error("archive metadata unavailable: unindexed or rewritten nodes")
  })
  use revision <- result.try(store.one(
    db,
    "SELECT COALESCE((SELECT revision FROM lcm_inventory_state WHERE session=?),0)",
    [sqlight.text(session)],
    decode.field(0, decode.int, decode.success),
    "graph generation unavailable",
  ))
  use edges <- result.try(
    store.rows(
      db,
      "SELECT e.child,e.parent,e.position FROM lcm_compaction_edge e JOIN lcm_compaction_node n ON n.id=e.parent WHERE n.session=? ORDER BY e.parent,e.position",
      [sqlight.text(session)],
      {
        use child <- decode.field(0, decode.int)
        use parent <- decode.field(1, decode.int)
        use position <- decode.field(2, decode.int)
        decode.success(selection.Edge(child, parent, position))
      },
    ),
  )
  use nodes <- result.try(
    store.rows(
      db,
      "SELECT n.id,n.depth,n.first_seq,n.last_seq,n.formation_id,m.narrator_subject,m.content_identity,m.own_tokens,m.foreign_tokens,m.own_total,m.own_external,m.foreign_total,m.foreign_external,m.legacy_frame,m.error FROM lcm_compaction_node n JOIN lcm_compaction_metadata m ON m.node_id=n.id WHERE n.session=? AND n.last_seq<=? ORDER BY n.first_seq,n.id",
      [sqlight.text(session), sqlight.int(source.transcript_upper)],
      {
        use id <- decode.field(0, decode.int)
        use depth <- decode.field(1, decode.int)
        use first <- decode.field(2, decode.int)
        use last <- decode.field(3, decode.int)
        use formed <- decode.field(4, decode.optional(decode.int))
        use subject <- decode.field(5, decode.optional(decode.string))
        use identity <- decode.field(6, decode.string)
        use own_tokens <- decode.field(7, decode.int)
        use foreign_tokens <- decode.field(8, decode.int)
        use own_total <- decode.field(9, decode.int)
        use own_external <- decode.field(10, decode.int)
        use foreign_total <- decode.field(11, decode.int)
        use foreign_external <- decode.field(12, decode.int)
        use legacy <- decode.field(13, sqlight.decode_bool())
        use error <- decode.field(14, decode.optional(decode.string))
        let own = subject != None && subject == profile.subject
        decode.success(selection.ArchivedNode(
          id,
          depth,
          projection_types.SourceRange(first, last, 0, 0),
          formed,
          subject,
          identity,
          context_cost.CostEntryKey(
            context_cost.profile_id(profile),
            identity,
            0,
          ),
          case own {
            True -> own_tokens
            False -> foreign_tokens
          },
          context_salience.SalienceFacts(
            case own {
              True -> own_total
              False -> foreign_total
            },
            case own {
              True -> own_external
              False -> foreign_external
            },
            context_salience.policy_version,
          ),
          [],
          [],
          False,
          error,
          legacy,
        ))
      },
    ),
  )
  let resolved =
    list.map(nodes, fn(node) { resolve(node, nodes, edges, units, []) })
  let roots =
    list.filter(resolved, fn(node) {
      !list.any(edges, fn(edge) { edge.child == node.id })
    })
    |> list.map(fn(node) { node.id })
  Ok(selection.ArchiveInventory(
    source,
    units,
    resolved,
    edges,
    roots,
    profile,
    revision,
  ))
}

fn resolve(
  node: selection.ArchivedNode,
  nodes: List(selection.ArchivedNode),
  edges: List(selection.Edge),
  units: List(context_source.SourceUnit),
  seen: List(Int),
) -> selection.ArchivedNode {
  let children =
    list.filter(edges, fn(e) { e.parent == node.id })
    |> list.map(fn(e) { e.child })
  case list.contains(seen, node.id) {
    True ->
      selection.ArchivedNode(..node, exclusion: Some("cyclic archive lineage"))
    False -> {
      let leaves =
        list.filter(units, fn(u) {
          u.first_seq >= node.range.first_seq
          && u.last_seq <= node.range.last_seq
        })
      let actual = list.map(leaves, fn(u) { u.position })
      let child_nodes =
        list.filter_map(children, fn(id) {
          list.find(nodes, fn(n) { n.id == id })
        })
      let resolved =
        list.map(child_nodes, fn(child) {
          resolve(child, nodes, edges, units, [node.id, ..seen])
        })
      let coverage = case node.depth {
        0 -> actual
        _ -> list.flat_map(resolved, fn(n) { n.coverage })
      }
      let exact = case list.first(leaves), list.last(leaves) {
        Ok(first), Ok(last) ->
          first.first_seq == node.range.first_seq
          && last.last_seq == node.range.last_seq
          && list.all(leaves, fn(u) { u.closed })
        _, _ -> False
      }
      let available =
        exact
        && coverage == actual
        && node.exclusion == None
        && case node.depth {
          0 -> children == []
          _ ->
            list.length(resolved) == list.length(children)
            && list.length(children) >= 2
            && list.all(resolved, fn(n) { n.available && n.depth < node.depth })
        }
      let first_position = list.first(coverage) |> result.unwrap(0)
      let last_position = list.last(coverage) |> result.unwrap(0)
      let exclusion = case available, node.exclusion {
        True, _ -> None
        False, Some(error) -> Some(error)
        False, None -> Some("incomplete actual archive coverage")
      }
      selection.ArchivedNode(
        ..node,
        range: projection_types.SourceRange(
          node.range.first_seq,
          node.range.last_seq,
          first_position,
          last_position,
        ),
        coverage: coverage,
        children: children,
        available: available,
        exclusion: exclusion,
      )
    }
  }
}
