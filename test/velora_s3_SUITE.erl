%%% @doc End-to-end integration against object storage over GDAL /vsis3.
%%%
%%% Exercises the real production data plane: a scene is read from an S3 bucket,
%%% every tile is written back to S3, and the assembled COG is read from S3 again.
%%% Skips unless AWS_S3_ENDPOINT is set, so it is a no-op locally and runs in CI
%%% against a MinIO service container. Credentials/endpoint come from the
%%% environment (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_S3_ENDPOINT,
%%% AWS_VIRTUAL_HOSTING, AWS_HTTPS), which GDAL child processes inherit.
-module(velora_s3_SUITE).
-compile([export_all, nowarn_export_all]).
-include_lib("common_test/include/ct.hrl").

all() -> [ndvi_over_s3].

init_per_suite(Config) ->
    case os:getenv("AWS_S3_ENDPOINT") of
        false ->
            {skip, "no S3 endpoint (set AWS_S3_ENDPOINT to run against MinIO/S3)"};
        _ ->
            {ok, _} = application:ensure_all_started(velora),
            Config
    end.

end_per_suite(_) ->
    _ = application:stop(velora),
    ok.

ndvi_over_s3(_Config) ->
    Bucket  = case os:getenv("VELORA_S3_BUCKET") of false -> "velora-test"; B -> B end,
    Dir     = velora_worker_tests:tmp_dir(),
    Local   = velora_worker_tests:make_2band_u16(Dir, "s3scene", 16, 16),
    SceneS3 = "s3://" ++ Bucket ++ "/scene.tif",
    OutS3   = "s3://" ++ Bucket ++ "/out/ndvi.tif",

    %% --- vsis3 WRITE: upload the scene to the bucket ---
    ok = gdal_copy(Local, velora_storage:to_vsi(list_to_binary(SceneS3))),

    %% --- vsis3 READ + WRITE: NDVI job reads the scene and writes tiles + COG
    %%     straight to object storage ---
    {ok, Job} = velora_job_manager:submit(
                  #{op => ndvi,
                    sources => [#{uri => list_to_binary(SceneS3), 'band' => 1},
                                #{uri => list_to_binary(SceneS3), 'band' => 2}],
                    out_uri => list_to_binary(OutS3),
                    tile => {8, 8}}),
    St = poll(Job, 120),
    done = maps:get(status, St),
    Stats = maps:get(stats, St),
    256 = maps:get(count, Stats),                    %% 16x16 pixels, all present

    %% --- vsis3 READ: the assembled COG is back in the bucket and valid ---
    {ok, M} = velora_storage:scene_meta(velora_storage:to_vsi(list_to_binary(OutS3))),
    16 = maps:get(width, M),
    16 = maps:get(height, M),
    <<"Float32">> = maps:get(dtype, M),
    ok.

%% Copy a local raster to a /vsis3 destination via gdal_translate (inherits the
%% AWS_* env of the emulator, so credentials/endpoint reach GDAL).
gdal_copy(Src, DstVsi) ->
    Exe = filename:nativename(velora_worker_tests:gdal("gdal_translate")),
    P = open_port({spawn_executable, Exe},
                  [{args, ["-of", "GTiff", Src, DstVsi]},
                   binary, exit_status, stderr_to_stdout, in]),
    case wait(P, <<>>) of
        {ok, _} -> ok;
        {error, N, Out} ->
            ct:pal("gdal_translate -> /vsis3 failed (~p):~n~ts", [N, Out]),
            {error, {gdal_translate, N}}
    end.

wait(P, Acc) ->
    receive
        {P, {data, D}}         -> wait(P, <<Acc/binary, D/binary>>);
        {P, {exit_status, 0}}  -> {ok, Acc};
        {P, {exit_status, N}}  -> {error, N, Acc}
    after 60000 -> {error, timeout, Acc} end.

poll(_Job, 0) -> #{status => timeout};
poll(Job, N) ->
    case velora_job_manager:status(Job) of
        #{status := done}  = M -> M;
        #{status := error} = M -> ct:fail({job_error, maps:get(error, M)});
        _ -> timer:sleep(500), poll(Job, N - 1)
    end.
