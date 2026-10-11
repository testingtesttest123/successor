//// Living identity values. Native authenticated adapters supply actor authority.

import gleam/option.{type Option}

pub type DomainError {
  Invalid(String)
  Conflict(String)
  RevisionConflict(Int)
  Forbidden(String)
  CallReused
  NotFound
  SetupRequired
  Storage(String)
}

pub type Persona {
  Persona(
    id: String,
    name: String,
    identity_revision: Int,
    document: String,
    writable: Bool,
  )
}

pub type Binding {
  Binding(
    session: String,
    persona_id: String,
    mode: String,
    generation: Int,
    pre_binding_through: Int,
  )
}

pub type Captured {
  Captured(persona: Persona, binding: Binding)
}

/// Transport identities come from authenticated HTTP or tool context, never
/// model arguments. Human retry keys are ordinary transport metadata.
pub type Actor {
  User(retry_key: String)
  OwnerAgent(call_id: String)
}

pub type Receipt {
  Receipt(
    persona_id: String,
    identity_revision: Int,
    actor: String,
    origin_session: String,
    call_id: String,
  )
}

pub type DocumentPage {
  DocumentPage(revision: Int, text: String, next_offset: Option(Int))
}

pub type Inspection {
  Inspection(
    binding: Option(Binding),
    persona: Option(Persona),
    history_through: Int,
    history_count: Int,
    default_persona: Option(String),
    owner_sessions: List(String),
    identity_choices: List(#(String, String)),
  )
}
