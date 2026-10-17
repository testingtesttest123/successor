%% Observe the real replacement-allocation boundary on the current test process.
%% Fixtures describe at most 2 MiB of output; no OOM-sized probe is executed.
-module(successor_edit_test_support).
-export([count_replacements/2]).

count_replacements(Owner, Run) ->
    Pattern = {gleam_stdlib, string_replace, 3},
    {module, gleam_stdlib} = code:ensure_loaded(gleam_stdlib),
    Tracer = spawn(fun() -> collect(0, none) end),
    1 = erlang:trace_pattern(Pattern, true, [local]),
    erlang:trace(Owner, true, [call, {tracer, Tracer}]),
    try
        Value = Run(),
        Tracer ! {count, self(), Owner},
        receive {replacement_count, Count} -> {Value, Count}
        after 3000 -> error(replacement_trace_timeout)
        end
    after
        erlang:trace(Owner, false, [call]),
        erlang:trace_pattern(Pattern, false, [local]),
        exit(Tracer, kill)
    end.

%% Drain the delivery marker on the same mailbox as trace events, so a zero
%% count proves the allocator was not entered rather than racing the tracer.
collect(Count, Finish) ->
    receive
        {trace, _, call, {gleam_stdlib, string_replace, [_, _, _]}} ->
            collect(Count + 1, Finish);
        {count, Reply, Owner} ->
            collect(Count, {Reply, erlang:trace_delivered(Owner)});
        {trace_delivered, _, Ref} ->
            {Reply, Ref} = Finish,
            Reply ! {replacement_count, Count},
            collect(Count, none);
        _ -> collect(Count, Finish)
    end.
