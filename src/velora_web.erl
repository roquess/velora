%%% @doc Server-side web display of arbitrary rasters. `prepare/1` ingests any
%%% GDAL-readable source (any format/size, georeferenced or not) once into a local
%%% 8-bit web-mercator COG with overviews — this is the heavy, Erlang-side step.
%%% Each XYZ tile is then cut from that local COG on demand: GDAL reads only the
%%% overview level and window the tile covers, so the browser only ever fetches
%%% the currently-visible tiles and never the whole image.
-module(velora_web).
-export([prepare/1, tile/4, source_path/1, sweep/1, info/1, prepare_ndvi/2]).
%% exported for unit tests
-export([bbox_3857/3, fake_extent/2, jdecode/1, native_zoom/1, scheme/1, allowed/1]).

-include_lib("kernel/include/file.hrl").

-define(SHIFT, 20037508.342789244).   %% half the web-mercator world extent (m)
-define(NDVI_MAX_DIM, 1024).          %% cap the NDVI working grid's larger axis

%% @doc Ingest a source URI to a local web-mercator COG; returns an id, lat/lon
%% bounds [[S,W],[N,E]], and the data's native web-mercator zoom (so the client
%% can stop requesting fresh tiles past it and just crisp-scale the sharpest ones).
-spec prepare(binary() | string()) ->
        {ok, binary(), [[float()]], integer()} | {error, term()}.
prepare(Uri) ->
    case allowed(Uri) of
        false -> {error, {scheme_not_allowed, scheme(Uri)}};
        true  -> prepare_1(Uri)
    end.

prepare_1(Uri) ->
    Vsi = velora_storage:to_vsi(Uri),
    case raw_info(Vsi) of
        {ok, M} ->
            Id   = integer_to_list(erlang:unique_integer([positive])),
            NB   = length(maps:get(<<"bands">>, M, [])),
            Warp = filename:join(velora_config:work_dir(), "web_" ++ Id ++ "_3857.tif"),
            Out  = source_path(Id),
            %% non-georeferenced images get a valid near-equator extent first
            {Src, Vrt} = case has_crs(M) of
                             true  -> {Vsi, undefined};
                             false -> V = geo_vrt(M, Vsi, Id), {V, V}
                         end,
            R = case velora_storage:cmd("gdalwarp",
                         ["-q", "-t_srs", "EPSG:3857", "-r", "bilinear",
                          "-of", "GTiff", Src, Warp]) of
                    {ok, _} ->
                        case velora_storage:cmd("gdal_translate",
                                 ["-q", "-of", "COG", "-ot", "Byte", "-scale"]
                                 ++ band_args(NB) ++ [Warp, Out]) of
                            {ok, _}    -> bounds(Out);
                            {error, E} -> {error, {translate, E}}
                        end;
                    {error, E} -> {error, {warp, E}}
                end,
            _ = file:delete(Warp),
            _ = case Vrt of undefined -> ok; _ -> file:delete(Vrt) end,
            case R of
                {ok, B} -> {ok, list_to_binary(Id), B, native_zoom(Out)};
                Err     -> Err
            end;
        _ -> {error, unreadable}
    end.

%% Web-mercator zoom at which one COG pixel maps to one screen pixel, from the
%% prepared COG's pixel size (geoTransform[1], metres in EPSG:3857).
native_zoom(Path) ->
    case velora_storage:cmd("gdalinfo", ["-json", Path]) of
        {ok, Json} ->
            try
                M = jdecode(Json),
                [_, Pw | _] = maps:get(<<"geoTransform">>, M),
                Z = math:log2((2 * ?SHIFT) / (256 * abs(Pw))),
                max(0, min(24, round(Z)))
            catch _:_ -> 19 end;
        _ -> 19
    end.

%% @doc Cut one XYZ tile (z/x/y) from the prepared COG as a 256x256 PNG binary.
-spec tile(binary(), integer(), integer(), integer()) ->
        {ok, binary()} | {error, term()}.
tile(Id, Z, X, Y) ->
    Src = source_path(Id),
    case filelib:is_regular(Src) of
        false -> {error, not_found};
        true  ->
            %% tiles are deterministic per (id,z,x,y); serve from the on-disk
            %% cache to skip GDAL entirely on repeat views and across clients
            Cache = cache_path(Id, Z, X, Y),
            case file:read_file(Cache) of
                {ok, Bin} -> {ok, Bin};
                _         -> render_tile(Src, Z, X, Y, Cache)
            end
    end.

cache_path(Id, Z, X, Y) ->
    Name = to_list(Id) ++ "_" ++ integer_to_list(Z) ++ "_"
           ++ integer_to_list(X) ++ "_" ++ integer_to_list(Y) ++ ".png",
    filename:join([velora_config:work_dir(), "tc", Name]).

