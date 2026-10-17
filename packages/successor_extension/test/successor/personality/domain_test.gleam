//// Catches UTF-8 paging and replacement-size/allocation errors in the extracted
//// library. These boundaries have no installed daemon surface in slice 1.

import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import successor/personality/domain
import successor/personality/types as p

@external(erlang, "successor_edit_test_support", "count_replacements")
fn count_replacements(
  owner: process.Pid,
  run: fn() -> Result(String, p.DomainError),
) -> #(Result(String, p.DomainError), Int)

@external(erlang, "binary", "referenced_byte_size")
fn retained_bytes(value: String) -> Int

pub fn exact_write_limit_accepts_ascii_and_multibyte_documents_test() {
  domain.validate_document(string.repeat("a", 1_048_576)) |> should.be_ok
  domain.validate_document(string.repeat("🙂", 262_144)) |> should.be_ok
}

pub fn over_limit_uses_utf8_bytes_instead_of_character_count_test() {
  domain.validate_document(string.repeat("a", 1_048_577))
  |> should.equal(Error(p.Invalid("document exceeds 1 MiB UTF-8 write limit")))
  domain.validate_document(string.repeat("🙂", 262_145))
  |> should.equal(Error(p.Invalid("document exceeds 1 MiB UTF-8 write limit")))
}

pub fn unique_edit_preserves_surrounding_utf8_test() {
  domain.edit("before🙂after", "🙂", "你好", False)
  |> should.equal(Ok("before你好after"))
}

pub fn missing_empty_and_ambiguous_targets_refuse_test() {
  domain.edit("one two", "absent", "x", False)
  |> should.equal(Error(p.Conflict("old_string not found")))
  domain.edit("one two", "", "x", False)
  |> should.equal(Error(p.Invalid("old_string must be nonempty")))
  domain.edit("one one", "one", "x", False)
  |> should.equal(
    Error(p.Conflict(
      "old_string is ambiguous; supply more context or replace_all",
    )),
  )
}

pub fn replace_all_counts_only_nonoverlapping_matches_test() {
  domain.edit("aaa", "aa", "🙂", True) |> should.equal(Ok("🙂a"))
  domain.edit("one one", "one", "x", True) |> should.equal(Ok("x x"))
}

pub fn exact_sized_replacement_is_permitted_test() {
  let replacement = string.repeat("a", 1_048_576)
  domain.edit("x", "x", replacement, False) |> should.equal(Ok(replacement))
}

pub fn overflowing_edit_never_enters_replacement_allocator_test() {
  // A broken guard would allocate at most 2 MiB, not an OOM-sized probe.
  let replacement = string.repeat("x", 1_048_576)
  let #(outcome, calls) =
    count_replacements(process.self(), fn() {
      domain.edit("aa", "a", replacement, True)
    })
  outcome
  |> should.equal(Error(p.Invalid("document exceeds 1 MiB UTF-8 write limit")))
  calls |> should.equal(0)
}

pub fn allocation_observer_sees_actual_successful_replacement_test() {
  let #(outcome, calls) =
    count_replacements(process.self(), fn() {
      domain.edit("a", "a", "b", False)
    })
  outcome |> should.equal(Ok("b"))
  calls |> should.equal(1)
}

pub fn hashing_retains_standard_preimage_identity_test() {
  domain.hash("hello")
  |> should.equal(
    "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
  )
}

pub fn prefix_never_splits_codepoints_or_retains_the_source_binary_test() {
  domain.prefix("🙂z", -1) |> should.equal("")
  domain.prefix("🙂z", 3) |> should.equal("")
  domain.prefix("🙂z", 4) |> should.equal("🙂")
  domain.prefix("🙂z", 5) |> should.equal("🙂z")
  let prefix = domain.prefix(string.repeat("a", 1_048_576), 32_768)
  string.byte_size(prefix) |> should.equal(32_768)
  retained_bytes(prefix) |> should.equal(32_768)
}

pub fn paging_carries_revision_and_advances_by_utf8_bytes_test() {
  domain.page("ab🙂cd", 7, 0, 4)
  |> should.equal(Ok(p.DocumentPage(7, "ab", Some(2))))
  domain.page("ab🙂cd", 7, 2, 4)
  |> should.equal(Ok(p.DocumentPage(7, "🙂", Some(6))))
  domain.page("ab🙂cd", 7, 6, 2)
  |> should.equal(Ok(p.DocumentPage(7, "cd", None)))
}

pub fn invalid_offsets_and_nonprogressing_page_sizes_refuse_test() {
  domain.page("🙂x", 3, 1, 4)
  |> should.equal(Error(p.Invalid("offset must be a UTF-8 codepoint boundary")))
  domain.page("🙂x", 3, 0, 3)
  |> should.equal(
    Error(p.Invalid("page limit cannot fit the next UTF-8 codepoint")),
  )
  domain.page("x", 3, -1, 1) |> should.be_error
  domain.page("x", 3, 2, 1) |> should.be_error
  domain.page("x", 3, 0, 0) |> should.be_error
  domain.page("x", 3, 0, 32_769) |> should.be_error
}

pub fn empty_and_end_pages_terminate_without_an_offset_test() {
  domain.page("", 11, 0, 1) |> should.equal(Ok(p.DocumentPage(11, "", None)))
  domain.page("x", 11, 1, 1) |> should.equal(Ok(p.DocumentPage(11, "", None)))
}
