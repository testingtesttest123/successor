//// Session-owned native memory work, separate from foreground turn.Activity.
//// Only durable host notifications advance its watermark. No state is stored
//// here across restart: ordinary actor load reconsiders durable graph/source.

import albedo/daemon/store
import albedo/daemon/turn
import gleam/erlang/process
import gleam/int
import gleam/option.{type Option, None, Some}

pub type Job {
  Job(
    generation: Int,
    watermark: Int,
    pid: process.Pid,
    monitor: process.Monitor,
    stop: turn.Latch,
    outcome: Option(Result(Bool, String)),
  )
}

pub type Memory {
  Memory(
    generation: Int,
    watermark: Int,
    attempted: Int,
    again: Bool,
    job: Option(Job),
  )
}

pub fn new(watermark: Int) -> Memory {
  Memory(0, watermark, -1, False, None)
}

pub fn notify(memory: Memory, watermark: Int) -> Memory {
  Memory(..memory, watermark: int.max(memory.watermark, watermark))
}

pub fn needed(memory: Memory) -> Bool {
  memory.job == None && { memory.again || memory.watermark > memory.attempted }
}

/// An unselected session or a refused preparation stops this watermark.
pub fn quiet(memory: Memory) -> Memory {
  Memory(..memory, attempted: memory.watermark, again: False)
}

/// Successful native composition adoption can finish after a preparation
/// deadline. Reconsider that same watermark without cancelling a healthy job.
pub fn rearm(memory: Memory) -> Memory {
  Memory(..memory, again: True)
}

/// A late host completion belongs to its captured lifecycle, even after the
/// original worker's deadline. Cancelled/stale completions cannot rearm it.
pub fn composition_ready(
  memory: Memory,
  generation: Int,
  stop: turn.Latch,
) -> Memory {
  case generation == memory.generation && !turn.raised(stop) {
    True -> rearm(memory)
    False -> memory
  }
}

/// The actor supplies a host worker, never a model-controlled task callback.
pub fn start(
  memory: Memory,
  starter: fn(Int, turn.Latch) -> process.Pid,
) -> Memory {
  case needed(memory) {
    False -> memory
    True -> {
      let stop = turn.latch()
      let pid = starter(memory.generation, stop)
      Memory(
        ..memory,
        again: False,
        job: Some(Job(
          memory.generation,
          memory.watermark,
          pid,
          process.monitor(pid),
          stop,
          None,
        )),
      )
    }
  }
}

pub fn finished(
  memory: Memory,
  generation: Int,
  pid: process.Pid,
  outcome: Result(Bool, String),
) -> Memory {
  case memory.job {
    Some(job) if job.pid == pid && job.generation == generation ->
      case generation == memory.generation && !turn.raised(job.stop) {
        True -> Memory(..memory, job: Some(Job(..job, outcome: Some(outcome))))
        False -> memory
      }
    _ -> memory
  }
}

/// Keep even a cancelled slot occupied until its exact monitor terminates.
/// True asks the actor to enqueue another tick, yielding through its mailbox.
pub fn down(memory: Memory, down: process.Down) -> #(Memory, Bool) {
  case memory.job, down {
    Some(job), process.ProcessDown(monitor, pid, _)
      if job.pid == pid && job.monitor == monitor
    -> {
      let current = job.generation == memory.generation
      let again = memory.again || { current && job.outcome == Some(Ok(True)) }
      let attempted = case current {
        True -> job.watermark
        False -> memory.attempted
      }
      let next = Memory(..memory, job: None, attempted:, again:)
      #(next, needed(next))
    }
    _, _ -> #(memory, False)
  }
}

/// Raise before any teardown. The stoppable native provider can return and
/// account for its attempt; its retiring slot still prevents another worker.
pub fn invalidate(memory: Memory) -> Memory {
  case memory.job {
    Some(job) -> turn.raise(job.stop)
    None -> Nil
  }
  Memory(
    ..memory,
    generation: memory.generation + 1,
    attempted: -1,
    again: False,
  )
}

pub fn active(owner: process.Pid, stop: turn.Latch) -> Bool {
  !turn.raised(stop) && process.is_alive(owner)
}

/// Close linearizes after all previously queued store closures. A closure
/// whose caller died still runs, but its raised liveness guard refuses a graph
/// write. A transaction already past its guard finishes before this fence.
pub fn close(memory: Memory, ledger: store.Store) -> Result(Nil, String) {
  let _ = invalidate(memory)
  case memory.job {
    None -> Nil
    Some(job) -> {
      // Give a returned provider result time to enter native accounting. An
      // idle provider is cancelled by stoppable's 25ms latch poll.
      let selector =
        process.new_selector()
        |> process.select_specific_monitor(job.monitor, fn(_) { Nil })
      case process.selector_receive(selector, 100) {
        Ok(_) -> Nil
        Error(_) -> {
          process.kill(job.pid)
          let _ = process.selector_receive(selector, 1000)
          Nil
        }
      }
      process.demonitor_process(job.monitor)
    }
  }
  store.query(ledger, fn(_) { Ok(Nil) })
}
