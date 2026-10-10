-module(successor_session_supervisor).
-behaviour(supervisor).
-export([start/1, init/1, open/3, start_session/1, count_children/1]).

start(Name) ->
    case supervisor:start_link({local, Name}, ?MODULE, []) of
        {ok, Pid} -> {ok, Pid};
        {error, Reason} -> {error, describe(Reason)}
    end.

init([]) ->
    {ok, {#{strategy => one_for_one, intensity => 2, period => 5}, []}}.

open(Name, Id, Spec) ->
    Child = #{id => Id, start => {?MODULE, start_session, [Spec]},
              restart => transient, shutdown => 5000,
              type => worker, modules => ['successor@session']},
    %% Resolve the catalog owner once. A replaced registered name must never
    %% silently receive this request or a retained-child retry.
    Pid = whereis(Name),
    try
        case gen_server:call(Pid, {start_child, Child}, 15000) of
            {ok, _Pid, _Data} -> {ok, nil};
            {error, {already_started, _Pid}} -> {ok, nil};
            {error, already_present} -> restart_retained(Pid, Id);
            {error, Reason} -> {error, {start_failed, describe(Reason)}}
        end
    catch
        exit:_ -> {error, unavailable}
    end.

%% A normally stopped or explicitly terminated transient child retains its
%% spec. Restart it through the same serialized OTP owner, never by deleting
%% the spec and admitting a second child. Concurrent callers may observe the
%% first restart as running or in progress.
restart_retained(Pid, Id) ->
    case gen_server:call(Pid, {restart_child, Id}, 15000) of
        {ok, _Pid, _Data} -> {ok, nil};
        {ok, _Pid} -> {ok, nil};
        {error, running} -> {ok, nil};
        {error, restarting} -> {error, restarting};
        {error, Reason} -> {error, {start_failed, describe(Reason)}}
    end.

start_session(Spec) ->
    case 'successor@session':start(Spec) of
        {ok, {started, Pid, Data}} -> {ok, Pid, Data};
        {error, Reason} -> {error, Reason}
    end.

count_children({supervisor, Name}) ->
    proplists:get_value(active, supervisor:count_children(Name)).

describe(Reason) ->
    iolist_to_binary(io_lib:format("~p", [Reason])).
