//// Acyclic, store-only inheritance inside native child/fork transactions.
//// Copies a live reference and provenance cut, never a permanent identity.

import albedo/clock
import albedo/daemon/store
import albedo/harness/extensions/personality/migrations/schema
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import sqlight

pub type Kind {
  Task(compactions: List(String))
  Fork
}

/// The caller owns the creation transaction and has already copied a fork's
/// actual prefix. Unbound, unselected sessions need no optional schema.
pub fn inherit_in(
  db: sqlight.Connection,
  parent: String,
  child: String,
  kind: Kind,
) -> Result(Nil, String) {
  use flags <- result.try(
    store.rows(
      db,
      "SELECT name,enabled FROM session_extensions WHERE session=?",
      [sqlight.text(parent)],
      {
        use name <- decode.field(0, decode.string)
        use enabled <- decode.field(1, sqlight.decode_bool())
        decode.success(#(name, enabled))
      },
    ),
  )
  let explicit = list.key_find(flags, "personality") |> option.from_result
  let selected = case kind {
    Task(compactions) ->
      case
        explicit != Some(True)
        && list.any(flags, fn(flag) {
          flag.0 != "personality"
          && flag.1
          && list.contains(compactions, flag.0)
        })
      {
        True -> Some(False)
        False -> explicit
      }
    Fork -> explicit
  }
  use exists <- result.try(store.one(
    db,
    "SELECT EXISTS(SELECT 1 FROM main.sqlite_master WHERE name='personality_session')",
    [],
    decode.field(0, decode.int, decode.success),
    "binding schema lookup failed",
  ))
  case exists {
    0 -> missing_binding_in(db, parent, explicit)
    _ -> {
      let bindings =
        store.rows(
          db,
          "SELECT persona_id,mode,generation,pre_binding_through FROM main.personality_session WHERE session=?",
          [sqlight.text(parent)],
          {
            use persona <- decode.field(0, decode.string)
            use mode <- decode.field(1, decode.string)
            use generation <- decode.field(2, decode.int)
            use through <- decode.field(3, decode.int)
            decode.success(#(persona, mode, generation, through))
          },
        )
      case bindings {
        // Damaged optional storage cannot make ordinary unrelated creation
        // depend on this extension. An explicit selected/suspended pin cannot
        // silently lose its potentially retained identity, however.
        Error(_) if explicit == None -> missing_binding_in(db, parent, explicit)
        Error(error) -> Error(error)
        Ok([]) if selected != Some(True) -> missing_binding_in(db, parent, None)
        Ok([]) -> Error("selected parent personality binding unavailable")
        Ok([binding]) -> {
          use _ <- result.try(schema.validate(db))
          use _ <- result.try(case binding {
            #(_, mode, generation, through)
              if { mode == "owner" || mode == "delegate" }
              && generation > 0
              && through >= 0
            -> Ok(Nil)
            _ -> Error("invalid parent personality binding")
          })
          use _ <- result.try(store.one(
            db,
            "SELECT 1 FROM personality_persona p JOIN personality_revision r ON r.persona_id=p.id AND r.revision=p.identity_revision WHERE p.id=?",
            [sqlight.text(binding.0)],
            decode.field(0, decode.int, decode.success),
            "parent personality document unavailable",
          ))
          use through <- result.try(case kind {
            Task(_) -> Ok(0)
            Fork -> mapped_boundary(db, parent, child, binding.3)
          })
          let choices =
            option.map(selected, fn(enabled) { [#("personality", enabled)] })
            |> option.unwrap([])
          let choices = case
            kind,
            selected,
            list.key_find(flags, "lcm-memory")
          {
            Task(_), Some(True), Ok(enabled) -> [
              #("lcm-memory", enabled),
              ..choices
            ]
            _, _, _ -> choices
          }
          insert_in(db, child, binding.0, through, choices)
        }
        Ok(_) -> Error("duplicate parent personality binding")
      }
    }
  }
}

fn missing_binding_in(
  db: sqlight.Connection,
  parent: String,
  explicit: Option(Bool),
) -> Result(Nil, String) {
  case explicit {
    Some(_) -> Error("personality binding storage unavailable")
    None -> {
      // Native strategy replacement can remove the bundle pin. Surviving
      // binding history still proves this parent must not silently lose self.
      // Ordinary unrelated sessions remain independent of damaged optional data.
      use exists <- result.try(store.one(
        db,
        "SELECT EXISTS(SELECT 1 FROM main.sqlite_master WHERE name='personality_binding_revision' AND type='table')",
        [],
        decode.field(0, decode.int, decode.success),
        "binding history schema lookup failed",
      ))
      case exists {
        0 -> Ok(Nil)
        _ ->
          case
            store.rows(
              db,
              "SELECT 1 FROM personality_binding_revision WHERE session=? LIMIT 1",
              [sqlight.text(parent)],
              decode.field(0, decode.int, decode.success),
            )
          {
            Ok([1]) -> Error("personality binding storage unavailable")
            _ -> Ok(Nil)
          }
      }
    }
  }
}

fn mapped_boundary(
  db: sqlight.Connection,
  parent: String,
  child: String,
  through: Int,
) -> Result(Int, String) {
  // Global seqs can have gaps. Native fork copies rows in order; the first N
  // branch rows correspond to N parent rows through its witnessed boundary.
  store.one(
    db,
    "SELECT COALESCE(MAX(seq),0) FROM (SELECT seq FROM transcript WHERE session=? ORDER BY seq LIMIT (SELECT COUNT(*) FROM transcript WHERE session=? AND seq<=?))",
    [sqlight.text(child), sqlight.text(parent), sqlight.int(through)],
    decode.field(0, decode.int, decode.success),
    "fork binding boundary unavailable",
  )
}

fn insert_in(
  db: sqlight.Connection,
  child: String,
  persona: String,
  through: Int,
  choices: List(#(String, Bool)),
) -> Result(Nil, String) {
  // Delegate is a provenance/continuity role, not a document-write ACL.
  // Native forks have no family row but must not become automatic owner sources.
  use _ <- result.try(
    store.run(
      db,
      "INSERT INTO personality_session(session,persona_id,mode,generation,pre_binding_through) VALUES(?,?,'delegate',1,?)",
      [sqlight.text(child), sqlight.text(persona), sqlight.int(through)],
    ),
  )
  use _ <- result.try(
    store.run(
      db,
      "INSERT INTO personality_binding_revision(session,generation,persona_id,mode,pre_binding_through,created_at) VALUES(?,1,?,'delegate',?,?)",
      [
        sqlight.text(child),
        sqlight.text(persona),
        sqlight.int(through),
        sqlight.int(clock.system_ms()),
      ],
    ),
  )
  // Only this bundle and an existing explicit required-memory override follow
  // a fresh task. Forks already copied native selection; no general capability
  // selection or promise state is inherited here.
  list.try_each(choices, fn(choice) {
    store.run(
      db,
      "INSERT INTO session_extensions(session,name,enabled) VALUES(?,?,?) ON CONFLICT(session,name) DO UPDATE SET enabled=excluded.enabled",
      [sqlight.text(child), sqlight.text(choice.0), sqlight.bool(choice.1)],
    )
  })
}
