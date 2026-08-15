-module(velora_web_tests).
-include_lib("eunit/include/eunit.hrl").

-define(SHIFT, 20037508.342789244).

%% ---- pure functions ----

bbox_world_test() ->
    {Ulx, Uly, Lrx, Lry} = velora_web:bbox_3857(0, 0, 0),
    ?assert(abs(Ulx + ?SHIFT) < 1.0e-3),
    ?assert(abs(Uly - ?SHIFT) < 1.0e-3),
    ?assert(abs(Lrx - ?SHIFT) < 1.0e-3),
    ?assert(abs(Lry + ?SHIFT) < 1.0e-3).

bbox_quadrant_test() ->
    %% z=1, x=1, y=0 is the north-east quadrant: ulx=0, uly=S, lrx=S, lry=0
    {Ulx, Uly, Lrx, Lry} = velora_web:bbox_3857(1, 1, 0),
    ?assert(abs(Ulx) < 1.0e-3),
    ?assert(abs(Uly - ?SHIFT) < 1.0e-3),
    ?assert(abs(Lrx - ?SHIFT) < 1.0e-3),
    ?assert(abs(Lry) < 1.0e-3).

fake_extent_aspect_test() ->
    %% aspect 2 -> latHalf 10, lonHalf 20, centred on the equator
    ?assertEqual({-20.0, 10.0, 20.0, -10.0}, velora_web:fake_extent(200, 100)).

fake_extent_wide_cap_test() ->
    %% very wide image: lonHalf is capped at 170, latHalf scaled down
    {Ulx, Uly, Lrx, Lry} = velora_web:fake_extent(1000, 10),
    ?assert(abs(Lrx - 170.0) < 1.0e-6),
    ?assert(abs(Ulx + 170.0) < 1.0e-6),
    ?assert(Uly < 10.0 andalso Uly > 0.0),
    ?assert(abs(Uly + Lry) < 1.0e-9).   %% symmetric about the equator

