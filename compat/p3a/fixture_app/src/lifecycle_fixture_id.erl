%% Stock admissions require current UUIDv7 operation IDs, unlike mail.new_id.
-module(lifecycle_fixture_id).
-export([operation_id/0]).
operation_id() ->
    Now = erlang:system_time(millisecond),
    <<RandA:12, RandB:62, _:6>> = crypto:strong_rand_bytes(10),
    Hex = binary:encode_hex(<<Now:48, 7:4, RandA:12, 2:2, RandB:62>>, lowercase),
    <<A:8/binary, B:4/binary, C:4/binary, D:4/binary, E:12/binary>> = Hex,
    <<A/binary, "-", B/binary, "-", C/binary, "-", D/binary, "-", E/binary>>.
