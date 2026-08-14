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
