%%% @doc POST /render — prepare any source URI for web display (server-side warp
%%% to a web-mercator COG) and return an id + lat/lon bounds. The heavy work is
%%% done here in Erlang/GDAL; the client only draws the resulting tiles.
-module(velora_render_h).
-export([init/2]).

init(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"POST">> ->
            {ok, Body, Req1} = cowboy_req:read_body(Req0),
            case uri(Body) of
                {ok, Uri} ->
                    case velora_web:prepare(Uri) of
                        {ok, Id, Bounds, MaxNativeZoom} ->
                            {ok, json(Req1, 200, #{id => Id, bounds => Bounds,
                                                   maxNativeZoom => MaxNativeZoom}), State};
                        {error, R} ->
                            {ok, json(Req1, 400, #{error => errbin(R)}), State}
                    end;
                error ->
                    {ok, json(Req1, 400, #{error => <<"missing uri">>}), State}
            end;
        _ ->
            {ok, json(Req0, 405, #{error => <<"method_not_allowed">>}), State}
    end.

uri(Body) ->
    try
        #{<<"uri">> := U} = jsx:decode(Body, [return_maps]),
        {ok, U}
    catch _:_ -> error end.

json(Req, Code, Map) ->
    cowboy_req:reply(Code, #{<<"content-type">> => <<"application/json">>},
                     jsx:encode(Map), Req).

errbin(A) when is_atom(A) -> atom_to_binary(A, utf8);
errbin(E) -> iolist_to_binary(io_lib:format("~p", [E])).
