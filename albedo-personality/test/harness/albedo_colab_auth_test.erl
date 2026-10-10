%% Colab's fixed Google endpoints cannot be replaced by the model-turn E2E
%% fixture. Guard tests run offline and catch missing runtime configuration
%% before exchange can send a code or bundled credential to Google.
-module(albedo_colab_auth_test).
-include_lib("eunit/include/eunit.hrl").

bundled_client_secret_is_forbidden_test() ->
    {ok, Source} = file:read_file("src/albedo/harness/extensions/colab/albedo_colab_auth.erl"),
    %% Failure contains match offsets only, never credential bytes.
    ?assertEqual(nomatch, re:run(Source, <<"-define\\(CLIENT_SECRET,">>)).

missing_client_secret_is_an_explicit_error_test() ->
    with_secret(false, fun() ->
        ?assert(albedo_colab_auth:client_secret() =:= {error, configuration_error()})
    end).

empty_client_secret_is_an_explicit_error_test() ->
    with_secret("", fun() ->
        ?assert(albedo_colab_auth:client_secret() =:= {error, configuration_error()})
    end).

configured_client_secret_uses_exact_runtime_value_test() ->
    with_secret("synthetic-only-colab-not-a-credential +&=", fun() ->
        ?assert(albedo_colab_auth:client_secret() =:=
            {ok, <<"synthetic-only-colab-not-a-credential +&=">>})
    end).

missing_exchange_configuration_test() ->
    with_secret(false, fun() ->
        ?assertEqual({error, configuration_error()},
            albedo_colab_auth:exchange(<<"synthetic-code">>, <<"http://127.0.0.1/callback">>, fun(_) -> nil end))
    end).

missing_configuration_is_visible_before_login_test() ->
    with_secret(false, fun() ->
        Detail = login_detail(),
        ?assertNotEqual(nomatch, binary:match(Detail, <<"ALBEDO_COLAB_CLIENT_SECRET">>))
    end).

configured_login_keeps_existing_detail_test() ->
    with_secret("synthetic-only-colab-not-a-credential", fun() ->
        ?assertEqual(<<"oauth · google colab gpu runtimes"/utf8>>, login_detail())
    end).

login_detail() ->
    Login = 'albedo@harness@extensions@colab@extension':login(),
    element(4, Login).

configuration_error() ->
    <<"Google Colab OAuth requires ALBEDO_COLAB_CLIENT_SECRET in the daemon environment">>.

with_secret(Value, Run) ->
    Name = "ALBEDO_COLAB_CLIENT_SECRET",
    Previous = os:getenv(Name),
    try
        setenv(Name, Value),
        Run()
    after setenv(Name, Previous) end.

setenv(Name, false) -> os:unsetenv(Name);
setenv(Name, Value) -> os:putenv(Name, Value).
