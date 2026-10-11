-module(albedo_runtime_test_support).
-export([temporary_database/0, cleanup/1, temporary_workspace/0, cleanup_workspace/1,
         with_runtime/1, start/1, start_with_config/2,
         kernel_memory/1, catalog_does_not_block/3, catalog_forget_while_blocked/3,
         hold_preparation/2, capture_during_preparation/3]).
temporary_workspace() ->
    Path = filename:join(os:getenv("TMPDIR", "/tmp"),
                         "runtime-workspace-" ++ binary_to_list(albedo_native:new_id())),
    ok = file:make_dir(Path),
    unicode:characters_to_binary(Path).
cleanup_workspace(Path) ->
    _ = file:del_dir_r(Path),
    nil.
temporary_database() ->
    unicode:characters_to_binary(filename:join(os:getenv("TMPDIR", "/tmp"), "albedo-" ++ binary_to_list(albedo_native:new_id()) ++ ".sqlite" )).
cleanup(Path) ->
    case get({?MODULE, fixture_owner}) of
        undefined -> cleanup_files(Path);
        Owner -> fixture_call(Owner, {cleanup_path, Path})
    end.
cleanup_files(<<":memory:">>) -> nil;
cleanup_files(Path) ->
    lists:foreach(fun(Suffix) -> file:delete(<<Path/binary, Suffix/binary>>) end,
                  [<<>>, <<"-wal">>, <<"-shm">>]),
    _ = file:del_dir_r(<<Path/binary, ".backup">>),
    nil.

%% EUnit's setup owner survives assertion failures and killed test bodies.
%% One owner tracks every reopening; all owners stop before any DB is unlinked.
with_runtime(Test) ->
    {setup, fun fixture_owner/0, fun(Owner) -> fixture_call(Owner, finish) end,
     fun(Owner) -> fun() ->
         put({?MODULE, fixture_owner}, Owner),
         try Test() after erase({?MODULE, fixture_owner}) end
     end end}.

start(Path) ->
    fixture_start(Path, fun() -> 'albedo@harness@runtime':start(Path) end).
start_with_config(Path, Config) ->
    fixture_start(Path, fun() -> 'albedo@harness@runtime':start_with_config(Path, Config) end).
fixture_start(Path, Start) ->
    case get({?MODULE, fixture_owner}) of
        undefined -> Start();
        Owner -> fixture_call(Owner, {start, Path, Start})
    end.

