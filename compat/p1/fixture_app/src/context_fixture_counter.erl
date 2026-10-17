-module(context_fixture_counter).
-export([new/0, next/1, read/1, set/2, with_settings/2, with_provider_home/1]).
new() -> atomics:new(1, []).
next(Counter) -> atomics:add_get(Counter, 1, 1).
read(Counter) -> atomics:get(Counter, 1).
set(Counter, Value) -> atomics:put(Counter, 1, Value), nil.
with_settings(Text, Run) ->
    Previous = os:getenv("ALBEDO_HOME"),
    Dir = "/tmp/successor-context-settings-" ++ integer_to_list(erlang:unique_integer([positive])),
    ok = file:make_dir(Dir),
    Path = filename:join(Dir, "extensions.json"),
    ok = file:write_file(Path, Text),
    true = os:putenv("ALBEDO_HOME", Dir),
    try Run()
    after
        case Previous of false -> os:unsetenv("ALBEDO_HOME"); _ -> os:putenv("ALBEDO_HOME", Previous) end,
        ok = file:delete(Path),
        ok = file:del_dir(Dir)
    end.

with_provider_home(Run) ->
    Previous = os:getenv("ALBEDO_HOME"),
    Dir = "/tmp/successor-warming-home-" ++ integer_to_list(erlang:unique_integer([positive])),
    ok = file:make_dir(Dir),
    ok = file:write_file(filename:join(Dir, "config.json"),
        <<"{\"active\":\"fixture\",\"providers\":{\"fixture\":{\"extension\":\"fixture-provider\",\"model\":\"model\",\"protocol\":\"responses\"}}}">>),
    ok = file:write_file(filename:join(Dir, "extensions.json"), <<"{}">>),
    true = os:putenv("ALBEDO_HOME", Dir),
    try Run(unicode:characters_to_binary(Dir))
    after
        case Previous of false -> os:unsetenv("ALBEDO_HOME"); _ -> os:putenv("ALBEDO_HOME", Previous) end,
        file:del_dir_r(Dir)
    end.
