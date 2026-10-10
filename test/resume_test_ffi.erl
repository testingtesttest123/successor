-module(resume_test_ffi).
-export([vanishing_supervisor/1]).

%% A deterministic transport fault: the child catalog reports a retained
%% spec, then the supervisor dies before the follow-up restart request.
vanishing_supervisor(Name) ->
    Parent = self(),
    Ready = make_ref(),
    Pid = spawn(fun() ->
        register(Name, self()),
        Parent ! Ready,
        receive
            {'$gen_call', From, {start_child, _Spec}} ->
                gen_server:reply(From, {error, already_present})
        end
    end),
    receive Ready -> Pid end.
