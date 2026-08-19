%%% @doc POST /render — prepare any source URI for web display (server-side warp
%%% to a web-mercator COG). Asynchronous: the warp runs in the background and the
%%% response is a `processing' id the client polls at `GET /prepare/:id' until it
%%% reports `done' with the tile template — so a slow warp never holds the
%%% request open (and can't hit an upstream/proxy timeout).
-module(velora_render_h).
-export([init/2]).

init(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"POST">> ->
            {ok, Body, Req1} = cowboy_req:read_body(Req0),
            case uri(Body) of
                {ok, Uri} ->
                    {ok, PrepId} = velora_prepare_async:submit(Uri),
                    {ok, json(Req1, 202, #{status => <<"processing">>,
                                           prepare => PrepId,
                                           poll => <<"/prepare/", PrepId/binary>>}), State};
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
