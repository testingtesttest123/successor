-module(successor_ffi).

-export([now_ms/0, println_stderr/1, ensure_parent_dir/1, stop_gen_server/1,
         spawn_unlinked/1, spawn_owned/1, subject_snapshot/1]).

now_ms() ->
    erlang:system_time(millisecond).

println_stderr(Line) ->
    io:put_chars(standard_error, [Line, $\n]),
    nil.

ensure_parent_dir(Path) ->
    %% Creates all parent directories of the file path (the data_dir itself),
    %% and does not fail if they already exist.
    filelib:ensure_dir(Path),
    nil.

%% Unlinked spawn: gleam_erlang's process.spawn is proc_lib:spawn_link, which
%% would tie the host keeper to its caller's
%% lifetime. Ownership here is explicit: the keeper owns the tree, nobody owns
%% the keeper.
spawn_unlinked(F) ->
    erlang:spawn(F).

stop_gen_server(Pid) ->
    %% Ordered termination for gleam_otp supervisors (gen_server-based):
    %% synchronous, does not propagate exit signals to the caller.
    gen_server:stop(Pid, normal, 10000),
    nil.

%% Snapshot the tag and pid together. A pid send cannot fail when the named
%% registry is briefly absent, nor accidentally target a later incarnation.
subject_snapshot({named_subject, Name}) ->
    case whereis(Name) of
        undefined -> {error, nil};
        Pid -> {ok, {subject, Pid, Name}}
    end;
subject_snapshot({subject, Pid, _} = Subject) ->
    case is_process_alive(Pid) of
        true -> {ok, Subject};
        false -> {error, nil}
    end.

%% One-way ownership: adapter failure is isolated from the agent, while
%% owner death (including kill and host shutdown) cannot orphan provider work.
%% Install the owner monitor before spawning work, and link the worker to
%% the guardian atomically. No cleanup callback in the dying owner is needed.
spawn_owned(F) ->
    Owner = self(),
    Ready = make_ref(),
    spawn(fun() ->
        process_flag(trap_exit, true),
        Monitor = monitor(process, Owner),
        Worker = spawn_link(F),
        Owner ! {Ready, Worker},
        receive
            {'DOWN', Monitor, process, Owner, _} ->
                exit(Worker, kill),
                receive {'EXIT', Worker, _} -> ok end;
            {'EXIT', Worker, _} ->
                demonitor(Monitor, [flush])
        end
    end),
    receive {Ready, Worker} -> Worker end.
