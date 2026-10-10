//// Agent-owned Python execution. The store owns receipts; this coordinator
//// owns temporary execution actors, each of which owns exactly one interpreter.
//// No namespace replay and no workspace-family moves are implicit here.

import gleam/dict
import gleam/erlang/process.{type Monitor, type Pid, type Subject, ProcessDown}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/factory_supervisor as factory
import gleam/otp/supervision
import gleam/result
import gleam/string
import successor/calls
import successor/ids
import successor/python
import successor/store
import successor/workspace_types as types

pub type Policy {
  Policy(max_live_kernels: Int)
}

pub fn default_policy() -> Policy {
  Policy(16)
}

pub type Msg {
  Root(
    session: ids.SessionId,
    name: String,
    reply: Subject(Result(types.AgentWorkspace, String)),
  )
  Child(
    parent: ids.AgentId,
    name: String,
    reply: Subject(Result(types.AgentWorkspace, String)),
  )
  Execute(
    agent: ids.AgentId,
    source: String,
    limits: python.Limits,
    reply: Subject(Result(types.Cell, String)),
  )
  Close(agent: ids.AgentId, reply: Subject(Result(Nil, String)))
  KernelPid(agent: ids.AgentId, reply: Subject(Result(Int, String)))
  ExecutorOwner(agent: ids.AgentId, reply: Subject(Result(Pid, String)))
  Began(agent: ids.AgentId, pid: Pid, id: String)
  Completed(
    agent: ids.AgentId,
    pid: Pid,
    reply: Subject(Result(types.Cell, String)),
    result: Result(types.Cell, String),
    retire: Bool,
  )
  WorkerDown(pid: Pid)
  IgnoreDown
}

type Worker {
  Worker(
    subject: Subject(ExecMsg),
    pid: Pid,
    monitor: Monitor,
    busy: Bool,
    closing: Bool,
    pending: Option(Subject(Result(types.Cell, String))),
    cell_id: Option(String),
    completed: Option(Result(types.Cell, String)),
    closes: List(Subject(Result(Nil, String))),
  )
}

type Pool {
  Pool(
    self: Subject(Msg),
    store: Subject(store.Msg),
    data_dir: String,
    factory: factory.Supervisor(ExecSpec, Subject(ExecMsg)),
    workers: dict.Dict(String, Worker),
    policy: Policy,
  )
}

type ExecSpec {
  ExecSpec(
    pool: Subject(Msg),
    store: Subject(store.Msg),
    agent: ids.AgentId,
    path: String,
  )
}

type ExecMsg {
  Run(
    source: String,
    limits: python.Limits,
    reply: Subject(Result(types.Cell, String)),
  )
  Finished(
    id: String,
    incarnation: ids.AgentIncarnationId,
    outcome: Result(python.Outcome, String),
  )
  DispatchDown(pid: Pid)
  IgnoreDispatchDown
  Stop
  PidRequest(reply: Subject(Result(Int, String)))
}

type Active {
  Active(
    cell: types.Cell,
    reply: Subject(Result(types.Cell, String)),
    dispatch: Pid,
    monitor: Monitor,
  )
}

type Executor {
  Executor(
    self: Subject(ExecMsg),
    spec: ExecSpec,
    kernel: Option(python.Kernel),
    incarnation: ids.AgentIncarnationId,
    active: Option(Active),
  )
}

pub fn start(
  store: Subject(store.Msg),
  data_dir: String,
  name: process.Name(Msg),
) -> actor.StartResult(Subject(Msg)) {
  start_with_policy(store, data_dir, name, default_policy())
}

pub fn start_with_policy(
  store: Subject(store.Msg),
  data_dir: String,
  name: process.Name(Msg),
  policy: Policy,
) -> actor.StartResult(Subject(Msg)) {
  case policy.max_live_kernels > 0 {
    False ->
      Error(actor.InitFailed("workspace kernel capacity must be positive"))
    True ->
      actor.new_with_initialiser(10_000, fn(subject) {
        use _ <- result.try(ask_store(store, store.RecoverWorkspaces))
        use supervised <- result.try(
          factory.worker_child(start_executor)
          |> factory.restart_strategy(supervision.Temporary)
          |> factory.start
          |> result.map_error(fn(_) { "workspace factory failed to start" }),
        )
        let selector =
          process.new_selector()
          |> process.select_map(subject, fn(msg) { msg })
          |> process.select_monitors(fn(down) {
            case down {
              ProcessDown(_, pid, _) -> WorkerDown(pid)
              _ -> IgnoreDown
            }
          })
        Ok(
          actor.initialised(Pool(
            subject,
            store,
            data_dir,
            supervised.data,
            dict.new(),
            policy,
          ))
          |> actor.selecting(selector)
          |> actor.returning(subject),
        )
      })
      |> actor.named(name)
      |> actor.on_message(handle_pool)
      |> actor.start
  }
}

