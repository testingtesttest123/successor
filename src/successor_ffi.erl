-module(successor_ffi).

-export([now_ms/0, println_stderr/1, ensure_parent_dir/1, stop_gen_server/1,
         spawn_unlinked/1]).

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
%% would tie the host keeper (and the agent's provider tasks) to their caller's
%% lifetime. Ownership here is explicit: the keeper owns the tree, nobody owns
%% the keeper.
spawn_unlinked(F) ->
    erlang:spawn(F).

stop_gen_server(Pid) ->
    %% Ordered termination for gleam_otp supervisors (gen_server-based):
    %% synchronous, does not propagate exit signals to the caller.
    gen_server:stop(Pid, normal, 10000),
    nil.
