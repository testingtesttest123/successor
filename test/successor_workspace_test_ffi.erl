-module(successor_workspace_test_ffi).
-export([exists/1, read_text/1, os_alive/1, kill_process/1, set_env/2, unset_env/1, stop_actor/1, suspend_actor/1, resume_actor/1, factory_count/1]).
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
    try 'gleam@otp@factory_supervisor':count_children(Supervisor) of
        Count -> {ok, Count}
    catch exit:_ -> {error, nil} end.
