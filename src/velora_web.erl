%%% @doc Server-side web display of arbitrary rasters. `prepare/1` ingests any
%%% GDAL-readable source (any format/size, georeferenced or not) once into a local
%%% 8-bit web-mercator COG with overviews — this is the heavy, Erlang-side step.
%%% Each XYZ tile is then cut from that local COG on demand: GDAL reads only the
%%% overview level and window the tile covers, so the browser only ever fetches
%%% the currently-visible tiles and never the whole image.
-module(velora_web).
-export([prepare/1, tile/4, source_path/1, sweep/1, info/1, prepare_ndvi/2]).
%% exported for unit tests
-export([bbox_3857/3, fake_extent/2, jdecode/1, native_zoom/1, scheme/1, allowed/1,
         source_size_ok/2, tile_key/4, tiles_cache/0, render_count/0, reset_render_count/0,
         prepare_cache/0, canonical/1, source_hash/1]).

-include_lib("kernel/include/file.hrl").

-define(SHIFT, 20037508.342789244).   %% half the web-mercator world extent (m)
-define(NDVI_MAX_DIM, 1024).          %% cap the NDVI working grid's larger axis
-define(TILES_CACHE_STATE, {?MODULE, tiles_cache_state}). %% persistent_term key
-define(PREPARE_CACHE_STATE, {?MODULE, prepare_cache_state}). %% persistent_term key
-define(RENDER_COUNT, {?MODULE, render_count}).            %% persistent_term key

%% @doc Ingest a source URI to a local web-mercator COG; returns an id, lat/lon
%% bounds [[S,W],[N,E]], and the data's native web-mercator zoom (so the client
%% can stop requesting fresh tiles past it and just crisp-scale the sharpest ones).
-spec prepare(binary() | string()) ->
        {ok, binary(), [[float()]], integer()} | {error, term()}.
prepare(Uri) ->
    case allowed(Uri) of
        false -> {error, {scheme_not_allowed, scheme(Uri)}};
        true  -> velora_render_limiter:with_slot(fun() -> prepare_1(Uri) end)
    end.

