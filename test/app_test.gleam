import gleam/erlang/process
import gleam/list
import successor/app
import successor/config
import successor/db
import successor/ids
import successor/operator
import successor/store

// Chapter 23.1A gate: the host starts and stops cleanly with ZERO configured
// providers, and the walking-slice durability premise holds across restart.

pub fn host_starts_and_stops_with_zero_providers_test() {
  let cfg = config.default(data_dir: tmp_dir())
  let assert Ok(host) = app.start(cfg)
  let operator.HealthReport(healthy, providers, schema_version) =
    operator.health(host.operator)
  assert healthy
  assert providers == 0
  assert schema_version == config.schema_version
  // The store answers through its operator-visible subject.
  let reply = process.new_subject()
  process.send(host.store, store.ListSessions(reply))
  let assert Ok(_) = process.receive(reply, 5000)
  app.stop(host)
}

pub fn restart_reopens_same_deployment_and_sessions_test() {
  let dir = tmp_dir()
  let assert Ok(host1) = app.start(config.default(data_dir: dir))
  let deployment = host1.deployment
  let reply = process.new_subject()
  process.send(host1.store, store.CreateSession("probe", reply))
  let assert Ok(Ok(_)) = process.receive(reply, 5000)
  app.stop(host1)

  let assert Ok(host2) = app.start(config.default(data_dir: dir))
  assert db_deploy_to_string(host2.deployment) == db_deploy_to_string(deployment)
  let reply2 = process.new_subject()
  process.send(host2.store, store.ListSessions(reply2))
  let assert Ok(Ok(sessions)) = process.receive(reply2, 5000)
  assert list.length(sessions) == 1
  app.stop(host2)
}

fn db_deploy_to_string(id: ids.DeploymentId) -> String {
  db.deploy_to_string(id)
}


fn tmp_dir() -> String {
  "/tmp/" <> ids.fresh(prefix: "successor-apptest")
}
