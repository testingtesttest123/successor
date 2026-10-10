import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/otp/actor
import gleam/string
import successor/app
import successor/config
import successor/ids
import successor/providers/mock
import successor/python
import successor/registry
import successor/session
import successor/session_supervisor as factory
import successor/store
import successor/workspace_types as types
import successor/workspaces

pub fn real_namespaces_files_errors_and_environment_test() {
  set_env("SUCCESSOR_SYNTHETIC_SECRET", "must-not-reach-agent")
  let host = host()
  let assert Ok(sid) = app.start_session(host, "resident")
  let assert Ok(root) = app.root_workspace(host, sid)
  let assert Ok(root_again) = app.root_workspace(host, sid)
  assert root.id == root_again.id
  let assert Ok(a) = app.child_workspace(host, root.id, "same-label")
  let assert Ok(b) = app.child_workspace(host, root.id, "same-label")
  assert a.id != b.id && a.id != root.id
  assert a.parent == Some(root.id) && b.session == sid
  let limits = python.default_limits()
  let assert Ok(initial) =
    app.execute_python(
      host,
      root.id,
      "from pathlib import Path\nx = 40\nPath('retained.txt').write_text('root')\nx + 2",
      limits,
    )
  assert initial.state == types.Succeeded
  assert string.contains(initial.output, "42")
  let assert Ok(next) = app.execute_python(host, root.id, "x += 2\nx", limits)
  assert string.contains(next.output, "42")
  let assert Ok(failed) =
    app.execute_python(
      host,
      root.id,
      "x = 99\nraise ValueError('retained namespace')",
      limits,
    )
  assert failed.state == types.Failed
  let assert Ok(after) = app.execute_python(host, root.id, "x", limits)
  assert string.contains(after.output, "99")
  let assert Ok(separate) =
    app.execute_python(
      host,
      a.id,
      "from pathlib import Path\nassert 'x' not in globals()\nassert not Path('retained.txt').exists()\nx = 'child-a'\nPath('retained.txt').write_text('child-a')\nx",
      limits,
    )
  assert separate.state == types.Succeeded
  let assert Ok(other) =
    app.execute_python(
      host,
      b.id,
      "from pathlib import Path\nassert 'x' not in globals()\nassert not Path('retained.txt').exists()\nimport os\nassert 'SUCCESSOR_SYNTHETIC_SECRET' not in os.environ\nassert os.getcwd() == os.environ['HOME']\nprint(os.getcwd())",
      limits,
    )
  assert other.state == types.Succeeded
  let assert Ok(expected) =
    workspaces.workspace_path(host.config.data_dir, b.id)
  assert string.contains(other.output, expected)
  let assert Ok(saved) = app.inspect_python(host, initial.id)
  assert saved == initial
  let assert Ok(pid) = workspaces.kernel_pid(host.workspaces, root.id)
  assert pid > 0 && os_alive(pid)
  app.stop(host)
  assert wait_os_dead(pid, 200)
  unset_env("SUCCESSOR_SYNTHETIC_SECRET")
}

pub fn bounded_output_and_pre_dispatch_validation_test() {
  let host = host()
  let assert Ok(sid) = app.start_session(host, "bounds")
  let assert Ok(root) = app.root_workspace(host, sid)
  let limits = python.Limits(5000, 4096, 97)
  let assert Ok(result) =
    app.execute_python(host, root.id, "print('z' * 1000000)", limits)
  assert result.state == types.Succeeded && result.truncated
  assert string.byte_size(result.output) <= 97
  let assert Error(_) =
    app.execute_python(
      host,
      root.id,
      "open('not-dispatched','w').write('bad')",
      python.Limits(5000, 1, 97),
    )
  let assert Error(_) =
    app.execute_python(
      host,
      root.id,
      "open('bad-timer','w').write('wrong')",
      python.Limits(-100_000, 4096, 97),
    )
  let assert Error(_) =
    app.execute_python(
      host,
      root.id,
      "open('bad-timer','w').write('wrong')",
      python.Limits(4_294_937_296, 4096, 97),
    )
  let assert Ok(path) = workspaces.workspace_path(host.config.data_dir, root.id)
  assert !exists(path <> "/not-dispatched")
  assert !exists(path <> "/bad-timer")
  let assert Ok(cells) = workspaces.cells(host.store, root.id)
  assert list.length(cells) == 1
  app.stop(host)
}

