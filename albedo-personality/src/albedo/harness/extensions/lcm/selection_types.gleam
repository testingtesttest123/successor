//// Immutable archive/receipt values. Validation is structural in Stage1;
//// provider request acceptance remains the existing compaction path.

import albedo/context_cost
import albedo/context_salience
import albedo/daemon/context_source
import albedo/harness/projection_types
import gleam/list
import gleam/option.{type Option, None}
import gleam/result

pub type Edge {
  Edge(child: Int, parent: Int, position: Int)
}

pub type ArchivedNode {
  ArchivedNode(
    id: Int,
    depth: Int,
    range: projection_types.SourceRange,
    formation_id: Option(Int),
    narrator_subject: Option(String),
    content_identity: String,
    cost_key: context_cost.CostEntryKey,
    tokens: Int,
    salience: context_salience.SalienceFacts,
    coverage: List(Int),
    children: List(Int),
    available: Bool,
    exclusion: Option(String),
    legacy_frame: Bool,
  )
}

pub type ArchiveInventory {
  ArchiveInventory(
    source: projection_types.SourceBound,
    units: List(context_source.SourceUnit),
    nodes: List(ArchivedNode),
    edges: List(Edge),
    roots: List(Int),
    profile: context_cost.CostProfile,
    graph_revision: Int,
  )
}

pub type ProjectionSnapshot {
  ProjectionSnapshot(
    source: projection_types.SourceBound,
    graph_revision: Int,
    receipt_generation: Int,
    profile_id: String,
    identity: String,
  )
}

pub type RenderRef {
  Raw(first_seq: Int, key: context_cost.CostEntryKey)
  Recall(node_id: Int, key: context_cost.CostEntryKey)
}

pub type SelectionReceipt {
  SelectionReceipt(
    version: Int,
    generation: Int,
    source: Option(projection_types.SourceBound),
    profile: Option(context_cost.CostProfile),
    refs: List(RenderRef),
    diagnostic: Option(String),
  )
}

pub type ProjectionCapture {
  ProjectionCapture(
    inventory: ArchiveInventory,
    previous: SelectionReceipt,
    expected: ProjectionSnapshot,
  )
}

pub opaque type ValidatedSelection {
  ValidatedSelection(
    snapshot: ProjectionSnapshot,
    profile: context_cost.CostProfile,
    refs: List(RenderRef),
    tokens: Int,
  )
}

pub fn empty_receipt(
  generation: Int,
  diagnostic: Option(String),
) -> SelectionReceipt {
  SelectionReceipt(1, generation, None, None, [], diagnostic)
}

pub fn snapshot(selection: ValidatedSelection) -> ProjectionSnapshot {
  selection.snapshot
}

pub fn profile(selection: ValidatedSelection) -> context_cost.CostProfile {
  selection.profile
}

pub fn references(selection: ValidatedSelection) -> List(RenderRef) {
  selection.refs
}

pub fn tokens(selection: ValidatedSelection) -> Int {
  selection.tokens
}

pub fn coverage(
  inventory: ArchiveInventory,
  reference: RenderRef,
) -> Result(#(List(Int), Int), String) {
  case reference {
    Raw(first, key) -> {
      use unit <- result.try(
        list.find(inventory.units, fn(u) {
          u.first_seq == first && u.cost_key == key
        })
        |> result.replace_error("raw reference outside source scope/profile"),
      )
      Ok(#([unit.position], unit.tokens))
    }
    Recall(id, key) -> {
      use node <- result.try(
        list.find(inventory.nodes, fn(n) { n.id == id && n.cost_key == key })
        |> result.replace_error("recall reference outside archive/profile"),
      )
      case node.available {
        True -> Ok(#(node.coverage, node.tokens))
        False -> Error("recall coverage unavailable")
      }
    }
  }
}

/// Every actual unit appears exactly once, in order; unfinished units remain raw.
pub fn validate(
  capture: ProjectionCapture,
  refs: List(RenderRef),
) -> Result(ValidatedSelection, String) {
  let inventory = capture.inventory
  use resolved <- result.try(list.try_map(refs, coverage(inventory, _)))
  let positions = list.flat_map(resolved, fn(pair) { pair.0 })
  use _ <- result.try(
    case positions == list.map(inventory.units, fn(u) { u.position }) {
      True -> Ok(Nil)
      False ->
        Error("selection must cover actual source units exactly once in order")
    },
  )
  use _ <- result.try(
    case
      list.all(inventory.units, fn(unit) {
        unit.closed
        || list.any(refs, fn(ref) {
          case ref {
            Raw(first, key) -> first == unit.first_seq && key == unit.cost_key
            _ -> False
          }
        })
      })
    {
      True -> Ok(Nil)
      False -> Error("unfinished source unit must remain raw")
    },
  )
  Ok(ValidatedSelection(
    capture.expected,
    inventory.profile,
    refs,
    list.fold(resolved, 0, fn(n, pair) { n + pair.1 }),
  ))
}