render_tile(Src, Z, X, Y, Cache) ->
    ok = filelib:ensure_dir(Cache),
    {Ulx, Uly, Lrx, Lry} = bbox_3857(Z, X, Y),
    case velora_storage:cmd("gdal_translate",
             ["-q", "-of", "PNG", "-outsize", "256", "256",
              "-projwin_srs", "EPSG:3857",
              "-projwin", f(Ulx), f(Uly), f(Lrx), f(Lry), Src, Cache]) of
        {ok, _} ->
            _ = file:delete(Cache ++ ".aux.xml"),
            file:read_file(Cache);
        {error, E} ->
            _ = file:delete(Cache),   %% e.g. tile fully outside data
            {error, E}
    end.

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) -> L.

source_path(Id) when is_binary(Id) -> source_path(binary_to_list(Id));
source_path(Id) -> filename:join(velora_config:work_dir(), "web_" ++ Id ++ ".tif").

%% @doc The URI's scheme as a lowercase binary; a bare path is `<<"file">>'.
-spec scheme(binary() | string()) -> binary().
scheme(Uri0) ->
    Uri = if is_binary(Uri0) -> binary_to_list(Uri0); true -> Uri0 end,
    case string:split(Uri, "://") of
        [S, _] when S =/= Uri -> list_to_binary(string:lowercase(S));
        _                     -> <<"file">>
    end.

%% @doc Whether a source URI's scheme is permitted. Default-deny: unless the
%% app env `allowed_schemes' is set (a list of schemes), only https/s3/gs/work
%% are fetchable, so `file'/`http' are refused out of the box to avoid
%% local-file reads and SSRF. An exposed deployment widens or narrows the set
%% via `allowed_schemes'.
-spec allowed(binary() | string()) -> boolean().
allowed(Uri) ->
    L = case application:get_env(velora, allowed_schemes) of
            {ok, LL} when is_list(LL) -> LL;
            _ -> [<<"https">>, <<"s3">>, <<"gs">>, <<"work">>]
        end,
    lists:member(scheme(Uri), [to_bin(X) || X <- L]).

to_bin(A) when is_atom(A)   -> atom_to_binary(A, utf8);
to_bin(S) when is_list(S)   -> list_to_binary(S);
to_bin(B) when is_binary(B) -> B.

%% @doc Delete prepared COGs, uploads and straggler tiles in the work dir older
%% than TtlMs (their mtime). Returns how many files were removed. Prevents the
%% work dir from growing without bound on a long-running server.
-spec sweep(pos_integer()) -> non_neg_integer().
sweep(TtlMs) ->
    Dir = velora_config:work_dir(),
    Now = erlang:system_time(millisecond),
    Files = lists:append([filelib:wildcard(filename:join(Dir, P))
                          || P <- ["web_*", "upload_*", "t_*.png", "tc/*.png", "*.vec"]]),
    Stale = [F || F <- Files, is_stale(F, Now, TtlMs)],
    _ = [file:delete(F) || F <- Stale],
    length(Stale).

is_stale(F, Now, Ttl) ->
    case file:read_file_info(F, [{time, posix}]) of
        {ok, #file_info{mtime = M}} -> Now - (M * 1000) >= Ttl;
        _ -> false
    end.

band_args(N) when N >= 3 -> ["-b", "1", "-b", "2", "-b", "3"];
band_args(_)             -> [].

%% Non-georeferenced image -> lightweight VRT referencing it with a valid
%% near-equator extent (aspect-preserving) so mercator distortion is tiny.
geo_vrt(M, Vsi, Id) ->
    [W, H] = maps:get(<<"size">>, M, [1, 1]),
    {Ulx, Uly, Lrx, Lry} = fake_extent(W, H),
    Vrt = filename:join(velora_config:work_dir(), "web_" ++ Id ++ "_geo.vrt"),
    case velora_storage:cmd("gdal_translate",
             ["-q", "-of", "VRT", "-a_srs", "EPSG:4326",
              "-a_ullr", f(Ulx), f(Uly), f(Lrx), f(Lry), Vsi, Vrt]) of
        {ok, _}    -> Vrt;
        {error, _} -> Vsi
    end.

%% Centre a small box on the equator so web-mercator's latitude stretching stays
%% negligible (otherwise a round object looks egg-shaped). {Ulx,Uly,Lrx,Lry}.
fake_extent(W, H) when is_integer(W), is_integer(H), W > 0, H > 0 ->
    Aspect = W / H,
    LatHalf = 10.0,
    LonHalf0 = LatHalf * Aspect,
    {LatH, LonH} = case LonHalf0 > 170.0 of
                       true  -> {170.0 / Aspect, 170.0};
                       false -> {LatHalf, LonHalf0}
                   end,
    {-LonH, LatH, LonH, -LatH};
fake_extent(_, _) -> {-10.0, 10.0, 10.0, -10.0}.

has_crs(#{<<"coordinateSystem">> := #{<<"wkt">> := Wkt}}) when is_binary(Wkt), Wkt =/= <<>> -> true;
has_crs(_) -> false.

raw_info(Vsi) ->
    case velora_storage:cmd("gdalinfo", ["-json", Vsi]) of
        {ok, Json} -> try {ok, jdecode(Json)} catch _:_ -> error end;
        _ -> error
    end.

%% @doc Compact `gdalinfo -json' metadata for a source: pixel `size' `[W,H]',
%% `bands' count, coordinate-system `crs' WKT, and GDAL `driver' short name.
%% Used by the emergence agent to answer an `info' intent.
-spec info(binary() | string()) -> {ok, map()} | {error, term()}.
info(Uri) ->
    case allowed(Uri) of
        false -> {error, {scheme_not_allowed, scheme(Uri)}};
        true  -> info_1(Uri)
    end.

