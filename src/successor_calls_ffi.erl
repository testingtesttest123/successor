%% Gleam-erlang Subject representation bridge, covered by the lifecycle tests.
%% Resolve once and send to the pinned PID even if its registered name changes.
-module(successor_calls_ffi).
-export([send_pinned/3]).
send_pinned({subject, Owner, Tag}, Owner, Message) ->
    Owner ! {Tag, Message}, {ok, nil};
send_pinned({named_subject, Name}, Owner, Message) ->
    case whereis(Name) of
        Owner -> Owner ! {Name, Message}, {ok, nil};
        _ -> {error, <<"request owner changed; not dispatched">>}
    end;
send_pinned(_, _, _) -> {error, <<"request owner changed; not dispatched">>}.