pub fn excessive_output_limit_is_rejected_before_intent_test() {
  let host = host()
  let assert Ok(sid) = app.start_session(host, "output-limit")
  let assert Ok(root) = app.root_workspace(host, sid)
  let source =
    "from pathlib import Path\nPath('must-not-run').write_text('bad')"
  let limits = python.Limits(5000, 4096, python.max_output_bytes_limit + 1)
  let assert Error(_) = app.execute_python(host, root.id, source, limits)
  let assert Ok(path) = workspaces.workspace_path(host.config.data_dir, root.id)
  assert !exists(path <> "/must-not-run")
  let assert Ok(cells) = workspaces.cells(host.store, root.id)
  assert cells == []
  app.stop(host)
}

pub fn deadline_closes_kernel_and_new_incarnation_has_no_heap_test() {
  let host = host()
  let assert Ok(sid) = app.start_session(host, "deadline")
  let assert Ok(root) = app.root_workspace(host, sid)
  let assert Ok(first) =
    app.execute_python(host, root.id, "held = 123", python.default_limits())
  let assert Ok(pid) = workspaces.kernel_pid(host.workspaces, root.id)
  let assert Ok(timed) =
    app.execute_python(
      host,
      root.id,
      "from pathlib import Path\nPath('once.txt').write_text('once')\nimport time\ntime.sleep(10)",
      python.Limits(80, 4096, 1024),
    )
  assert timed.state == types.OutcomeUnknown
  assert wait_os_dead(pid, 200)
  let assert Ok(replacement) =
    app.execute_python(
      host,
      root.id,
      "assert 'held' not in globals()\nfrom pathlib import Path\nassert Path('once.txt').read_text() == 'once'\nprint('fresh')",
      python.default_limits(),
    )
  assert replacement.state == types.Succeeded
  assert replacement.incarnation != first.incarnation
  let assert Ok(inspected) = app.inspect_python(host, timed.id)
  assert inspected.state == types.OutcomeUnknown
  app.stop(host)
}

pub fn close_preserves_identity_files_and_receipts_test() {
  let host = host()
  let assert Ok(sid) = app.start_session(host, "close")
  let assert Ok(root) = app.root_workspace(host, sid)
  let assert Ok(cell) =
    app.execute_python(
      host,
      root.id,
      "value = 1\nfrom pathlib import Path\nPath('file.txt').write_text('retained')",
      python.default_limits(),
    )
  let assert Ok(pid) = workspaces.kernel_pid(host.workspaces, root.id)
  let assert Ok(_) = app.close_python(host, root.id)
  assert wait_os_dead(pid, 200)
  let assert Ok(again) = app.root_workspace(host, sid)
  assert again.id == root.id
  let assert Ok(saved) = app.inspect_python(host, cell.id)
  assert saved == cell
  let assert Ok(fresh) =
    app.execute_python(
      host,
      root.id,
      "assert 'value' not in globals()\nfrom pathlib import Path\nassert Path('file.txt').read_text() == 'retained'",
      python.default_limits(),
    )
  assert fresh.state == types.Succeeded && fresh.incarnation != cell.incarnation
  app.stop(host)
}

pub fn intent_is_visible_busy_is_refused_and_other_agent_runs_test() {
  let host = host()
  let assert Ok(sid) = app.start_session(host, "concurrency")
  let assert Ok(root) = app.root_workspace(host, sid)
  let assert Ok(child) = app.child_workspace(host, root.id, "independent")
  let response = process.new_subject()
  let _ =
    spawn_unlinked(fn() {
      process.send(
        response,
        app.execute_python(
          host,
          root.id,
          "from pathlib import Path\nPath('started').write_text('yes')\nimport time\ntime.sleep(0.6)\nprint('done')",
          python.default_limits(),
        ),
      )
    })
  let cell = await_intent(host.store, root.id, 200)
  let assert Ok(inspected) = app.inspect_python(host, cell.id)
  assert inspected.state == types.Intent
  let assert Error(busy) =
    app.execute_python(
      host,
      root.id,
      "print('must not run')",
      python.default_limits(),
    )
  assert string.contains(busy, "busy")
  let assert Ok(independent) =
    app.execute_python(
      host,
      child.id,
      "print('independent')",
      python.default_limits(),
    )
  assert independent.state == types.Succeeded
  let assert Ok(Ok(finished)) = process.receive(response, 5000)
  assert finished.id == cell.id && finished.state == types.Succeeded
  let assert Ok(cells) = workspaces.cells(host.store, root.id)
  assert list.length(cells) == 1
  app.stop(host)
}

