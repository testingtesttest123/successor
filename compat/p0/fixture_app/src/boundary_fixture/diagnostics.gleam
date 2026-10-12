//// Read-only typed observations for the isolated acceptance driver.

import albedo/daemon/registry
import albedo/daemon/store
import albedo/harness/runtime
import gleam/erlang/process
import gleam/json

@external(erlang, "boundary_fixture_native", "registry_name")
fn registry_name() -> process.Name(registry.Message)

@external(erlang, "erlang", "pid_to_list")
fn pid_text(pid: process.Pid) -> List(Int)

@external(erlang, "unicode", "characters_to_binary")
fn text(chars: List(Int)) -> String

pub fn facts() -> String {
  let subject = process.named_subject(registry_name())
  let assert Ok(registry_owner) = process.subject_owner(subject)
  let assert Ok(host) = registry.host(subject)
  let assert Ok(runtime_owner) = process.subject_owner(host.subject)
  let assert Ok(summaries) = runtime.extension_summaries(host, "")
  json.object([
    #("registry", json.string(text(pid_text(registry_owner)))),
    #("runtime", json.string(text(pid_text(runtime_owner)))),
    #("store", json.string(text(pid_text(store.owner(runtime.ledger(host)))))),
    #("defaults", json.array(runtime.base_defaults(host), json.string)),
    #(
      "summaries",
      json.array(summaries, fn(summary) {
        json.object([
          #("name", json.string(summary.name)),
          #("description", json.string(summary.description)),
          #("enabled", json.bool(summary.enabled)),
          #("global_enabled", json.bool(summary.global_enabled)),
          #("overridden", json.bool(summary.overridden)),
          #("context", json.bool(summary.context)),
          #("requires", json.array(summary.requires, json.string)),
          #("tools", json.array(summary.tools, json.string)),
          #("python_modules", json.array(summary.python_modules, json.string)),
          #("plugins", json.array(summary.plugins, json.string)),
          #("quarantined", json.nullable(summary.quarantined, json.string)),
        ])
      }),
    ),
  ])
  |> json.to_string
}
