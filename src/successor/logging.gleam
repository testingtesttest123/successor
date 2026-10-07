//// Structured logging (chapter 23.1A).
////
//// Single-line key=value events on stderr through one choke point, so the
//// format stays auditable and machine-parseable. Timestamps and pid fields
//// are added by the logger, not by call sites.

import gleam/int
import gleam/list
import gleam/string

@external(erlang, "successor_ffi", "now_ms")
pub fn now_ms() -> Int

pub type Field {
  Field(key: String, value: String)
}

pub fn field(key key: String, value value: String) -> Field {
  Field(key, value)
}

pub fn int_field(key key: String, value value: Int) -> Field {
  Field(key, int.to_string(value))
}

/// Emit one structured event. `event` names the behavior; fields carry the
/// structured payload. Never log secrets (provider keys, continuation
/// envelopes — chapter 20.5).
pub fn event(name name: String, fields fields: List(Field)) -> Nil {
  let rendered =
    fields
    |> list.map(fn(f: Field) { f.key <> "=" <> quote(f.value) })
    |> string.join(" ")
  let prefix =
    "[successor] ts=" <> int.to_string(now_ms()) <> " event=" <> quote(name)
  case rendered {
    "" -> io_println_error(prefix)
    _ -> io_println_error(prefix <> " " <> rendered)
  }
}

/// Info-level convenience.
pub fn info(name name: String, fields fields: List(Field)) -> Nil {
  event(name, [Field("level", "info"), ..fields])
}

/// Warn-level convenience.
pub fn warn(name name: String, fields fields: List(Field)) -> Nil {
  event(name, [Field("level", "warn"), ..fields])
}

/// Error-level convenience.
pub fn error(name name: String, fields fields: List(Field)) -> Nil {
  event(name, [Field("level", "error"), ..fields])
}

fn quote(value: String) -> String {
  case
    string.contains(value, " ") || string.contains(value, "=") || value == ""
  {
    True -> "\"" <> value <> "\""
    False -> value
  }
}

@external(erlang, "successor_ffi", "println_stderr")
fn io_println_error(line: String) -> Nil