pub fn close_mid_cell_settles_unknown_and_reaps_test() {
  let host = host()
  let assert Ok(sid) = app.start_session(host, "cancel")
  let assert Ok(root) = app.root_workspace(host, sid)
  let response = process.new_subject()
  let _ =
    spawn_unlinked(fn() {
      process.send(
        response,
        app.execute_python(
          host,
          root.id,
          "import time\ntime.sleep(10)",
          python.default_limits(),
        ),
      )
    })
  let cell = await_intent(host.store, root.id, 200)
  let assert Ok(pid) = workspaces.kernel_pid(host.workspaces, root.id)
  let assert Ok(_) = app.close_python(host, root.id)
  let assert Ok(Ok(cancelled)) = process.receive(response, 5000)
  assert cancelled.id == cell.id && cancelled.state == types.OutcomeUnknown
  assert wait_os_dead(pid, 200)
  let assert Ok(inspected) = app.inspect_python(host, cell.id)
  assert inspected.state == types.OutcomeUnknown
  app.stop(host)
}

pub fn host_restart_retains_canonical_session_workspaces_files_and_receipts_test() {
  let host = host()
  let assert Ok(sid) = app.start_session(host, "restart")
  let assert Ok(root) = app.root_workspace(host, sid)
  let assert Ok(child) = app.child_workspace(host, root.id, "child")
  let assert Ok(saved) =
    app.execute_python(
      host,
      root.id,
      "heap = 'lost'\nfrom pathlib import Path\nPath('file.txt').write_text('persistent')",
      python.default_limits(),
    )
  let assert Ok(pid) = workspaces.kernel_pid(host.workspaces, root.id)
  app.stop(host)
  assert wait_os_dead(pid, 200)
  let assert Ok(reopened) =
    app.start(config.default(host.config.data_dir), process.new_subject())
  assert reopened.deployment == host.deployment
  let assert Ok(same) = app.open_session(reopened, sid)
  assert same == sid
  let assert Ok(same_root) = app.root_workspace(reopened, sid)
  assert same_root.id == root.id
  let child_reply = process.new_subject()
  process.send(reopened.store, store.GetWorkspace(child.id, child_reply))
  let assert Ok(Ok(same_child)) = process.receive(child_reply, 5000)
  assert same_child.id == child.id && same_child.parent == Some(root.id)
  let assert Ok(receipt) = app.inspect_python(reopened, saved.id)
  assert receipt == saved
  let assert Ok(fresh) =
    app.execute_python(
      reopened,
      root.id,
      "assert 'heap' not in globals()\nfrom pathlib import Path\nassert Path('file.txt').read_text() == 'persistent'",
      python.default_limits(),
    )
  assert fresh.state == types.Succeeded
    && fresh.incarnation != saved.incarnation
  app.stop(reopened)
}

pub fn interrupted_host_classifies_intent_without_replay_on_boot_test() {
  let host = host()
  let assert Ok(sid) = app.start_session(host, "unfinished")
  let assert Ok(root) = app.root_workspace(host, sid)
  let response = process.new_subject()
  let _ =
    spawn_unlinked(fn() {
      process.send(
        response,
        app.execute_python(
          host,
          root.id,
          "from pathlib import Path\nPath('count.txt').write_text('one')\nimport time\ntime.sleep(10)\nPath('replayed.txt').write_text('no')",
          python.default_limits(),
        ),
      )
    })
  let cell = await_intent(host.store, root.id, 200)
  let assert Ok(path) = workspaces.workspace_path(host.config.data_dir, root.id)
  assert await_file(path <> "/count.txt", 200)
  let assert Ok(pid) = workspaces.kernel_pid(host.workspaces, root.id)
  app.stop(host)
  assert wait_os_dead(pid, 200)
  let assert Ok(reopened) =
    app.start(config.default(host.config.data_dir), process.new_subject())
  let assert Ok(inspected) = app.inspect_python(reopened, cell.id)
  assert inspected.state == types.OutcomeUnknown
  assert inspected.source == cell.source
  assert !exists(path <> "/replayed.txt")
  let assert Ok(text) = read_text(path <> "/count.txt")
  assert text == "one"
  app.stop(reopened)
}

