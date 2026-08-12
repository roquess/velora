-module(velora_worker_tests).
-include_lib("eunit/include/eunit.hrl").
-compile([export_all, nowarn_export_all]).

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

with_scope(F) ->
    {ok, Pid} = pg:start_link(velora_jobs:scope()),
    try F() after gen_server:stop(Pid) end.

do_worker_ndvi() ->
    with_scope(fun() ->
        Dir = tmp_dir(),
        Scene = make_2band_u16(Dir, "wscene", 8, 8),
        OutBase = filename:join(Dir, "wout_" ++ integer_to_list(erlang:unique_integer([positive]))),
        filelib:ensure_dir(OutBase ++ "/x"),
        {ok, M} = velora_storage:scene_meta(Scene),
        Ctx = #{op => ndvi,
                out_base => OutBase,
                sources => [#{uri => list_to_binary(Scene), 'band' => 1},
                            #{uri => list_to_binary(Scene), 'band' => 2}],
                gt => maps:get(gt, M), srs => maps:get(srs, M), dtype => maps:get(dtype, M),
                range => {-1.0, 1.0}, bins => 64},
        Tiles = rast_tiling:tile_grid(8, 8, 4, 4),
        Parent = self(),
        {ok, _C} = velora_coordinator:start_link(
                    #{tiles => Tiles, ctx => Ctx,
                      on_done => fun(A, _Stats) -> Parent ! {done, length(A)} end}),
        {ok, _W} = velora_worker:start_link(),
        receive {done, N} -> ?assertEqual(length(Tiles), N)
        after 60000 -> ?assert(false) end,
        Files = filelib:wildcard(OutBase ++ "/tile_*.tif"),
        ?assertEqual(length(Tiles), length(Files)),
        {ok, MO} = velora_storage:scene_meta(hd(Files)),
        ?assertEqual(<<"Float32">>, maps:get(dtype, MO))
    end).

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

%% Portable temp dir: TMP (Windows), TMPDIR (POSIX), then /tmp.
tmp_dir() ->
    case os:getenv("TMP") of
        false ->
            case os:getenv("TMPDIR") of
                false -> "/tmp";
                D -> D
            end;
        D -> D
    end.

gdal(N) ->
    Ext = case os:type() of {win32,_} -> ".exe"; _ -> "" end,
    Full = N ++ Ext,
    case os:getenv("GDAL_BIN_DIR") of
        false ->
            case os:type() of
                {win32,_} -> "C:/Program Files/GDAL/" ++ Full;
                %% spawn_executable does not search PATH; resolve to a full path.
                _ -> case os:find_executable(Full) of false -> Full; P -> P end
            end;
        D -> filename:join(D, Full)
    end.

wait(P) -> receive {P,{data,_}} -> wait(P); {P,{exit_status,0}} -> ok;
                   {P,{exit_status,N}} -> {error,N} after 30000 -> {error,timeout} end.

%% A worker that cannot open its sources aborts the job rather than hanging.
worker_bad_source_test_() ->
    {timeout, 30, fun() ->
        velora_storage:ensure_gdal_env(),
        case gdal_available() of
            false -> ?debugMsg("GDAL not available, skipping"), ok;
            true  -> do_worker_bad_source()
        end
    end}.

do_worker_bad_source() ->
    with_scope(fun() ->
        Parent = self(),
        Ctx = #{op => ndvi, out_base => tmp_dir(),
                sources => [#{uri => <<"file:///no/such/scene.tif">>, 'band' => 1},
                            #{uri => <<"file:///no/such/scene.tif">>, 'band' => 2}],
                gt => {0.0,1.0,0.0,0.0,0.0,-1.0}, srs => "", dtype => <<"UInt16">>,
                range => {-1.0, 1.0}, bins => 64},
        Tiles = rast_tiling:tile_grid(8, 8, 4, 4),
        {ok, _C} = velora_coordinator:start_link(
                    #{tiles => Tiles, ctx => Ctx,
                      on_done => fun(_, _) -> Parent ! done end,
                      on_fail => fun(R) -> Parent ! {failed, R} end}),
        {ok, _W} = velora_worker:start_link(),
        receive
            {failed, R} -> ?assertMatch({setup_failed, _}, R);
            done        -> ?assert(false)
        after 20000 -> ?assert(false) end
    end).
