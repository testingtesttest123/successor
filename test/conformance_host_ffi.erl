-module(conformance_host_ffi).
-export([read_line/0, process_id/0, uri_path/1]).

read_line() ->
    case io:get_line("") of
        eof -> {error, nil};
        {error, _} -> {error, nil};
        Line -> {ok, unicode:characters_to_binary(Line)}
    end.

process_id() -> unicode:characters_to_binary(os:getpid()).

uri_path(Path) ->
    binary:replace(binary:replace(binary:replace(Path, <<"%">>, <<"%25">>, [global]),
        <<"?">>, <<"%3F">>, [global]), <<"#">>, <<"%23">>, [global]).
