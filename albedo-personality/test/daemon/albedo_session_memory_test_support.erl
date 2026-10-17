-module(albedo_session_memory_test_support).
-export([queued/1, late_composition/2, count_reads/2, fixture_cleanup/1]).
-include_lib("eunit/include/eunit.hrl").

%% Exercise the real native memory fixture under EUnit's assertion and killed
%% body paths. Observe ownership before fallback cleanup of this known fixture.
fixture_cleanup(Start) ->
    lists:foreach(fun(Mode) -> fixture_cleanup(Start, Mode) end,
                  [assertion, timeout, success]).

fixture_cleanup(Start, Mode) ->
    Parent = self(),
    Ref = make_ref(),
    Test = fun() ->
        Fixture = Start(),
        Parent ! {known_memory_fixture, Ref, Fixture},
        case Mode of
            assertion -> ?assert(false);
            timeout -> receive intentional_memory_fixture_hang -> ok end;
            success -> ok
        end
    end,
    {setup, Setup, Cleanup, Instantiate} = albedo_runtime_test_support:with_runtime(Test),
    Descriptor = {setup, Setup, Cleanup,
                  fun(Owner) -> {timeout, 1, Instantiate(Owner)} end},
    Expected = case Mode of success -> ok; _ -> error end,
    Result = eunit:test(Descriptor, [no_tty, {scale_timeouts, 1}]),
    Fixture = receive {known_memory_fixture, Ref, Known} -> Known
              after 1000 -> error(memory_fixture_did_not_start)
              end,
    {Runtime, Home, Session} = Fixture,
    {runtime, Subject, Store, Shared} = Runtime,
    {ok, RuntimeOwner} = 'gleam@erlang@process':subject_owner(Subject),
    {ok, SessionOwner} = 'gleam@erlang@process':subject_owner(Session),
    Observation = {is_process_alive(RuntimeOwner),
                   is_process_alive('albedo@daemon@store':owner(Store)),
                   persistent_term:get(Shared, absent) =/= absent,
                   is_process_alive(SessionOwner), filelib:is_dir(Home)},
    try
        ?assertEqual(Expected, Result),
        ?assertEqual({false, false, false, false, false}, Observation)
    after
        %% A red regression must not leave its deliberately failed fixture alive.
        case is_process_alive(SessionOwner) of
            true -> 'albedo@daemon@session':close(Session);
            false -> ok
        end,
        case is_process_alive(RuntimeOwner) of
            true -> 'albedo@harness@runtime':stop(Runtime);
            false -> ok
        end,
        _ = file:del_dir_r(Home)
    end.

%% The runtime's accepted composition request remains queued beyond the
%% production15s deadline. Always release its suspension, including test errors.
late_composition(Owner, Start) ->
    true = erlang:suspend_process(Owner),
    try
        Result = Start(),
        timer:sleep(16000),
        Result
    after
        true = erlang:resume_process(Owner)
    end.

%% Count real source decoding and transactional prefix rows, not estimates or
%% wall-clock performance. Only the selected store owner emits row traces.
count_reads(Owner, Work) ->
    Mfa = {albedo@daemon@conversation, sourced_entry, 3},
    Rows = {albedo@daemon@store, rows, 4},
    Tracer = spawn(fun() -> trace_rows(0, false) end),
    erlang:trace_pattern(Rows, [{'_', [], [{return_trace}]}], [local]),
    erlang:trace(Owner, true, [call, {tracer, Tracer}]),
    erlang:trace_pattern(Mfa, true, [local, call_count]),
    try
        Result = Work(),
        {call_count, Decoded} = erlang:trace_info(Mfa, call_count),
        Ref = erlang:trace_delivered(Owner),
        receive {trace_delivered, Owner, Ref} -> ok end,
        Tracer ! {count, self()},
        Count = receive {count, N} -> N end,
        {Result, Decoded, Count}
    after
        erlang:trace_pattern(Mfa, false, [local, call_count]),
        erlang:trace(Owner, false, [call]),
        erlang:trace_pattern(Rows, false, [local]),
        Tracer ! stop
    end.

trace_rows(N, Active) ->
    receive
        {trace, _, call, {albedo@daemon@store, rows, [_, Sql, _, _]}} ->
            Prefix = <<"SELECT seq,row_class FROM transcript WHERE session=? AND seq>?">>,
            Match = binary:match(Sql, Prefix) =:= {0, byte_size(Prefix)},
            trace_rows(N, Match);
        {trace, _, return_from, {albedo@daemon@store, rows, 4}, {ok, Rows}} when Active ->
            trace_rows(N + length(Rows), false);
        {trace, _, return_from, {albedo@daemon@store, rows, 4}, _} ->
            trace_rows(N, false);
        {count, Caller} -> Caller ! {count, N}, trace_rows(N, Active);
        stop -> ok;
        _ -> trace_rows(N, Active)
    end.

%% The store is deliberately held in a real query. Observe a queued native
%% closure before closing its owning actor; no database state is fabricated.
queued(Owner) -> queued(Owner, erlang:monotonic_time(millisecond) + 1000).
queued(Owner, Deadline) ->
    case process_info(Owner, message_queue_len) of
        {message_queue_len, N} when N > 0 -> true;
        _ ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true -> timer:sleep(1), queued(Owner, Deadline);
                false -> false
            end
    end.
