%% E2E cannot observe EUnit's assertion/timeout fixture ownership or its locks.
-module(runtime_fixture_test).
-include_lib("eunit/include/eunit.hrl").

runtime_success_cleanup_test() -> runtime_case(success).
runtime_assertion_cleanup_test() -> runtime_case(assertion).
runtime_timeout_cleanup_test() -> runtime_case(timeout).
runtime_reopen_cleanup_test() -> runtime_case(reopen).
runtime_already_stopped_cleanup_test() -> runtime_case(stopped).
runtime_abnormal_exit_is_reported_test() -> runtime_case(abnormal).
runtime_failed_path_cleanup_drains_other_runtime_test() ->
    First = albedo_runtime_test_support:temporary_database(),
    Second = albedo_runtime_test_support:temporary_database(),
    Parent = self(),
    Test = fun() ->
        {ok, A} = albedo_runtime_test_support:start_with_config(First, {config, [], []}),
        {ok, B} = albedo_runtime_test_support:start_with_config(Second, {config, [], []}),
        Parent ! {known_runtime, A},
        Parent ! {known_runtime, B},
        {ok, Owner} = 'gleam@erlang@process':subject_owner(element(2, A)),
        Monitor = erlang:monitor(process, Owner),
        exit(Owner, kill),
        receive {'DOWN', Monitor, process, Owner, killed} -> ok end,
        ?assertException(error, {fixture_teardown_failed, _}, albedo_runtime_test_support:cleanup(First))
    end,
    ?assertEqual(error, eunit:test(albedo_runtime_test_support:with_runtime(Test), [no_tty])),
    lists:foreach(fun(_) ->
        receive {known_runtime, Runtime} -> assert_runtime_closed(Runtime)
        after 1000 -> error(runtime_was_not_started)
        end
    end, [first, second]),
    ?assertNot(filelib:is_regular(First)),
    ?assertNot(filelib:is_regular(Second)).
runtime_failed_start_preserves_files_and_error_test() ->
    Path = albedo_runtime_test_support:temporary_database(),
    Backup = <<Path/binary, ".backup">>,
    Sentinel = filename:join(Backup, <<"keep">>),
    ok = file:make_dir(Path),
    ok = file:make_dir(Backup),
    ok = file:write_file(Sentinel, <<"unowned">>),
    Parent = self(),
    Test = fun() ->
        Direct = 'albedo@harness@runtime':start_with_config(Path, {config, [], []}),
        Wrapped = albedo_runtime_test_support:start_with_config(Path, {config, [], []}),
        ?assertMatch({error, _}, Direct),
        ?assertEqual(Direct, Wrapped),
        Parent ! start_error_preserved
    end,
    ?assertEqual(error, eunit:test(albedo_runtime_test_support:with_runtime(Test), [no_tty])),
    receive start_error_preserved -> ok after 1000 -> error(start_error_changed) end,
    ?assertEqual({ok, <<"unowned">>}, file:read_file(Sentinel)),
    ok = file:del_dir_r(Backup),
    ok = file:del_dir(Path).
usage_assertion_cleanup_test() -> usage_case(assertion), usage_case(success).
usage_timeout_cleanup_test() -> usage_case(timeout), usage_case(success).

runtime_case(Mode) ->
    Path = albedo_runtime_test_support:temporary_database(),
    Neighbor = <<Path/binary, ".keep">>,
    ok = file:write_file(Neighbor, <<"keep me">>),
    Parent = self(),
    Test = fun() ->
        {ok, Runtime} = albedo_runtime_test_support:start_with_config(Path, {config, [], []}),
        Parent ! {known_runtime, Runtime},
        case Mode of
            reopen ->
                'albedo@harness@runtime':stop(Runtime),
                ?assert(filelib:is_regular(Path)),
                {ok, Reopened} = albedo_runtime_test_support:start_with_config(Path, {config, [], []}),
                Parent ! {known_runtime, Reopened};
            stopped -> 'albedo@harness@runtime':stop(Runtime);
            abnormal ->
                {ok, Owner} = 'gleam@erlang@process':subject_owner(element(2, Runtime)),
                exit(Owner, kill);
            _ -> outcome(Mode)
        end
    end,
    Descriptor = bounded(albedo_runtime_test_support:with_runtime(Test)),
    Expected = case Mode of success -> ok; reopen -> ok; stopped -> ok; _ -> error end,
    ?assertEqual(Expected, eunit:test(Descriptor, [no_tty, {scale_timeouts, 1}])),
    Count = case Mode of reopen -> 2; _ -> 1 end,
    lists:foreach(fun(_) ->
        receive {known_runtime, Runtime} -> assert_runtime_closed(Runtime)
        after 1000 -> error(runtime_was_not_started)
        end
    end, lists:seq(1, Count)),
    ?assertNot(filelib:is_regular(Path)),
    ?assertNot(filelib:is_regular(<<Path/binary, "-wal">>)),
    ?assertNot(filelib:is_regular(<<Path/binary, "-shm">>)),
    ?assertEqual({ok, <<"keep me">>}, file:read_file(Neighbor)),
    ok = file:delete(Neighbor).

assert_runtime_closed({runtime, Subject, Store, Shared}) ->
    {ok, Owner} = 'gleam@erlang@process':subject_owner(Subject),
    ?assertNot(is_process_alive(Owner)),
    ?assertNot(is_process_alive('albedo@daemon@store':owner(Store))),
    ?assertEqual(absent, persistent_term:get(Shared, absent)).

usage_case(Mode) ->
    Parent = self(),
    Test = fun(Fake) -> Parent ! {known_fake, Fake}, outcome(Mode) end,
    Expected = case Mode of success -> ok; _ -> error end,
    ?assertEqual(Expected, eunit:test(bounded(albedo_usage_test_support:with_fake(Test)),
                                    [no_tty, {scale_timeouts, 1}])),
    Fake = receive {known_fake, Known} -> Known
    after 1000 -> error(fake_was_not_started)
    end,
    ?assertNot(is_process_alive(maps:get(server, Fake))),
    ?assertNot(filelib:is_dir(maps:get(dir, Fake))),
    %% A different module may already own the next global override.
    ?assertNotEqual(maps:get(owner, Fake), whereis(albedo_usage_fake)),
    ?assertNotEqual(filename:join(maps:get(dir, Fake), "usage"), os:getenv("ALBEDO_USAGE_CORE")).

%% A deliberately blocked child has its own one-second regression deadline.
%% Existing production and suite deadlines remain unchanged.
bounded({setup, Start, Stop, Instantiate}) ->
    {setup, Start, Stop, fun(Fixture) -> {timeout, 1, Instantiate(Fixture)} end}.
outcome(success) -> ok;
outcome(assertion) -> ?assert(false);
outcome(timeout) -> receive intentional_fixture_hang -> ok end.
