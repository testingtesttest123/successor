%% Process-owned protocol-v1 transport for successor/python.gleam.
%% Independent small implementation informed by Albedo's framing and ownership
%% lessons; no Albedo source is copied here.
-module(successor_python_ffi).

-export([start/1, execute/5, close/1, os_pid/1]).

-define(STARTUP_MS, 5000).
-define(MAX_FRAME, 67108864).
-define(RESPONSE_OVERHEAD, 65536).
-define(MAX_OUTPUT, ((?MAX_FRAME - ?RESPONSE_OVERHEAD) div 6)).

start(Workspace) when is_binary(Workspace) ->
    Caller = self(),
    Ref = make_ref(),
    {Pid, Mon} = spawn_monitor(fun() -> init(Caller, Ref, Workspace) end),
    receive
        {Ref, Result} -> demonitor(Mon, [flush]), Result;
        {'DOWN', Mon, process, Pid, Reason} ->
            {error, detail(<<"python transport failed to start">>, Reason)}
    after ?STARTUP_MS + 1000 ->
        exit(Pid, kill),
        {error, <<"python transport startup timed out">>}
    end;
start(_) -> {error, <<"workspace must be a string">>}.

execute(Pid, Id, Source, Timeout, MaxOutput)
        when is_pid(Pid), is_binary(Id), is_binary(Source), is_integer(Timeout),
             is_integer(MaxOutput) ->
    call(Pid, {execute, Id, Source, Timeout, MaxOutput});
execute(_, _, _, _, _) -> {error, <<"invalid execute arguments">>}.

close(Pid) when is_pid(Pid) ->
    case call(Pid, close) of _ -> nil end;
close(_) -> nil.

os_pid(Pid) when is_pid(Pid) ->
    case call(Pid, os_pid) of {ok, N} when is_integer(N) -> N; _ -> -1 end;
os_pid(_) -> -1.

call(Pid, Request) ->
    Ref = make_ref(),
    Mon = monitor(process, Pid),
    Pid ! {call, self(), Ref, Request},
    receive
        {Ref, Reply} -> demonitor(Mon, [flush]), Reply;
        {'DOWN', Mon, process, Pid, _} -> {error, <<"python kernel is closed">>}
    end.

init(Owner, Ref, Workspace) ->
    process_flag(trap_exit, true),
    OwnerMon = monitor(process, Owner),
    case boot(Workspace) of
        {ok, LockPort, Port, OsPid} ->
            case startup(Port, OsPid) of
                ok ->
                    Owner ! {Ref, {ok, self()}},
                    loop(#{owner_mon => OwnerMon, lock => LockPort,
                           port => Port, os_pid => OsPid});
                {error, Reason} ->
                    terminate(Port, OsPid),
                    release_lock(LockPort),
                    Owner ! {Ref, {error, Reason}}
            end;
        {error, Reason} -> Owner ! {Ref, {error, Reason}}
    end.

boot(Workspace) ->
    case binary:match(Workspace, <<0>>) of
        nomatch -> boot_path(Workspace);
        _ -> {error, <<"workspace contains a NUL byte">>}
    end.

boot_path(Workspace) ->
    Path = filename:absname(binary_to_list(Workspace)),
    Tmp = filename:join(Path, ".tmp"),
    Runtime = filename:join(Path, ".successor-runtime"),
    case ensure_private(Path, Tmp, Runtime) of
        ok ->
            case {os:find_executable("env"), os:find_executable("python3"), scripts()} of
                {false, _, _} -> {error, <<"env executable not found">>};
                {_, false, _} -> {error, <<"python3 executable not found">>};
                {_, _, {error, Why}} -> {error, Why};
                {Env, Python, {ok, Kernel, Lock}} ->
                    open_locked(Env, Python, Kernel, Lock, Path, Tmp, Runtime)
            end;
        {error, Reason} -> {error, detail(<<"cannot prepare python workspace">>, Reason)}
    end.

