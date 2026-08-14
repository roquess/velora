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
    Dir = velora_worker_tests:tmp_dir(),
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
    ?assertEqual(<<"Float32">>, maps:get(dtype, M)),
    #{status := done, stats := Stats} = velora_job_manager:status(JobId),
    ?assert(is_map(Stats)),
    ?assert(abs(maps:get(mean, Stats) - (1.0/3.0)) < 1.0e-4),
    ?assert(maps:get(stddev, Stats) < 1.0e-4),
    ?assertEqual(12*12, maps:get(count, Stats)).

%% A coordinator crashing must not take down the job manager: the manager stays
%% up and responsive, and new jobs still run.
job_manager_survives_coordinator_crash_test_() ->
    {timeout, 90, fun() ->
        case gdal_available() of
            false -> ?debugMsg("GDAL not available, skipping"), ok;
            true  -> with_apps(fun do_coord_crash/0)
        end
    end}.

do_coord_crash() ->
    Dir = velora_worker_tests:tmp_dir(),
    Scene = velora_worker_tests:make_2band_u16(Dir, "jmcrash", 16, 16),
    Req = fun() ->
        Out = filename:join(Dir, "jmcrash_"
                ++ integer_to_list(erlang:unique_integer([positive])) ++ ".tif"),
        #{op => ndvi,
          sources => [#{uri => list_to_binary(Scene), 'band' => 1},
                      #{uri => list_to_binary(Scene), 'band' => 2}],
          out_uri => list_to_binary("file://" ++ Out),
          tile => {4, 4}}
    end,
    Mgr = whereis(velora_job_manager),
    {ok, _J1} = velora_job_manager:submit(Req()),
    case grab_coord(50) of
        undefined -> ok;                 %% job finished before we could catch it
        Coord     -> exit(Coord, kill)   %% crash the coordinator
    end,
    timer:sleep(300),
    %% the job manager is the SAME process, alive and responsive
    ?assertEqual(Mgr, whereis(velora_job_manager)),
    ?assert(is_process_alive(Mgr)),
    ?assert(is_list(velora_job_manager:list())),
    %% and a fresh job still completes end to end
    {ok, J2} = velora_job_manager:submit(Req()),
    ?assertEqual(ok, poll_done(J2, 60)).

grab_coord(0) -> undefined;
grab_coord(N) ->
    case velora_jobs:active() of
        [C | _] -> C;
        _       -> timer:sleep(20), grab_coord(N - 1)
    end.

poll_done(_JobId, 0) -> {error, timeout};
poll_done(JobId, N) ->
    case velora_job_manager:status(JobId) of
        #{status := done}  -> ok;
        #{status := error} = S -> {error, S};
        _ -> timer:sleep(1000), poll_done(JobId, N - 1)
    end.

evict_expired_test() ->
    Now = 1000000,
    Fresh   = velora_job_manager:test_job(<<"a">>, done, Now - 10),
    Stale   = velora_job_manager:test_job(<<"b">>, done, Now - 999999),
    Running = velora_job_manager:test_job(<<"c">>, running, undefined),
    Jobs = #{<<"a">> => Fresh, <<"b">> => Stale, <<"c">> => Running},
    {Kept, Dropped} = velora_job_manager:evict_expired(Jobs, Now, 1000),
    ?assertEqual([<<"b">>], lists:sort(Dropped)),
    ?assertEqual([<<"a">>, <<"c">>], lists:sort(maps:keys(Kept))).

result_path_test() ->
    Done   = velora_job_manager:test_job2(<<"d">>, done, "C:/no/such/out.tif"),
    Run    = velora_job_manager:test_job2(<<"r">>, running, "C:/x.tif"),
    Remote = velora_job_manager:test_job2(<<"m">>, done, "/vsis3/b/o.tif"),
    ?assertEqual({error, missing}, velora_job_manager:result_path_of(Done)),   %% path not on disk
    ?assertEqual({error, not_done}, velora_job_manager:result_path_of(Run)),
    ?assertEqual({error, remote},  velora_job_manager:result_path_of(Remote)).
