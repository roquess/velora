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

%% @doc Parse an em_filter-style JSON query and return a results list.
-spec handle_query(binary()) -> [map()].
handle_query(Body) ->
    try
        M = jsx:decode(Body, [return_maps]),
        case uri_of(M) of
            undefined -> [];
            Uri ->
                case velora_web:prepare(Uri) of
                    {ok, Id, Bounds, NZ} ->
                        [#{type => <<"raster">>, id => Id, bounds => Bounds,
                           maxNativeZoom => NZ,
                           tiles => <<"/tiles/", Id/binary, "/{z}/{x}/{y}">>}];
                    {error, _} -> []
                end
        end
    catch _:_ -> [] end.

uri_of(#{<<"uri">> := U}) when is_binary(U) -> U;
uri_of(#{<<"query">> := Q}) when is_binary(Q) ->
    case binary:match(Q, <<"://">>) of nomatch -> undefined; _ -> Q end;
uri_of(_) -> undefined.

json(Req, Code, Map) ->
    cowboy_req:reply(Code, #{<<"content-type">> => <<"application/json">>},
                     jsx:encode(Map), Req).