pub fn executor_death_immediately_classifies_unknown_without_next_execute_test() {
  let host = host()
  let assert Ok(sid) = app.start_session(host, "owner-death")
  let assert Ok(root) = app.root_workspace(host, sid)
  let assert Ok(path) = workspaces.workspace_path(host.config.data_dir, root.id)
  let response = process.new_subject()
  let _ =
    spawn_unlinked(fn() {
      process.send(
        response,
        app.execute_python(
          host,
          root.id,
          "held = 456\nfrom pathlib import Path\nPath('once').write_text('one')\nimport time\ntime.sleep(10)",
          python.default_limits(),
        ),
      )
    })
  let cell = await_intent(host.store, root.id, 200)
  assert await_file(path <> "/once", 200)
  let assert Ok(pid) = workspaces.kernel_pid(host.workspaces, root.id)
  let assert Ok(owner) = workspaces.executor_owner(host.workspaces, root.id)
  kill_process(owner)
  let assert Ok(Error(_)) = process.receive(response, 3000)
  let assert Ok(inspected) = app.inspect_python(host, cell.id)
  assert inspected.state == types.OutcomeUnknown
  assert wait_os_dead(pid, 200)
  let assert Ok(fresh) =
    app.execute_python(
      host,
      root.id,
      "assert 'held' not in globals()\nfrom pathlib import Path\nassert Path('once').read_text() == 'one'",
      python.default_limits(),
    )
  assert fresh.state == types.Succeeded && fresh.incarnation != cell.incarnation
  app.stop(host)
}

pub fn wedged_close_does_not_block_other_agents_test() {
  let host = host()
  let assert Ok(sid) = app.start_session(host, "independent-close")
  let assert Ok(root) = app.root_workspace(host, sid)
  let assert Ok(child) = app.child_workspace(host, root.id, "other")
  let assert Ok(_) =
    app.execute_python(host, root.id, "held = 1", python.default_limits())
  let assert Ok(owner) = workspaces.executor_owner(host.workspaces, root.id)
  let assert Ok(pid) = workspaces.kernel_pid(host.workspaces, root.id)
  suspend_actor(owner)
  let response = process.new_subject()
  let _ =
    spawn_unlinked(fn() {
      process.send(response, app.close_python(host, root.id))
    })
  assert await_closing(host.workspaces, root.id, 200)
  let assert Ok(other) =
    app.execute_python(
      host,
      child.id,
      "print('still independent')",
      python.default_limits(),
    )
  assert other.state == types.Succeeded
  let assert Error(_) = process.receive(response, 0)
  resume_actor(owner)
  let assert Ok(Ok(_)) = process.receive(response, 3000)
  assert wait_os_dead(pid, 200)
  app.stop(host)
}

pub fn store_restart_tears_down_kernels_and_marks_unknown_before_admission_test() {
  let host = host()
  let assert Ok(sid) = app.start_session(host, "writer-restart")
  assert factory.count_children(host.sessions) == 1
  let assert Ok(root) = app.root_workspace(host, sid)
  let assert Ok(path) = workspaces.workspace_path(host.config.data_dir, root.id)
  let response = process.new_subject()
  let _ =
    spawn_unlinked(fn() {
      process.send(
        response,
        app.execute_python(
          host,
          root.id,
          "from pathlib import Path\nPath('once').write_text('one')\nimport time\ntime.sleep(10)",
          python.default_limits(),
        ),
      )
    })
  let cell = await_intent(host.store, root.id, 200)
  assert await_file(path <> "/once", 200)
  let assert Ok(pid) = workspaces.kernel_pid(host.workspaces, root.id)
  let assert Ok(old_store) = process.subject_owner(host.store)
  kill_process(old_store)
  let assert Ok(Error(_)) = process.receive(response, 3000)
  let inspected = await_unknown(host.store, cell.id, 200)
  assert inspected.source == cell.source
  assert wait_os_dead(pid, 200)
  let assert Ok(new_store) = process.subject_owner(host.store)
  assert new_store != old_store
  assert await_factory(host.sessions, 200) == 0
  assert factory.count_children(host.sessions) == 0
  let assert Ok(_) = app.open_session(host, sid)
  assert factory.count_children(host.sessions) == 1
  let assert Ok(fresh) =
    app.execute_python(
      host,
      root.id,
      "from pathlib import Path\nassert Path('once').read_text() == 'one'\nprint('recovered')",
      python.default_limits(),
    )
  assert fresh.state == types.Succeeded
  app.stop(host)
}

