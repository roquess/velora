%%% @doc Orchestrates an Emergence query into imagery/analysis. Intents:
%%%   tiles — render satellite tiles;
%%%   ndvi  — vegetation index tiles + stats;
%%%   info  — raster metadata.
%%% A query is either a raster URI (rendered directly) or a place name
%%% (geocoded, then a Sentinel-2 scene is found via STAC). Config-gated: with no
%%% geocoder/STAC, only URI queries resolve; everything else yields [].
-module(velora_agent).
-export([handle/1, resolve/2, tiles_card/3, info_card/1, ndvi_card/4]).

-spec handle(map()) -> [map()].
handle(#{query := Q} = M) ->
    Intent = maps:get(intent, M, tiles),
    try do(Intent, Q) of
        {ok, Card} -> [Card];
        {error, _} -> []
    catch _:_ -> [] end;
handle(_) -> [].

do(tiles, Q) ->
    case resolve(tiles, Q) of
        {ok, Src} ->
            case velora_web:prepare(Src) of
                {ok, Id, Bounds, NZ} -> {ok, tiles_card(Id, Bounds, NZ)};
                E -> E
            end;
        E -> E
    end;
do(info, Q) ->
    case resolve(info, Q) of
        {ok, Src} ->
            case velora_web:info(Src) of
                {ok, Meta} -> {ok, info_card(Meta)};
                E -> E
            end;
        E -> E
    end;
do(ndvi, Q) ->
    case resolve(ndvi, Q) of
        {ok, {Red, Nir}} ->
            case velora_web:prepare_ndvi(Red, Nir) of
                {ok, Id, Bounds, NZ, Stats} -> {ok, ndvi_card(Id, Bounds, NZ, Stats)};
                E -> E
            end;
        E -> E
    end;
do(_, _) -> {error, unknown_intent}.

%% Resolve a query to a source. tiles/info -> a single COG uri; ndvi -> {Red,Nir}.
-spec resolve(atom(), binary()) -> {ok, term()} | {error, term()}.
resolve(Intent, Q) ->
    case velora_query:classify(Q) of
        unknown -> {error, empty_query};
        {raster_uri, U} when Intent =:= ndvi -> {ok, {U, U}};
        {raster_uri, U} -> {ok, U};
        {place, P} -> resolve_place(Intent, P)
    end.

resolve_place(Intent, Place) ->
    case velora_geocode:geocode(Place) of
        {ok, #{bbox := BBox}} ->
            case velora_stac:search(BBox, #{}) of
                {ok, Assets} -> pick_assets(Intent, Assets);
                E -> E
            end;
        E -> E
    end.

pick_assets(ndvi, #{red := R, nir := N}) when is_binary(R), is_binary(N) ->
    {ok, {R, N}};
pick_assets(ndvi, _) -> {error, no_ndvi_bands};
pick_assets(_, #{visual := V}) when is_binary(V) -> {ok, V};
pick_assets(_, _) -> {error, no_visual_asset}.

-spec tiles_card(binary(), [[float()]], integer()) -> map().
tiles_card(Id, Bounds, NZ) ->
    #{type => <<"raster">>, id => Id, bounds => Bounds, maxNativeZoom => NZ,
      tiles => <<"/tiles/", Id/binary, "/{z}/{x}/{y}">>}.

-spec ndvi_card(binary(), [[float()]], integer(), map()) -> map().
ndvi_card(Id, Bounds, NZ, Stats) ->
    (tiles_card(Id, Bounds, NZ))#{type => <<"ndvi">>, stats => Stats}.

-spec info_card(map()) -> map().
info_card(Meta) -> Meta#{type => <<"info">>}.
