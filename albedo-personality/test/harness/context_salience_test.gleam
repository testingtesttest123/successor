//// The pinned upstream static function is the oracle; these fixtures catch UTF-16,
//// JSON number/escaping and whole-unit clamp drift that HTTP cannot isolate.

import albedo/context_salience
import albedo/openai_api/types
import gleam/float
import gleam/json
import gleam/list
import gleeunit/should

fn image() -> types.Image {
  let assert Ok(image) = types.image("image/png", "AA==", 16, 16, 1)
  image
}

fn replay(protocol: types.Protocol, raw: String) -> types.Input {
  let assert Ok(item) = json.parse(raw, types.replay_decoder(protocol))
  types.Replay(item)
}

pub fn native_adapter_matches_executed_pinned_static_salience_test() -> Nil {
  let cases = [
    #([types.User("")], 1.0),
    // empty
    #([types.User("ordinary conversation")], 1.0),
    // conversation
    #([types.User("👩‍💻é")], 1.0),
    // unicode
    #([types.User("before```python\nprint(1)```after")], 0.625),
    // fence
    #([types.User("before```typescript\nx")], 0.5428571428571429),
    // unclosed
    #([types.User("﻿  https://example.test/a👩‍💻 ")], 0.3032258064516129),
    // bare_url
    #([types.User("HTTP://example.test")], 1.0),
    // uppercase_url
    #([types.User("https://example.test a")], 1.0),
    // url_with_space
    #([types.User("```\nhttps://example.test/a\n```")], 0.2),
    // url_inside_fence
    #([types.User(" https://example.test ")], 0.2727272727272727),
    // ecma_space
    #(
      [
        types.User("ordinary conversation length"),
        replay(
          types.Responses,
          "{\"type\": \"function_call\", \"id\": \"item\", \"call_id\": \"call\", \"name\": \"run\", \"arguments\": \"{\\\"note\\\":\\\"👩‍💻\\\\n\\\\\\\"\\\",\\\"n\\\":1e-7,\\\"big\\\":1e20,\\\"huge\\\":1e21,\\\"zero\\\":-0,\\\"array\\\":[true,null]}\"}",
        ),
      ],
      0.37637795275590546,
    ),
    // tool_structured
    #(
      [
        types.User("ordinary conversation length"),
        replay(
          types.Responses,
          "{\"type\": \"function_call\", \"id\": \"item\", \"call_id\": \"call\", \"name\": \"run\", \"arguments\": \"null\"}",
        ),
      ],
      0.9466666666666667,
    ),
    // tool_null
    #(
      [
        types.User("ordinary conversation length"),
        replay(
          types.Responses,
          "{\"type\": \"function_call\", \"id\": \"item\", \"call_id\": \"call\", \"name\": \"run\", \"arguments\": \"{\\\"partial\\\":\"}",
        ),
      ],
      0.7209302325581395,
    ),
    // tool_malformed
    #(
      [
        types.User("ordinary conversation length"),
        replay(
          types.Responses,
          "{\"type\": \"function_call\", \"id\": \"item\", \"call_id\": \"call\", \"name\": \"run\", \"arguments\": \"{\\\"n\\\":9007199254740993}\"}",
        ),
      ],
      0.6479999999999999,
    ),
    // tool_integer_rounding
    #([types.ToolOutput("call", "👩‍💻\nresult", list.repeat(image(), 0))], 0.2),
    // tool_result
    #([types.UserImage("look", list.repeat(image(), 2))], 0.20024992189940638),
    // user_images
    #([types.ToolOutput("call", "result", list.repeat(image(), 1))], 0.2),
    // result_image
    #(
      [
        replay(
          types.ChatCompletions,
          "{\"role\": \"assistant\", \"content\": \"portable 👩‍💻\", \"tool_calls\": [{\"id\": \"call\", \"type\": \"function\", \"function\": {\"name\": \"run\", \"arguments\": \"{\\\"x\\\":1e-7}\"}}]}",
        ),
      ],
      0.6666666666666666,
    ),
    // chat_text_and_call
    #(
      [
        types.User("```\nhttps://x\n```"),
        types.Assistant(
          "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        ),
      ],
      0.7922077922077922,
    ),
    // whole_unit_clamp
  ]
  list.each(cases, fn(fixture) {
    let assert Ok(facts) = list.try_map(fixture.0, context_salience.measure)
    let actual = context_salience.score(context_salience.combine(facts))
    should.be_true(float.absolute_value(actual -. fixture.1) <. 1.0e-12)
  })
}