pub fn coordinator_restart_fences_orphans_without_replay_test() {
  let host = host()
  let assert Ok(sid) = app.start_session(host, "coordinator-restart")
  let assert Ok(root) = app.root_workspace(host, sid)
  let response = process.new_subject()
  let _ =
    spawn_unlinked(fn() {
      process.send(
        response,
        app.execute_python(
          host,
          root.id,
          "import time\ntime.sleep(10)",
          python.default_limits(),
        ),
      )
    })
  let cell = await_intent(host.store, root.id, 200)
  let assert Ok(pid) = workspaces.kernel_pid(host.workspaces, root.id)
  let assert Ok(store_before) = process.subject_owner(host.store)
  let assert Ok(pool_before) = process.subject_owner(host.workspaces)
  kill_process(pool_before)
  let assert Ok(Error(_)) = process.receive(response, 3000)
  let inspected = await_unknown(host.store, cell.id, 200)
  assert inspected.state == types.OutcomeUnknown
  assert wait_os_dead(pid, 200)
  let assert Ok(store_after) = process.subject_owner(host.store)
  assert store_before == store_after
  let assert Ok(fresh) =
    app.execute_python(
      host,
      root.id,
      "print('fresh after coordinator death')",
      python.default_limits(),
    )
  assert fresh.state == types.Succeeded
  app.stop(host)
}

pub fn finite_kernel_slots_are_freed_by_close_and_unknown_test() {
  let host = host()
  let assert Ok(sid) = app.start_session(host, "capacity")
  let assert Ok(root) = app.root_workspace(host, sid)
  let assert Ok(child) = app.child_workspace(host, root.id, "other")
  let assert Ok(pool) =
    workspaces.start_with_policy(
      host.store,
      host.config.data_dir,
      process.new_name("capacity-pool"),
      workspaces.Policy(1),
    )
  let assert Ok(_) =
    workspaces.execute(pool.data, root.id, "held = 1", python.default_limits())
  let assert Error(reason) =
    workspaces.execute(
      pool.data,
      child.id,
      "open('never','w').write('wrong')",
      python.default_limits(),
    )
  assert string.contains(reason, "capacity")
  let assert Ok(cells) = workspaces.cells(host.store, child.id)
  assert cells == []
  let assert Ok(_) = workspaces.close(pool.data, root.id)
  let assert Ok(timed) =
    workspaces.execute(
      pool.data,
      child.id,
      "import time\ntime.sleep(10)",
      python.Limits(40, 4096, 1024),
    )
  assert timed.state == types.OutcomeUnknown
  let assert Ok(fresh) =
    workspaces.execute(
      pool.data,
      root.id,
      "assert 'held' not in globals()",
      python.default_limits(),
    )
  assert fresh.state == types.Succeeded
  let assert Ok(_) = workspaces.close(pool.data, root.id)
  stop_actor(pool.pid)
  app.stop(host)
}

fn await_unknown(
  store: Subject(store.Msg),
  id: String,
  remaining: Int,
) -> types.Cell {
  case workspaces.inspect(store, id) {
    Ok(cell) ->
      case cell.state == types.OutcomeUnknown {
        True -> cell
        False -> {
          assert remaining > 0
          process.sleep(10)
          await_unknown(store, id, remaining - 1)
        }
      }
    Error(_) -> {
      assert remaining > 0
      process.sleep(10)
      await_unknown(store, id, remaining - 1)
    }
  }
}

fn await_closing(
  pool: Subject(workspaces.Msg),
  agent: ids.AgentId,
  remaining: Int,
) -> Bool {
  case workspaces.executor_owner(pool, agent) {
    Error(_) -> True
    Ok(_) ->
      case remaining > 0 {
        False -> False
        True -> {
          process.sleep(10)
          await_closing(pool, agent, remaining - 1)
        }
      }
  }
}

type Fault {
  RejectIntent
  PersistWithoutAck
  HoldAck
  RejectSettlement
}

pub fn rejected_and_unacknowledged_intent_produces_no_side_effect_test() {
  let host = host()
  let assert Ok(sid) = app.start_session(host, "reject-intent")
  let assert Ok(root) = app.root_workspace(host, sid)
  let assert Ok(path) = workspaces.workspace_path(host.config.data_dir, root.id)
  let proxied =
    proxy(
      host.store,
      RejectIntent,
      process.new_subject(),
      process.new_subject(),
    )
  let assert Ok(pool) =
    workspaces.start(
      proxied,
      host.config.data_dir,
      process.new_name("reject-pool"),
    )
  let assert Error(_) =
    workspaces.execute(
      pool.data,
      root.id,
      "open('never-ran','w').write('wrong')",
      python.default_limits(),
    )
  assert !exists(path <> "/never-ran")
  let assert Ok(cells) = workspaces.cells(host.store, root.id)
  assert cells == []
  stop_actor(pool.pid)
  let proxy2 =
    proxy(
      host.store,
      PersistWithoutAck,
      process.new_subject(),
      process.new_subject(),
    )
  let assert Ok(pool2) =
    workspaces.start(
      proxy2,
      host.config.data_dir,
      process.new_name("unack-pool"),
    )
  let assert Error(_) =
    workspaces.execute(
      pool2.data,
      root.id,
      "open('never-ran','w').write('wrong')",
      python.default_limits(),
    )
  assert !exists(path <> "/never-ran")
  let assert Ok([intent]) = workspaces.cells(host.store, root.id)
  assert intent.state == types.OutcomeUnknown
  stop_actor(pool2.pid)
  app.stop(host)
  let assert Ok(reopened) =
    app.start(config.default(host.config.data_dir), process.new_subject())
  let assert Ok(unknown) = app.inspect_python(reopened, intent.id)
  assert unknown.state == types.OutcomeUnknown
  assert !exists(path <> "/never-ran")
  app.stop(reopened)
}

