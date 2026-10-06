import gleam/erlang/atom.{type Atom}
import gleam/erlang/process
import successor/agent
import successor/app
import successor/config
import successor/ids
import successor/provider
import successor/registry
import successor/session
import successor/session_supervisor as factory
import successor/store

pub fn registry_restart_recovers_live_session_mapping_test() {
  let events = process.new_subject()
  let assert Ok(host) = app.start(config.default(data_dir: tmp_dir()), events)
  let assert Ok(sid) = app.start_session(host, name: "live")
  let assert Ok(original) = app.session_of(host, sid)
  let assert Ok(old_registry) = process.subject_owner(host.registry)
  process.kill(old_registry)
  wait_replacement(host.registry, old_registry, 100)
  let recovered = wait_session(host, sid, 100)
  assert recovered == original
  let assert Ok(_) = session.submit(recovered, text: "after registry restart")
  await_completed(events)
  app.stop(host)
}

pub fn dispatch_stops_when_agent_owner_dies_test() {
  let events = process.new_subject()
  let assert Ok(host) = app.start(config.default(data_dir: tmp_dir()), events)
  let reply = process.new_subject()
  process.send(host.store, store.CreateSession("probe", reply))
  let assert Ok(Ok(record)) = process.receive(reply, 5000)
  let started = process.new_subject()
  let adapter =
    provider.Adapter(
      id: "blocking",
      compatibility_domain: "test",
      complete: fn(_, _) {
        process.send(started, process.self())
        process.sleep_forever()
        Error(provider.Aborted)
      },
    )
  let assert Ok(owner) =
    agent.start(spec: agent.Spec(
      session: record.id,
      branch: record.current_branch,
      store: host.store,
      adapter: adapter,
      events: events,
      model: "test",
    ))
  let assert Ok(owner_pid) = process.subject_owner(owner)
  process.unlink(owner_pid)
  let activated = process.new_subject()
  process.send(owner, agent.Activate("test", activated))
  let assert Ok(Ok(_)) = process.receive(activated, 5000)
  let assert Ok(dispatch) = process.receive(started, 5000)
  let monitor = process.monitor(dispatch)
  process.kill(owner_pid)
  let stopped =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(1000)
  // Cleanup even on the original implementation before asserting.
  process.kill(dispatch)
  app.stop(host)
  assert stopped == Ok(Nil)
}

fn wait_replacement(subject: process.Subject(a), old: process.Pid, tries: Int) {
  case process.subject_owner(subject) {
    Ok(pid) if pid != old -> Nil
    _ -> {
      assert tries > 0
      process.sleep(10)
      wait_replacement(subject, old, tries - 1)
    }
  }
}

fn wait_session(
  host: app.Started,
  sid: ids.SessionId,
  tries: Int,
) -> process.Subject(session.Msg) {
  case app.session_of(host, sid) {
    Ok(subject) -> subject
    Error(_) -> {
      case tries > 0 {
        True -> {
          process.sleep(10)
          wait_session(host, sid, tries - 1)
        }
        False -> {
          app.stop(host)
          panic as "live session did not re-register"
        }
      }
    }
  }
}

fn await_completed(events: process.Subject(agent.TurnEvent)) {
  let assert Ok(event) = process.receive(events, 5000)
  case event {
    agent.TurnStarted(_, _) -> await_completed(events)
    agent.TurnCompleted(_, _, _) -> Nil
    agent.TurnFailed(_, _, reason) -> panic as reason
  }
}

fn tmp_dir() -> String {
  "/tmp/" <> ids.fresh(prefix: "successor-lifecycle")
}

// Hold the root supervisor while its registry is dead: the new session
// starts against an absent registry, not just an already-healed one.
pub fn session_started_during_registry_outage_is_recovered_test() {
  let events = process.new_subject()
  let assert Ok(host) = app.start(config.default(data_dir: tmp_dir()), events)
  let assert Ok(existing_id) = app.start_session(host, name: "existing")
  let assert Ok(existing) = app.session_of(host, existing_id)
  let assert Ok(old_registry) = process.subject_owner(host.registry)
  let monitor = process.monitor(old_registry)
  let _ = suspend(host.supervisor_pid)
  process.kill(old_registry)
  await_down(monitor)
  let created = app.start_session(host, name: "during outage")
  let _ = resume(host.supervisor_pid)
  let assert Ok(new_id) = created
  wait_replacement(host.registry, old_registry, 100)
  assert wait_session(host, existing_id, 100) == existing
  let new_session = wait_session(host, new_id, 100)
  let assert Ok(_) = session.submit(new_session, text: "after outage")
  await_completed(events)
  app.stop(host)
}

