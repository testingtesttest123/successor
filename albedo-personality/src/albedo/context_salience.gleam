//// Static salience at ingestion, pinned to context-manager 537d921 computeStaticSalience.
//// Facts combine before clamping
//// Units count JavaScript UTF-16, not UTF-8/graphemes.

import albedo/daemon/message_content
import albedo/openai_api/types
import gleam/dict
import gleam/float
import gleam/int
import gleam/list
import gleam/result
import gleam/string

pub const policy_version = 1

pub type SalienceFacts {
  SalienceFacts(total_utf16: Int, external_utf16: Int, policy_version: Int)
}

pub fn combine(facts: List(SalienceFacts)) -> SalienceFacts {
  list.fold(facts, SalienceFacts(0, 0, policy_version), fn(a, b) {
    SalienceFacts(
      a.total_utf16 + b.total_utf16,
      a.external_utf16 + b.external_utf16,
      policy_version,
    )
  })
}

pub fn score(facts: SalienceFacts) -> Float {
  case facts.total_utf16 <= 0 {
    True -> 1.0
    False ->
      float.max(
        0.2,
        1.0
          -. 0.8
          *. float.min(
          1.0,
          int.to_float(facts.external_utf16) /. int.to_float(facts.total_utf16),
        ),
      )
  }
}

pub fn measure(input: types.Input) -> Result(SalienceFacts, String) {
  case input {
    types.User(text) | types.Assistant(text) -> Ok(text_facts(text))
    types.UserImage(text, images) ->
      Ok(combine([text_facts(text), image_facts(images)]))
    types.ToolOutput(_, output, images) ->
      Ok(combine([external(utf16_length(output)), image_facts(images)]))
    types.Replay(item) -> {
      use parts <- result.try(
        message_content.portable_assistant_parts(item)
        |> result.replace_error(
          "static salience: malformed portable assistant semantics",
        ),
      )
      Ok(
        combine([
          text_facts(parts.0),
          ..list.map(parts.1, fn(call) {
            external(tool_input_size(call.arguments))
          })
        ]),
      )
    }
  }
}

fn image_facts(images: List(types.Image)) -> SalienceFacts {
  external(6400 * list.length(images))
}

fn external(size: Int) -> SalienceFacts {
  SalienceFacts(size, size, policy_version)
}

pub fn utf16_length(text: String) -> Int {
  count(<<text:utf8>>, 0, False)
}

fn count(bytes: BitArray, total: Int, escaped: Bool) -> Int {
  case bytes {
    <<cp:utf8_codepoint, rest:bytes>> -> {
      let code = string.utf_codepoint_to_int(cp)
      let size = case escaped, code {
        True, 34
        | True, 92
        | True, 8
        | True, 9
        | True, 10
        | True, 12
        | True, 13
        -> 2
        True, code if code < 32 -> 6
        _, code if code > 65_535 -> 2
        _, _ -> 1
      }
      count(rest, total + size, escaped)
    }
    _ -> total
  }
}

fn text_facts(text: String) -> SalienceFacts {
  let fences =
    text
    |> string.split("```")
    |> list.index_map(fn(part, i) {
      case i % 2 {
        1 -> utf16_length(part)
        _ -> 0
      }
    })
    |> list.fold(0, fn(a, b) { a + b })
  let links =
    text
    |> string.split("\n")
    |> list.fold(0, fn(total, line) {
      let scalars =
        string.to_utf_codepoints(line)
        |> list.drop_while(fn(cp) {
          ecma_space(string.utf_codepoint_to_int(cp))
        })
        |> list.reverse
        |> list.drop_while(fn(cp) {
          ecma_space(string.utf_codepoint_to_int(cp))
        })
        |> list.reverse
      let trimmed = string.from_utf_codepoints(scalars)
      let suffix = case
        string.starts_with(trimmed, "https://"),
        string.starts_with(trimmed, "http://")
      {
        True, _ -> string.from_utf_codepoints(list.drop(scalars, 8))
        _, True -> string.from_utf_codepoints(list.drop(scalars, 7))
        _, _ -> ""
      }
      case
        suffix != ""
        && !list.any(scalars, fn(cp) {
          ecma_space(string.utf_codepoint_to_int(cp))
        })
      {
        True -> total + utf16_length(trimmed)
        False -> total
      }
    })
  SalienceFacts(utf16_length(text), fences + links, policy_version)
}

