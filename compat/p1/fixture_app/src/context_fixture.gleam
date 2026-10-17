//// Reusable external runtime/loop fixture; fake providers never open transport.

import albedo/daemon/context_snapshot
import albedo/daemon/conversation
import albedo/daemon/family
import albedo/daemon/requests
import albedo/daemon/store
import albedo/harness/extension
import albedo/harness/extensions
import albedo/harness/extensions/python/link
import albedo/harness/loop
import albedo/harness/request_context as context
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

pub type Counter

@external(erlang, "context_fixture_counter", "new")
pub fn counter() -> Counter

@external(erlang, "context_fixture_counter", "next")
pub fn next(counter: Counter) -> Int

@external(erlang, "context_fixture_counter", "read")
pub fn read(counter: Counter) -> Int

@external(erlang, "context_fixture_counter", "set")
pub fn set(counter: Counter, value: Int) -> Nil

@external(erlang, "context_fixture_counter", "with_settings")
pub fn with_settings(settings: String, run: fn() -> a) -> a

pub fn static_tool() -> extension.Extension {
  extension.Extension(
    "tool",
    "stable native tool schema",
    [],
    [
      extension.ToolPlugin(
        "fixture tool",
        [
          extension.Tool(
            types.Tool(
              "fixture_read",
              "read a fixture",
              json.object([
                #("type", json.string("object")),
                #("properties", json.object([])),
              ]),
              False,
            ),
            fn(_, _) { Ok(extension.text("fixture result")) },
            fn(_) { None },
          ),
        ],
        [],
        [],
      ),
    ],
    extension.no_initialise,
  )
}

pub fn initialise(ledger: store.Store) -> Result(Nil, String) {
  store.query(ledger, fn(db) {
    use _ <- result.try(link.apply(db))
    store.exec(
      db,
      "CREATE TABLE fixture_source(live TEXT NOT NULL); INSERT INTO fixture_source VALUES('revision-1');",
    )
  })
}

pub fn revision(ledger: store.Store) -> String {
  let assert Ok(revision) =
    store.query(ledger, fn(db) {
      store.one(
        db,
        "SELECT live FROM fixture_source",
        [],
        decode.field(0, decode.string, decode.success),
        "source missing",
      )
    })
  revision
}

pub fn change(ledger: store.Store) -> Nil {
  let assert Ok(_) =
    store.query(ledger, fn(db) {
      store.exec(db, "UPDATE fixture_source SET live='revision-2'")
    })
  Nil
}

pub fn declaration(
  calls: Counter,
  inputs: process.Subject(context.Input),
  blocks: List(context.Block),
) -> extension.Extension {
  extension.Extension(
    "fixture",
    "unrelated request-context consumer",
    [],
    [
      extension.RequestContextPlugin(
        fn(input) {
          let _ = next(calls)
          process.send(inputs, input)
          let revision = revision(input.store)
          Ok(
            context.Contribution(
              revision,
              [context.Block("source", revision, True)],
              blocks,
              ["coherent fixture read"],
            ),
          )
        },
        True,
      ),
    ],
    initialise,
  )
}

pub fn catalog(tokens: Option(Int)) -> extension.Extension {
  extension.Extension(
    "catalog",
    "fixture model capacity",
    [],
    [
      extension.ModelsPlugin(extension.ModelCatalog(
        fn(model, _) {
          Some(
            extension.ModelInfo(
              ..extension.blank_model(model, "fixture"),
              context_tokens: tokens,
              source: "arbitrary fixture provenance",
            ),
          )
        },
        fn(_, _) { ["model"] },
        None,
      )),
    ],
    extension.no_initialise,
  )
}

pub fn start(
  declarations: List(extension.Extension),
) -> #(runtime.Runtime, runtime.Session) {
  let host =
    start_host(extensions.Config(
      declarations,
      list.map(declarations, fn(item) { item.name }),
    ))
  let assert Ok(kernel) = runtime.open_session(host, "s", "/tmp")
  #(host, kernel)
}

pub fn start_host(config: extensions.Config) -> runtime.Runtime {
  let assert Ok(host) = runtime.start_with_config(":memory:", config)
  let ledger = runtime.ledger(host)
  let assert Ok(_) = conversation.initialise(ledger)
  let assert Ok(_) = family.initialise(ledger)
  let assert Ok(_) =
    store.query(ledger, fn(db) { store.exec(db, requests.schema) })
  let assert Ok(_) =
    conversation.create(
      ledger,
      conversation.Info(
        "s",
        "fixture",
        "/tmp",
        "fixture",
        "model",
        types.Responses,
        conversation.Idle,
        None,
        None,
      ),
      [],
    )
  host
}

pub fn upstream(
  protocol: types.Protocol,
  stream: fn(types.Request, fn(types.Event) -> types.Control) ->
    Result(types.Turn, types.Error),
) -> extension.Upstream {
  extension.Upstream(
    "http://127.0.0.1/scripted",
    protocol,
    stream,
    fn(_) { None },
    fn() { None },
    fn(_) { [] },
    types.any_images,
  )
}

pub fn complete() -> types.Turn {
  let assert Ok(text) =
    json.parse(
      "{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"saved facts\"}]}",
      types.replay_decoder(types.Responses),
    )
  types.Turn(None, [text], [], None, types.Complete, None, [])
}

pub fn worker(
  host: runtime.Runtime,
  kernel: runtime.Session,
  upstream: extension.Upstream,
  snapshots: process.Subject(context_snapshot.Snapshot),
  steering: fn() -> Result(List(types.Input), String),
  pin: loop.Pin,
) -> loop.Loop {
  loop.Loop(
    "model",
    None,
    host,
    kernel,
    pin,
    upstream,
    fn(_) { True },
    "generation",
    fn(_, _, _, _, _) { True },
    fn(_, _, _, _, _) { True },
    fn(_) { Nil },
    fn(_) { Nil },
    fn(inputs, stage, _) {
      conversation.commit(runtime.ledger(host), "s", inputs, stage)
      |> result.map(fn(timestamp) { #(timestamp, None) })
    },
    fn(_) { Ok(Nil) },
    fn(request, observed, _, final) {
      context_snapshot.from_request(
        None,
        "fixture",
        types.protocol_name(upstream.protocol),
        upstream.protocol,
        request,
        observed,
      )
      |> context_snapshot.with_request_context(final)
      |> process.send(snapshots, _)
    },
    fn(_) { Ok(Nil) },
    steering,
    fn(_) { Nil },
    fn(_) { Nil },
    "s",
    "fixture",
    "run",
    None,
    fn() { Nil },
    False,
    0,
  )
}

pub fn receive(subject: process.Subject(a)) -> a {
  let assert Ok(value) = process.receive(subject, 1000)
  value
}

pub fn image() -> types.Image {
  let assert Ok(image) =
    types.image(
      "image/png",
      "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKElEQVR4nO3NsQ0AAAzCMP5/un0CNkuZ41wybXsHAAAAAAAAAAAAxR4yw/wuPL6QkAAAAABJRU5ErkJggg==",
      32,
      32,
      97,
    )
  image
}