fixture_owner() ->
    Parent = self(),
    Owner = spawn(fun() ->
        process_flag(trap_exit, true),
        Monitor = erlang:monitor(process, Parent),
        fixture_loop(Monitor, [], {#{}, []})
    end),
    Owner.

fixture_call(Owner, Request) ->
    Ref = erlang:monitor(process, Owner),
    Owner ! {request, self(), Ref, Request},
    receive
        {reply, Ref, {returned, Value}} -> erlang:demonitor(Ref, [flush]), Value;
        {reply, Ref, {raised, Class, Reason, Stack}} ->
            erlang:demonitor(Ref, [flush]), erlang:raise(Class, Reason, Stack);
        {'DOWN', Ref, process, Owner, Reason} -> error({fixture_owner_failed, Reason})
    end.

fixture_loop(Monitor, Runtimes, {Paths, EarlierFailures}) ->
    receive
        {request, Caller, Ref, {start, Path, Start}} ->
            Result = try {returned, Start()} catch C:R:S -> {raised, C, R, S} end,
            {Next, NextPaths} = case Result of
                {returned, {ok, Runtime}} ->
                    {[{Path, Runtime, monitor_runtime(Runtime)} | Runtimes],
                     Paths#{Path => maps:get(Path, Paths, owned)}};
                _ -> {Runtimes, Paths#{Path => unresolved}}
            end,
            Caller ! {reply, Ref, Result},
            fixture_loop(Monitor, Next, {NextPaths, EarlierFailures});
        {request, Caller, Ref, {cleanup_path, Path}} ->
            {Owned, Rest} = lists:partition(fun({P, _, _}) -> P =:= Path end, Runtimes),
            {Closed, Failures} = stop_fixture_runtimes(Owned),
            OwnedPath = maps:get(Path, Paths, unresolved) =:= owned,
            Value = case Closed andalso OwnedPath of true -> cleanup_files(Path); false -> nil end,
            CleanupFailures = Failures ++ unresolved_paths(maps:with([Path], Paths)),
            Reply = case CleanupFailures of
                [] -> {returned, Value};
                _ -> {raised, error, {fixture_teardown_failed, CleanupFailures}, []}
            end,
            Caller ! {reply, Ref, Reply},
            %% A failed request must not kill the owner before EUnit teardown
            %% drains other fixtures. An actor can die after a missed DOWN:
            %% retain every unresolved handle so its known key still gets erased.
            Remaining = case Closed of
                true -> [];
                false -> [{P, Runtime, monitor_runtime(Runtime)} || {P, Runtime, _} <- Owned]
            end,
            fixture_loop(Monitor, Remaining ++ Rest, {Paths, EarlierFailures ++ CleanupFailures});
        {request, Caller, Ref, finish} ->
            finish_fixture(Runtimes, Paths, EarlierFailures),
            Caller ! {reply, Ref, {returned, nil}};
        {'DOWN', Monitor, process, _, _} -> finish_fixture(Runtimes, Paths, EarlierFailures);
        {'EXIT', _, _} -> fixture_loop(Monitor, Runtimes, {Paths, EarlierFailures})
    end.

finish_fixture(Runtimes, Paths, EarlierFailures) ->
    {Closed, Failures} = stop_fixture_runtimes(Runtimes),
    case Closed of
        true -> lists:foreach(fun cleanup_files/1, [P || {P, owned} <- maps:to_list(Paths)]);
        false -> ok
    end,
    require_fixture_cleanup(EarlierFailures ++ Failures ++ unresolved_paths(Paths)).

%% No returned handle means the fixture has no store-DOWN proof for that path.
%% Preserve files and the startup error; teardown reports its own incomplete ownership.
unresolved_paths(Paths) -> [{fixture_start_unresolved, P} || {P, unresolved} <- maps:to_list(Paths)].

monitor_runtime({runtime, Subject, Store, _}) ->
    {ok, Owner} = 'gleam@erlang@process':subject_owner(Subject),
    StoreOwner = 'albedo@daemon@store':owner(Store),
    {Owner, erlang:monitor(process, Owner), StoreOwner, erlang:monitor(process, StoreOwner)}.

stop_fixture_runtimes(Runtimes) ->
    Results = [stop_fixture_runtime(Runtime, Monitors) || {_, Runtime, Monitors} <- Runtimes],
    {lists:all(fun({Closed, _}) -> Closed end, Results),
     lists:append([Failures || {_, Failures} <- Results])}.

require_fixture_cleanup([]) -> ok;
require_fixture_cleanup(Failures) -> error({fixture_teardown_failed, Failures}).

stop_fixture_runtime({runtime, _, Store, Shared} = Runtime, {Owner, R, StoreOwner, S}) ->
    %% A success-tail stop can already have acknowledged/released its key while
    %% the actor is finishing. Its DOWN barrier, rather than a second Stop, wins.
    Stop = try
        case {is_process_alive(Owner), persistent_term:get(Shared, absent) =/= absent,
              is_process_alive(StoreOwner)} of
            {true, true, _} -> 'albedo@harness@runtime':stop(Runtime);
            {false, _, true} -> 'albedo@daemon@store':close(Store);
            _ -> ok
        end,
        ok
    catch C:Reason -> {C, Reason}
    end,
    Results = [await_fixture_down(R, Owner), await_fixture_down(S, StoreOwner)],
    [RuntimeDown, _] = Results,
    case RuntimeDown of
        {down, _} -> 'albedo@shared':release(Shared);
        {alive, _} -> ok
    end,
    Failures = [Failure || {_, Failure} <- Results, Failure =/= ok],
    StopFailures = case {Stop, Failures} of
        {ok, _} -> [];
        {_, []} -> []; % A concurrent normal stop won the race.
        {Error, _} -> [{fixture_stop_failed, Error}]
    end,
    {lists:all(fun({Status, _}) -> Status =:= down end, Results), Failures ++ StopFailures}.

await_fixture_down(Ref, Owner) ->
    receive
        {'DOWN', Ref, process, Owner, Reason} when Reason =:= normal; Reason =:= shutdown -> {down, ok};
        {'DOWN', Ref, process, Owner, Reason} -> {down, {fixture_owner_failed, Owner, Reason}}
    after 1000 -> {alive, {fixture_owner_did_not_stop, Owner}}
    end.

%% A barrier followed by GC measures retained ownership, not transient boot garbage.
kernel_memory({session, _, _, Kernel, _, _, _, _, _}) ->
    _ = albedo_python:events(Kernel),
    true = erlang:garbage_collect(Kernel),
    {memory, Bytes} = erlang:process_info(Kernel, memory),
    Bytes.

%% A catalog worker waiting on the real ledger must not own the runtime loop.
catalog_does_not_block(Runtime, Home, Id) ->
    Store = 'albedo@harness@runtime':ledger(Runtime),
    Owner = 'albedo@daemon@store':owner(Store),
    erlang:suspend_process(Owner),
    Parent = self(),
    Worker = spawn_link(fun() ->
        Result = 'albedo@harness@runtime':observe_catalog(Runtime, Home, Id),
        Parent ! {catalog_complete, self(), Result}
    end),
    try
        await_store_query(Owner, erlang:monotonic_time(millisecond) + 3000),
        Reader = spawn_link(fun() ->
            Loaded = 'albedo@harness@runtime':loaded_sessions(Runtime),
            Parent ! {loaded_complete, self(), Loaded}
        end),
        Responsive = receive
            {loaded_complete, Reader, _} -> true
        after 1000 -> false
        end,
        erlang:resume_process(Owner),
        Completed = receive
            {catalog_complete, Worker, {ok, _}} -> true;
            {catalog_complete, Worker, {error, _}} -> false
        after 10000 -> false
        end,
        {Responsive, Completed}
    after
        resume(Owner)
    end.

%% The catalog began against a prepared composition that is removed while its
%% discovery is held. Its eventual response must observe that newer ownership.
catalog_forget_while_blocked(Runtime, Home, Id) ->
    Store = 'albedo@harness@runtime':ledger(Runtime),
    Owner = 'albedo@daemon@store':owner(Store),
    erlang:suspend_process(Owner),
    Parent = self(),
    Worker = spawn_link(fun() ->
        Result = 'albedo@harness@runtime':observe_catalog(Runtime, Home, Id),
        Parent ! {catalog_complete, self(), Result}
    end),
    try
        await_store_query(Owner, erlang:monotonic_time(millisecond) + 3000),
        'albedo@harness@runtime':forget_session(Runtime, Id),
        erlang:resume_process(Owner),
        receive
            {catalog_complete, Worker, Result} -> Result
        after 10000 -> error(catalog_did_not_complete)
        end
    after
        resume(Owner)
    end.

%% A body that already resumed Owner leaves nothing to resume.
resume(Owner) ->
    try erlang:resume_process(Owner) catch error:badarg -> false end.

await_store_query(Owner, Deadline) ->
    case process_info(Owner, message_queue_len) of
        {message_queue_len, N} when N > 0 -> ok;
        _ ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true -> receive after 10 -> ok end, await_store_query(Owner, Deadline);
                false -> error(catalog_did_not_query_store)
            end
    end.

%% The real composition worker calls this context loader. Only an explicit
%% release lets it finish; no process state or runtime messages are injected.
hold_preparation(Parent, Workspace) ->
    Parent ! {preparation_held, self(), Workspace},
    receive
        release_preparation -> {ok, <<>>}
    after 20000 -> {error, <<"preparation release was not received">>}
    end.

capture_during_preparation(Runtime, Session, Requests) ->
    Parent = self(),
    %% Fixture startup follows peek_commands' deadline, not a latency assertion.
    Deadline = erlang:monotonic_time(millisecond) + 15000,
    %% Inspect only the public runtime handle's subject, never actor State.
    {ok, Owner} = 'gleam@erlang@process':subject_owner(element(2, Runtime)),
    Callers = [spawn(fun() ->
        erlang:trace(self(), true, [send, {tracer, Parent}]),
        Result = try 'albedo@harness@runtime':peek_commands(Runtime, Id, Workspace)
                 catch Class:Reason -> {error, {preparation_caller_failed, Class, Reason}}
                 end,
        erlang:trace(self(), false, [send]),
        Parent ! {preparation_complete, self(), Result}
    end) || {Id, Workspace} <- Requests],
    try
        await_preparation_requests(Callers, Owner, Deadline),
        %% All actual request sends precede this public owner roundtrip.
        _ = 'albedo@harness@runtime':loaded_sessions(Runtime),
        await_preparation_hold(Deadline),
        Captured = 'albedo@daemon@session':capture(Session),
        Completed = release_preparations(Callers, true),
        {Captured, Completed}
    catch Class:Reason:Stack ->
        %% Failure during setup must also release callbacks and drain callers.
        _ = release_preparations(Callers, true),
        erlang:raise(Class, Reason, Stack)
    end.

await_preparation_requests([], _Owner, _Deadline) -> ok;
await_preparation_requests(Callers, Owner, Deadline) ->
    receive
        {trace, Caller, send, _, Owner} ->
            await_preparation_requests(lists:delete(Caller, Callers), Owner, Deadline);
        {preparation_complete, _, _} = Completion ->
            self() ! Completion,
            error({preparation_completed_before_admission, Completion})
    after max(0, Deadline - erlang:monotonic_time(millisecond)) ->
        error(preparation_request_was_not_sent)
    end.

await_preparation_hold(Deadline) ->
    receive
        {preparation_held, _, _} = Held ->
            %% Retain the hold so cleanup releases it after synchronous capture.
            self() ! Held;
        {preparation_complete, _, _} = Completion ->
            self() ! Completion,
            error({preparation_completed_before_context_hold, Completion})
    after max(0, Deadline - erlang:monotonic_time(millisecond)) ->
        error(preparation_context_did_not_start_before_call_deadline)
    end.

release_preparations([], Completed) -> Completed;
release_preparations(Callers, Completed) ->
    receive
        {preparation_held, Worker, _} ->
            Worker ! release_preparation,
            release_preparations(Callers, Completed);
        {preparation_complete, Caller, Result} ->
            Successful = case Result of {ok, _} -> true; _ -> false end,
            release_preparations(lists:delete(Caller, Callers), Completed andalso Successful);
        {trace, _, send, _, _} -> release_preparations(Callers, Completed)
    after 10000 -> false
    end.