pub fn reviewed_edges_match_executed_pinned_oracle_test() -> Nil {
  let cases = [
    #([types.User("https://́")], 0.2),
    // combining_url
    #(
      [
        types.User("ordinary conversation length"),
        replay(
          types.Responses,
          "{\"type\": \"function_call\", \"id\": \"item\", \"call_id\": \"call\", \"name\": \"run\", \"arguments\": \"{\\\"x\\\":1e309}\"}",
        ),
      ],
      0.7894736842105263,
    ),
    // exponent_overflow
    #(
      [
        types.User("ordinary conversation length"),
        replay(
          types.Responses,
          "{\"type\": \"function_call\", \"id\": \"item\", \"call_id\": \"call\", \"name\": \"run\", \"arguments\": \"{\\\"x\\\":1000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000}\"}",
        ),
      ],
      0.7894736842105263,
    ),
    // integer_overflow
    #(
      [
        types.User("ordinary conversation length"),
        replay(
          types.Responses,
          "{\"type\": \"function_call\", \"id\": \"item\", \"call_id\": \"call\", \"name\": \"run\", \"arguments\": \"{\\\"x\\\":\\\"\\\\ud800\\\"}\"}",
        ),
      ],
      0.7333333333333334,
    ),
    // lone_surrogate
    #(
      [
        types.User("ordinary conversation length"),
        replay(
          types.Responses,
          "{\"type\": \"function_call\", \"id\": \"item\", \"call_id\": \"call\", \"name\": \"run\", \"arguments\": \"{\\\"x\\\":1,\\\"x\\\":\\\"short\\\"}\"}",
        ),
      ],
      0.7463414634146341,
    ),
    // duplicate_json_keys
    #(
      [
        types.User("ordinary conversation length"),
        replay(
          types.Responses,
          "{\"type\": \"function_call\", \"id\": \"item\", \"call_id\": \"call\", \"name\": \"run\", \"arguments\": \"{\\\"x\\\":\\\"\\\\ud83d\\\\ude00\\\"}\"}",
        ),
      ],
      0.7894736842105263,
    ),
    // surrogate_pair
    #(
      [
        types.User("ordinary conversation length"),
        replay(
          types.Responses,
          "{\"type\": \"function_call\", \"id\": \"item\", \"call_id\": \"call\", \"name\": \"run\", \"arguments\": \" null\\n\"}",
        ),
      ],
      0.9466666666666667,
    ),
    // top_null_whitespace
    #(
      [
        types.User("ordinary conversation length"),
        replay(
          types.Responses,
          "{\"type\": \"function_call\", \"id\": \"item\", \"call_id\": \"call\", \"name\": \"run\", \"arguments\": \"1e309\"}",
        ),
      ],
      0.9,
    ),
    // top_exponent_overflow
    #(
      [
        types.User("ordinary conversation length"),
        replay(
          types.Responses,
          "{\"type\": \"function_call\", \"id\": \"item\", \"call_id\": \"call\", \"name\": \"run\", \"arguments\": \"-1e309\"}",
        ),
      ],
      0.9,
    ),
    // top_negative_overflow
    #(
      [
        types.User("ordinary conversation length"),
        replay(
          types.Responses,
          "{\"type\": \"function_call\", \"id\": \"item\", \"call_id\": \"call\", \"name\": \"run\", \"arguments\": \"1000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000\"}",
        ),
      ],
      0.9,
    ),
    // top_integer_overflow
  ]
  list.each(cases, fn(fixture) {
    let assert Ok(facts) = list.try_map(fixture.0, context_salience.measure)
    should.be_true(
      float.absolute_value(
        context_salience.score(context_salience.combine(facts)) -. fixture.1,
      )
      <. 1.0e-12,
    )
  })
}