info_1(Uri) ->
    In = velora_storage:to_vsi(Uri),
    case velora_storage:cmd("gdalinfo", ["-json", In]) of
        {ok, Out} ->
            J = jdecode(Out),
            {ok, #{size   => maps:get(<<"size">>, J, [0, 0]),
                   bands  => length(maps:get(<<"bands">>, J, [])),
                   crs    => case J of
                                 #{<<"coordinateSystem">> := #{<<"wkt">> := W}} -> W;
                                 _ -> <<"unknown">>
                             end,
                   driver => maps:get(<<"driverShortName">>, J, <<"?">>)}};
        {error, R} -> {error, R}
    end.

%% @doc Compute NDVI from a Red and a Nir source and lay the result out as a
%% web-mercator Byte COG identical to `prepare/1''s, so `tile/4' serves it
%% unchanged. Both sources are warped to one shared, size-capped 3857 grid, read
%% as `u16' band binaries, and combined with `rast:ndvi_u16/2' (which returns a
%% little-endian `f32' NDVI binary in the real [-1,1] range). `Stats' are the
%% mean/min/max over those f32 NDVI pixels. Returns the tile id, lat/lon bounds
%% [[S,W],[N,E]], the data's native web-mercator zoom, and `Stats'.
-spec prepare_ndvi(binary() | string(), binary() | string()) ->
        {ok, binary(), [[float()]], integer(), map()} | {error, term()}.
prepare_ndvi(RedUri, NirUri) ->
    case allowed(RedUri) andalso allowed(NirUri) of
        false -> {error, {scheme_not_allowed, scheme(RedUri)}};
        true  -> prepare_ndvi_1(RedUri, NirUri)
    end.

prepare_ndvi_1(RedUri, NirUri) ->
    Id   = integer_to_list(erlang:unique_integer([positive])),
    Dir  = velora_config:work_dir(),
    RedW = filename:join(Dir, "ndvi_" ++ Id ++ "_red_3857.tif"),
    NirW = filename:join(Dir, "ndvi_" ++ Id ++ "_nir_3857.tif"),
    F32  = filename:join(Dir, "ndvi_" ++ Id ++ "_f32.tif"),
    Out  = source_path(Id),
    R = try
            {W, H, Ulx, Uly, Lrx, Lry} = warp_capped(RedUri, RedW),
            ok = warp_to_grid(NirUri, NirW, {W, H, Ulx, Uly, Lrx, Lry}),
            {ok, RedBin} = read_band1(RedW),
            {ok, NirBin} = read_band1(NirW),
            {ok, Ndvi}   = rast:ndvi_u16(NirBin, RedBin),
            %% f32 NDVI GeoTIFF in 3857, then a Byte COG laid out like prepare/1.
            %% NDVI's known [-1,1] range maps to 0..255 (a fixed, meaningful
            %% stretch), unlike prepare/1's data-derived auto -scale.
            ok = velora_storage:write_tile(F32, Ndvi, W, H, "EPSG:3857",
                                           {Ulx, Uly, Lrx, Lry}),
            {ok, _} = velora_storage:cmd("gdal_translate",
                        ["-q", "-of", "COG", "-ot", "Byte",
                         "-scale", "-1", "1", "0", "255", F32, Out]),
            {ok, Bounds} = bounds(Out),
            {ok, Bounds, ndvi_stats(Ndvi)}
        catch _:E -> {error, {prepare_ndvi, E}} end,
    _ = [file:delete(P) || P <- [RedW, NirW, F32]],
    case R of
        {ok, B, Stats} -> {ok, list_to_binary(Id), B, native_zoom(Out), Stats};
        Err            -> Err
    end.

