//// Durable identities and journal values for agent-owned Python workspaces.
////
//// These values describe trusted local execution. They do not claim sandboxing
//// or model-driven subagent inference.

import gleam/option.{type Option}
import successor/ids

pub type AgentWorkspace {
  AgentWorkspace(
    id: ids.AgentId,
    session: ids.SessionId,
    parent: Option(ids.AgentId),
    name: String,
    incarnation: Option(ids.AgentIncarnationId),
  )
}

pub type CellState {
  Intent
  Succeeded
  Failed
  OutcomeUnknown
}

pub type Cell {
  Cell(
    id: String,
    agent: ids.AgentId,
    incarnation: ids.AgentIncarnationId,
    source: String,
    state: CellState,
    output: String,
    truncated: Bool,
    error: Option(String),
  )
}