fn ecma_space(code: Int) -> Bool {
  case code {
    9
    | 10
    | 11
    | 12
    | 13
    | 32
    | 160
    | 5760
    | 8232
    | 8233
    | 8239
    | 8287
    | 12_288
    | 65_279 -> True
    code if code >= 8192 && code <= 8202 -> True
    _ -> False
  }
}

type JsonValue {
  Null
  NonFinite
  Text(String)
  CodeUnits(List(Int))
  CodeObject(List(#(List(Int), JsonValue)))
  Number(Float)
  Boolean(Bool)
  Array(List(JsonValue))
}

// JSON.parse/JSON.stringify length, including ECMAScript overflow and lone surrogates.
// Parsing UTF-16 code units avoids silently treating valid JS JSON as literal text.
fn tool_input_size(arguments: String) -> Int {
  let codes =
    string.to_utf_codepoints(arguments) |> list.map(string.utf_codepoint_to_int)
  case parse_value(skip_json_space(codes)) {
    Ok(#(value, rest)) ->
      case skip_json_space(rest) {
        [] ->
          case value {
            Null -> 2
            _ -> json_size(value)
          }
        _ -> json_size(Text(arguments))
      }
    Error(_) -> json_size(Text(arguments))
  }
}

fn skip_json_space(codes: List(Int)) -> List(Int) {
  list.drop_while(codes, fn(c) { c == 32 || c == 9 || c == 10 || c == 13 })
}

fn parse_value(codes: List(Int)) -> Result(#(JsonValue, List(Int)), Nil) {
  case codes {
    [110, 117, 108, 108, ..rest] -> Ok(#(Null, rest))
    [116, 114, 117, 101, ..rest] -> Ok(#(Boolean(True), rest))
    [102, 97, 108, 115, 101, ..rest] -> Ok(#(Boolean(False), rest))
    [34, ..rest] -> {
      use parsed <- result.try(parse_json_string(rest, []))
      Ok(#(CodeUnits(parsed.0), parsed.1))
    }
    [91, ..rest] -> parse_array(skip_json_space(rest), [])
    [123, ..rest] -> parse_object(skip_json_space(rest), dict.new())
    _ -> parse_number(codes)
  }
}

fn parse_array(
  codes: List(Int),
  values: List(JsonValue),
) -> Result(#(JsonValue, List(Int)), Nil) {
  case codes {
    [93, ..rest] -> Ok(#(Array(list.reverse(values)), rest))
    _ -> {
      use parsed <- result.try(parse_value(codes))
      case skip_json_space(parsed.1) {
        [93, ..rest] -> Ok(#(Array(list.reverse([parsed.0, ..values])), rest))
        [44, ..rest] ->
          case skip_json_space(rest) {
            [93, ..] -> Error(Nil)
            more -> parse_array(more, [parsed.0, ..values])
          }
        _ -> Error(Nil)
      }
    }
  }
}

fn parse_object(
  codes: List(Int),
  values: dict.Dict(List(Int), JsonValue),
) -> Result(#(JsonValue, List(Int)), Nil) {
  case codes {
    [125, ..rest] -> Ok(#(CodeObject(dict.to_list(values)), rest))
    [34, ..rest] -> {
      use key <- result.try(parse_json_string(rest, []))
      use after <- result.try(case skip_json_space(key.1) {
        [58, ..rest] -> Ok(skip_json_space(rest))
        _ -> Error(Nil)
      })
      use parsed <- result.try(parse_value(after))
      let values = dict.insert(values, key.0, parsed.0)
      case skip_json_space(parsed.1) {
        [125, ..rest] -> Ok(#(CodeObject(dict.to_list(values)), rest))
        [44, ..rest] ->
          case skip_json_space(rest) {
            [125, ..] -> Error(Nil)
            more -> parse_object(more, values)
          }
        _ -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

fn parse_json_string(
  codes: List(Int),
  accumulated: List(Int),
) -> Result(#(List(Int), List(Int)), Nil) {
  case codes {
    [34, ..rest] -> Ok(#(list.reverse(accumulated), rest))
    [92, 117, a, b, c, d, ..rest] -> {
      use hex <- result.try(hex4(a, b, c, d))
      parse_json_string(rest, [hex, ..accumulated])
    }
    [92, escape, ..rest] -> {
      use code <- result.try(case escape {
        34 | 92 | 47 -> Ok(escape)
        98 -> Ok(8)
        102 -> Ok(12)
        110 -> Ok(10)
        114 -> Ok(13)
        116 -> Ok(9)
        _ -> Error(Nil)
      })
      parse_json_string(rest, [code, ..accumulated])
    }
    [code, ..rest] if code >= 32 && code != 92 -> {
      case code > 65_535 {
        True ->
          parse_json_string(rest, [
            56_320 + { code - 65_536 } % 1024,
            55_296 + { code - 65_536 } / 1024,
            ..accumulated
          ])
        False -> parse_json_string(rest, [code, ..accumulated])
      }
    }
    _ -> Error(Nil)
  }
}

fn hex4(a: Int, b: Int, c: Int, d: Int) -> Result(Int, Nil) {
  use a <- result.try(hex(a))
  use b <- result.try(hex(b))
  use c <- result.try(hex(c))
  use d <- result.try(hex(d))
  Ok(a * 4096 + b * 256 + c * 16 + d)
}

fn hex(code: Int) -> Result(Int, Nil) {
  case code {
    n if n >= 48 && n <= 57 -> Ok(n - 48)
    n if n >= 65 && n <= 70 -> Ok(n - 55)
    n if n >= 97 && n <= 102 -> Ok(n - 87)
    _ -> Error(Nil)
  }
}

fn units_size(units: List(Int)) -> Int {
  case units {
    [high, low, ..rest]
      if high >= 55_296 && high <= 56_319 && low >= 56_320 && low <= 57_343
    -> 2 + units_size(rest)
    [code, ..rest] -> {
      let n = case code {
        34 | 92 | 8 | 9 | 10 | 12 | 13 -> 2
        n if n < 32 || { n >= 55_296 && n <= 57_343 } -> 6
        _ -> 1
      }
      n + units_size(rest)
    }
    [] -> 0
  }
}

fn digit(code: Int) -> Bool {
  code >= 48 && code <= 57
}

fn valid_number(codes: List(Int)) -> Bool {
  let unsigned = case codes {
    [45, ..rest] -> rest
    _ -> codes
  }
  let after_integer = case unsigned {
    [48, ..rest] -> Ok(rest)
    [n, ..rest] if n >= 49 && n <= 57 -> Ok(list.drop_while(rest, digit))
    _ -> Error(Nil)
  }
  case after_integer {
    Error(_) -> False
    Ok(rest) -> {
      let after_fraction = case rest {
        [46, n, ..more] if n >= 48 && n <= 57 -> Ok(list.drop_while(more, digit))
        [46, ..] -> Error(Nil)
        _ -> Ok(rest)
      }
      case after_fraction {
        Error(_) -> False
        Ok([]) -> True
        Ok([exp, ..rest]) if exp == 69 || exp == 101 -> {
          let after_sign = case rest {
            [sign, ..rest] if sign == 43 || sign == 45 -> rest
            _ -> rest
          }
          case after_sign {
            [n, ..more] if n >= 48 && n <= 57 ->
              list.drop_while(more, digit) == []
            _ -> False
          }
        }
        _ -> False
      }
    }
  }
}

fn parse_number(codes: List(Int)) -> Result(#(JsonValue, List(Int)), Nil) {
  let digits =
    list.take_while(codes, fn(c) {
      c == 45
      || c == 43
      || c == 46
      || c == 69
      || c == 101
      || { c >= 48 && c <= 57 }
    })
  let raw =
    string.from_utf_codepoints(list.filter_map(digits, string.utf_codepoint))
  case valid_number(digits) {
    False -> Error(Nil)
    True -> {
      let sign = case string.starts_with(raw, "-") {
        True -> "-"
        False -> ""
      }
      let unsigned = case sign {
        "-" -> string.drop_start(raw, 1)
        _ -> raw
      }
      let pieces = string.split(string.lowercase(unsigned), "e")
      let mantissa = list.first(pieces) |> result.unwrap("0")
      let exponent = case pieces {
        [_, exp] -> int.parse(string.replace(exp, "+", "")) |> result.unwrap(0)
        _ -> 0
      }
      let segments = string.split(mantissa, ".")
      let before = list.first(segments) |> result.unwrap("0")
      let all = string.concat(segments)
      let significant = trim_zero_start(all)
      let position =
        string.byte_size(before)
        + exponent
        - { string.byte_size(all) - string.byte_size(significant) }
      let normalized =
        sign
        <> string.slice(significant, 0, 1)
        <> "."
        <> string.drop_start(significant, 1)
        <> "0e"
        <> int.to_string(position - 1)
      let number = case significant == "0", position {
        True, _ -> Number(0.0)
        _, p if p > 309 -> NonFinite
        _, p if p < -325 -> Number(0.0)
        _, _ ->
          case float.parse(normalized) {
            Ok(n) -> Number(n)
            Error(_) -> NonFinite
          }
      }
      Ok(#(number, list.drop(codes, list.length(digits))))
    }
  }
}

fn json_size(value: JsonValue) -> Int {
  case value {
    CodeUnits(units) -> 2 + units_size(units)
    CodeObject(values) ->
      2
      + int.max(0, list.length(values) - 1)
      + list.fold(values, 0, fn(n, pair) {
        n + 2 + units_size(pair.0) + 1 + json_size(pair.1)
      })
    Null | NonFinite -> 4
    Text(text) -> 2 + count(<<text:utf8>>, 0, True)
    Boolean(True) -> 4
    Boolean(False) -> 5
    Number(value) -> string.byte_size(js_number(value))
    Array(values) ->
      2
      + int.max(0, list.length(values) - 1)
      + list.fold(values, 0, fn(n, value) { n + json_size(value) })
  }
}

// OTP's shortest round-tripping digits, reformatted with ECMAScript's fixed/exponent thresholds.
fn js_number(number: Float) -> String {
  case number == 0.0 {
    True -> "0"
    False -> {
      let sign = case number <. 0.0 {
        True -> "-"
        False -> ""
      }
      let parts =
        float.to_string(float.absolute_value(number)) |> string.split("e")
      let #(mantissa, exponent) = case parts {
        [m, e] -> #(
          m,
          int.parse(string.replace(e, "+", "")) |> result.unwrap(0),
        )
        [m] -> #(m, 0)
        _ -> #("0", 0)
      }
      let segments = string.split(mantissa, ".")
      let before = list.first(segments) |> result.unwrap("")
      let all = string.concat(segments)
      let digits = trim_zero_start(all)
      let position =
        string.byte_size(before)
        + exponent
        - { string.byte_size(all) - string.byte_size(digits) }
      let digits = trim_zero_end(digits)
      let size = string.byte_size(digits)
      let body = case position {
        p if p > 0 && p <= 21 -> {
          case p >= size {
            True -> digits <> string.repeat("0", p - size)
            False ->
              string.slice(digits, 0, p) <> "." <> string.drop_start(digits, p)
          }
        }
        p if p <= 0 && p > -6 -> "0." <> string.repeat("0", -p) <> digits
        p -> {
          let head = string.slice(digits, 0, 1)
          let rest = string.drop_start(digits, 1)
          let tail = case rest {
            "" -> ""
            _ -> "." <> rest
          }
          head
          <> tail
          <> "e"
          <> case p - 1 >= 0 {
            True -> "+"
            False -> ""
          }
          <> int.to_string(p - 1)
        }
      }
      sign <> body
    }
  }
}

fn trim_zero_start(text: String) -> String {
  case string.starts_with(text, "0") && string.byte_size(text) > 1 {
    True -> trim_zero_start(string.drop_start(text, 1))
    False -> text
  }
}

fn trim_zero_end(text: String) -> String {
  case string.ends_with(text, "0") && string.byte_size(text) > 1 {
    True -> trim_zero_end(string.slice(text, 0, string.byte_size(text) - 1))
    False -> text
  }
}
