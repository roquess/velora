%%% @doc STAC scene search for Sentinel-2 L2A (Earth Search v1). Picks the
%%% least-cloudy scene intersecting a bbox and returns its asset hrefs.
-module(velora_stac).
-export([search/2, parse_assets/2]).

-define(DEFAULT_URL, "https://earth-search.aws.element84.com/v1/search").

%% @doc BBox = [MinX,MinY,MaxX,MaxY]. Opts overrides url/collection/cloud/assets.
-spec search([number()], map()) -> {ok, map()} | {error, term()}.
search(BBox, Opts) ->
    Url  = maps:get(url, Opts,
             application:get_env(velora, stac_url, ?DEFAULT_URL)),
    Coll = maps:get(collection, Opts,
             application:get_env(velora, stac_collection, <<"sentinel-2-l2a">>)),
    Lt   = maps:get(cloud_lt, Opts,
             application:get_env(velora, stac_cloud_cover_lt, 20)),
    Keys = maps:get(assets, Opts,
             application:get_env(velora, stac_assets,
               #{visual => <<"visual">>, red => <<"red">>, nir => <<"nir">>})),
    Query = #{<<"collections">> => [Coll],
              <<"bbox">>        => BBox,
              <<"limit">>       => 1,
              <<"query">>       => #{<<"eo:cloud_cover">> => #{<<"lt">> => Lt}},
              <<"sortby">>      => [#{<<"field">> => <<"properties.eo:cloud_cover">>,
                                      <<"direction">> => <<"asc">>}]},
    case post_json(Url, jsx:encode(Query)) of
        {ok, Body} ->
            try parse_assets(jsx:decode(Body, [return_maps]), Keys)
            catch _:_ -> {error, bad_stac_body} end;
        {error, _} = E -> E
    end.

-spec parse_assets(map(), map()) -> {ok, map()} | {error, term()}.
parse_assets(#{<<"features">> := [Feat | _]}, Keys) ->
    Assets = maps:get(<<"assets">>, Feat, #{}),
    Href = fun(K) ->
        case maps:get(K, Assets, undefined) of
            #{<<"href">> := H} -> H;
            _ -> undefined
        end
    end,
    {ok, maps:map(fun(_Name, AssetKey) -> Href(AssetKey) end, Keys)};
parse_assets(_, _) -> {error, no_scene}.

post_json(Url, Body) ->
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(ssl),
    Req = {Url, [{"accept", "application/json"}], "application/json", Body},
    case httpc:request(post, Req, [{timeout, 20000}], [{body_format, binary}]) of
        {ok, {{_, 200, _}, _H, RespBody}} -> {ok, RespBody};
        {ok, {{_, Code, _}, _H, _}}       -> {error, {http, Code}};
        {error, R}                        -> {error, R}
    end.
