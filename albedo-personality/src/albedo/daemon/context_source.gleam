//// Conversation-owned derived source index. Payloads are read only at ingestion/backfill.
//// Unit/profile pricing walks scalar native projection facts, never archived payloads.

import albedo/context_cost
import albedo/context_salience
import albedo/daemon/image_fit
import albedo/daemon/message_content
import albedo/daemon/projection
import albedo/daemon/store
import albedo/daemon/tool_results
import albedo/daemon/transcript
import albedo/harness/projection_types
import albedo/openai_api/types
import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import sqlight

pub type SourceUnit {
  SourceUnit(
    first_seq: Int,
    last_seq: Int,
    position: Int,
    closed: Bool,
    content_identity: String,
    affected_fit_revision: Int,
    salience: context_salience.SalienceFacts,
    cost_key: context_cost.CostEntryKey,
    tokens: Int,
  )
}

pub fn initialise_in(db: sqlight.Connection) -> Result(Nil, String) {
  use _ <- result.try(
    store.add_columns(db, "transcript", [
      #("context_indexed", "INTEGER NOT NULL DEFAULT 0"),
    ]),
  )
  use _ <- result.try(store.exec(
    db,
    "CREATE TABLE IF NOT EXISTS context_source_revision(session TEXT PRIMARY KEY REFERENCES sessions(id),revision INTEGER NOT NULL);"
      <> "CREATE TABLE IF NOT EXISTS context_source_call(session TEXT NOT NULL,seq INTEGER NOT NULL,position INTEGER NOT NULL,call_id TEXT NOT NULL,PRIMARY KEY(seq,position)); CREATE INDEX IF NOT EXISTS context_source_calls ON context_source_call(session,seq); CREATE TABLE IF NOT EXISTS context_source_entry(session TEXT NOT NULL REFERENCES sessions(id),seq INTEGER PRIMARY KEY REFERENCES transcript(seq),row_class TEXT NOT NULL,content_identity TEXT NOT NULL,total_utf16 INTEGER NOT NULL,external_utf16 INTEGER NOT NULL,policy_version INTEGER NOT NULL,facts TEXT NOT NULL,base_facts TEXT NOT NULL,calls_valid INTEGER NOT NULL,salience_error TEXT,result_id TEXT,fit_revision INTEGER NOT NULL DEFAULT 0); CREATE INDEX IF NOT EXISTS context_source_entries ON context_source_entry(session,seq); CREATE INDEX IF NOT EXISTS context_source_starts ON context_source_entry(session,seq) WHERE row_class IN ('user','image_fit');"
      <> "CREATE TABLE IF NOT EXISTS context_source_image(session TEXT NOT NULL,seq INTEGER NOT NULL,image_position INTEGER NOT NULL,effective_hash TEXT NOT NULL,width INTEGER NOT NULL,height INTEGER NOT NULL,source_hash TEXT NOT NULL,source_width INTEGER NOT NULL,source_height INTEGER NOT NULL,PRIMARY KEY(seq,image_position)); CREATE INDEX IF NOT EXISTS context_source_images ON context_source_image(session,effective_hash);"
      <> "CREATE TABLE IF NOT EXISTS context_source_fit(session TEXT NOT NULL,seq INTEGER PRIMARY KEY,source_hash TEXT NOT NULL,target_hash TEXT NOT NULL,width INTEGER NOT NULL,height INTEGER NOT NULL,revision INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS context_source_fit_dirty(session TEXT PRIMARY KEY,cursor INTEGER NOT NULL DEFAULT 0); CREATE TABLE IF NOT EXISTS context_source_change(session TEXT NOT NULL,kind TEXT NOT NULL,position INTEGER NOT NULL,revision INTEGER NOT NULL,PRIMARY KEY(session,kind,position)); CREATE TABLE IF NOT EXISTS context_source_unit(session TEXT NOT NULL REFERENCES sessions(id),first_seq INTEGER NOT NULL,last_seq INTEGER NOT NULL,content_identity TEXT NOT NULL,fit_revision INTEGER NOT NULL,total_utf16 INTEGER NOT NULL,external_utf16 INTEGER NOT NULL,policy_version INTEGER NOT NULL,complete_tools INTEGER NOT NULL,error TEXT,PRIMARY KEY(session,first_seq));"
      <> "CREATE TABLE IF NOT EXISTS context_source_unit_cost(session TEXT NOT NULL,first_seq INTEGER NOT NULL,provider TEXT NOT NULL,foreign_mode INTEGER NOT NULL,protocol TEXT NOT NULL,tokens INTEGER,error TEXT,PRIMARY KEY(session,first_seq,provider,foreign_mode,protocol));",
  ))
  use _ <- result.try(store.exec(
    db,
    "CREATE INDEX IF NOT EXISTS context_source_pending ON transcript(session,seq) WHERE context_indexed=0; CREATE TRIGGER IF NOT EXISTS context_unit_cost_cleanup AFTER DELETE ON context_source_unit BEGIN DELETE FROM context_source_unit_cost WHERE session=OLD.session AND first_seq=OLD.first_seq; END",
  ))
  use _ <- result.try(
    list.try_each(
      [#("transcript", "seq"), #("continuation_markers", "rowid")],
      fn(table) {
        list.try_each(["INSERT", "UPDATE", "DELETE"], fn(action) {
          let old = case action {
            "DELETE" -> "OLD"
            _ -> "NEW"
          }
          let of_columns = case table.0, action {
            "transcript", "UPDATE" ->
              " OF payload,provider,row_class,session,seq"
            _, _ -> ""
          }
          let invalidate = case table.0, action {
            "transcript", "UPDATE" ->
              " UPDATE transcript SET context_indexed=0 WHERE seq=NEW.seq OR (session=OLD.session AND (OLD.session<>NEW.session OR OLD.seq<>NEW.seq) AND seq IN (SELECT e.seq FROM context_source_entry e JOIN context_source_unit u ON u.session=e.session AND e.seq>=u.first_seq AND e.seq<=u.last_seq WHERE u.session=OLD.session AND u.first_seq<=OLD.seq AND u.last_seq>=OLD.seq)); DELETE FROM context_source_call WHERE seq=OLD.seq AND (OLD.session<>NEW.session OR OLD.seq<>NEW.seq); DELETE FROM context_source_image WHERE seq=OLD.seq AND (OLD.session<>NEW.session OR OLD.seq<>NEW.seq); DELETE FROM context_source_entry WHERE seq=OLD.seq AND (OLD.session<>NEW.session OR OLD.seq<>NEW.seq); DELETE FROM context_source_unit WHERE session=OLD.session AND first_seq<=OLD.seq AND last_seq>=OLD.seq AND (OLD.session<>NEW.session OR OLD.seq<>NEW.seq); INSERT INTO context_source_fit_dirty(session) SELECT OLD.session WHERE OLD.row_class='image_fit' ON CONFLICT(session) DO UPDATE SET cursor=0; DELETE FROM context_source_fit WHERE seq=OLD.seq AND OLD.row_class='image_fit';"
            "transcript", "DELETE" ->
              " INSERT INTO context_source_fit_dirty(session) SELECT OLD.session WHERE OLD.row_class='image_fit' ON CONFLICT(session) DO UPDATE SET cursor=0; DELETE FROM context_source_fit WHERE seq=OLD.seq; UPDATE transcript SET context_indexed=0 WHERE session=OLD.session AND seq IN (SELECT e.seq FROM context_source_entry e JOIN context_source_unit u ON u.session=e.session AND e.seq>=u.first_seq AND e.seq<=u.last_seq WHERE u.session=OLD.session AND u.first_seq<=OLD.seq AND u.last_seq>=OLD.seq); DELETE FROM context_source_call WHERE seq=OLD.seq; DELETE FROM context_source_image WHERE seq=OLD.seq; DELETE FROM context_source_entry WHERE seq=OLD.seq; DELETE FROM context_source_unit WHERE session=OLD.session AND first_seq<=OLD.seq AND last_seq>=OLD.seq;"
            _, _ -> ""
          }
          store.exec(
            db,
            "CREATE TRIGGER IF NOT EXISTS context_revision_"
              <> table.0
              <> "_"
              <> action
              <> " AFTER "
              <> action
              <> of_columns
              <> " ON "
              <> table.0
              <> " BEGIN INSERT INTO context_source_revision(session,revision) VALUES("
              <> old
              <> ".session,1) ON CONFLICT(session) DO UPDATE SET revision=revision+1;"
              <> " INSERT INTO context_source_change(session,kind,position,revision) VALUES("
              <> old
              <> ".session,'"
              <> table.0
              <> "',"
              <> old
              <> "."
              <> table.1
              <> ",(SELECT revision FROM context_source_revision WHERE session="
              <> old
              <> ".session)) ON CONFLICT(session,kind,position) DO UPDATE SET revision=excluded.revision;"
              <> case action {
              "UPDATE" ->
                " INSERT INTO context_source_revision(session,revision) SELECT OLD.session,1 WHERE OLD.session<>NEW.session ON CONFLICT(session) DO UPDATE SET revision=revision+1; INSERT INTO context_source_change(session,kind,position,revision) SELECT OLD.session,'"
                <> table.0
                <> "',OLD."
                <> table.1
                <> ",(SELECT revision FROM context_source_revision WHERE session=OLD.session) WHERE OLD.session<>NEW.session OR OLD."
                <> table.1
                <> "<>NEW."
                <> table.1
                <> " ON CONFLICT(session,kind,position) DO UPDATE SET revision=excluded.revision;"
              _ -> ""
            }
              <> invalidate
              <> " END",
          )
        })
      },
    ),
  )
  use _ <- result.try(store.exec(
    db,
    "CREATE TABLE IF NOT EXISTS context_source_versions(estimator INTEGER NOT NULL,renderer INTEGER NOT NULL,salience INTEGER NOT NULL)",
  ))
  use versions <- result.try(
    store.rows(
      db,
      "SELECT estimator,renderer,salience FROM context_source_versions",
      [],
      {
        use a <- decode.field(0, decode.int)
        use b <- decode.field(1, decode.int)
        use c <- decode.field(2, decode.int)
        decode.success(#(a, b, c))
      },
    ),
  )
  case
    versions
    == [
      #(
        context_cost.estimator_version,
        context_cost.renderer_version,
        context_salience.policy_version,
      ),
    ]
  {
    True -> Ok(Nil)
    False -> {
      use _ <- result.try(store.exec(
        db,
        "UPDATE transcript SET context_indexed=0; DELETE FROM context_source_versions",
      ))
      store.run(db, "INSERT INTO context_source_versions VALUES(?,?,?)", [
        sqlight.int(context_cost.estimator_version),
        sqlight.int(context_cost.renderer_version),
        sqlight.int(context_salience.policy_version),
      ])
    }
  }
}

pub fn bound_in(
  db: sqlight.Connection,
  session: String,
) -> Result(projection_types.SourceBound, String) {
  store.one(
    db,
    "SELECT COALESCE((SELECT MAX(seq) FROM transcript WHERE session=s.id),0),COALESCE((SELECT MAX(rowid) FROM continuation_markers WHERE session=s.id),0),COALESCE((SELECT revision FROM context_source_revision WHERE session=s.id),0),s.config_revision FROM sessions s WHERE s.id=?",
    [sqlight.text(session)],
    {
      use upper <- decode.field(0, decode.int)
      use continuations <- decode.field(1, decode.int)
      use revision <- decode.field(2, decode.int)
      use configuration <- decode.field(3, decode.int)
      decode.success(projection_types.SourceBound(
        session,
        upper,
        continuations,
        revision,
        configuration,
      ))
    },
    "source scope unavailable",
  )
}

pub fn index_entry_in(
  db: sqlight.Connection,
  session: String,
  seq: Int,
  input: types.Input,
) -> Result(Nil, String) {
  use _ <- result.try(index_entry_metadata_in(db, session, seq, input))
  refresh_around_in(db, session, seq)
}

/// Stage scalar facts inside the caller's transaction; refresh its units before commit.
pub fn index_entry_metadata_in(
  db: sqlight.Connection,
  session: String,
  seq: Int,
  input: types.Input,
) -> Result(Nil, String) {
  use row <- result.try(store.one(
    db,
    "SELECT payload,provider,row_class FROM transcript WHERE session=? AND seq=?",
    [sqlight.text(session), sqlight.int(seq)],
    {
      use payload <- decode.field(0, decode.bit_array)
      use provider <- decode.field(1, decode.optional(decode.string))
      use kind <- decode.field(2, decode.optional(decode.string))
      decode.success(#(payload, provider, kind))
    },
    "source entry missing",
  ))
  let facts =
    projection.cost_facts(transcript.Entry(input, None, row.1, None, None))
  let measured = context_salience.measure(input)
  let salience =
    result.unwrap(
      measured,
      context_salience.SalienceFacts(0, 0, context_salience.policy_version),
    )
  let error = case measured {
    Ok(_) -> None
    Error(message) -> Some(message)
  }
  use _ <- result.try(
    store.run(db, "DELETE FROM context_source_call WHERE seq=?", [
      sqlight.int(seq),
    ]),
  )
  use _ <- result.try(
    message_content.calls(input)
    |> list.index_map(fn(call, position) { #(call.id, position) })
    |> list.try_each(fn(call) {
      store.run(
        db,
        "INSERT INTO context_source_call(session,seq,position,call_id) VALUES(?,?,?,?)",
        [
          sqlight.text(session),
          sqlight.int(seq),
          sqlight.int(call.1),
          sqlight.text(call.0),
        ],
      )
    }),
  )
  let result_id = case input {
    types.ToolOutput(id, _, _) -> Some(id)
    _ -> None
  }
  use _ <- result.try(
    store.run(
      db,
      "INSERT INTO context_source_entry(session,seq,row_class,content_identity,total_utf16,external_utf16,policy_version,facts,base_facts,calls_valid,salience_error,result_id) VALUES(?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(seq) DO UPDATE SET session=excluded.session,row_class=excluded.row_class,content_identity=excluded.content_identity,total_utf16=excluded.total_utf16,external_utf16=excluded.external_utf16,policy_version=excluded.policy_version,facts=excluded.facts,base_facts=excluded.base_facts,calls_valid=excluded.calls_valid,salience_error=excluded.salience_error,result_id=excluded.result_id,fit_revision=0",
      [
        sqlight.text(session),
        sqlight.int(seq),
        sqlight.text(option.unwrap(row.2, transcript.row_class(input))),
        sqlight.text(context_cost.fingerprint(#(row.0, row.1, row.2))),
        sqlight.int(salience.total_utf16),
        sqlight.int(salience.external_utf16),
        sqlight.int(salience.policy_version),
        sqlight.text(json.to_string(projection.cost_facts_json(facts))),
        sqlight.text(json.to_string(projection.cost_facts_json(facts))),
        sqlight.bool(tool_results.identified_calls(
          input,
          message_content.calls(input),
        )),
        sqlight.nullable(sqlight.text, error),
        sqlight.nullable(sqlight.text, result_id),
      ],
    ),
  )
  use _ <- result.try(
    store.run(db, "DELETE FROM context_source_image WHERE seq=?", [
      sqlight.int(seq),
    ]),
  )
  let images = case input {
    types.UserImage(_, images) | types.ToolOutput(_, _, images) -> images
    _ -> []
  }
  use _ <- result.try(
    list.try_each(
      list.index_map(images, fn(image, position) { #(image, position) }),
      fn(pair) {
        let #(_, width, height, _) = types.image_meta(pair.0)
        store.run(
          db,
          "INSERT INTO context_source_image(session,seq,image_position,effective_hash,width,height,source_hash,source_width,source_height) VALUES(?,?,?,?,?,?,?,?,?)",
          [
            sqlight.text(session),
            sqlight.int(seq),
            sqlight.int(pair.1),
            sqlight.text(image_fit.source(pair.0)),
            sqlight.int(width),
            sqlight.int(height),
            sqlight.text(image_fit.source(pair.0)),
            sqlight.int(width),
            sqlight.int(height),
          ],
        )
      },
    ),
  )
  use _ <- result.try(
    store.run(db, "UPDATE transcript SET context_indexed=1 WHERE seq=?", [
      sqlight.int(seq),
    ]),
  )
  use _ <- result.try(case row.2 {
    Some("image_fit") -> {
      use fit <- result.try(
        unpack_fit(row.0, unread)
        |> result.replace_error("source image-fit metadata unreadable"),
      )
      index_fit_in(db, session, seq, fit)
    }
    _ -> Ok(Nil)
  })
  restore_images_in(db, session, Some(seq))
}

/// A batch append rebuilds each affected complete unit once, after all rows are indexed.
pub fn refresh_appended_in(
  db: sqlight.Connection,
  session: String,
  first_seq: Int,
  last_seq: Int,
) -> Result(Nil, String) {
  case first_seq > last_seq {
    True -> Ok(Nil)
    False -> {
      use first <- result.try(unit_start_in(db, session, first_seq))
      use starts <- result.try(store.rows(
        db,
        "SELECT seq FROM context_source_entry WHERE session=? AND seq>? AND seq<=? AND row_class IN ('user','image_fit') ORDER BY seq",
        [sqlight.text(session), sqlight.int(first), sqlight.int(last_seq)],
        decode.field(0, decode.int, decode.success),
      ))
      list.try_each([first, ..starts], fn(position) {
        refresh_around_in(db, session, position)
      })
    }
  }
}

fn facts_decoder() -> decode.Decoder(projection.CostFacts) {
  decode.string
  |> decode.then(fn(raw) {
    case json.parse(raw, projection.cost_facts_decoder()) {
      Ok(facts) -> decode.success(facts)
      Error(_) ->
        decode.failure(
          projection.CostFacts(0, None, None, Ok(0), Ok(projection.Direct(0))),
          "valid source projection facts",
        )
    }
  })
}

type IndexedEntry {
  IndexedEntry(
    seq: Int,
    identity: String,
    total: Int,
    external: Int,
    fit_revision: Int,
    facts: projection.CostFacts,
    error: Option(String),
  )
}

fn entry_decoder() -> decode.Decoder(IndexedEntry) {
  use seq <- decode.field(0, decode.int)
  use identity <- decode.field(1, decode.string)
  use total <- decode.field(2, decode.int)
  use external <- decode.field(3, decode.int)
  use fit <- decode.field(4, decode.int)
  use facts <- decode.field(5, facts_decoder())
  use error <- decode.field(6, decode.optional(decode.string))
  decode.success(IndexedEntry(seq, identity, total, external, fit, facts, error))
}

fn unit_start_in(
  db: sqlight.Connection,
  session: String,
  seq: Int,
) -> Result(Int, String) {
  store.one(
    db,
    "SELECT COALESCE((SELECT MAX(seq) FROM context_source_entry WHERE session=?1 AND seq<=?2 AND row_class IN ('user','image_fit')),(SELECT MIN(seq) FROM context_source_entry WHERE session=?1),0)",
    [sqlight.text(session), sqlight.int(seq)],
    decode.field(0, decode.int, decode.success),
    "source unit start unavailable",
  )
}

fn refresh_around_in(
  db: sqlight.Connection,
  session: String,
  seq: Int,
) -> Result(Nil, String) {
  use first <- result.try(unit_start_in(db, session, seq))
  use previous <- result.try(unit_start_in(db, session, first - 1))
  use crosses <- result.try(store.one(
    db,
    "SELECT COALESCE((SELECT last_seq>=?3 FROM context_source_unit WHERE session=?1 AND first_seq=?2),0)",
    [sqlight.text(session), sqlight.int(previous), sqlight.int(first)],
    decode.field(0, sqlight.decode_bool(), decode.success),
    "source boundary repair unavailable",
  ))
  use _ <- result.try(case previous > 0 && previous < first && crosses {
    True -> refresh_unit_in(db, session, previous)
    False -> Ok(Nil)
  })
  refresh_unit_in(db, session, first)
}

fn refresh_unit_in(
  db: sqlight.Connection,
  session: String,
  first: Int,
) -> Result(Nil, String) {
  use last <- result.try(store.one(
    db,
    "SELECT COALESCE((SELECT MAX(seq) FROM transcript WHERE session=?1 AND seq<(SELECT MIN(seq) FROM context_source_entry WHERE session=?1 AND seq>?2 AND row_class IN ('user','image_fit'))),(SELECT MAX(seq) FROM transcript WHERE session=?1),0)",
    [sqlight.text(session), sqlight.int(first)],
    decode.field(0, decode.int, decode.success),
    "source unit end unavailable",
  ))
  use entries <- result.try(store.rows(
    db,
    "SELECT seq,content_identity,total_utf16,external_utf16,fit_revision,facts,salience_error FROM context_source_entry WHERE session=? AND seq>=? AND seq<=? ORDER BY seq",
    [sqlight.text(session), sqlight.int(first), sqlight.int(last)],
    entry_decoder(),
  ))
  let total = list.fold(entries, 0, fn(n, e) { n + e.total })
  let external = list.fold(entries, 0, fn(n, e) { n + e.external })
  let fit = list.fold(entries, 0, fn(n, e) { int.max(n, e.fit_revision) })
  let identity =
    context_cost.fingerprint(list.map(entries, fn(e) { #(e.seq, e.identity) }))
  let errors =
    list.filter_map(entries, fn(e) { option.to_result(e.error, Nil) })
  let error = list.first(errors) |> option.from_result
  use events <- result.try(
    store.rows(
      db,
      "SELECT seq,call_id,1 FROM context_source_call WHERE session=?1 AND seq>=?2 AND seq<=?3 UNION ALL SELECT seq,result_id,0 FROM context_source_entry WHERE session=?1 AND seq>=?2 AND seq<=?3 AND result_id IS NOT NULL ORDER BY 1,3 DESC",
      [sqlight.text(session), sqlight.int(first), sqlight.int(last)],
      {
        use id <- decode.field(1, decode.string)
        use call <- decode.field(2, sqlight.decode_bool())
        decode.success(#(id, call))
      },
    ),
  )
  let pending =
    list.fold(events, dict.new(), fn(pending, event) {
      let count = result.unwrap(dict.get(pending, event.0), 0)
      case event.1 {
        True -> dict.insert(pending, event.0, count + 1)
        False if count == 1 -> dict.delete(pending, event.0)
        False if count > 1 -> dict.insert(pending, event.0, count - 1)
        False -> pending
      }
    })
  use invalid <- result.try(store.one(
    db,
    "SELECT COUNT(*) FROM context_source_entry WHERE session=? AND seq>=? AND seq<=? AND calls_valid=0",
    [sqlight.text(session), sqlight.int(first), sqlight.int(last)],
    decode.field(0, decode.int, decode.success),
    "native call validity unavailable",
  ))
  let incomplete = dict.size(pending) + invalid
  use _ <- result.try(
    store.run(
      db,
      "DELETE FROM context_source_unit WHERE session=? AND first_seq>? AND first_seq<=?",
      [sqlight.text(session), sqlight.int(first), sqlight.int(last)],
    ),
  )
  use _ <- result.try(
    store.run(
      db,
      "INSERT INTO context_source_unit(session,first_seq,last_seq,content_identity,fit_revision,total_utf16,external_utf16,policy_version,complete_tools,error) VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(session,first_seq) DO UPDATE SET last_seq=excluded.last_seq,content_identity=excluded.content_identity,fit_revision=excluded.fit_revision,total_utf16=excluded.total_utf16,external_utf16=excluded.external_utf16,policy_version=excluded.policy_version,complete_tools=excluded.complete_tools,error=excluded.error",
      [
        sqlight.text(session),
        sqlight.int(first),
        sqlight.int(last),
        sqlight.text(identity),
        sqlight.int(fit),
        sqlight.int(total),
        sqlight.int(external),
        sqlight.int(context_salience.policy_version),
        sqlight.int(case incomplete == 0 {
          True -> 1
          False -> 0
        }),
        sqlight.nullable(sqlight.text, error),
      ],
    ),
  )
  use _ <- result.try(
    store.run(
      db,
      "DELETE FROM context_source_unit_cost WHERE session=? AND first_seq=?",
      [sqlight.text(session), sqlight.int(first)],
    ),
  )
  let facts = list.map(entries, fn(e) { e.facts })
  let providers =
    list.filter_map(facts, fn(f) { option.to_result(f.provider, Nil) })
    |> list.unique
    |> list.map(Some)
  list.try_each([None, ..providers], fn(provider) {
    list.try_each([types.Responses, types.ChatCompletions], fn(protocol) {
      let priced = projection.estimate_facts(facts, provider, protocol)
      store.run(
        db,
        "INSERT INTO context_source_unit_cost(session,first_seq,provider,foreign_mode,protocol,tokens,error) VALUES(?,?,?,?,?,?,?)",
        [
          sqlight.text(session),
          sqlight.int(first),
          sqlight.text(option.unwrap(provider, "")),
          sqlight.int(case provider {
            None -> 1
            _ -> 0
          }),
          sqlight.text(types.protocol_name(protocol)),
          sqlight.nullable(sqlight.int, option.from_result(priced)),
          sqlight.nullable(sqlight.text, case priced {
            Ok(_) -> None
            Error(e) -> Some(e)
          }),
        ],
      )
    })
  })
}

/// A durable fit map preserves lineage when a source row is rewritten or a fit is removed.
fn index_fit_in(
  db: sqlight.Connection,
  session: String,
  seq: Int,
  fit: transcript.ImageFit,
) -> Result(Nil, String) {
  let #(_, width, height, _) = types.image_meta(fit.image)
  use scope <- result.try(bound_in(db, session))
  use _ <- result.try(
    store.run(
      db,
      "INSERT INTO context_source_fit(session,seq,source_hash,target_hash,width,height,revision) VALUES(?,?,?,?,?,?,?) ON CONFLICT(seq) DO UPDATE SET source_hash=excluded.source_hash,target_hash=excluded.target_hash,width=excluded.width,height=excluded.height,revision=excluded.revision",
      [
        sqlight.text(session),
        sqlight.int(seq),
        sqlight.text(fit.source),
        sqlight.text(image_fit.source(fit.image)),
        sqlight.int(width),
        sqlight.int(height),
        sqlight.int(scope.revision),
      ],
    ),
  )
  use affected <- result.try(store.rows(
    db,
    "SELECT DISTINCT seq FROM context_source_image WHERE session=?1 AND seq<?2 AND (effective_hash=?3 OR source_hash IN (WITH RECURSIVE ancestors(hash) AS (SELECT ?3 UNION SELECT f.source_hash FROM context_source_fit f JOIN ancestors a ON f.target_hash=a.hash WHERE f.session=?1 AND f.seq<?2) SELECT hash FROM ancestors))",
    [sqlight.text(session), sqlight.int(seq), sqlight.text(fit.source)],
    decode.field(0, decode.int, decode.success),
  ))
  list.try_each(affected, fn(position) {
    restore_images_in(db, session, Some(position))
  })
}

type IndexedFit {
  IndexedFit(
    seq: Int,
    source: String,
    target: String,
    width: Int,
    height: Int,
    revision: Int,
  )
}

fn restore_images_in(
  db: sqlight.Connection,
  session: String,
  only: Option(Int),
) -> Result(Nil, String) {
  use fits <- result.try(
    store.rows(
      db,
      "SELECT seq,source_hash,target_hash,width,height,revision FROM context_source_fit WHERE session=? ORDER BY seq",
      [sqlight.text(session)],
      {
        use seq <- decode.field(0, decode.int)
        use source <- decode.field(1, decode.string)
        use target <- decode.field(2, decode.string)
        use width <- decode.field(3, decode.int)
        use height <- decode.field(4, decode.int)
        use revision <- decode.field(5, decode.int)
        decode.success(IndexedFit(seq, source, target, width, height, revision))
      },
    ),
  )
  use positions <- result.try(store.rows(
    db,
    "SELECT DISTINCT seq FROM context_source_image WHERE session=?1 AND (?2 IS NULL OR seq=?2) ORDER BY seq",
    [sqlight.text(session), sqlight.nullable(sqlight.int, only)],
    decode.field(0, decode.int, decode.success),
  ))
  list.try_each(positions, fn(position) {
    use images <- result.try(
      store.rows(
        db,
        "SELECT image_position,source_hash,source_width,source_height,effective_hash,width,height FROM context_source_image WHERE seq=? ORDER BY image_position",
        [sqlight.int(position)],
        {
          use i <- decode.field(0, decode.int)
          use hash <- decode.field(1, decode.string)
          use width <- decode.field(2, decode.int)
          use height <- decode.field(3, decode.int)
          use old_hash <- decode.field(4, decode.string)
          use old_width <- decode.field(5, decode.int)
          use old_height <- decode.field(6, decode.int)
          decode.success(#(
            i,
            hash,
            width,
            height,
            old_hash,
            old_width,
            old_height,
          ))
        },
      ),
    )
    let projected =
      list.map(images, fn(image) {
        let fit =
          list.fold(fits, #(image.1, image.2, image.3, 0), fn(state, fit) {
            case fit.seq > position && fit.source == state.0 {
              True -> #(
                fit.target,
                fit.width,
                fit.height,
                int.max(state.3, fit.revision),
              )
              False -> state
            }
          })
        #(image, fit)
      })
    use previous <- result.try(store.one(
      db,
      "SELECT base_facts,facts,fit_revision FROM context_source_entry WHERE seq=?",
      [sqlight.int(position)],
      {
        use base <- decode.field(0, facts_decoder())
        use facts <- decode.field(1, decode.string)
        use revision <- decode.field(2, decode.int)
        decode.success(#(base, facts, revision))
      },
      "source image baseline unavailable",
    ))
    let delta =
      list.fold(projected, 0, fn(n, pair) {
        n
        + context_cost.image_tokens(pair.1.1, pair.1.2)
        - context_cost.image_tokens(pair.0.2, pair.0.3)
      })
    let revision = list.fold(projected, 0, fn(n, pair) { int.max(n, pair.1.3) })
    let facts =
      json.to_string(
        projection.cost_facts_json(projection.adjust_image_tokens(
          previous.0,
          delta,
        )),
      )
    case facts == previous.1 && revision == previous.2 {
      True -> Ok(Nil)
      False -> {
        use _ <- result.try(
          store.run(
            db,
            "UPDATE context_source_entry SET facts=?,fit_revision=? WHERE seq=?",
            [sqlight.text(facts), sqlight.int(revision), sqlight.int(position)],
          ),
        )
        use _ <- result.try(
          list.try_each(projected, fn(pair) {
            store.run(
              db,
              "UPDATE context_source_image SET effective_hash=?,width=?,height=? WHERE seq=? AND image_position=?",
              [
                sqlight.text(pair.1.0),
                sqlight.int(pair.1.1),
                sqlight.int(pair.1.2),
                sqlight.int(position),
                sqlight.int(pair.0.0),
              ],
            )
          }),
        )
        use scope <- result.try(bound_in(db, session))
        use _ <- result.try(
          store.run(
            db,
            "INSERT INTO context_source_change(session,kind,position,revision) VALUES(?,'transcript',?,?) ON CONFLICT(session,kind,position) DO UPDATE SET revision=excluded.revision",
            [
              sqlight.text(session),
              sqlight.int(position),
              sqlight.int(scope.revision),
            ],
          ),
        )
        refresh_around_in(db, session, position)
      }
    }
  })
}

/// Transactional recovery of touched rows. Startup itself yields every128 rows.
pub fn reindex_in(
  db: sqlight.Connection,
  session: String,
) -> Result(Nil, String) {
  use dirty <- result.try(store.rows(
    db,
    "SELECT session FROM context_source_fit_dirty WHERE session=?",
    [sqlight.text(session)],
    decode.field(0, decode.string, decode.success),
  ))
  use _ <- result.try(case dirty {
    [] -> Ok(Nil)
    _ -> restore_images_in(db, session, None)
  })
  use _ <- result.try(
    store.run(db, "DELETE FROM context_source_fit_dirty WHERE session=?", [
      sqlight.text(session),
    ]),
  )
  use rows <- result.try(
    store.rows(
      db,
      "SELECT seq,payload FROM transcript WHERE session=? AND context_indexed=0 ORDER BY seq LIMIT 128",
      [sqlight.text(session)],
      {
        use seq <- decode.field(0, decode.int)
        use payload <- decode.field(1, decode.bit_array)
        decode.success(#(seq, payload))
      },
    ),
  )
  use _ <- result.try(
    list.try_each(rows, fn(row) {
      use input <- result.try(
        unpack(row.1, unread)
        |> result.replace_error(
          "source metadata backfill cannot decode transcript",
        ),
      )
      index_entry_in(db, session, row.0, input)
    }),
  )
  case list.length(rows) == 128 {
    True -> reindex_in(db, session)
    False -> Ok(Nil)
  }
}

pub fn inventory_in(
  db: sqlight.Connection,
  scope: projection_types.SourceBound,
  profile: context_cost.CostProfile,
) -> Result(List(SourceUnit), String) {
  use pending <- result.try(store.one(
    db,
    "SELECT (SELECT COUNT(*) FROM transcript WHERE session=?1 AND seq<=?2 AND context_indexed=0)+(SELECT COUNT(*) FROM context_source_fit_dirty WHERE session=?1)",
    [sqlight.text(scope.session), sqlight.int(scope.transcript_upper)],
    decode.field(0, decode.int, decode.success),
    "source index readiness unavailable",
  ))
  use _ <- result.try(case pending {
    0 -> Ok(Nil)
    _ -> Error("source metadata unavailable: unindexed or rewritten rows")
  })
  use rows <- result.try(
    store.rows(
      db,
      "SELECT u.first_seq,u.last_seq,u.content_identity,u.fit_revision,u.total_utf16,u.external_utf16,u.policy_version,u.complete_tools,u.error,CASE WHEN own.protocol IS NOT NULL THEN own.tokens ELSE foreign_cost.tokens END,CASE WHEN own.protocol IS NOT NULL THEN own.error ELSE foreign_cost.error END FROM context_source_unit u LEFT JOIN context_source_unit_cost own ON own.session=u.session AND own.first_seq=u.first_seq AND own.provider=?3 AND own.foreign_mode=0 AND own.protocol=?4 LEFT JOIN context_source_unit_cost foreign_cost ON foreign_cost.session=u.session AND foreign_cost.first_seq=u.first_seq AND foreign_cost.foreign_mode=1 AND foreign_cost.protocol=?4 WHERE u.session=?1 AND u.last_seq<=?2 ORDER BY u.first_seq",
      [
        sqlight.text(scope.session),
        sqlight.int(scope.transcript_upper),
        sqlight.text(profile.provider),
        sqlight.text(types.protocol_name(profile.protocol)),
      ],
      {
        use first <- decode.field(0, decode.int)
        use last <- decode.field(1, decode.int)
        use identity <- decode.field(2, decode.string)
        use fit <- decode.field(3, decode.int)
        use total <- decode.field(4, decode.int)
        use external <- decode.field(5, decode.int)
        use policy <- decode.field(6, decode.int)
        use complete <- decode.field(7, sqlight.decode_bool())
        use source_error <- decode.field(8, decode.optional(decode.string))
        use tokens <- decode.field(9, decode.optional(decode.int))
        use cost_error <- decode.field(10, decode.optional(decode.string))
        decode.success(#(
          SourceUnit(
            first,
            last,
            0,
            complete,
            identity,
            fit,
            context_salience.SalienceFacts(total, external, policy),
            context_cost.CostEntryKey(
              context_cost.profile_id(profile),
              identity,
              fit,
            ),
            option.unwrap(tokens, 0),
          ),
          source_error,
          cost_error,
          tokens,
        ))
      },
    ),
  )
  let size = list.length(rows)
  rows
  |> list.index_map(fn(row, i) { #(row, i) })
  |> list.try_map(fn(pair) {
    let row = pair.0
    case row.1, row.2, row.3 {
      None, None, Some(_) ->
        Ok(
          SourceUnit(
            ..row.0,
            position: pair.1 + 1,
            closed: row.0.closed && pair.1 < size - 1,
          ),
        )
      Some(error), _, _ | _, Some(error), _ ->
        Error("source metadata unavailable: " <> error)
      _, _, _ -> Error("source projection cost metadata unavailable")
    }
  })
}

pub fn forget_in(
  db: sqlight.Connection,
  session: String,
) -> Result(Nil, String) {
  store.forget_session(
    db,
    [
      "context_source_call",
      "context_source_unit_cost",
      "context_source_unit",
      "context_source_image",
      "context_source_entry",
      "context_source_revision",
      "context_source_fit",
      "context_source_fit_dirty",
      "context_source_change",
    ],
    session,
  )
}

@external(erlang, "albedo_conversation", "unpack")
fn unpack(
  bytes: BitArray,
  read: fn(String) -> Result(String, Nil),
) -> Result(types.Input, Nil)

@external(erlang, "albedo_conversation", "unpack_fit")
fn unpack_fit(
  bytes: BitArray,
  read: fn(String) -> Result(String, Nil),
) -> Result(transcript.ImageFit, Nil)

fn unread(_: String) -> Result(String, Nil) {
  Error(Nil)
}

/// Startup recovery yields after at most128 metadata image entries, including fit tombstones.
pub fn recover_fits(ledger: store.Store) -> Result(Nil, String) {
  use more <- result.try(
    store.query(ledger, fn(db) {
      store.transaction(db, fn() {
        use sessions <- result.try(
          store.rows(
            db,
            "SELECT session,cursor FROM context_source_fit_dirty ORDER BY session LIMIT 1",
            [],
            {
              use session <- decode.field(0, decode.string)
              use cursor <- decode.field(1, decode.int)
              decode.success(#(session, cursor))
            },
          ),
        )
        case sessions {
          [] -> Ok(False)
          [pending] -> {
            use positions <- result.try(store.rows(
              db,
              "SELECT DISTINCT seq FROM context_source_image WHERE session=? AND seq>? ORDER BY seq LIMIT 128",
              [sqlight.text(pending.0), sqlight.int(pending.1)],
              decode.field(0, decode.int, decode.success),
            ))
            use _ <- result.try(
              list.try_each(positions, fn(seq) {
                restore_images_in(db, pending.0, Some(seq))
              }),
            )
            use _ <- result.try(case list.length(positions) == 128 {
              True ->
                store.run(
                  db,
                  "UPDATE context_source_fit_dirty SET cursor=? WHERE session=?",
                  [
                    sqlight.int(
                      list.last(positions) |> result.unwrap(pending.1),
                    ),
                    sqlight.text(pending.0),
                  ],
                )
              False ->
                store.run(
                  db,
                  "DELETE FROM context_source_fit_dirty WHERE session=?",
                  [sqlight.text(pending.0)],
                )
            })
            Ok(True)
          }
          _ -> Error("fit recovery scope unavailable")
        }
      })
    }),
  )
  case more {
    True -> recover_fits(ledger)
    False -> Ok(Nil)
  }
}
