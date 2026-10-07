//// Session ownership is keyed by durable identity in OTP's child catalog.
//// Unlike a registry lookup followed by an anonymous factory start, the
//// supervisor atomically enforces one child per session even while the
//// registry is unavailable or a session is restarting.

import gleam/erlang/process.{type Name, type Pid}
import gleam/otp/actor
import successor/session

pub type Msg

pub opaque type Supervisor {
  Supervisor(name: Name(Msg))
}

pub type StartError {
  Restarting
  Unavailable
  StartFailed(String)
}

pub fn get_by_name(name: Name(Msg)) -> Supervisor {
  Supervisor(name)
}

pub fn start(name: Name(Msg)) -> actor.StartResult(Supervisor) {
  case start_otp(name) {
    Ok(pid) -> Ok(actor.Started(pid, Supervisor(name)))
    Error(reason) -> Error(actor.InitFailed(reason))
  }
}

/// Starting an already-running session is idempotent. A retained child
/// specification is restarted through OTP, never deleted and replaced.
/// An in-progress restart is reported as a retryable state.
pub fn start_child(
  supervisor: Supervisor,
  spec: session.Spec,
) -> Result(Nil, StartError) {
  start_otp_child(supervisor.name, spec.session.value, spec)
}

@external(erlang, "successor_session_supervisor", "start")
fn start_otp(name: Name(Msg)) -> Result(Pid, String)

@external(erlang, "successor_session_supervisor", "open")
fn start_otp_child(
  name: Name(Msg),
  id: String,
  spec: session.Spec,
) -> Result(Nil, StartError)

@external(erlang, "successor_session_supervisor", "count_children")
pub fn count_children(supervisor: Supervisor) -> Int
