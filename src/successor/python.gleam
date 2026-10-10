//// A small, process-owned transport for trusted local Python workspaces.
////
//// Each Kernel is a persistent isolated-mode CPython interpreter. It is not a
//// filesystem or network sandbox; the limits protect the transport from
//// accidental runaway cells.

import gleam/string

pub type Kernel

pub const max_output_bytes_limit = 11_173_888

pub type Limits {
  Limits(timeout_ms: Int, max_source_bytes: Int, max_output_bytes: Int)
}

pub type Outcome {
  Succeeded(output: String, truncated: Bool)
  Failed(output: String, truncated: Bool, error: String)
  Unknown(reason: String)
}

pub fn default_limits() -> Limits {
  Limits(
    timeout_ms: 300_000,
    max_source_bytes: 1_048_576,
    max_output_bytes: 262_144,
  )
}

@external(erlang, "successor_python_ffi", "start")
pub fn start(workspace: String) -> Result(Kernel, String)

pub fn execute(
  kernel: Kernel,
  cell_id: String,
  source: String,
  limits: Limits,
) -> Result(Outcome, String) {
  case limits {
    Limits(timeout_ms, max_source_bytes, max_output_bytes) ->
      case
        timeout_ms < 1
        || timeout_ms > 4_294_937_295
        || max_source_bytes < 0
        || max_output_bytes < 0
        || max_output_bytes > max_output_bytes_limit
        || cell_id == ""
        || string.byte_size(cell_id) > 4096
        || string.byte_size(source) > max_source_bytes
      {
        True ->
          Error(
            "invalid cell id or limits (timeout must be 1..4294937295 ms and output at most 11173888 bytes), or source exceeds its byte limit",
          )
        False ->
          execute_native(kernel, cell_id, source, timeout_ms, max_output_bytes)
      }
  }
}

@external(erlang, "successor_python_ffi", "execute")
fn execute_native(
  kernel: Kernel,
  cell_id: String,
  source: String,
  timeout_ms: Int,
  max_output_bytes: Int,
) -> Result(Outcome, String)

@external(erlang, "successor_python_ffi", "close")
pub fn close(kernel: Kernel) -> Nil

@external(erlang, "successor_python_ffi", "os_pid")
pub fn os_pid(kernel: Kernel) -> Int