pub fn persisted_intent_does_not_dispatch_until_ack_test() {
  let host = host()
  let assert Ok(sid) = app.start_session(host, "ack-gate")
  let assert Ok(root) = app.root_workspace(host, sid)
  let assert Ok(path) = workspaces.workspace_path(host.config.data_dir, root.id)
  let observed = process.new_subject()
  let decision = process.new_subject()
  let proxied = proxy(host.store, HoldAck, observed, decision)
  let assert Ok(pool) =
    workspaces.start(
      proxied,
      host.config.data_dir,
      process.new_name("ack-pool"),
    )
  let response = process.new_subject()
  let _ =
    spawn_unlinked(fn() {
      process.send(
        response,
        workspaces.execute(
          pool.data,
          root.id,
          "job=run('python3','-c',\"from pathlib import Path; Path('after-ack').write_text('yes')\")\nawait job",
          python.default_limits(),
        ),
      )
    })
  let assert Ok(intent) = process.receive(observed, 5000)
  assert intent.state == types.Intent
  let assert Ok(saved) = app.inspect_python(host, intent.id)
  assert saved == intent
  assert !exists(path <> "/after-ack")
  let assert Ok(gate) = process.receive(decision, 5000)
  process.send(gate, True)
  let assert Ok(Ok(done)) = process.receive(response, 5000)
  assert done.state == types.Succeeded && exists(path <> "/after-ack")
  stop_actor(pool.pid)
  app.stop(host)
}

pub fn settlement_refusal_never_publishes_success_or_replays_test() {
  let host = host()
  let assert Ok(sid) = app.start_session(host, "receipt-gate")
  let assert Ok(root) = app.root_workspace(host, sid)
  let assert Ok(path) = workspaces.workspace_path(host.config.data_dir, root.id)
  let proxied =
    proxy(
      host.store,
      RejectSettlement,
      process.new_subject(),
      process.new_subject(),
    )
  let assert Ok(pool) =
    workspaces.start(
      proxied,
      host.config.data_dir,
      process.new_name("receipt-pool"),
    )
  let assert Error(error) =
    workspaces.execute(
      pool.data,
      root.id,
      "from pathlib import Path\nPath('external-effect').write_text('once')\nprint('physically completed')",
      python.default_limits(),
    )
  assert string.contains(error, "terminal receipt not acknowledged")
  assert exists(path <> "/external-effect")
  let assert Ok([intent]) = workspaces.cells(host.store, root.id)
  assert intent.state == types.OutcomeUnknown
  assert string.contains(error, intent.id)
  stop_actor(pool.pid)
  app.stop(host)
  let assert Ok(reopened) =
    app.start(config.default(host.config.data_dir), process.new_subject())
  let assert Ok(inspected) = app.inspect_python(reopened, intent.id)
  assert inspected.state == types.OutcomeUnknown
  let assert Ok(text) = read_text(path <> "/external-effect")
  assert text == "once"
  app.stop(reopened)
}

pub fn concurrent_session_open_has_one_live_owner_test() {
  let host = host()
  let assert Ok(sid) = app.start_session(host, "opened")
  let assert Ok(before) = app.session_of(host, sid)
  let responses = process.new_subject()
  let _ =
    spawn_unlinked(fn() { process.send(responses, app.open_session(host, sid)) })
  let _ =
    spawn_unlinked(fn() { process.send(responses, app.open_session(host, sid)) })
  let assert Ok(Ok(one)) = process.receive(responses, 5000)
  let assert Ok(Ok(two)) = process.receive(responses, 5000)
  assert one == sid && two == sid
  let assert Ok(after) = app.session_of(host, sid)
  assert before == after
  // The keyed OTP catalog, not registry presence, serializes ownership.
  // An idempotent duplicate cannot replace the running child or its spec.
  let spec =
    session.Spec(
      sid,
      ids.BranchId("unused"),
      host.store,
      session_adapter(),
      "unused",
      host.events,
      host.registry,
    )
  let assert Ok(_) = factory.start_child(host.sessions, spec)
  let assert Ok(still) = app.session_of(host, sid)
  assert still == before
  assert factory.count_children(host.sessions) == 1
  app.stop(host)
}

