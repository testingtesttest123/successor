//// Monitored, incarnation-pinned calls. A named handle is resolved once;
//// a request is never silently re-routed or re-sent across owner replacement.

import gleam/erlang/process.{type Pid, type Subject}
import gleam/result

type Event(a) {
  Reply(a)
  OwnerDown
}

pub fn call(
  subject: Subject(message),
  build: fn(Subject(a)) -> message,
  timeout: Int,
) -> Result(a, String) {
  use _ <- result.try(case timeout >= 0 && timeout <= 4_294_967_295 {
    True -> Ok(Nil)
    False -> Error("invalid request timer; not dispatched")
  })
  use owner <- result.try(
    process.subject_owner(subject)
    |> result.map_error(fn(_) { "request owner is unavailable; not dispatched" }),
  )
  let reply = process.new_subject()
  let monitor = process.monitor(owner)
  let selector =
    process.new_selector()
    |> process.select_map(reply, Reply)
    |> process.select_specific_monitor(monitor, fn(_) { OwnerDown })
  let outcome = case send_pinned(subject, owner, build(reply)) {
    Error(error) -> Error(error)
    Ok(_) ->
      case process.selector_receive(selector, timeout) {
        Ok(Reply(value)) -> Ok(value)
        Ok(OwnerDown) ->
          Error(
            "request owner died; acknowledgement unknown, inspect before retry",
          )
        Error(_) ->
          Error("request acknowledgement timed out; inspect before retry")
      }
  }
  process.demonitor_process(monitor)
  outcome
}

@external(erlang, "successor_calls_ffi", "send_pinned")
fn send_pinned(
  subject: Subject(message),
  owner: Pid,
  message: message,
) -> Result(Nil, String)