%% Memo check: a cache hit whose COG still exists on disk short-circuits the
%% whole warp; a miss, or a hit whose COG was swept by the janitor, falls
%% through to the heavy path (`prepare_fresh/2'), which stores a fresh memo
%% entry on success. When the cache NIF is unavailable, this degrades to the
%% original unmemoized behavior (see `prepare_cache/0').
prepare_1(Uri) ->
    case prepare_cache() of
        {ok, C} ->
            Hash = source_hash(Uri),
            case velora_cache:get(C, Hash) of
                {ok, Bin} ->
                    #{id := Id, bounds := B, nz := NZ} = binary_to_term(Bin),
                    case filelib:is_regular(source_path(Id)) of
                        true  -> {ok, list_to_binary(Id), B, NZ};   %% hit, no warp
                        false -> prepare_fresh(Uri, {memo, C, Hash})  %% stale memo
                    end;
                miss -> prepare_fresh(Uri, {memo, C, Hash})
            end;
        unavailable -> prepare_fresh(Uri, none)
    end.

prepare_fresh(Uri, Memo) ->
    Vsi = velora_storage:to_vsi(Uri),
    case raw_info(Vsi) of
        {ok, M} ->
            MaxMP = application:get_env(velora, max_source_megapixels, 500),
            case source_size_ok(M, MaxMP) of
                {error, _} = TooBig -> TooBig;
                ok -> prepare_2(Vsi, M, Memo)
            end;
        _ -> {error, unreadable}
    end.

prepare_2(Vsi, M, Memo) ->
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
        {ok, B} ->
            NZ = native_zoom(Out),
            ok = memo_put(Memo, Id, B, NZ),
            {ok, list_to_binary(Id), B, NZ};
        Err -> Err
    end.

%% Store the freshly-prepared `{Id,Bounds,NativeZoom}' under the memo hash
%% computed before the warp, keeping the string `Id' (not the binary form
%% `prepare/1' returns) so a later hit's `source_path(Id)' check works the
%% same way as here. No-op when memoization is unavailable for this call.
memo_put({memo, C, Hash}, Id, B, NZ) ->
    velora_cache:put(C, Hash, term_to_binary(#{id => Id, bounds => B, nz => NZ}));
memo_put(none, _Id, _B, _NZ) ->
    ok.

%% @doc Whether a `gdalinfo -json' metadata map's pixel count is within
%% `MaxMP' megapixels. Pure and GDAL-free so it's unit-testable in isolation;
%% a missing/malformed `size' is treated as ok (the caller's downstream GDAL
%% call will surface the real failure).
-spec source_size_ok(map(), pos_integer()) -> ok | {error, {source_too_large, non_neg_integer()}}.
source_size_ok(M, MaxMP) ->
    case maps:get(<<"size">>, M, [0, 0]) of
        [W, H] when is_integer(W), is_integer(H), W * H > MaxMP * 1000000 ->
            {error, {source_too_large, W * H div 1000000}};
        _ -> ok
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
%% Memory-first: a bounded `velora_cache' instance (`tiles', 2Q eviction) sits
%% in front of GDAL, keyed on `{Id,Z,X,Y}'. When the cache NIF is unavailable
%% on this platform/build, this degrades to the original on-disk `tc/' cache
%% so tiles are still deduplicated across requests. See `tiles_cache/0'.
-spec tile(binary(), integer(), integer(), integer()) ->
        {ok, binary()} | {error, term()}.
tile(Id, Z, X, Y) ->
    Src = source_path(Id),
    case filelib:is_regular(Src) of
        false -> {error, not_found};
        true  ->
            case tiles_cache() of
                {ok, tiles} -> tile_memory(Id, Src, Z, X, Y);
                unavailable -> tile_disk(Id, Src, Z, X, Y)
            end
    end.

%% Memory-cache path: hit serves straight from `velora_cache' (no disk, no
%% GDAL); miss renders, populates the memory cache, and optionally also
%% writes the disk L2 (`tile_disk_cache' app env, default false).
tile_memory(Id, Src, Z, X, Y) ->
    Key = tile_key(Id, Z, X, Y),
    case velora_cache:get(tiles, Key) of
        {ok, Bin} -> {ok, Bin};
        miss ->
            case render_tile_bin(Src, Z, X, Y) of
                {ok, Bin} ->
                    ok = velora_cache:put(tiles, Key, Bin),
                    _ = maybe_write_disk_l2(Id, Z, X, Y, Bin),
                    {ok, Bin};
                {error, _} = Err -> Err
            end
    end.

%% Disk-cache fallback path (memory cache NIF unavailable): the original
%% behavior, unconditional on `tile_disk_cache'.
tile_disk(Id, Src, Z, X, Y) ->
    Cache = cache_path(Id, Z, X, Y),
    case file:read_file(Cache) of
        {ok, Bin} -> {ok, Bin};
        _ ->
            case render_tile_bin(Src, Z, X, Y) of
                {ok, Bin} ->
                    ok = write_disk_cache(Cache, Bin),
                    {ok, Bin};
                {error, _} = Err -> Err
            end
    end.

maybe_write_disk_l2(Id, Z, X, Y, Bin) ->
    case application:get_env(velora, tile_disk_cache, false) of
        true  -> write_disk_cache(cache_path(Id, Z, X, Y), Bin);
        false -> ok
    end.

write_disk_cache(Cache, Bin) ->
    ok = filelib:ensure_dir(Cache),
    file:write_file(Cache, Bin).

%% @doc Whether the in-memory tile cache is usable. Lazily creates the named
%% `velora_cache' instance `tiles' on first use and memoizes the outcome in a
%% `persistent_term' so a NIF-absent platform (no prebuilt `velora_cache' NIF
%% for this OS/arch, or a cargo-less build) is only probed once, not retried
%% on every tile request. Capacity from app env `tile_cache_entries' (default
%% 2048), policy `twoq' (scan-resistant, so panning a large scene does not
%% evict the hot centre).
-spec tiles_cache() -> {ok, tiles} | unavailable.
tiles_cache() ->
    case persistent_term:get(?TILES_CACHE_STATE, undefined) of
        undefined ->
            State = init_tiles_cache(),
            persistent_term:put(?TILES_CACHE_STATE, State),
            State;
        State -> State
    end.

init_tiles_cache() ->
    Cap = application:get_env(velora, tile_cache_entries, 2048),
    try velora_cache:new(tiles, #{capacity => Cap, policy => twoq}) of
        ok             -> {ok, tiles};
        {error, _}     -> unavailable
    catch
        _:_ -> unavailable
    end.

%% @doc Whether the `prepare/1' memoization cache is usable. Same lazy
%% `persistent_term'-memoized probe pattern as `tiles_cache/0': a NIF-absent
%% platform/build is only probed once. Capacity from app env
%% `prepare_cache_entries' (default 256), policy `lru' (recency, not
%% scan-resistance, is what matters for a small set of distinct sources).
-spec prepare_cache() -> {ok, prepare} | unavailable.
prepare_cache() ->
    case persistent_term:get(?PREPARE_CACHE_STATE, undefined) of
        undefined ->
            State = init_prepare_cache(),
            persistent_term:put(?PREPARE_CACHE_STATE, State),
            State;
        State -> State
    end.

