%% Gleam-erlang Subject representation bridge, covered by the lifecycle tests.
%% Resolve once and send to the pinned PID even if its registered name changes.
-module(successor_calls_ffi).
-export([send_pinned/3, start_child_safe/2]).
send_pinned({subject, Owner, Tag}, Owner, Message) ->
    Owner ! {Tag, Message}, {ok, nil};
send_pinned({named_subject, Name}, Owner, Message) ->
    case whereis(Name) of
        Owner -> Owner ! {Name, Message}, {ok, nil};
        _ -> {error, <<"request owner changed; not dispatched">>}
    end;
send_pinned(_, _, _) -> {error, <<"request owner changed; not dispatched">>}.

%% simple_one_for_one's public start_child request, with a finite wait and a
%% single PID resolution instead of an unbounded call to a replaceable name.
start_child_safe({supervisor, Handle}, Argument) ->
    Pid = case Handle of
        Name when is_atom(Name) -> whereis(Name);
        Owner when is_pid(Owner) -> Owner;
        _ -> undefined
    end,
    case is_pid(Pid) of
        false -> {error, {init_failed, <<"factory unavailable; child not dispatched">>}};
        true ->
            try gen_server:call(Pid, {start_child, [Argument]}, 15000) of
                {ok, Child, Data} -> {ok, {started, Child, Data}};
                {error, Why} -> {error, Why};
                _ -> {error, {init_failed, <<"unexpected factory start response">>}}
            catch exit:_ ->
                {error, {init_failed, <<"factory ownership/creation acknowledgement unknown; inspect before retry">>}}
            end
    end.
