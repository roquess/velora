%%% @doc Geocode a place name to lat/lon/bbox. Two backends, chosen by the
%%% `geocoder_kind' env: `emfilter' (default) asks a mesh geocoder that speaks
%%% the em_filter /agent/query contract (e.g. nominatim_filter) — reciprocity,
%%% velora consuming a mesh filter; `nominatim' does a direct GET against a
%%% public Nominatim endpoint (`geocoder_url', default OSM), which needs no mesh.
-module(velora_geocode).
-export([geocode/1, parse_result/2, parse_nominatim/2]).

-spec geocode(binary()) -> {ok, map()} | {error, term()}.
geocode(Place) when is_binary(Place) ->
    case application:get_env(velora, geocoder_kind, emfilter) of
        nominatim -> geocode_nominatim(Place);
        _         -> geocode_emfilter(Place)
    end.

geocode_emfilter(Place) ->
    case application:get_env(velora, geocoder_url) of
        {ok, Url} ->
            Half = application:get_env(velora, geocode_bbox_half_deg, 0.05),
            Body = jsx:encode(#{<<"query">> => Place}),
            case post_json(Url, Body) of
                {ok, Resp} ->
                    try parse_result(decode_results(jsx:decode(Resp, [return_maps])), Half)
                    catch _:_ -> {error, bad_geocoder_body} end;
                {error, _} = E -> E
            end;
        undefined -> {error, no_geocoder}
    end.

geocode_nominatim(Place) ->
    Base = application:get_env(velora, geocoder_url,
                               "https://nominatim.openstreetmap.org/search"),
    Half = application:get_env(velora, geocode_bbox_half_deg, 0.05),
    Query = uri_string:compose_query([{"format", "json"}, {"limit", "1"},
                                      {"q", binary_to_list(Place)}]),
    Url = Base ++ "?" ++ Query,
    case get_json(Url) of
        {ok, Resp} ->
            try parse_nominatim(jsx:decode(Resp, [return_maps]), Half)
            catch _:_ -> {error, bad_geocoder_body} end;
        {error, _} = E -> E
    end.

%% Nominatim item: lat/lon strings + boundingbox [South, North, West, East].
-spec parse_nominatim([map()], number()) -> {ok, map()} | {error, term()}.
parse_nominatim([R | _], Half) when is_map(R) ->
    Lat = num(maps:get(<<"lat">>, R)),
    Lon = num(maps:get(<<"lon">>, R)),
    BBox = case maps:get(<<"boundingbox">>, R, undefined) of
        [S, N, W, E] -> [num(W), num(S), num(E), num(N)];
        _            -> [Lon - Half, Lat - Half, Lon + Half, Lat + Half]
    end,
    {ok, #{lat => Lat, lon => Lon, bbox => BBox}};
parse_nominatim(_, _) -> {error, not_found}.

get_json(Url) ->
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(ssl),
    %% Nominatim requires a User-Agent; without one it returns 403.
    Req = {Url, [{"User-Agent", "velora"}, {"accept", "application/json"}]},
    case httpc:request(get, Req, [{timeout, 15000}], [{body_format, binary}]) of
        {ok, {{_, 200, _}, _H, RespBody}} -> {ok, RespBody};
        {ok, {{_, Code, _}, _H, _}}       -> {error, {http, Code}};
        {error, R}                        -> {error, R}
    end.

%% em_filter handlers reply either as a bare list or {"results": [...]}.
decode_results(L) when is_list(L) -> L;
decode_results(#{<<"results">> := L}) when is_list(L) -> L;
decode_results(_) -> [].

-spec parse_result([map()], number()) -> {ok, map()} | {error, term()}.
parse_result([R | _], Half) ->
    Lat = num(maps:get(<<"lat">>, R)),
    Lon = num(maps:get(<<"lon">>, R)),
    BBox = case maps:get(<<"bbox">>, R, undefined) of
        [A, B, C, D] -> [num(A), num(B), num(C), num(D)];
        _            -> [Lon - Half, Lat - Half, Lon + Half, Lat + Half]
    end,
    {ok, #{lat => Lat, lon => Lon, bbox => BBox}};
parse_result([], _) -> {error, not_found}.

num(X) when is_number(X) -> float(X);
num(B) when is_binary(B) ->
    case string:to_float(binary_to_list(B)) of
        {F, _} when is_float(F) -> F;
        _ -> {I, _} = string:to_integer(binary_to_list(B)), float(I)
    end.

post_json(Url, Body) ->
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(ssl),
    Req = {Url, [{"accept", "application/json"}], "application/json", Body},
    case httpc:request(post, Req, [{timeout, 15000}], [{body_format, binary}]) of
        {ok, {{_, 200, _}, _H, RespBody}} -> {ok, RespBody};
        {ok, {{_, Code, _}, _H, _}}       -> {error, {http, Code}};
        {error, R}                        -> {error, R}
    end.
