//// Immutable projection boundaries; no compaction or strategy imports.

import gleam/option.{type Option}

pub type SourceBound {
  SourceBound(
    session: String,
    transcript_upper: Int,
    continuation_upper: Int,
    revision: Int,
    configuration_revision: Int,
  )
}

pub type SourceRange {
  SourceRange(
    first_seq: Int,
    last_seq: Int,
    first_position: Int,
    last_position: Int,
  )
}

pub type MissingLevelOne {
  MissingLevelOne(range: SourceRange, source_scope: SourceBound)
}

pub type Diagnostics {
  Diagnostics(
    hard_budget: Int,
    target_budget: Float,
    actual_tokens: Int,
    fixed_tokens: Int,
    raw_tokens: Int,
    recall_tokens: Int,
    available_levels: List(Int),
    attempted_levels: List(Int),
    perturbation: Float,
    override_reason: Option(String),
    recovery_failure: Option(String),
  )
}

pub type Failure {
  Rejected(message: String)
  OverBudget(diagnostics: Diagnostics, missing_l1: List(MissingLevelOne))
}