ensure_private(Path, Tmp, Runtime) ->
    case filelib:ensure_dir(filename:join(Path, ".keep")) of
        ok ->
            _ = file:change_mode(Path, 8#700),
            case filelib:ensure_dir(filename:join(Tmp, ".keep")) of
                ok ->
                    _ = file:change_mode(Tmp, 8#700),
                    case filelib:ensure_dir(filename:join(Runtime, ".keep")) of
                        ok -> _ = file:change_mode(Runtime, 8#700), ok;
                        RuntimeError -> RuntimeError
                    end;
                Error -> Error
            end;
        Error -> Error
    end.

scripts() ->
    case code:priv_dir(successor) of
        {error, _} -> {error, <<"successor priv directory unavailable">>};
        Dir ->
            Kernel = filename:join([Dir, "python", "kernel.py"]),
            Lock = filename:join([Dir, "python", "lock.py"]),
            case filelib:is_regular(Kernel) andalso filelib:is_regular(Lock) of
                true -> {ok, Kernel, Lock};
                false -> {error, <<"python runtime script is missing">>}
            end
    end.

open_locked(Env, Python, Kernel, Lock, Workspace, Tmp, Runtime) ->
    LockFile = filename:join(Runtime, "kernel.lock"),
    Args = ["-i", "HOME=" ++ Workspace, "TMPDIR=" ++ Tmp,
            "LC_ALL=C.UTF-8", "LANG=C.UTF-8", "PATH=/usr/bin:/bin",
            Python, "-I", "-u", Lock, LockFile],
    try open_port({spawn_executable, Env},
                  [binary, use_stdio, exit_status, hide,
                   {args, Args}, {cd, Workspace}]) of
        LockPort ->
            case lock_startup(LockPort) of
                ok ->
                    case open(Env, Python, Kernel, Workspace, Tmp) of
                        {ok, Port, OsPid} -> {ok, LockPort, Port, OsPid};
                        Error -> safe_port_close(LockPort), Error
                    end;
                Error -> safe_port_close(LockPort), Error
            end
    catch _:Reason -> {error, detail(<<"could not acquire workspace lock">>, Reason)}
    end.

lock_startup(LockPort) ->
    Deadline = erlang:monotonic_time(millisecond) + ?STARTUP_MS,
    lock_startup(LockPort, Deadline, new_parser()).

lock_startup(LockPort, Deadline, Parser) ->
    After = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {LockPort, {data, Data}} ->
            case feed_frame(Data, Parser, 4096) of
                {more, Next} -> lock_startup(LockPort, Deadline, Next);
                {frame, Frame, <<>>} -> decode_lock_startup(Frame);
                {frame, _, _Trailing} -> {error, <<"invalid trailing workspace lock data">>};
                {error, Reason} -> {error, Reason}
            end;
        {LockPort, {exit_status, _}} -> {error, <<"workspace lock helper exited">>};
        {'EXIT', LockPort, _} -> {error, <<"workspace lock helper closed">>}
    after After -> {error, <<"workspace lock acquisition timed out">>}
    end.

decode_lock_startup(Data) ->
    try json:decode(Data) of
        #{<<"v">> := 1, <<"type">> := <<"lock_ready">>} -> ok;
        #{<<"v">> := 1, <<"type">> := <<"lock_busy">>} ->
            {error, <<"python workspace is already active">>};
        _ -> {error, <<"invalid workspace lock handshake">>}
    catch _:_ -> {error, <<"malformed workspace lock handshake">>} end.

open(Env, Python, Script, Workspace, Tmp) ->
    Args = ["-i", "HOME=" ++ Workspace, "TMPDIR=" ++ Tmp,
            "LC_ALL=C.UTF-8", "LANG=C.UTF-8", "PATH=/usr/bin:/bin",
            Python, "-I", "-u", Script],
    try open_port({spawn_executable, Env},
                  [binary, use_stdio, stderr_to_stdout, exit_status, hide,
                   {args, Args}, {cd, Workspace}]) of
        Port ->
            case erlang:port_info(Port, os_pid) of
                {os_pid, OsPid} -> {ok, Port, OsPid};
                _ -> port_close(Port), {error, <<"python process has no OS pid">>}
            end
    catch _:Reason -> {error, detail(<<"could not start python">>, Reason)}
    end.

startup(Port, OsPid) ->
    Deadline = erlang:monotonic_time(millisecond) + ?STARTUP_MS,
    startup(Port, OsPid, Deadline, new_parser()).

startup(Port, OsPid, Deadline, Parser) ->
    After = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, Data}} ->
            case feed_frame(Data, Parser, 4096) of
                {more, Next} -> startup(Port, OsPid, Deadline, Next);
                {frame, Frame, <<>>} -> decode_startup(Frame, OsPid);
                {frame, _, _Trailing} -> {error, <<"invalid trailing python startup data">>};
                {error, Reason} -> {error, Reason}
            end;
        {Port, {exit_status, _}} -> {error, <<"python exited during startup">>};
        {'EXIT', Port, _} -> {error, <<"python port closed during startup">>}
    after After -> {error, <<"python startup timed out">>}
    end.

decode_startup(Data, OsPid) ->
    try json:decode(Data) of
        #{<<"v">> := 1, <<"type">> := <<"ready">>,
          <<"pid">> := OsPid, <<"pgid">> := OsPid} -> ok;
        _ -> {error, <<"invalid python startup handshake">>}
    catch _:_ -> {error, <<"malformed python startup handshake">>} end.