pub fn absent_registered_runtime_returns_error_without_panicking_test() {
  let missing_registry =
    process.named_subject(process.new_name("missing-registry"))
  let assert Error(_) = registry.lookup(missing_registry, "not-open")
  let missing_factory = factory.get_by_name(process.new_name("missing-factory"))
  let spec =
    session.Spec(
      ids.new_session_id(),
      ids.new_branch_id(),
      process.new_subject(),
      session_adapter(),
      "unused",
      process.new_subject(),
      process.new_subject(),
    )
  let assert Error(_) = factory.start_child(missing_factory, spec)
}

pub fn coding_helpers_pipeline_private_child_and_retained_artifact_test() {
  let host = host()
  let assert Ok(sid) = app.start_session(host, "coding-cohort")
  let assert Ok(root) = app.root_workspace(host, sid)
  let assert Ok(child) = app.child_workspace(host, root.id, "helper-child")
  let assert Ok(done) =
    app.execute_python(
      host,
      root.id,
      "await files.write('hello.txt', 'hello\\n')\nleft=run('python3','-c', 'import sys; print(sys.stdin.read(),end=\"\");sys.exit(7)',stdin='hello')\njob=left.pipe('python3','-c','import sys; print(sys.stdin.read().upper())')\nawait job\nassert left.exit_code==7 and job.exit_code==0\nassert left.duration is not None and job.duration is not None\njob.save('complete.log')\nawait files.edit('hello.txt','hello','changed')\nprint('joined-ok')\nawait files.read('hello.txt')",
      python.default_limits(),
    )
  assert done.state == types.Succeeded
  assert string.contains(done.output, "joined-ok")
  assert string.contains(done.output, "1 | changed")
  let assert Ok(private) =
    app.execute_python(
      host,
      child.id,
      "assert not Path('hello.txt').exists()\nassert not jobs\nassert 'job' not in globals()\nprint('private')",
      python.default_limits(),
    )
  assert private.state == types.Succeeded && private.output == "private\n"
  let assert Ok(_) = app.close_python(host, root.id)
  let assert Ok(fresh) =
    app.execute_python(
      host,
      root.id,
      "assert 'job' not in globals()\nassert not jobs\nassert list(output.list())==['native']\nprint(Path('complete.log').read_text(),end='')",
      python.default_limits(),
    )
  assert fresh.state == types.Succeeded && fresh.output == "HELLO\n"
  assert fresh.incarnation != done.incarnation
  let assert Ok(receipt) = app.inspect_python(host, done.id)
  assert receipt == done
  app.stop(host)
}

pub fn coding_helper_spawn_is_not_terminal_job_receipt_and_close_cleans_test() {
  let host = host()
  let assert Ok(sid) = app.start_session(host, "spawn-receipt")
  let assert Ok(root) = app.root_workspace(host, sid)
  let assert Ok(spawned) =
    app.execute_python(
      host,
      root.id,
      "job=run('python3','-c',\"from pathlib import Path;import os,time;Path('target-pid').write_text(str(os.getpid()));time.sleep(30)\")\nwhile not Path('target-pid').exists(): await asyncio.sleep(.01)\nassert job.duration is None\nprint('spawn-only')",
      python.default_limits(),
    )
  assert spawned.state == types.Succeeded && spawned.output == "spawn-only\n"
  let assert Ok(path) = workspaces.workspace_path(host.config.data_dir, root.id)
  let assert Ok(pid_text) = read_text(path <> "/target-pid")
  let assert Ok(pid) = int.parse(pid_text)
  assert os_alive(pid)
  let assert Ok(_) = app.close_python(host, root.id)
  assert wait_os_dead(pid, 400)
  let assert Ok(receipt) = app.inspect_python(host, spawned.id)
  assert receipt == spawned
  let assert Ok(fresh) =
    app.execute_python(
      host,
      root.id,
      "assert not jobs\nassert 'job' not in globals()\nprint('no-replay')",
      python.default_limits(),
    )
  assert fresh.state == types.Succeeded && fresh.output == "no-replay\n"
  let assert Ok(cells) = workspaces.cells(host.store, root.id)
  assert list.length(cells) == 2
  app.stop(host)
}