fn handle_pool(state: Pool, msg: Msg) -> actor.Next(Pool, Msg) {
  case msg {
    Root(session, name, reply) -> {
      process.send(
        reply,
        ask_store(state.store, store.EnsureRootWorkspace(session, name, _)),
      )
      actor.continue(state)
    }
    Child(parent, name, reply) -> {
      process.send(
        reply,
        ask_store(state.store, store.CreateChildWorkspace(parent, name, _)),
      )
      actor.continue(state)
    }
    Execute(agent, source, limits, reply) -> {
      case validate(source, limits) {
        Error(error) -> {
          process.send(reply, Error(error))
          actor.continue(state)
        }
        Ok(_) ->
          case ensure_executor(state, agent) {
            Error(error) -> {
              process.send(reply, Error(error))
              actor.continue(state)
            }
            Ok(#(next, worker)) ->
              case worker.busy || worker.closing {
                True -> {
                  process.send(
                    reply,
                    Error("Python workspace is busy or closing"),
                  )
                  actor.continue(next)
                }
                False -> {
                  let admitted =
                    Worker(..worker, busy: True, pending: Some(reply))
                  process.send(worker.subject, Run(source, limits, reply))
                  actor.continue(
                    Pool(
                      ..next,
                      workers: dict.insert(next.workers, agent.value, admitted),
                    ),
                  )
                }
              }
          }
      }
    }
    KernelPid(agent, reply) -> {
      case dict.get(state.workers, agent.value) {
        Ok(worker) ->
          case worker.closing || !process.is_alive(worker.pid) {
            True -> process.send(reply, Ok(0))
            False -> process.send(worker.subject, PidRequest(reply))
          }
        Error(_) -> process.send(reply, Ok(0))
      }
      actor.continue(state)
    }
    ExecutorOwner(agent, reply) -> {
      let result = case dict.get(state.workers, agent.value) {
        Ok(worker) ->
          case worker.closing {
            True -> Error("workspace is closing")
            False -> Ok(worker.pid)
          }
        Error(_) -> Error("workspace has no executor")
      }
      process.send(reply, result)
      actor.continue(state)
    }
    Close(agent, reply) -> {
      case dict.get(state.workers, agent.value) {
        Error(_) -> {
          process.send(reply, Ok(Nil))
          actor.continue(state)
        }
        Ok(worker) -> {
          let closing =
            Worker(..worker, closing: True, closes: [reply, ..worker.closes])
          case worker.closing {
            False -> process.send(worker.subject, Stop)
            True -> Nil
          }
          // The pool keeps serving other agents. A replacement for this identity
          // is refused until DOWN and durable uncertainty classification.
          actor.continue(
            Pool(
              ..state,
              workers: dict.insert(state.workers, agent.value, closing),
            ),
          )
        }
      }
    }
    Began(agent, pid, id) -> {
      case dict.get(state.workers, agent.value) {
        Ok(worker) ->
          case worker.pid == pid && worker.busy {
            True ->
              actor.continue(
                Pool(
                  ..state,
                  workers: dict.insert(
                    state.workers,
                    agent.value,
                    Worker(..worker, cell_id: Some(id)),
                  ),
                ),
              )
            False -> actor.continue(state)
          }
        Error(_) -> actor.continue(state)
      }
    }
    Completed(agent, pid, reply, result, retire) -> {
      case dict.get(state.workers, agent.value) {
        Ok(worker) ->
          case worker.pid == pid && worker.pending == Some(reply) {
            False -> actor.continue(state)
            True ->
              case retire {
                True ->
                  actor.continue(
                    Pool(
                      ..state,
                      workers: dict.insert(
                        state.workers,
                        agent.value,
                        Worker(..worker, closing: True, completed: Some(result)),
                      ),
                    ),
                  )
                False -> {
                  process.send(reply, result)
                  actor.continue(
                    Pool(
                      ..state,
                      workers: dict.insert(
                        state.workers,
                        agent.value,
                        Worker(
                          ..worker,
                          busy: False,
                          pending: None,
                          cell_id: None,
                        ),
                      ),
                    ),
                  )
                }
              }
          }
        Error(_) -> actor.continue(state)
      }
    }
    WorkerDown(pid) -> {
      case
        list.find(dict.to_list(state.workers), fn(pair) { pair.1.pid == pid })
      {
        Error(_) -> actor.continue(state)
        Ok(#(key, worker)) -> {
          process.demonitor_process(worker.monitor)
          let classified =
            ask_store(state.store, store.ActivateWorkspace(
              ids.AgentId(key),
              ids.new_agent_incarnation_id(),
              _,
            ))
          case worker.pending {
            None -> Nil
            Some(reply) -> {
              let outcome = case worker.completed {
                Some(result) -> result
                None -> {
                  let id = case worker.cell_id {
                    Some(id) -> "cell " <> id <> ": "
                    None -> ""
                  }
                  Error(
                    id
                    <> "workspace owner died; outcome unknown, inspect before retry",
                  )
                }
              }
              process.send(reply, outcome)
            }
          }
          list.each(worker.closes, fn(reply) { process.send(reply, classified) })
          actor.continue(
            Pool(..state, workers: dict.delete(state.workers, key)),
          )
        }
      }
    }
    IgnoreDown -> actor.continue(state)
  }
}

fn ensure_executor(
  state: Pool,
  agent: ids.AgentId,
) -> Result(#(Pool, Worker), String) {
  case dict.get(state.workers, agent.value) {
    Ok(worker) ->
      case process.is_alive(worker.pid) {
        True -> Ok(#(state, worker))
        False ->
          Error(
            "workspace owner exited; inspect journal before further admission",
          )
      }
    Error(_) -> create_executor(state, agent)
  }
}

fn create_executor(
  state: Pool,
  agent: ids.AgentId,
) -> Result(#(Pool, Worker), String) {
  use _ <- result.try(ask_store(state.store, store.GetWorkspace(agent, _)))
  use path <- result.try(workspace_path(state.data_dir, agent))
  case dict.size(state.workers) >= state.policy.max_live_kernels {
    True ->
      Error("live Python workspace capacity reached; close an idle workspace")
    False -> {
      use started <- result.try(
        factory.start_child(
          state.factory,
          ExecSpec(state.self, state.store, agent, path),
        )
        |> result.map_error(fn(_) { "workspace executor failed to start" }),
      )
      let worker =
        Worker(
          started.data,
          started.pid,
          process.monitor(started.pid),
          False,
          False,
          None,
          None,
          None,
          [],
        )
      Ok(#(
        Pool(..state, workers: dict.insert(state.workers, agent.value, worker)),
        worker,
      ))
    }
  }
}

/// The path comes from a durable identity, never a display name or project CWD.
pub fn workspace_path(
  data_dir: String,
  agent: ids.AgentId,
) -> Result(String, String) {
  let safe =
    agent.value != ""
    && list.all(string.to_graphemes(agent.value), fn(char) {
      string.contains(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-",
        char,
      )
    })
  case safe {
    True -> Ok(data_dir <> "/agents/" <> agent.value <> "/workspace")
    False -> Error("invalid workspace agent identity")
  }
}

fn start_executor(spec: ExecSpec) -> actor.StartResult(Subject(ExecMsg)) {
  actor.new_with_initialiser(10_000, fn(subject) {
    let selector =
      process.new_selector()
      |> process.select_map(subject, fn(msg) { msg })
      |> process.select_monitors(fn(down) {
        case down {
          ProcessDown(_, pid, _) -> DispatchDown(pid)
          _ -> IgnoreDispatchDown
        }
      })
    Ok(
      actor.initialised(Executor(
        subject,
        spec,
        None,
        ids.new_agent_incarnation_id(),
        None,
      ))
      |> actor.selecting(selector)
      |> actor.returning(subject),
    )
  })
  |> actor.on_message(handle_executor)
  |> actor.start
}

fn handle_executor(
  state: Executor,
  msg: ExecMsg,
) -> actor.Next(Executor, ExecMsg) {
  case msg {
    Run(source, limits, reply) ->
      case state.active {
        Some(_) -> {
          process.send(reply, Error("Python workspace is busy"))
          actor.continue(state)
        }
        None ->
          case prepare_kernel(state) {
            Error(error) -> {
              complete(state, reply, Error(error), True)
              actor.stop()
            }
            Ok(prepared) -> begin(prepared, source, limits, reply)
          }
      }
    Finished(id, incarnation, outcome) ->
      case state.active {
        Some(active) ->
          case active.cell.id == id && active.cell.incarnation == incarnation {
            True -> finish(state, active, outcome)
            False -> actor.continue(state)
          }
        None -> actor.continue(state)
      }
    DispatchDown(pid) ->
      case state.active {
        Some(active) ->
          case active.dispatch == pid {
            True ->
              finish(
                state,
                active,
                Ok(python.Unknown(
                  "Python dispatch died; effects may have occurred",
                )),
              )
            False -> actor.continue(state)
          }
        None -> actor.continue(state)
      }
    IgnoreDispatchDown -> actor.continue(state)
    PidRequest(reply) -> {
      let pid = case state.kernel {
        Some(kernel) -> python.os_pid(kernel)
        None -> 0
      }
      process.send(reply, Ok(pid))
      actor.continue(state)
    }
    Stop -> {
      close_kernel(state.kernel)
      case state.active {
        None -> Nil
        Some(active) -> {
          process.demonitor_process(active.monitor)
          let cell =
            terminal(
              active.cell,
              python.Unknown(
                "workspace closed during execution; inspect effects",
              ),
            )
          let saved = ask_store(state.spec.store, store.SettleCell(cell, _))
          complete(
            state,
            active.reply,
            case saved {
              Ok(_) -> Ok(cell)
              Error(error) -> Error(receipt_error(cell.id, error))
            },
            True,
          )
        }
      }
      actor.stop()
    }
  }
}

fn prepare_kernel(state: Executor) -> Result(Executor, String) {
  case state.kernel {
    Some(_) -> Ok(state)
    None -> {
      let incarnation = ids.new_agent_incarnation_id()
      use _ <- result.try(
        ask_store(state.spec.store, store.ActivateWorkspace(
          state.spec.agent,
          incarnation,
          _,
        )),
      )
      use kernel <- result.try(python.start(state.spec.path))
      Ok(Executor(..state, kernel: Some(kernel), incarnation: incarnation))
    }
  }
}

fn begin(
  state: Executor,
  source: String,
  limits: python.Limits,
  reply: Subject(Result(types.Cell, String)),
) -> actor.Next(Executor, ExecMsg) {
  let cell =
    types.Cell(
      ids.fresh(prefix: "cell"),
      state.spec.agent,
      state.incarnation,
      source,
      types.Intent,
      "",
      False,
      None,
    )
  case ask_store(state.spec.store, store.BeginCell(cell, _)) {
    Error(error) -> {
      close_kernel(state.kernel)
      complete(
        state,
        reply,
        Error(
          "cell "
          <> cell.id
          <> ": intent not acknowledged; source not dispatched: "
          <> error,
        ),
        True,
      )
      actor.stop()
    }
    Ok(_) -> {
      process.send(
        state.spec.pool,
        Began(state.spec.agent, process.self(), cell.id),
      )
      let assert Some(kernel) = state.kernel
      let target = state.self
      let dispatch =
        spawn_unlinked(fn() {
          let outcome = python.execute(kernel, cell.id, source, limits)
          process.send(target, Finished(cell.id, cell.incarnation, outcome))
        })
      let active = Active(cell, reply, dispatch, process.monitor(dispatch))
      actor.continue(Executor(..state, active: Some(active)))
    }
  }
}

fn finish(
  state: Executor,
  active: Active,
  outcome: Result(python.Outcome, String),
) -> actor.Next(Executor, ExecMsg) {
  process.demonitor_process(active.monitor)
  let result = case outcome {
    Ok(value) -> value
    Error(reason) -> python.Unknown("Python transport lost: " <> reason)
  }
  let cell = terminal(active.cell, result)
  let saved = ask_store(state.spec.store, store.SettleCell(cell, _))
  let preserve = cell.state != types.OutcomeUnknown && saved == Ok(Nil)
  let kernel = case preserve {
    True -> state.kernel
    False -> {
      close_kernel(state.kernel)
      None
    }
  }
  complete(
    state,
    active.reply,
    case saved {
      Ok(_) -> Ok(cell)
      Error(error) -> Error(receipt_error(cell.id, error))
    },
    !preserve,
  )
  case preserve {
    True -> actor.continue(Executor(..state, active: None, kernel: kernel))
    False -> actor.stop()
  }
}

fn terminal(cell: types.Cell, outcome: python.Outcome) -> types.Cell {
  case outcome {
    python.Succeeded(output, truncated) ->
      types.Cell(
        ..cell,
        state: types.Succeeded,
        output: output,
        truncated: truncated,
      )
    python.Failed(output, truncated, error) ->
      types.Cell(
        ..cell,
        state: types.Failed,
        output: output,
        truncated: truncated,
        error: Some(error),
      )
    python.Unknown(reason) ->
      types.Cell(..cell, state: types.OutcomeUnknown, error: Some(reason))
  }
}

fn receipt_error(id: String, reason: String) -> String {
  "cell "
  <> id
  <> ": terminal receipt not acknowledged; inspect before any retry: "
  <> reason
}

fn validate(source: String, limits: python.Limits) -> Result(Nil, String) {
  case
    limits.timeout_ms < 1
    || limits.timeout_ms > 4_294_937_295
    || limits.max_source_bytes < 0
    || limits.max_output_bytes < 0
    || limits.max_output_bytes > python.max_output_bytes_limit
    || string.byte_size(source) > limits.max_source_bytes
  {
    True -> Error("invalid Python limits or source exceeds its byte limit")
    False -> Ok(Nil)
  }
}

fn close_kernel(kernel: Option(python.Kernel)) -> Nil {
  case kernel {
    Some(value) -> python.close(value)
    None -> Nil
  }
}

fn complete(
  state: Executor,
  reply: Subject(Result(types.Cell, String)),
  result: Result(types.Cell, String),
  retire: Bool,
) -> Nil {
  process.send(
    state.spec.pool,
    Completed(state.spec.agent, process.self(), reply, result, retire),
  )
}

fn ask_store(
  store: Subject(store.Msg),
  request: fn(Subject(Result(a, String))) -> store.Msg,
) -> Result(a, String) {
  case calls.call(store, request, 5000) {
    Ok(result) -> result
    Error(error) -> Error(error)
  }
}

pub fn root(
  pool: Subject(Msg),
  session: ids.SessionId,
  name: String,
) -> Result(types.AgentWorkspace, String) {
  call(pool, Root(session, name, _), 10_000)
}

pub fn child(
  pool: Subject(Msg),
  parent: ids.AgentId,
  name: String,
) -> Result(types.AgentWorkspace, String) {
  call(pool, Child(parent, name, _), 10_000)
}

pub fn execute(
  pool: Subject(Msg),
  agent: ids.AgentId,
  source: String,
  limits: python.Limits,
) -> Result(types.Cell, String) {
  use _ <- result.try(validate(source, limits))
  call(pool, Execute(agent, source, limits, _), limits.timeout_ms + 30_000)
}

pub fn close(pool: Subject(Msg), agent: ids.AgentId) -> Result(Nil, String) {
  call(pool, Close(agent, _), 20_000)
}

pub fn kernel_pid(
  pool: Subject(Msg),
  agent: ids.AgentId,
) -> Result(Int, String) {
  call(pool, KernelPid(agent, _), 10_000)
}

/// Diagnostic only: this PID is not a durable identity or recovery handle.
pub fn executor_owner(
  pool: Subject(Msg),
  agent: ids.AgentId,
) -> Result(Pid, String) {
  call(pool, ExecutorOwner(agent, _), 10_000)
}

pub fn inspect(
  store: Subject(store.Msg),
  id: String,
) -> Result(types.Cell, String) {
  ask_store(store, store.GetCell(id, _))
}

pub fn cells(
  store: Subject(store.Msg),
  agent: ids.AgentId,
) -> Result(List(types.Cell), String) {
  ask_store(store, store.ListCells(agent, _))
}

fn call(
  pool: Subject(Msg),
  request: fn(Subject(Result(a, String))) -> Msg,
  timeout: Int,
) -> Result(a, String) {
  case calls.call(pool, request, timeout) {
    Ok(result) -> result
    Error(error) -> Error(error)
  }
}

@external(erlang, "successor_ffi", "spawn_unlinked")
fn spawn_unlinked(run: fn() -> Nil) -> Pid