init_prepare_cache() ->
    Cap = application:get_env(velora, prepare_cache_entries, 256),
    try velora_cache:new(prepare, #{capacity => Cap, policy => lru}) of
        ok         -> {ok, prepare};
        {error, _} -> unavailable
    catch
        _:_ -> unavailable
    end.

%% @doc Normalize a source URI for hashing: accept binary or string, trim
%% surrounding whitespace. Keeps the full URI string as-is (scheme, path and
%% query together) rather than trying to strip volatile query tokens (e.g.
%% signed-S3 credentials): two different callers presenting different
%% credentials for the same `s3://bucket/key' object will therefore share one
%% memoized render. That is acceptable — the underlying object content is the
%% same — but distinct object paths never collide since the whole URI is
%% hashed.
-spec canonical(binary() | string()) -> binary().
canonical(Uri) when is_list(Uri) -> canonical(list_to_binary(Uri));
canonical(Uri) when is_binary(Uri) -> string:trim(Uri).

%% @doc Stable memoization key for a source URI: sha256 of `canonical/1',
%% hex-encoded.
-spec source_hash(binary() | string()) -> binary().
source_hash(Uri) -> binary:encode_hex(crypto:hash(sha256, canonical(Uri))).

%% @doc Canonical binary cache key for one `{Id,Z,X,Y}' tile coordinate.
-spec tile_key(binary() | string(), integer(), integer(), integer()) -> binary().
tile_key(Id, Z, X, Y) ->
    iolist_to_binary([to_list(Id), "/", integer_to_list(Z), "/",
                       integer_to_list(X), "/", integer_to_list(Y)]).

cache_path(Id, Z, X, Y) ->
    Name = to_list(Id) ++ "_" ++ integer_to_list(Z) ++ "_"
           ++ integer_to_list(X) ++ "_" ++ integer_to_list(Y) ++ ".png",
    filename:join([velora_config:work_dir(), "tc", Name]).

%% @doc Render one tile from the prepared COG to a PNG binary (GDAL work
%% only; does not touch the disk cache). Bumps a `persistent_term' render
%% counter (test seam: lets tests observe a memory-cache hit by asserting
%% this does NOT increment, without GDAL spawns being the only signal).
render_tile_bin(Src, Z, X, Y) ->
    bump_render_count(),
    Tmp = filename:join([velora_config:work_dir(), "tc",
             "tmp_" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".png"]),
    ok = filelib:ensure_dir(Tmp),
    {Ulx, Uly, Lrx, Lry} = bbox_3857(Z, X, Y),
    case velora_storage:cmd("gdal_translate",
             ["-q", "-of", "PNG", "-outsize", "256", "256",
              "-projwin_srs", "EPSG:3857",
              "-projwin", f(Ulx), f(Uly), f(Lrx), f(Lry), Src, Tmp]) of
        {ok, _} ->
            _ = file:delete(Tmp ++ ".aux.xml"),
            R = file:read_file(Tmp),
            _ = file:delete(Tmp),
            R;
        {error, E} ->
            _ = file:delete(Tmp),
            _ = file:delete(Tmp ++ ".aux.xml"),
            {error, E}   %% e.g. tile fully outside data
    end.

bump_render_count() ->
    N = case persistent_term:get(?RENDER_COUNT, undefined) of
            undefined -> 0;
            V         -> V
        end,
    persistent_term:put(?RENDER_COUNT, N + 1).

%% @doc Current value of the render-count test seam (see `render_tile_bin/4').
-spec render_count() -> non_neg_integer().
render_count() ->
    case persistent_term:get(?RENDER_COUNT, undefined) of
        undefined -> 0;
        V         -> V
    end.

%% @doc Reset the render-count test seam to 0.
-spec reset_render_count() -> ok.
reset_render_count() ->
    persistent_term:put(?RENDER_COUNT, 0).

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
            _ -> [<<"https">>, <<"s3">>, <<"gs">>, <<"work">>, <<"asset">>]
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
        true  -> velora_render_limiter:with_slot(fun() -> prepare_ndvi_1(RedUri, NirUri) end)
    end.

prepare_ndvi_1(RedUri, NirUri) ->
    MaxMP = application:get_env(velora, max_source_megapixels, 500),
    case ndvi_sources_size_ok(RedUri, NirUri, MaxMP) of
        {error, _} = TooBig -> TooBig;
        ok -> prepare_ndvi_2(RedUri, NirUri)
    end.

%% Both Red and Nir are guarded: warp_capped/1 below reads Red's size via
%% info/1 for its `-ts' args, but Nir is warped straight onto Red's grid
%% without ever being sized, so an oversized Nir source would otherwise skip
%% the cap entirely.
ndvi_sources_size_ok(RedUri, NirUri, MaxMP) ->
    case ndvi_source_size_ok(RedUri, MaxMP) of
        {error, _} = E -> E;
        ok             -> ndvi_source_size_ok(NirUri, MaxMP)
    end.

ndvi_source_size_ok(Uri, MaxMP) ->
    case raw_info(velora_storage:to_vsi(Uri)) of
        {ok, M} -> source_size_ok(M, MaxMP);
        _       -> ok   %% unreadable; the warp step below surfaces the real error
    end.

prepare_ndvi_2(RedUri, NirUri) ->
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
