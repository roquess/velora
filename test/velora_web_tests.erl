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

%% ---- source-scheme restriction ----

scheme_test() ->
    ?assertEqual(<<"https">>, velora_web:scheme(<<"https://h/x.tif">>)),
    ?assertEqual(<<"s3">>,    velora_web:scheme(<<"s3://b/k.tif">>)),
    ?assertEqual(<<"file">>,  velora_web:scheme(<<"file:///a.tif">>)),
    ?assertEqual(<<"file">>,  velora_web:scheme(<<"/local/a.tif">>)).

allowed_default_test() ->
    application:unset_env(velora, allowed_schemes),
    ?assert(velora_web:allowed(<<"file:///x.tif">>)),
    ?assert(velora_web:allowed(<<"http://h/x.tif">>)).

allowed_restricted_test() ->
    application:set_env(velora, allowed_schemes, [https, s3]),
    try
        ?assertNot(velora_web:allowed(<<"file:///x.tif">>)),
        ?assertNot(velora_web:allowed(<<"http://h/x.tif">>)),
        ?assert(velora_web:allowed(<<"https://h/x.tif">>)),
        ?assert(velora_web:allowed(<<"s3://b/k.tif">>))
    after application:unset_env(velora, allowed_schemes) end.

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
    [R] = velora_agent_h:handle_query(Body),
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
    R = velora_web:prepare(list_to_binary(Scene)),
    ?assertMatch({ok, _, [[_, _], [_, _]], _}, R),
    {ok, Id, [[S, W], [N, E]], NZ} = R,
    ?assert(is_integer(NZ) andalso NZ >= 0),
    %% a tile covering the data centre must come back as a PNG
    Z = 4,
    {X, Y} = lonlat_to_xy((W + E) / 2, (S + N) / 2, Z),
    {ok, Png} = velora_web:tile(Id, Z, X, Y),
    ?assertMatch(<<137, 80, 78, 71, _/binary>>, Png).

%% A rendered tile is cached to disk; a repeat request is served from the cache
%% (same bytes, file not re-rendered).
tile_cache_test_() ->
    {timeout, 60, fun() ->
        case gdal_available() of
            false -> ?debugMsg("GDAL not available, skipping"), ok;
            true  -> do_tile_cache()
        end
    end}.

do_tile_cache() ->
    velora_storage:ensure_gdal_env(),
    Dir = velora_worker_tests:tmp_dir(),
    Scene = velora_worker_tests:make_2band_u16(Dir, "cachescene", 16, 16),
    {ok, Id, [[S, W], [N, E]], _} = velora_web:prepare(list_to_binary(Scene)),
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
                {ok, Id, [[S,W],[N,E]], NZ, Stats} = velora_web:prepare_ndvi(B, B),
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
                {ok, Info} = velora_web:info(list_to_binary(Scene)),
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