loop(S = #{owner_mon := OwnerMon, lock := LockPort, port := Port, os_pid := OsPid}) ->
    receive
        {call, From, Ref, {execute, Id, Source, Timeout, MaxOutput}}
                when byte_size(Id) > 0, byte_size(Id) =< 4096,
                     Timeout > 0, Timeout =< 4294937295,
                     MaxOutput >= 0, MaxOutput =< ?MAX_OUTPUT ->
            Request = iolist_to_binary(json:encode(#{v => 1, type => <<"execute">>, id => Id,
                                    source => Source, max_output_bytes => MaxOutput})),
            Size = byte_size(Request),
            case Size =< ?MAX_FRAME of
                true ->
                    Wire = <<Size:32/unsigned-big, Request/binary>>,
                    case port_command(Port, Wire) of
                        true ->
                            Deadline = erlang:monotonic_time(millisecond) + Timeout,
                            wait_result(S, From, Ref, Id, Deadline, MaxOutput, new_parser());
                        false ->
                            From ! {Ref, {error, <<"python port rejected request">>}},
                            loop(S)
                    end;
                false ->
                    From ! {Ref, {error, <<"python request exceeds protocol limit">>}},
                    loop(S)
            end;
        {call, From, Ref, {execute, _, _, _, _}} ->
            From ! {Ref, {error, <<"invalid execute limits">>}}, loop(S);
        {call, From, Ref, os_pid} -> From ! {Ref, {ok, OsPid}}, loop(S);
        {call, From, Ref, close} ->
            shutdown(S), From ! {Ref, nil};
        {'DOWN', OwnerMon, process, _, _} -> shutdown(S);
        {LockPort, {exit_status, _}} -> terminate(Port, OsPid);
        {'EXIT', LockPort, _} -> terminate(Port, OsPid);
        {Port, {exit_status, _}} -> shutdown(S);
        {'EXIT', Port, _} -> shutdown(S);
        _ -> loop(S)
    end.

wait_result(S, From, Ref, Id, Deadline, MaxOutput, Parser) ->
    Remaining = Deadline - erlang:monotonic_time(millisecond),
    case Remaining =< 0 of
        true ->
            shutdown(S),
            From ! {Ref, {ok, {unknown, <<"python cell deadline exceeded">>}}};
        false ->
            wait_result_receive(S, From, Ref, Id, Deadline, MaxOutput, Parser,
                                Remaining)
    end.

wait_result_receive(S = #{owner_mon := OwnerMon, lock := LockPort,
                          port := Port, os_pid := OsPid},
                    From, Ref, Id, Deadline, MaxOutput, Parser, After) ->
    FrameLimit = MaxOutput * 6 + ?RESPONSE_OVERHEAD,
    receive
        {Port, {data, Data}} ->
            case feed_frame(Data, Parser, FrameLimit) of
                {more, Next} ->
                    wait_result(S, From, Ref, Id, Deadline, MaxOutput, Next);
                {frame, Frame, <<>>} ->
                    case decode_result(Frame, Id) of
                        {ok, Outcome} -> From ! {Ref, {ok, Outcome}}, loop(S);
                        {error, Why} ->
                            shutdown(S), From ! {Ref, {ok, {unknown, Why}}}
                    end;
                {frame, _, _Trailing} ->
                    shutdown(S),
                    From ! {Ref, {ok, {unknown, <<"trailing bytes after python response">>}}};
                {error, Why} ->
                    shutdown(S), From ! {Ref, {ok, {unknown, Why}}}
            end;
        {LockPort, {exit_status, _}} ->
            terminate(Port, OsPid),
            From ! {Ref, {ok, {unknown, <<"python workspace lock was lost">>}}};
        {'EXIT', LockPort, _} ->
            terminate(Port, OsPid),
            From ! {Ref, {ok, {unknown, <<"python workspace lock was lost">>}}};
        {Port, {exit_status, Status}} ->
            shutdown(S),
            From ! {Ref, {ok, {unknown, detail(<<"python exited during cell">>, Status)}}};
        {'EXIT', Port, Reason} ->
            shutdown(S),
            From ! {Ref, {ok, {unknown, detail(<<"python port closed during cell">>, Reason)}}};
        {call, Closer, CloseRef, close} ->
            shutdown(S),
            From ! {Ref, {ok, {unknown, <<"python kernel closed during cell">>}}},
            Closer ! {CloseRef, nil};
        {call, Other, OtherRef, os_pid} ->
            Other ! {OtherRef, {ok, OsPid}},
            wait_result(S, From, Ref, Id, Deadline, MaxOutput, Parser);
        {call, Other, OtherRef, {execute, _, _, _, _}} ->
            Other ! {OtherRef, {error, <<"python kernel is busy">>}},
            wait_result(S, From, Ref, Id, Deadline, MaxOutput, Parser);
        {'DOWN', OwnerMon, process, _, _} ->
            shutdown(S),
            From ! {Ref, {ok, {unknown, <<"python owner exited during cell">>}}}
    after After ->
        shutdown(S),
        From ! {Ref, {ok, {unknown, <<"python cell deadline exceeded">>}}}
    end.