pub fn adapter_crash_is_isolated_and_guardian_exits_test() {
  let events = process.new_subject()
  let assert Ok(host) = app.start(config.default(data_dir: tmp_dir()), events)
  let started = process.new_subject()
  let release = process.new_subject()
  let adapter =
    provider.Adapter(
      id: "crashing",
      compatibility_domain: "test",
      complete: fn(_, _) {
        let proceed = process.new_subject()
        process.send(started, process.self())
        process.send(release, proceed)
        let assert Ok(_) = process.receive(proceed, 5000)
        panic as "intentional adapter failure"
      },
    )
  let #(owner, sess) = supervised_session(host, adapter)
  let assert Ok(_) = session.submit(sess, text: "crash")
  let assert Ok(worker) = process.receive(started, 5000)
  let #(guardian, monitor) = monitor_guardian(worker)
  let assert Ok(proceed) = process.receive(release, 5000)
  process.send(proceed, Nil)
  await_failed(events)
  await_down(monitor)
  assert !is_alive(guardian)
  let assert Ok(owner_pid) = process.subject_owner(owner)
  assert is_alive(owner_pid)
  // A request/reply handshake verifies the session remains serving too.
  assert session.agent_subject(sess) == owner
  app.stop(host)
}

pub fn host_shutdown_stops_blocked_dispatch_and_guardian_test() {
  let events = process.new_subject()
  let assert Ok(host) = app.start(config.default(data_dir: tmp_dir()), events)
  let started = process.new_subject()
  let adapter =
    provider.Adapter(
      id: "blocking-shutdown",
      compatibility_domain: "test",
      complete: fn(_, _) {
        process.send(started, process.self())
        process.sleep_forever()
        Error(provider.Aborted)
      },
    )
  let #(_, sess) = supervised_session(host, adapter)
  let assert Ok(_) = session.submit(sess, text: "block")
  let assert Ok(worker) = process.receive(started, 5000)
  let worker_monitor = process.monitor(worker)
  let #(_, guardian_monitor) = monitor_guardian(worker)
  app.stop(host)
  await_down(worker_monitor)
  await_down(guardian_monitor)
}

fn supervised_session(host: app.Started, adapter: provider.Adapter) {
  let reply = process.new_subject()
  process.send(host.store, store.CreateSession("custom", reply))
  let assert Ok(Ok(record)) = process.receive(reply, 5000)
  let assert Ok(_) =
    factory.start_child(
      host.sessions,
      session.Spec(
        session: record.id,
        branch: record.current_branch,
        store: host.store,
        adapter: adapter,
        model: "test",
        events: host.events,
        registry: host.registry,
      ),
    )
  #(
    session.agent_subject(wait_session(host, record.id, 100)),
    wait_session(host, record.id, 100),
  )
}

fn await_down(monitor: process.Monitor) {
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(5000)
  Nil
}

fn await_failed(events: process.Subject(agent.TurnEvent)) {
  let assert Ok(event) = process.receive(events, 5000)
  case event {
    agent.TurnStarted(_, _) -> await_failed(events)
    agent.TurnFailed(_, _, _) -> Nil
    agent.TurnCompleted(_, _, _) -> panic as "crashing adapter completed"
  }
}

fn monitor_guardian(worker: process.Pid) {
  let #(_, links) = process_links(worker, atom.create("links"))
  let assert [guardian] = links
  #(guardian, process.monitor(guardian))
}

@external(erlang, "erlang", "is_process_alive")
fn is_alive(pid: process.Pid) -> Bool

@external(erlang, "erlang", "process_info")
fn process_links(pid: process.Pid, key: Atom) -> #(Atom, List(process.Pid))

@external(erlang, "sys", "suspend")
fn suspend(pid: process.Pid) -> Nil

@external(erlang, "sys", "resume")
fn resume(pid: process.Pid) -> Nil

pub fn successful_dispatch_releases_guardian_test() {
  let events = process.new_subject()
  let assert Ok(host) = app.start(config.default(data_dir: tmp_dir()), events)
  let started = process.new_subject()
  let release = process.new_subject()
  let adapter =
    provider.Adapter(
      id: "successful",
      compatibility_domain: "test",
      complete: fn(_, _) {
        let proceed = process.new_subject()
        process.send(started, process.self())
        process.send(release, proceed)
        let assert Ok(_) = process.receive(proceed, 5000)
        Ok(provider.Response(
          stop_reason: provider.EndTurn,
          blocks: [provider.TextBlock("done")],
          usage: provider.Usage(1, 1),
          continuation: provider.Fresh,
        ))
      },
    )
  let #(_, sess) = supervised_session(host, adapter)
  let assert Ok(_) = session.submit(sess, text: "complete")
  let assert Ok(worker) = process.receive(started, 5000)
  let #(_, guardian_monitor) = monitor_guardian(worker)
  let assert Ok(proceed) = process.receive(release, 5000)
  process.send(proceed, Nil)
  await_completed(events)
  await_down(guardian_monitor)
  app.stop(host)
}

// A directly supplied pid-bound registry cannot be rediscovered by name.
// Treat it as unavailable rather than reconnecting to a dead pid on every
// immediate DOWN signal (which would spin the session indefinitely).
pub fn dead_pid_bound_registry_is_unavailable_test() {
  let ready = process.new_subject()
  let pid =
    process.spawn(fn() {
      process.send(ready, process.new_subject())
      process.sleep_forever()
    })
  process.unlink(pid)
  let assert Ok(endpoint) = process.receive(ready, 5000)
  let assert Ok(_) = registry.connect(endpoint)
  let monitor = process.monitor(pid)
  process.kill(pid)
  await_down(monitor)
  assert registry.connect(endpoint) == Error(Nil)
}