%% Warp a source to EPSG:3857 as a UInt16 GeoTIFF, capping the larger axis at
%% ?NDVI_MAX_DIM (square pixels: gdalwarp derives the free axis). -ot UInt16
%% guarantees the band format rast:ndvi_u16/2 requires. Returns the output grid
%% {W, H, Ulx, Uly, Lrx, Lry}.
warp_capped(Uri, OutTif) ->
    In     = velora_storage:to_vsi(Uri),
    TsArgs = case info(Uri) of
                 {ok, #{size := [W, H]}} when is_integer(W), is_integer(H), W >= H ->
                     ["-ts", integer_to_list(min(W, ?NDVI_MAX_DIM)), "0"];
                 {ok, #{size := [W, H]}} when is_integer(W), is_integer(H) ->
                     ["-ts", "0", integer_to_list(min(H, ?NDVI_MAX_DIM))];
                 _ ->
                     ["-ts", integer_to_list(?NDVI_MAX_DIM), "0"]
             end,
    case velora_storage:cmd("gdalwarp",
             ["-q", "-t_srs", "EPSG:3857", "-r", "bilinear", "-ot", "UInt16"]
             ++ TsArgs ++ ["-of", "GTiff", In, OutTif]) of
        {ok, _}    -> grid_of(OutTif);
        {error, E} -> erlang:error({warp_red, E})
    end.

%% Warp a source onto an existing grid's exact extent and size (pixel-aligned
%% with warp_capped's output), as UInt16.
warp_to_grid(Uri, OutTif, {W, H, Ulx, Uly, Lrx, Lry}) ->
    In = velora_storage:to_vsi(Uri),
    case velora_storage:cmd("gdalwarp",
             ["-q", "-t_srs", "EPSG:3857", "-r", "bilinear", "-ot", "UInt16",
              "-te", f(Ulx), f(Lry), f(Lrx), f(Uly),
              "-ts", integer_to_list(W), integer_to_list(H),
              "-of", "GTiff", In, OutTif]) of
        {ok, _}    -> ok;
        {error, E} -> erlang:error({warp_nir, E})
    end.

%% Pixel size and 3857 extent of a raster from its geoTransform.
grid_of(Path) ->
    {ok, Json} = velora_storage:cmd("gdalinfo", ["-json", Path]),
    M = jdecode(Json),
    [W, H] = maps:get(<<"size">>, M),
    [G0, G1, _, G3, _, G5] = maps:get(<<"geoTransform">>, M),
    {W, H, G0, G3, G0 + W * G1, G3 + H * G5}.

%% Read band 1 of a raster as a raw little-endian binary in its native dtype.
read_band1(Path) ->
    {ok, Hd = #{width := W, height := H}} = rast_gdal:open(Path),
    R = rast_gdal:read_window(Hd, #{x => 0, y => 0, w => W, h => H}, 1),
    ok = rast_gdal:close(Hd),
    R.

%% mean/min/max over a little-endian f32 NDVI binary, via velora_stats.
ndvi_stats(NdviBin) ->
    P = velora_stats:tile_stats(NdviBin, {-1.0, 1.0}, 64),
    F = velora_stats:finalize(P, {-1.0, 1.0}),
    #{mean => maps:get(mean, F), min => maps:get(min, F), max => maps:get(max, F)}.

%% gdalinfo output can be prefixed by GDAL warnings (stderr merged into stdout),
%% so decode from the first '{'.
jdecode(Bin) ->
    case binary:match(Bin, <<"{">>) of
        {Pos, _} -> json:decode(binary:part(Bin, Pos, byte_size(Bin) - Pos));
        nomatch  -> erlang:error(no_json)
    end.

%% XYZ tile (origin top-left) -> web-mercator bounding box {ulx,uly,lrx,lry}.
bbox_3857(Z, X, Y) ->
    N    = math:pow(2, Z),
    Size = (2 * ?SHIFT) / N,
    Ulx  = -?SHIFT + X * Size,
    Uly  =  ?SHIFT - Y * Size,
    {Ulx, Uly, Ulx + Size, Uly - Size}.

%% lat/lon bounds for Leaflet fitBounds, from gdalinfo's wgs84Extent.
bounds(Src) ->
    case velora_storage:cmd("gdalinfo", ["-json", Src]) of
        {ok, Json} ->
            try
                M = jdecode(Json),
                #{<<"wgs84Extent">> := #{<<"coordinates">> := [Ring | _]}} = M,
                Lons = [Lon || [Lon, _Lat] <- Ring],
                Lats = [Lat || [_Lon, Lat] <- Ring],
                {ok, [[lists:min(Lats), lists:min(Lons)],
                      [lists:max(Lats), lists:max(Lons)]]}
            catch _:_ -> {error, no_bounds} end;
        {error, E} -> {error, {gdalinfo, E}}
    end.

f(X) -> lists:flatten(io_lib:format("~.6f", [X])).
