-module(velora_worker_tests).
-include_lib("eunit/include/eunit.hrl").

gdal_available() ->
    case velora_storage:scene_meta("/nonexistent") of
        {error, {gdalinfo_failed, {spawn_failed, _}}} -> false;
        _ -> true
    end.

worker_ndvi_test_() ->
    {timeout, 90, fun() ->
        velora_storage:ensure_gdal_env(),
        case gdal_available() of
            false -> ?debugMsg("GDAL not available, skipping"), ok;
            true  -> do_worker_ndvi()
        end
    end}.

do_worker_ndvi() ->
    Dir = os:getenv("TMP"),
    Scene = make_2band_u16(Dir, "wscene", 8, 8),
    OutBase = filename:join(Dir, "wout_" ++ integer_to_list(erlang:unique_integer([positive]))),
    filelib:ensure_dir(OutBase ++ "/x"),
    {ok, M} = velora_storage:scene_meta(Scene),
    Ctx = #{op => ndvi,
            out_base => OutBase,
            sources => [#{uri => list_to_binary(Scene), 'band' => 1},
                        #{uri => list_to_binary(Scene), 'band' => 2}],
            gt => maps:get(gt, M), srs => maps:get(srs, M), dtype => maps:get(dtype, M)},
    Tiles = rast_tiling:tile_grid(8, 8, 4, 4),
    Parent = self(),
    {ok, C} = velora_coordinator:start_link(
                #{tiles => Tiles, ctx => Ctx,
                  on_done => fun(A) -> Parent ! {done, length(A)} end}),
    {ok, _W} = velora_worker:start_link(C),
    receive {done, N} -> ?assertEqual(length(Tiles), N)
    after 60000 -> ?assert(false) end,
    Files = filelib:wildcard(OutBase ++ "/tile_*.tif"),
    ?assertEqual(length(Tiles), length(Files)),
    {ok, MO} = velora_storage:scene_meta(hd(Files)),
    ?assertEqual(<<"Float32">>, maps:get(dtype, MO)).

%% 2-band UInt16 GeoTIFF, band1 = 200 (NIR), band2 = 100 (Red), constants.
make_2band_u16(Dir, Name, W, H) ->
    Raw = filename:join(Dir, Name ++ ".raw"),
    Hdr = filename:join(Dir, Name ++ ".hdr"),
    Tif = filename:join(Dir, Name ++ ".tif"),
    Nir = << <<200:16/unsigned-little>> || _ <- lists:seq(1, W*H) >>,
    Red = << <<100:16/unsigned-little>> || _ <- lists:seq(1, W*H) >>,
    ok = file:write_file(Raw, <<Nir/binary, Red/binary>>),
    ok = file:write_file(Hdr,
        io_lib:format("ENVI~nsamples = ~w~nlines = ~w~nbands = 2~nheader offset = 0~n"
                      "data type = 12~ninterleave = bsq~nbyte order = 0~n", [W, H])),
    Exe = filename:nativename(gdal("gdal_translate")),
    P = open_port({spawn_executable, Exe},
                  [{args, ["-q", "-a_srs", "EPSG:4326", "-a_ullr", "0", "8", "8", "0",
                           "-of", "GTiff", Raw, Tif]}, binary, exit_status, in]),
    ok = wait(P),
    Tif.

gdal(N) ->
    Ext = case os:type() of {win32,_} -> ".exe"; _ -> "" end,
    case os:getenv("GDAL_BIN_DIR") of
        false -> case os:type() of {win32,_} -> "C:/Program Files/GDAL/" ++ N ++ Ext; _ -> N end;
        D -> filename:join(D, N ++ Ext)
    end.

wait(P) -> receive {P,{data,_}} -> wait(P); {P,{exit_status,0}} -> ok;
                   {P,{exit_status,N}} -> {error,N} after 30000 -> {error,timeout} end.
