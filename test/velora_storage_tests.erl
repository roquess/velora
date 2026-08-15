-module(velora_storage_tests).
-include_lib("eunit/include/eunit.hrl").

to_vsi_test() ->
    ?assertEqual("/vsis3/bucket/key.tif",
                 velora_storage:to_vsi(<<"s3://bucket/key.tif">>)),
    ?assertEqual("/tmp/x.tif",
                 velora_storage:to_vsi(<<"file:///tmp/x.tif">>)),
    ?assertEqual("/vsicurl/https://h/x.tif",
                 velora_storage:to_vsi(<<"/vsicurl/https://h/x.tif">>)).

tile_geotransform_test() ->
    GT = {100.0, 10.0, 0.0, 200.0, 0.0, -10.0},
    {Ulx, Uly, Lrx, Lry} = velora_storage:tile_ullr(GT, #{x=>2, y=>3, w=>4, h=>5}),
    ?assert(abs(Ulx - 120.0) < 1.0e-6),
    ?assert(abs(Uly - 170.0) < 1.0e-6),
    ?assert(abs(Lrx - 160.0) < 1.0e-6),
    ?assert(abs(Lry - 120.0) < 1.0e-6).

gdal_available() ->
    case velora_storage:scene_meta("/nonexistent") of
        {error, {gdalinfo_failed, {spawn_failed, _}}} -> false;
        _ -> true
    end.

roundtrip_test_() ->
    {timeout, 60, fun() ->
        case gdal_available() of
            false -> ?debugMsg("GDAL not available, skipping"), ok;
            true  -> do_roundtrip()
        end
    end}.

do_roundtrip() ->
    Dir = velora_worker_tests:tmp_dir(),
    Bin = << <<(float(V)):32/float-little>> || V <- lists:seq(1, 16) >>,
    Path = filename:join(Dir, "vstore.tif"),
    ok = velora_storage:write_tile(Path, Bin, 4, 4, "EPSG:4326",
                                   {0.0, 4.0, -4.0, 0.0}),
    {ok, M} = velora_storage:scene_meta(Path),
    ?assertEqual(4, maps:get(width, M)),
    ?assertEqual(4, maps:get(height, M)),
    ?assertEqual(<<"Float32">>, maps:get(dtype, M)),
    file:delete(Path).

work_uri_test() ->
    Dir = velora_config:work_dir(),
    ?assertEqual(filename:join(Dir, "a.tif"),
                 velora_storage:to_vsi(<<"work://a.tif">>)).

gdal_env_has_timeouts_test() ->
    Env = velora_storage:gdal_env(),
    Keys = [K || {K, _} <- Env],
    ?assert(lists:member("GDAL_HTTP_TIMEOUT", Keys)),
    ?assert(lists:member("GDAL_HTTP_CONNECTTIMEOUT", Keys)).
