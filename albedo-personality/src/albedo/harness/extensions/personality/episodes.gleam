//// Automatic continuity selects a bounded pointer to an existing native node.
//// It grants no source access and never copies episodic rows into another store.

import albedo/daemon/store
import albedo/harness/extensions/lcm/graph
import albedo/harness/extensions/lcm/narration_types as n
import albedo/harness/request_context
import gleam/dynamic/decode
import gleam/option.{type Option, None, Some}
import gleam/result
import sqlight

/// Store-only generation guard. The graph invokes this inside its transaction;
/// no store actor re-entry, model calls, or document-revision conflict occurs.
pub fn guard(
  policy: request_context.SummaryPolicy,
  session: String,
) -> graph.CommitGuard {
  fn(db) {
    use rows <- result.map(store.rows(
      db,
      "SELECT 1 FROM personality_session p JOIN sessions s ON s.id=p.session WHERE p.session=? AND p.persona_id=? AND p.generation=? AND p.mode=? AND s.config_revision=? AND EXISTS(SELECT 1 FROM session_extensions e WHERE e.session=p.session AND e.name='personality' AND e.enabled=1)",
      [
        sqlight.text(session),
        sqlight.text(policy.lineage.subject),
        sqlight.int(policy.lineage.binding_revision),
        sqlight.text(policy.lineage.role),
        sqlight.int(policy.selection_revision),
      ],
      decode.field(0, decode.int, decode.success),
    ))
    rows == [1]
  }
}

pub fn latest(
  db: store.Store,
  current: String,
  policy: request_context.SummaryPolicy,
) -> Result(Option(#(String, graph.Node)), String) {
  case policy.lineage.role {
    "owner" -> latest_owner(db, current, policy.lineage.subject)
    _ -> Ok(None)
  }
}

fn latest_owner(
  db: store.Store,
  current: String,
  subject: String,
) -> Result(Option(#(String, graph.Node)), String) {
  // Restrict before reading bodies. Historical deliberate owner bindings count;
  // active delegate-family sessions never become automatic continuity sources.
  use candidates <- result.try(
    store.read(
      db,
      "SELECT n.session,n.id FROM lcm_compaction_node n WHERE n.session<>? AND n.narration IS NOT NULL AND json_extract(n.narration,'$.narrator.subject')=? AND EXISTS(SELECT 1 FROM personality_binding_revision b WHERE b.session=n.session AND b.persona_id=? AND b.mode='owner') AND NOT EXISTS(SELECT 1 FROM session_family f WHERE f.session=n.session) ORDER BY n.formation_id DESC,n.id ASC LIMIT 1",
      [sqlight.text(current), sqlight.text(subject), sqlight.text(subject)],
      {
        use session <- decode.field(0, decode.string)
        use id <- decode.field(1, decode.int)
        decode.success(#(session, id))
      },
    ),
  )
  find_candidate(db, subject, candidates)
}

fn find_candidate(
  db: store.Store,
  subject: String,
  candidates: List(#(String, Int)),
) -> Result(Option(#(String, graph.Node)), String) {
  case candidates {
    [] -> Ok(None)
    [#(session, id), ..rest] -> {
      use node <- result.try(graph.node(db, session, id))
      case node {
        Some(node) ->
          case node.frame {
            Some(n.Frame(Some(who), _, _, _)) if who.subject == subject ->
              Ok(Some(#(session, node)))
            _ -> find_candidate(db, subject, rest)
          }
        None -> find_candidate(db, subject, rest)
      }
    }
  }
}
