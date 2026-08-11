-module(velora_job_manager_tests).
-include_lib("eunit/include/eunit.hrl").

gdal_available() ->
    case velora_storage:scene_meta("/nonexistent") of
        {error, {gdalinfo_failed, {spawn_failed, _}}} -> false;
        _ -> true
    end.

submit_ndvi_test_() ->
    {timeout, 120, fun() ->
        case gdal_available() of
            false -> ?debugMsg("GDAL not available, skipping"), ok;
            true  -> with_apps(fun do_submit/0)
        end
    end}.

with_apps(F) ->
    {ok, _} = application:ensure_all_started(velora),
    try F() after application:stop(velora) end.

do_submit() ->
    Dir = os:getenv("TMP"),
    Scene = velora_worker_tests:make_2band_u16(Dir, "jmscene", 12, 12),
    Out = filename:join(Dir, "jm_ndvi_" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".tif"),
    Req = #{op => ndvi,
            sources => [#{uri => list_to_binary(Scene), 'band' => 1},
                        #{uri => list_to_binary(Scene), 'band' => 2}],
            out_uri => list_to_binary("file://" ++ Out),
            tile => {4, 4}},
    {ok, JobId} = velora_job_manager:submit(Req),
    ok = poll_done(JobId, 60),
    ?assert(filelib:is_regular(Out)),
    {ok, M} = velora_storage:scene_meta(Out),
    ?assertEqual(12, maps:get(width, M)),
    ?assertEqual(<<"Float32">>, maps:get(dtype, M)).

poll_done(_JobId, 0) -> {error, timeout};
poll_done(JobId, N) ->
    case velora_job_manager:status(JobId) of
        #{status := done}  -> ok;
        #{status := error} = S -> {error, S};
        _ -> timer:sleep(1000), poll_done(JobId, N - 1)
    end.