fn proxy(
  real: Subject(store.Msg),
  fault: Fault,
  observed: Subject(types.Cell),
  decision: Subject(Subject(Bool)),
) -> Subject(store.Msg) {
  let assert Ok(started) =
    actor.new(Nil)
    |> actor.on_message(fn(state, msg) {
      case msg {
        store.BeginCell(cell, reply) ->
          case fault {
            RejectIntent ->
              process.send(reply, Error("injected rejected intent"))
            PersistWithoutAck -> {
              let persisted = process.new_subject()
              process.send(real, store.BeginCell(cell, persisted))
              let assert Ok(Ok(_)) = process.receive(persisted, 5000)
              process.send(
                reply,
                Error("commit acknowledgement lost after durable write"),
              )
            }
            HoldAck -> {
              let persisted = process.new_subject()
              process.send(real, store.BeginCell(cell, persisted))
              let assert Ok(Ok(_)) = process.receive(persisted, 5000)
              let gate = process.new_subject()
              process.send(observed, cell)
              process.send(decision, gate)
              let assert Ok(True) = process.receive(gate, 4000)
              process.send(reply, Ok(Nil))
            }
            _ -> process.send(real, msg)
          }
        store.SettleCell(_, reply) ->
          case fault {
            RejectSettlement ->
              process.send(reply, Error("injected settlement refusal"))
            _ -> process.send(real, msg)
          }
        _ -> process.send(real, msg)
      }
      actor.continue(state)
    })
    |> actor.start
  started.data
}

fn host() -> app.Started {
  let dir = "/tmp/successor-python-" <> ids.fresh("test")
  let assert Ok(host) = app.start(config.default(dir), process.new_subject())
  host
}

fn await_intent(
  store: Subject(store.Msg),
  agent: ids.AgentId,
  remaining: Int,
) -> types.Cell {
  let assert Ok(cells) = workspaces.cells(store, agent)
  case list.find(cells, fn(cell) { cell.state == types.Intent }) {
    Ok(cell) -> cell
    Error(_) -> {
      assert remaining > 0
      process.sleep(10)
      await_intent(store, agent, remaining - 1)
    }
  }
}

fn await_file(path: String, remaining: Int) -> Bool {
  case exists(path) {
    True -> True
    False ->
      case remaining > 0 {
        False -> False
        True -> {
          process.sleep(10)
          await_file(path, remaining - 1)
        }
      }
  }
}

fn wait_os_dead(pid: Int, remaining: Int) -> Bool {
  case os_alive(pid) {
    False -> True
    True ->
      case remaining > 0 {
        False -> False
        True -> {
          process.sleep(10)
          wait_os_dead(pid, remaining - 1)
        }
      }
  }
}

fn session_adapter() {
  mock.adapter(mock.default_settings())
}

@external(erlang, "successor_workspace_test_ffi", "exists")
fn exists(path: String) -> Bool

@external(erlang, "successor_workspace_test_ffi", "read_text")
fn read_text(path: String) -> Result(String, Nil)

@external(erlang, "successor_workspace_test_ffi", "os_alive")
fn os_alive(pid: Int) -> Bool

@external(erlang, "successor_workspace_test_ffi", "set_env")
fn set_env(name: String, value: String) -> Nil

@external(erlang, "successor_workspace_test_ffi", "unset_env")
fn unset_env(name: String) -> Nil

@external(erlang, "successor_ffi", "spawn_unlinked")
fn spawn_unlinked(run: fn() -> Nil) -> Pid

@external(erlang, "successor_workspace_test_ffi", "stop_actor")
fn stop_actor(pid: Pid) -> Nil

@external(erlang, "successor_workspace_test_ffi", "kill_process")
fn kill_process(pid: Pid) -> Nil

@external(erlang, "successor_workspace_test_ffi", "suspend_actor")
fn suspend_actor(pid: Pid) -> Nil

@external(erlang, "successor_workspace_test_ffi", "resume_actor")
fn resume_actor(pid: Pid) -> Nil

fn await_factory(supervisor: factory.Supervisor, remaining: Int) -> Int {
  case factory_count(supervisor) {
    Ok(count) -> count
    Error(_) -> {
      assert remaining > 0
      process.sleep(10)
      await_factory(supervisor, remaining - 1)
    }
  }
}

@external(erlang, "successor_workspace_test_ffi", "factory_count")
fn factory_count(supervisor: factory.Supervisor) -> Result(Int, Nil)