%% Raw ports are intentional: {packet,4} trusts the advertised length and may
%% buffer gigabytes before delivering anything. This parser reads only four
%% header bytes, rejects the length, then retains bounded payload chunks once.
new_parser() -> {header, <<>>}.

feed_frame(Data, {header, Header}, Limit) when is_binary(Data) ->
    Missing = 4 - byte_size(Header),
    case byte_size(Data) < Missing of
        true -> {more, {header, <<Header/binary, Data/binary>>}};
        false ->
            <<Head:Missing/binary, Rest/binary>> = Data,
            <<Size:32/unsigned-big>> = <<Header/binary, Head/binary>>,
            case Size =< Limit of
                true -> feed_frame(Rest, {payload, Size, 0, []}, Limit);
                false -> {error, <<"python frame advertised an oversized payload">>}
            end
    end;
feed_frame(Data, {payload, Size, Seen, Chunks}, _Limit) ->
    Need = Size - Seen,
    case byte_size(Data) < Need of
        true -> {more, {payload, Size, Seen + byte_size(Data), [Data | Chunks]}};
        false ->
            <<Piece:Need/binary, Rest/binary>> = Data,
            Payload = iolist_to_binary(lists:reverse([Piece | Chunks])),
            {frame, Payload, Rest}
    end.

decode_result(Data, Id) ->
    try json:decode(Data) of
        #{<<"v">> := 1, <<"type">> := <<"result">>, <<"id">> := Id,
          <<"status">> := <<"succeeded">>, <<"output">> := Output,
          <<"truncated">> := Truncated}
                when is_binary(Output), is_boolean(Truncated) ->
            {ok, {succeeded, Output, Truncated}};
        #{<<"v">> := 1, <<"type">> := <<"result">>, <<"id">> := Id,
          <<"status">> := <<"failed">>, <<"output">> := Output,
          <<"truncated">> := Truncated, <<"error">> := Error}
                when is_binary(Output), is_boolean(Truncated), is_binary(Error) ->
            {ok, {failed, Output, Truncated, Error}};
        _ -> {error, <<"invalid or uncorrelated python response">>}
    catch _:_ -> {error, <<"malformed python response">>} end.

shutdown(#{lock := LockPort, port := Port, os_pid := OsPid}) ->
    terminate(Port, OsPid),
    release_lock(LockPort).

%% Request proof that ordinary job groups have released inherited shared leases.
%% On deadline/lost helper, stable jobs.lock still refuses early replacement.
release_lock(LockPort) ->
    try port_command(LockPort, <<"Q">>) of
        true -> wait_lock_release(LockPort, erlang:monotonic_time(millisecond) + 5000, new_parser());
        false -> ok
    catch _:_ -> ok end,
    safe_port_close(LockPort).

wait_lock_release(LockPort, Deadline, Parser) ->
    After = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {LockPort, {data, Data}} ->
            case feed_frame(Data, Parser, 4096) of
                {more, Next} -> wait_lock_release(LockPort, Deadline, Next);
                {frame, Frame, <<>>} ->
                    try json:decode(Frame) of
                        #{<<"v">> := 1, <<"type">> := <<"lock_released">>} -> released;
                        _ -> cleanup_unknown
                    catch _:_ -> cleanup_unknown end;
                _ -> cleanup_unknown
            end;
        {LockPort, {exit_status, _}} -> cleanup_unknown;
        {'EXIT', LockPort, _} -> cleanup_unknown
    after After -> cleanup_unknown end.

terminate(Port, OsPid) ->
    signal_group("-TERM", OsPid),
    receive
        {Port, {exit_status, _}} -> ok;
        {'EXIT', Port, _} -> ok
    after 200 -> ok
    end,
    signal_group("-KILL", OsPid),
    safe_port_close(Port),
    ok.

signal_group(Signal, OsPid) ->
    case os:find_executable("kill") of
        false -> ok;
        Kill ->
            Target = "-" ++ integer_to_list(OsPid),
            try open_port({spawn_executable, Kill},
                          [binary, stderr_to_stdout, exit_status, hide,
                           {args, [Signal, "--", Target]}]) of
                Helper -> wait_helper(Helper)
            catch _:_ -> ok end
    end.

wait_helper(Helper) ->
    receive
        {Helper, {data, _}} -> wait_helper(Helper);
        {Helper, {exit_status, _}} -> ok
    after 200 -> safe_port_close(Helper)
    end.

safe_port_close(Port) ->
    try port_close(Port) catch _:_ -> ok end.

detail(Prefix, Reason) ->
    iolist_to_binary([Prefix, <<": ">>, io_lib:format("~tp", [Reason])]).
