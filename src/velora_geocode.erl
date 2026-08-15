%%% @doc Geocode a place name to lat/lon/bbox by asking a mesh geocoder that
%%% speaks the em_filter /agent/query contract (default: nominatim_filter).
%%% Reciprocity: velora consumes a mesh filter to serve imagery back to the mesh.
-module(velora_geocode).
-export([geocode/1, parse_result/2]).

-spec geocode(binary()) -> {ok, map()} | {error, term()}.
geocode(Place) when is_binary(Place) ->
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
