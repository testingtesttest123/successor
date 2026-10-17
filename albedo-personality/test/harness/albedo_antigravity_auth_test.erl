%% The fixed Google refresh endpoint cannot be replaced by the model-turn E2E
%% fixture. These tests catch credential bundling and runtime configuration
%% failures without live credentials, and inspect exchanges only on loopback.
-module(albedo_antigravity_auth_test).
-include_lib("eunit/include/eunit.hrl").

bundled_client_secret_is_forbidden_test() ->
    {ok, Source} = file:read_file("src/albedo/harness/extensions/antigravity/albedo_antigravity.erl"),
    %% Return only match offsets on failure, never credential bytes.
    ?assertEqual(nomatch, re:run(Source, <<"-define\\(CLIENT_SECRET,">>)).

missing_exchange_configuration_test() ->
    with_secret(false, fun() ->
        ?assertEqual({error, configuration_error()}, exchange(<<"not-a-url">>))
    end).

empty_exchange_configuration_test() ->
    with_secret("", fun() ->
        ?assertEqual({error, configuration_error()}, exchange(<<"not-a-url">>))
    end).

missing_configuration_is_visible_before_login_test() ->
    with_secret(false, fun() ->
        Detail = login_detail(),
        ?assertNotEqual(nomatch, binary:match(Detail, <<"ALBEDO_ANTIGRAVITY_CLIENT_SECRET">>))
    end).

configured_login_keeps_existing_detail_test() ->
    with_secret("synthetic-only-not-a-credential", fun() ->
        ?assertEqual(<<"oauth · gemini 3, claude"/utf8>>, login_detail())
    end).

fresh_access_does_not_require_client_secret_test() ->
    with_secret(false, fun() ->
        with_accounts([credential(<<"fresh@example.invalid">>, fresh)], fun(Home, _) ->
            {ok, Encoded} = albedo_antigravity:access(Home, <<"test-session">>),
            ?assertEqual(<<"synthetic-access">>, maps:get(<<"access">>, json:decode(Encoded)))
        end)
    end).

missing_refresh_configuration_is_preserved_test() ->
    with_secret(false, fun() ->
        with_accounts([credential(<<"stale@example.invalid">>, stale)], fun(Home, Before) ->
            ?assertEqual({error, configuration_error()}, albedo_antigravity:access(Home, <<"test-session">>)),
            {ok, After} = file:read_file(albedo_credentials:creds_path(Home)),
            ?assertEqual(Before, After)
        end)
    end).

missing_refresh_configuration_still_allows_fresh_sibling_test() ->
    with_secret(false, fun() ->
        Stale = (credential(<<"stale@example.invalid">>, stale))#{<<"selected">> => true},
        Fresh = credential(<<"fresh@example.invalid">>, fresh),
        with_accounts([Stale, Fresh], fun(Home, _) ->
            {ok, Encoded} = albedo_antigravity:access(Home, <<"test-session">>),
            ?assertEqual(<<"fresh@example.invalid">>, maps:get(<<"email">>, json:decode(Encoded)))
        end)
    end).

configured_exchange_uses_runtime_secret_test() ->
    Secret = "synthetic-only-not-a-credential +&=",
    with_secret(Secret, fun() ->
        Fixture = albedo_antigravity_auth_test_server:start(),
        try
            {error, Failure} = exchange(albedo_antigravity_auth_test_server:url(Fixture)),
            ?assertNotEqual(nomatch, binary:match(Failure, <<"(400)">>)),
            Form = maps:from_list(uri_string:dissect_query(albedo_antigravity_auth_test_server:body(Fixture))),
            ?assert(maps:get(<<"client_secret">>, Form) =:= list_to_binary(Secret)),
            ?assertEqual(albedo_antigravity:client_id(), maps:get(<<"client_id">>, Form)),
            ?assertEqual(<<"synthetic-code">>, maps:get(<<"code">>, Form)),
            ?assertEqual(<<"authorization_code">>, maps:get(<<"grant_type">>, Form)),
            ?assertEqual(<<"http://127.0.0.1/callback">>, maps:get(<<"redirect_uri">>, Form))
        after albedo_antigravity_auth_test_server:stop(Fixture) end
    end).

login_detail() ->
    Login = 'albedo@harness@extensions@antigravity@extension':login(
        {endpoints, <<"not-used">>, <<"not-used">>, <<"not-used">>}),
    element(4, Login).

configuration_error() ->
    <<"Antigravity OAuth requires ALBEDO_ANTIGRAVITY_CLIENT_SECRET in the daemon environment">>.

exchange(TokenUrl) ->
    albedo_antigravity:exchange(<<"synthetic-code">>, <<"http://127.0.0.1/callback">>,
        fun(_) -> nil end, {endpoints, TokenUrl, <<"not-used">>, <<"not-used">>}).

with_secret(Value, Run) ->
    Name = "ALBEDO_ANTIGRAVITY_CLIENT_SECRET",
    Previous = os:getenv(Name),
    try
        setenv(Name, Value),
        Run()
    after setenv(Name, Previous) end.

setenv(Name, false) -> os:unsetenv(Name);
setenv(Name, Value) -> os:putenv(Name, Value).

credential(Email, Age) ->
    Expires = case Age of fresh -> erlang:system_time(millisecond) + 3600000; stale -> 1 end,
    #{<<"type">> => <<"oauth">>, <<"email">> => Email,
      <<"access">> => <<"synthetic-access">>, <<"refresh">> => <<"synthetic-refresh">>,
      <<"expires">> => Expires, <<"projectId">> => <<"synthetic-project">>}.

with_accounts(Accounts, Run) ->
    Home = filename:join("/tmp", "albedo-antigravity-auth-" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = file:make_dir(Home),
    Path = albedo_credentials:creds_path(Home),
    Document = #{<<"accounts">> => #{<<"google-antigravity">> => Accounts},
                 <<"providers">> => #{<<"unrelated">> => #{<<"apiKey">> => <<"synthetic-other-provider">>}}},
    ok = albedo_credentials:write(Path, Document),
    {ok, Before} = file:read_file(Path),
    try Run(Home, Before)
    after file:del_dir_r(Home) end.
