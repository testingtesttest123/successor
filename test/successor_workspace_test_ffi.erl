-module(successor_workspace_test_ffi).
-export([transport_call_queued/1, port_exit_queued/1, dispatch_process/1, transport_idle/1, write_text/2, kill_os/1, kernel_transport/1, exists/1, read_text/1, os_alive/1, kill_process/1, set_env/2, unset_env/1, stop_actor/1, suspend_actor/1, resume_actor/1, factory_count/1]).
exists(Path) -> filelib:is_regular(binary_to_list(Path)).
read_text(Path) -> case file:read_file(Path) of {ok, Bytes} -> {ok, Bytes}; _ -> {error, nil} end.
os_alive(Pid) when Pid > 0 -> filelib:is_dir("/proc/" ++ integer_to_list(Pid));
os_alive(_) -> false.
kill_process(Pid) -> erlang:exit(Pid, kill), nil.
set_env(Name, Value) -> os:putenv(binary_to_list(Name), binary_to_list(Value)), nil.
unset_env(Name) -> os:unsetenv(binary_to_list(Name)), nil.

stop_actor(Pid) -> unlink(Pid), erlang:exit(Pid, kill), nil.

suspend_actor(Pid) -> erlang:suspend_process(Pid), nil.
resume_actor(Pid) -> erlang:resume_process(Pid), nil.

factory_count(Supervisor) ->
    try successor_session_supervisor:count_children(Supervisor) of
        Count -> {ok, Count}
    catch exit:_ -> {error, nil} end.

kill_os(Pid) when Pid > 0 ->
    _ = os:cmd("/bin/kill -KILL " ++ integer_to_list(Pid)), nil.

kernel_transport(Owner) ->
    {monitored_by, Pids} = process_info(Owner, monitored_by),
    [Transport] = [Pid || Pid <- Pids,
        process_info(Pid, current_function) =:= {current_function, {successor_python_ffi, loop, 1}}],
    Transport.

dispatch_process(Owner) ->
    {monitors, Monitors} = process_info(Owner, monitors),
    [Dispatch] = [Pid || {process, Pid} <- Monitors,
        process_info(Pid, current_function) =:= {current_function, {successor_python_ffi, call, 2}}],
    Dispatch.

transport_idle(Pid) ->
    process_info(Pid, current_function) =:= {current_function, {successor_python_ffi, loop, 1}}.

write_text(Path, Text) -> ok = file:write_file(Path, Text), nil.

port_exit_queued(Pid) ->
    {messages, Messages} = process_info(Pid, messages),
    lists:any(fun({Port, {exit_status, _}}) when is_port(Port) -> true;
                 (_) -> false end, Messages).

transport_call_queued(Pid) ->
    {messages, Messages} = process_info(Pid, messages),
    lists:any(fun({call, _, _, _}) -> true; (_) -> false end, Messages).
