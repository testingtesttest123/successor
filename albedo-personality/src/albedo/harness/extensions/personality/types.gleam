//// Durable identity values. Authority comes from the authenticated adapter.

import gleam/option.{type Option}

pub type DomainError {
  Invalid(String)
  Conflict(String)
  RevisionConflict(Heads)
  RecordConflict(String, Int)
  SourceUnavailable(String)
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
  Snapshot(
    persona: Persona,
    binding: Binding,
    candidates: List(Record),
    eligible_count: Int,
  )
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
    memories: List(MemoryChange),
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
    records: List(#(String, Int)),
  )
}

pub type Editing {
  Editing(
    controls: Controls,
    ordinary_bytes: Int,
    corrective_bytes: Int,
    ordinary_limit: Int,
    corrective_limit: Int,
    current_records: Int,
    record_limit: Int,
  )
}

/// Input refs have empty trusted fields. Resolution derives all attribution.
pub type SourceRef {
  SourceRef(
    id: String,
    session: String,
    first_seq: Int,
    last_seq: Int,
    digest: String,
    actors: List(String),
    origin: String,
    binding_revision: Int,
    pre_binding_through: Int,
    lcm_hint: Option(String),
    availability: String,
  )
}

pub type Evidence {
  Evidence(relation: String, source: SourceRef)
}

pub type MemoryChange {
  MemoryChange(
    id: String,
    expected_revision: Int,
    action: String,
    text: String,
    provenance: String,
    uncertainty: String,
    importance: Int,
    tags: List(String),
    temporal_scope: String,
    sources: List(Evidence),
  )
}

pub type Memory {
  Memory(
    id: String,
    revision: Int,
    lifecycle: String,
    text: String,
    provenance: String,
    uncertainty: String,
    importance: Int,
    tags: List(String),
    temporal_scope: String,
    author: String,
    origin_session: String,
    event_id: Int,
    reason: String,
    unresolved: Bool,
    sources: List(Evidence),
    claim: ClaimAttribution,
  )
}

/// Whole-revision labels survive evidence fragmentation. Exact actor names
/// remain in separately paged evidence, identified here without truncation.
pub type ClaimAttribution {
  ClaimAttribution(
    origins: List(String),
    actor_kinds: List(String),
    source_ids: List(String),
  )
}

/// Inspection fragments preserve labels and exact pointers, never clip origins.
pub type Page {
  Page(records: List(Memory), fragment: Int, next: Option(String), bytes: Int)
}

pub type SourcePage {
  SourcePage(text: String, source: SourceRef, next: Option(String), bytes: Int)
}

/// Open/due are typed relevance supplied by the commitment domain, never tags.
/// Current curated-memory capture sets both false until that domain exists.
pub type Record {
  Record(
    memory: Memory,
    pinned: Bool,
    open_commitment: Bool,
    due: Bool,
    related_unresolved_ids: List(String),
  )
}

pub type Episode {
  Episode(source: SourceRef, summary: String, scalar_offset: Int)
}

pub type EpisodePage {
  EpisodePage(records: List(Episode), next: Option(String), bytes: Int)
}
