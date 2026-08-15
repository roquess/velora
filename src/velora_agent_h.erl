%%% @doc Emergence agent endpoint: POST /agent/query. Speaks the em_filter
%%% contract natively (velora doesn't depend on the em_filter package, which pins
%%% an incompatible sied). A query naming a raster source is prepared for viewing
%%% and answered with its tile template + bounds, so the Emergence mesh can route
%%% "render/view this raster" work to velora.
-module(velora_agent_h).
-export([init/2, handle_query/1]).

init(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"POST">> ->
            {ok, Body, Req1} = cowboy_req:read_body(Req0),
            {ok, json(Req1, 200, #{results => handle_query(Body)}), State};
        _ ->
            {ok, json(Req0, 405, #{error => <<"method_not_allowed">>}), State}
    end.

%% @doc Parse an em_filter-style JSON query and return a results list. Routes an
%% optional "intent" (tiles|ndvi|info, default tiles) through velora_agent, which
%% resolves a raster URI directly or geocodes a place and finds a Sentinel-2 scene.
-spec handle_query(binary()) -> [map()].
handle_query(Body) ->
    try
        M = jsx:decode(Body, [return_maps]),
        Query = query_of(M),
        Intent = intent_of(M),
        velora_agent:handle(#{intent => Intent, query => Query})
    catch _:_ -> [] end.

query_of(#{<<"query">> := Q}) when is_binary(Q) -> Q;
query_of(#{<<"uri">> := U}) when is_binary(U) -> U;
query_of(_) -> <<>>.

intent_of(#{<<"intent">> := <<"ndvi">>}) -> ndvi;
intent_of(#{<<"intent">> := <<"info">>}) -> info;
intent_of(_) -> tiles.

json(Req, Code, Map) ->
    cowboy_req:reply(Code, #{<<"content-type">> => <<"application/json">>},
                     jsx:encode(Map), Req).
