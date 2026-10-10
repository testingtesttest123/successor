//// Durable identity values. Authority comes from the authenticated adapter.

import gleam/option.{type Option}

pub type DomainError {
  Invalid(String)
  Conflict(String)
  RevisionConflict(Heads)
  Forbidden(String)
  OperationIdReused
  CapacityExceeded
  NotFound
  SetupRequired
  Storage(String)
}

pub type Identity {
  Identity(
    self_description: String,
    values: String,
    communication: String,
    instructions: String,
  )
}

pub type Persona {
  Persona(
    id: String,
    name: String,
    state: String,
    revision: Int,
    identity_revision: Int,
    identity: Identity,
    agent_identity_edits: Bool,
    agent_memory_edits: Bool,
  )
}

pub type Binding {
  Binding(
    session: String,
    persona_id: String,
    mode: String,
    revision: Int,
    pre_binding_through: Int,
  )
}

pub type Snapshot {
  Snapshot(persona: Persona, binding: Binding)
}

pub type Creation {
  Creation(
    operation_id: String,
    name: String,
    make_default: Bool,
    agent_identity_edits: Bool,
    agent_memory_edits: Bool,
  )
}

pub type Bind {
  Bind(
    operation_id: String,
    persona_id: String,
    expected_revision: Int,
    acknowledge_history_through: Int,
  )
}

pub type Inspection {
  Inspection(
    binding: Option(Binding),
    persona: Option(Persona),
    binding_revision: Int,
    history_through: Int,
    history_count: Int,
    default_persona: Option(String),
  )
}

/// Only adapters construct these. No model input is decoded as an Actor.
pub type Actor {
  User
  OwnerAgent(call_id: String)
}

pub type Heads {
  Heads(revision: Int, identity_revision: Int)
}

pub type Controls {
  Controls(
    field_locks: List(String),
    agent_identity_edits: Bool,
    agent_memory_edits: Bool,
  )
}

pub type ControlChange {
  ControlChange(
    field_locks: Option(List(String)),
    agent_identity_edits: Option(Bool),
    agent_memory_edits: Option(Bool),
  )
}

pub type Mutation {
  Mutation(
    operation_id: String,
    expected_revision: Int,
    expected_identity_revision: Int,
    changes: List(#(String, String)),
    reason: String,
    controls: Option(ControlChange),
  )
}

pub type Edit {
  Edit(identity: Identity, controls: Controls, identity_changed: Bool)
}

pub type Receipt {
  Receipt(
    operation_id: String,
    persona_id: String,
    actor: String,
    origin_session: String,
    origin_call_id: Option(String),
    event_id: Int,
    revision: Int,
    identity_revision: Int,
    payload_hash: String,
  )
}

pub type Editing {
  Editing(
    controls: Controls,
    ordinary_bytes: Int,
    corrective_bytes: Int,
    ordinary_limit: Int,
    corrective_limit: Int,
  )
}
