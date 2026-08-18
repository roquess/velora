-module(velora_ndvi_tests).
-include_lib("eunit/include/eunit.hrl").

gdal() ->
    case velora_storage:scene_meta("/nonexistent") of
        {error, {gdalinfo_failed, {spawn_failed, _}}} -> false; _ -> true
    end.

fullres_test_() ->
    {timeout, 180, fun() ->
        case gdal() of
            false -> ok;
            true  -> do_fullres()
        end
    end}.

do_fullres() ->
    {ok, _} = application:ensure_all_started(velora),
    application:set_env(velora, allowed_schemes, [file, work, https, s3, gs, asset]),
    try
        Dir = velora_worker_tests:tmp_dir(),
        Scene = velora_worker_tests:make_2band_u16(Dir, "ndvijob", 16, 16),
        U = list_to_binary(Scene),
        QAgent = list_to_binary("file://" ++ Scene),

        %% 1. agent ndvi intent returns an async "processing" card + preview
        [Card] = velora_agent:handle(#{intent => ndvi, query => QAgent}),
        ?assertEqual(<<"ndvi">>, maps:get(type, Card)),
        ?assertEqual(<<"processing">>, maps:get(status, Card)),
        ?assert(is_binary(maps:get(job, Card))),
        ?assert(maps:is_key(result_tiles, Card)),
        ?assert(maps:is_key(preview, Card)),

        %% 2. direct submit -> wait done -> result served as a mercator PNG tile
        {ok, JobId} = velora_ndvi:submit({single, U, 1, 2}),
        ok = wait_done(JobId),
        {ok, Path} = velora_job_manager:result_path(JobId),
        Uri = <<"work://", (list_to_binary(filename:basename(Path)))/binary>>,
        {ok, _PrepId, [[S, W], [N, E]], _NZ} = velora_render:prepare(Uri),
        {X, Y} = lonlat_to_xy((W + E) / 2, (S + N) / 2, 4),
        ?assertMatch({ok, <<137, 80, 78, 71, _/binary>>},
                     velora_ndvi:result_tile(JobId, 4, X, Y))
    after
        application:set_env(velora, allowed_schemes, undefined),
        application:stop(velora)
    end.

wait_done(JobId) ->
    R = velora_test_util:wait_until(fun() ->
        case velora_job_manager:status(JobId) of
            #{status := done}  -> true;
            #{status := error} -> throw(job_error);
            _ -> false
        end
    end, 120000),
    case R of
        true -> ok;
        ok   -> ok;
        Other -> throw({not_done, Other})
    end.

lonlat_to_xy(Lon, Lat, Z) ->
    N = math:pow(2, Z),
    X = trunc((Lon + 180.0) / 360.0 * N),
    LatR = Lat * math:pi() / 180.0,
    Y = trunc((1.0 - math:log(math:tan(LatR) + 1.0 / math:cos(LatR)) / math:pi()) / 2.0 * N),
    {X, Y}.