jdecode_test() ->
    %% GDAL warnings prefix the JSON on stderr->stdout; decode from the first '{'
    ?assertEqual(#{<<"a">> => 1},
                 velora_web:jdecode(<<"Warning 1: no .aux.xml\n{\"a\":1}">>)),
    ?assertEqual(#{<<"b">> => 2}, velora_web:jdecode(<<"{\"b\":2}">>)).

jdecode_no_json_test() ->
    ?assertError(no_json, velora_web:jdecode(<<"no json here">>)).

%% ---- source-size guard ----

source_size_ok_test() ->
    ?assertEqual(ok, velora_web:source_size_ok(#{<<"size">> => [1000,1000]}, 500)),
    ?assertMatch({error, {source_too_large, _}},
                 velora_web:source_size_ok(#{<<"size">> => [30000,30000]}, 500)),  %% 900 MP
    ?assertEqual(ok, velora_web:source_size_ok(#{}, 500)).                          %% no size => ok

%% ---- source-scheme restriction ----

scheme_test() ->
    ?assertEqual(<<"https">>, velora_web:scheme(<<"https://h/x.tif">>)),
    ?assertEqual(<<"s3">>,    velora_web:scheme(<<"s3://b/k.tif">>)),
    ?assertEqual(<<"file">>,  velora_web:scheme(<<"file:///a.tif">>)),
    ?assertEqual(<<"file">>,  velora_web:scheme(<<"/local/a.tif">>)).

allowed_default_test() ->
    application:unset_env(velora, allowed_schemes),
    ?assertNot(velora_web:allowed(<<"file:///x.tif">>)),
    ?assertNot(velora_web:allowed(<<"http://h/x.tif">>)).

%% The default (no `allowed_schemes' configured) denies local-file and plain-http
%% sources to close SSRF / local-file-read; only https/s3/gs/work are fetchable
%% out of the box. Operators widen the allowlist via `allowed_schemes'.
allowed_default_denies_file_http_test() ->
    application:unset_env(velora, allowed_schemes),
    ?assertNot(velora_web:allowed(<<"file:///etc/hosts">>)),
    ?assertNot(velora_web:allowed(<<"http://169.254.169.254/latest/meta-data">>)),
    ?assertNot(velora_web:allowed(<<"/tmp/x.tif">>)),          %% bare path => file
    ?assert(velora_web:allowed(<<"https://host/scene.tif">>)),
    ?assert(velora_web:allowed(<<"s3://bucket/scene.tif">>)),
    ?assert(velora_web:allowed(<<"gs://bucket/scene.tif">>)),
    ?assert(velora_web:allowed(<<"work://uploads/x.tif">>)).

allowed_restricted_test() ->
    application:set_env(velora, allowed_schemes, [https, s3]),
    try
        ?assertNot(velora_web:allowed(<<"file:///x.tif">>)),
        ?assertNot(velora_web:allowed(<<"http://h/x.tif">>)),
        ?assert(velora_web:allowed(<<"https://h/x.tif">>)),
        ?assert(velora_web:allowed(<<"s3://b/k.tif">>))
    after application:unset_env(velora, allowed_schemes) end.

info_scheme_gate_test() ->
    application:set_env(velora, allowed_schemes, [https]),
    try
        ?assertMatch({error, {scheme_not_allowed, _}},
                     velora_web:info(<<"file:///etc/hosts">>))
    after
        application:unset_env(velora, allowed_schemes)
    end.

%% ---- emergence agent query ----

agent_query_test_() ->
    {timeout, 60, fun() ->
        case gdal_available() of
            false -> ?debugMsg("GDAL not available, skipping"), ok;
            true  -> do_agent_query()
        end
    end}.

do_agent_query() ->
    velora_storage:ensure_gdal_env(),
    Dir = velora_worker_tests:tmp_dir(),
    Scene = velora_worker_tests:make_2band_u16(Dir, "agentscene", 16, 16),
    %% velora_agent classifies a query as a raster URI only when it carries a
    %% scheme ("://"); a bare filesystem path is otherwise treated as a place.
    Uri = <<"file://", (list_to_binary(Scene))/binary>>,
    Body = jsx:encode(#{uri => Uri}),
    %% this test drives velora_web:prepare/1 with a local `file://' fixture, so
    %% opt `file' back into the allowlist for the duration of the call (the
    %% product default stays deny; only the test widens it)
    [R] = with_file_scheme_allowed(fun() -> velora_agent_h:handle_query(Body) end),
    ?assertEqual(<<"raster">>, maps:get(type, R)),
    ?assert(is_binary(maps:get(id, R))),
    ?assertMatch([[_, _], [_, _]], maps:get(bounds, R)),
    %% a query without a source URI answers with no results
    ?assertEqual([], velora_agent_h:handle_query(jsx:encode(#{query => <<"hello world">>}))).

%% intent routing: a URI query resolves regardless of a network error being
%% possible downstream; an empty query (with or without an explicit intent)
%% always answers with no results.
agent_query_intent_test() ->
    R1 = velora_agent_h:handle_query(
           jsx:encode(#{<<"query">> => <<"https://example.invalid/x.tif">>})),
    ?assert(is_list(R1)),
    R2 = velora_agent_h:handle_query(jsx:encode(#{<<"query">> => <<>>})),
    ?assertEqual([], R2),
    R3 = velora_agent_h:handle_query(
           jsx:encode(#{<<"query">> => <<>>, <<"intent">> => <<"ndvi">>})),
    ?assertEqual([], R3).

%% ---- work-dir sweep ----

sweep_test() ->
    Dir = velora_config:work_dir(),
    Old = filename:join(Dir, "web_sweeptest_old.tif"),
    New = filename:join(Dir, "web_sweeptest_new.tif"),
    ok = file:write_file(Old, <<"x">>),
    ok = file:write_file(New, <<"y">>),
    %% backdate Old by 2h (local time, as file:change_time expects)
    Old2h = calendar:gregorian_seconds_to_datetime(
              calendar:datetime_to_gregorian_seconds(calendar:local_time()) - 7200),
    ok = file:change_time(Old, Old2h),
    N = velora_web:sweep(3600000),     %% 1h TTL
    ?assert(N >= 1),
    ?assertNot(filelib:is_regular(Old)),
    ?assert(filelib:is_regular(New)),
    file:delete(New).

%% ---- GDAL-backed: ingest a small raster and cut a tile ----

prepare_tile_test_() ->
    {timeout, 60, fun() ->
        case gdal_available() of
            false -> ?debugMsg("GDAL not available, skipping"), ok;
            true  -> do_prepare_tile()
        end
    end}.

do_prepare_tile() ->
    velora_storage:ensure_gdal_env(),
    Dir   = velora_worker_tests:tmp_dir(),
    Scene = velora_worker_tests:make_2band_u16(Dir, "webscene", 16, 16),
    %% local fixture: opt `file' back into the default-deny allowlist for the
    %% product-facing `prepare/1' call only; product default stays deny.
    R = with_file_scheme_allowed(fun() -> velora_web:prepare(list_to_binary(Scene)) end),
    ?assertMatch({ok, _, [[_, _], [_, _]], _}, R),
    {ok, Id, [[S, W], [N, E]], NZ} = R,
    ?assert(is_integer(NZ) andalso NZ >= 0),
    %% a tile covering the data centre must come back as a PNG
    Z = 4,
    {X, Y} = lonlat_to_xy((W + E) / 2, (S + N) / 2, Z),
    {ok, Png} = velora_web:tile(Id, Z, X, Y),
    ?assertMatch(<<137, 80, 78, 71, _/binary>>, Png).

%% A rendered tile is cached to disk; a repeat request is served from the cache
%% (same bytes, file not re-rendered). When the memory cache (velora_cache) is
%% available, `tile/4' serves hits from memory instead of touching disk at
%% all, so this test forces the `tile_disk_cache' L2 flag on to exercise the
%% disk-write path explicitly regardless of NIF availability; when the memory
%% cache NIF is absent, `tile/4' falls back unconditionally to this same disk
%% path (see `tile_memory_hit_test_' for the memory-cache-available case).
tile_cache_test_() ->
    {timeout, 60, fun() ->
        case gdal_available() of
            false -> ?debugMsg("GDAL not available, skipping"), ok;
            true  -> with_tile_disk_cache_enabled(fun do_tile_cache/0)
        end
    end}.

do_tile_cache() ->
    velora_storage:ensure_gdal_env(),
    Dir = velora_worker_tests:tmp_dir(),
    Scene = velora_worker_tests:make_2band_u16(Dir, "cachescene", 16, 16),
    {ok, Id, [[S, W], [N, E]], _} =
        with_file_scheme_allowed(fun() -> velora_web:prepare(list_to_binary(Scene)) end),
    Z = 4,
    {X, Y} = lonlat_to_xy((W + E) / 2, (S + N) / 2, Z),
    Cache = filename:join([velora_config:work_dir(), "tc",
                binary_to_list(Id) ++ "_4_" ++ integer_to_list(X) ++ "_"
                ++ integer_to_list(Y) ++ ".png"]),
    _ = file:delete(Cache),
    {ok, P1} = velora_web:tile(Id, Z, X, Y),          %% renders + caches
    ?assert(filelib:is_regular(Cache)),
    ?assertMatch(<<137, 80, 78, 71, _/binary>>, P1),
    Mt1 = filelib:last_modified(Cache),
    timer:sleep(1100),
    {ok, P2} = velora_web:tile(Id, Z, X, Y),          %% cache hit
    ?assertEqual(P1, P2),
    ?assertEqual(Mt1, filelib:last_modified(Cache)).  %% not re-rendered

%% A rendered tile is served from the in-memory `velora_cache' on a repeat
%% request: the render seam (`velora_web:render_count/0') stays at 1 instead
%% of incrementing to 2, proving the second `tile/4' call never re-spawns
%% GDAL. Skips cleanly when the velora_cache NIF isn't loaded for this
%% platform/build (in that case `tile/4' falls back to the disk cache
%% exercised by `tile_cache_test_' above).
tile_memory_hit_test_() ->
    {timeout, 60, fun() ->
        case velora_web:tiles_cache() =:= unavailable of
            true  -> ?debugMsg("velora_cache NIF not loaded, skipping"), ok;
            false ->
                case gdal_available() of
                    false -> ?debugMsg("GDAL not available, skipping"), ok;
                    true  -> do_tile_memory_hit()
                end
        end
    end}.

do_tile_memory_hit() ->
    velora_storage:ensure_gdal_env(),
    Dir = velora_worker_tests:tmp_dir(),
    Scene = velora_worker_tests:make_2band_u16(Dir, "memcachescene", 16, 16),
    {ok, Id, [[S, W], [N, E]], _} =
        with_file_scheme_allowed(fun() -> velora_web:prepare(list_to_binary(Scene)) end),
    Z = 4,
    {X, Y} = lonlat_to_xy((W + E) / 2, (S + N) / 2, Z),
    velora_web:reset_render_count(),
    {ok, P1} = velora_web:tile(Id, Z, X, Y),          %% memory miss: renders
    ?assertMatch(<<137, 80, 78, 71, _/binary>>, P1),
    ?assertEqual(1, velora_web:render_count()),
    {ok, P2} = velora_web:tile(Id, Z, X, Y),          %% memory hit: no render
    ?assertEqual(P1, P2),
    ?assertEqual(1, velora_web:render_count()).

%% ---- prepare/1 memoization key (canonical/1, source_hash/1) ----

canonical_trims_whitespace_test() ->
    ?assertEqual(velora_web:canonical(<<"https://h/x.tif">>),
                 velora_web:canonical(<<"  https://h/x.tif  ">>)).

canonical_normalizes_list_input_test() ->
    ?assertEqual(velora_web:canonical(<<"https://h/x.tif">>),
                 velora_web:canonical("https://h/x.tif")).

source_hash_same_uri_same_hash_test() ->
    ?assertEqual(velora_web:source_hash(<<"https://h/x.tif">>),
                 velora_web:source_hash(<<"https://h/x.tif">>)),
    %% list vs binary input normalizes to the same hash
    ?assertEqual(velora_web:source_hash(<<"https://h/x.tif">>),
                 velora_web:source_hash("https://h/x.tif")),
    %% leading/trailing whitespace does not change the hash
    ?assertEqual(velora_web:source_hash(<<"https://h/x.tif">>),
                 velora_web:source_hash(<<"  https://h/x.tif  ">>)).

source_hash_distinct_uris_test() ->
    ?assertNotEqual(velora_web:source_hash(<<"https://h/x.tif">>),
                     velora_web:source_hash(<<"https://h/y.tif">>)).

%% ---- prepare/1 memoization by source hash ----

%% Preparing the same source URI twice reuses the memoized COG: the second
%% call returns the same `Id' and does not re-warp (the COG's mtime is
%% unchanged). Skips cleanly when the velora_cache NIF isn't loaded for this
%% platform/build (`prepare/1' then behaves as before: no memo, and each call
%% would mint its own COG — see `prepare_tile_test_' for that unmemoized
%% path).
prepare_memo_hit_test_() ->
    {timeout, 60, fun() ->
        case velora_web:prepare_cache() =:= unavailable of
            true  -> ?debugMsg("velora_cache NIF not loaded, skipping"), ok;
            false ->
                case gdal_available() of
                    false -> ?debugMsg("GDAL not available, skipping"), ok;
                    true  -> do_prepare_memo_hit()
                end
        end
    end}.

do_prepare_memo_hit() ->
    velora_storage:ensure_gdal_env(),
    Dir = velora_worker_tests:tmp_dir(),
    Scene = velora_worker_tests:make_2band_u16(Dir, "memoscene", 16, 16),
    Uri = list_to_binary(Scene),
    {ok, Id1, _, _} = with_file_scheme_allowed(fun() -> velora_web:prepare(Uri) end),
    Cog1 = velora_web:source_path(Id1),
    ?assert(filelib:is_regular(Cog1)),
    Mt1 = filelib:last_modified(Cog1),
    timer:sleep(1100),
    {ok, Id2, _, _} = with_file_scheme_allowed(fun() -> velora_web:prepare(Uri) end),
    ?assertEqual(Id1, Id2),
    ?assertEqual(Mt1, filelib:last_modified(Cog1)).   %% not re-warped

%% If the memoized COG was swept from disk (janitor TTL), the memo entry is
%% stale: `prepare/1' re-warps and returns a fresh, valid result instead of
%% crashing or returning a dangling id.
prepare_memo_stale_test_() ->
    {timeout, 60, fun() ->
        case velora_web:prepare_cache() =:= unavailable of
            true  -> ?debugMsg("velora_cache NIF not loaded, skipping"), ok;
            false ->
                case gdal_available() of
                    false -> ?debugMsg("GDAL not available, skipping"), ok;
                    true  -> do_prepare_memo_stale()
                end
        end
    end}.

do_prepare_memo_stale() ->
    velora_storage:ensure_gdal_env(),
    Dir = velora_worker_tests:tmp_dir(),
    Scene = velora_worker_tests:make_2band_u16(Dir, "memostale", 16, 16),
    Uri = list_to_binary(Scene),
    {ok, Id1, _, _} = with_file_scheme_allowed(fun() -> velora_web:prepare(Uri) end),
    ok = file:delete(velora_web:source_path(Id1)),
    R = with_file_scheme_allowed(fun() -> velora_web:prepare(Uri) end),
    ?assertMatch({ok, _, [[_, _], [_, _]], _}, R),
    {ok, Id2, _, _} = R,
    ?assert(filelib:is_regular(velora_web:source_path(Id2))).

%% ---- tile cache key ----

%% Different {Id,Z,X,Y} coordinates never collide; identical coordinates
%% always produce the identical key.
tile_cache_key_distinct_test() ->
    K1 = velora_web:tile_key(<<"abc">>, 4, 1, 2),
    K2 = velora_web:tile_key(<<"abc">>, 4, 1, 2),
    ?assertEqual(K1, K2),
    Variants = [
        velora_web:tile_key(<<"xyz">>, 4, 1, 2),   %% different id
        velora_web:tile_key(<<"abc">>, 5, 1, 2),   %% different z
        velora_web:tile_key(<<"abc">>, 4, 2, 2),   %% different x
        velora_web:tile_key(<<"abc">>, 4, 1, 3)    %% different y
    ],
    ?assertEqual(4, length(lists:usort(Variants))),
    ?assertNot(lists:member(K1, Variants)).

%% ---- NDVI + info for the emergence agent ----

prepare_ndvi_test_() ->
    {timeout, 60, fun() ->
        case gdal_available() of
            false -> ?debugMsg("GDAL not available, skipping"), ok;
            true  ->
                velora_storage:ensure_gdal_env(),
                Dir = velora_worker_tests:tmp_dir(),
                Scene = velora_worker_tests:make_2band_u16(Dir, "ndvi_src", 32, 32),
                B = list_to_binary(Scene),
                {ok, Id, [[S,W],[N,E]], NZ, Stats} =
                    with_file_scheme_allowed(fun() -> velora_web:prepare_ndvi(B, B) end),
                ?assert(is_binary(Id)),
                ?assert(N >= S andalso E >= W),
                ?assert(is_integer(NZ)),
                ?assertMatch(#{mean := _, min := _, max := _}, Stats)
        end
    end}.

info_test_() ->
    {timeout, 30, fun() ->
        case gdal_available() of
            false -> ?debugMsg("GDAL not available, skipping"), ok;
            true  ->
                velora_storage:ensure_gdal_env(),
                Dir = velora_worker_tests:tmp_dir(),
                Scene = velora_worker_tests:make_2band_u16(Dir, "info_src", 16, 16),
                {ok, Info} =
                    with_file_scheme_allowed(fun() -> velora_web:info(list_to_binary(Scene)) end),
                ?assertMatch(#{bands := _, size := _, crs := _}, Info)
        end
    end}.

lonlat_to_xy(Lon, Lat, Z) ->
    N = math:pow(2, Z),
    X = trunc((Lon + 180.0) / 360.0 * N),
    LatR = Lat * math:pi() / 180.0,
    Y = trunc((1.0 - math:log(math:tan(LatR) + 1.0 / math:cos(LatR)) / math:pi()) / 2.0 * N),
    {X, Y}.

gdal_available() ->
    case velora_storage:scene_meta("/nonexistent") of
        {error, {gdalinfo_failed, {spawn_failed, _}}} -> false;
        _ -> true
    end.

%% GDAL-backed tests exercise `prepare/1', `info/1' and `prepare_ndvi/2' against
%% local filesystem fixtures. The product default now denies `file' sources
%% (SSRF / local-file-read hardening), so these tests opt `file' back into the
%% allowlist for the duration of the call; the product default itself is
%% untouched outside the fun.
with_file_scheme_allowed(Fun) ->
    application:set_env(velora, allowed_schemes, [file, https, s3, gs, work]),
    try Fun()
    after application:unset_env(velora, allowed_schemes) end.

%% Force the disk L2 on for the duration of `Fun', to exercise
%% `velora_web:tile/4''s disk-write path even when the memory cache is
%% available (the product default, `tile_disk_cache => false', is untouched
%% outside the fun).
with_tile_disk_cache_enabled(Fun) ->
    application:set_env(velora, tile_disk_cache, true),
    try Fun()
    after application:unset_env(velora, tile_disk_cache) end.
