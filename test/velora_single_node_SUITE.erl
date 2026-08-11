-module(velora_single_node_SUITE).
-compile(export_all).
-compile(nowarn_export_all).
-include_lib("common_test/include/ct.hrl").

all() -> [ndvi_end_to_end].

init_per_suite(Config) ->
    Gdal = case velora_storage:scene_meta("/nonexistent") of
               {error, {gdalinfo_failed, {spawn_failed, _}}} -> false; _ -> true
           end,
    [{gdal, Gdal} | Config].
end_per_suite(_) -> ok.

init_per_testcase(_TC, Config) ->
    case ?config(gdal, Config) of
        false -> {skip, "GDAL not available"};
        true  -> {ok, _} = application:ensure_all_started(velora), Config
    end.
end_per_testcase(_TC, _Config) -> application:stop(velora).

ndvi_end_to_end(Config) ->
    Dir = ?config(priv_dir, Config),
    Scene = velora_worker_tests:make_2band_u16(Dir, "sn_scene", 16, 16),
    Out = filename:join(Dir, "sn_ndvi.tif"),
    {ok, Id} = velora_job_manager:submit(
        #{op => ndvi,
          sources => [#{uri => list_to_binary(Scene), 'band' => 1},
                      #{uri => list_to_binary(Scene), 'band' => 2}],
          out_uri => list_to_binary("file://" ++ Out),
          tile => {4, 4}}),
    ok = poll(Id, 60),
    true = filelib:is_regular(Out),
    {ok, M} = velora_storage:scene_meta(Out),
    16 = maps:get(width, M),
    <<"Float32">> = maps:get(dtype, M).

poll(_Id, 0) -> {error, timeout};
poll(Id, N) ->
    case velora_job_manager:status(Id) of
        #{status := done} -> ok;
        #{status := error} = S -> S;
        _ -> timer:sleep(1000), poll(Id, N-1)
    end.
