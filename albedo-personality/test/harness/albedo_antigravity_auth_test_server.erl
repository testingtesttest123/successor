%% One loopback token endpoint. It captures synthetic form data and rejects the
%% grant, keeping the production exchange from contacting discovery endpoints.
-module(albedo_antigravity_auth_test_server).
-export([start/0, url/1, body/1, stop/1]).

start() ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {ip, {127, 0, 0, 1}}, {reuseaddr, true}]),
    {ok, {_, Port}} = inet:sockname(Listen),
    Owner = self(),
    Pid = spawn(fun() -> serve(Listen, Owner) end),
    {Pid, Listen, iolist_to_binary(["http://127.0.0.1:", integer_to_list(Port), "/token"])}.

url({_, _, Url}) -> Url.

body({Pid, _, _}) ->
    receive {token_form, Pid, Body} -> Body
    after 2000 -> error(token_form_not_received) end.

stop({Pid, Listen, _}) ->
    exit(Pid, shutdown),
    gen_tcp:close(Listen).

serve(Listen, Owner) ->
    {ok, Socket} = gen_tcp:accept(Listen, 2000),
    try
        Body = read_request(Socket, <<>>),
        Owner ! {token_form, self(), Body},
        ok = gen_tcp:send(Socket,
            <<"HTTP/1.1 400 Bad Request\r\ncontent-type: application/json\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{}">>)
    after gen_tcp:close(Socket) end.

read_request(Socket, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        {End, 4} ->
            <<Headers:End/binary, _:4/binary, Body/binary>> = Acc,
            Lines = binary:split(Headers, <<"\r\n">>, [global]),
            [Length] = [binary_to_integer(string:trim(Value)) || Line <- Lines,
                [Name, Value] <- [binary:split(Line, <<":">>)],
                string:lowercase(Name) =:= <<"content-length">>],
            read_body(Socket, Body, Length);
        nomatch ->
            {ok, Bytes} = gen_tcp:recv(Socket, 0, 2000),
            read_request(Socket, <<Acc/binary, Bytes/binary>>)
    end.

read_body(_, Body, Length) when byte_size(Body) >= Length -> binary:part(Body, 0, Length);
read_body(Socket, Body, Length) ->
    {ok, Bytes} = gen_tcp:recv(Socket, Length - byte_size(Body), 2000),
    read_body(Socket, <<Body/binary, Bytes/binary>>, Length).
