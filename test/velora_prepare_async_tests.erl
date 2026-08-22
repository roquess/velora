-module(velora_prepare_async_tests).
-include_lib("eunit/include/eunit.hrl").

unknown_id_test() ->
    {ok, Pid} = velora_prepare_async:start_link(),
    try
        ?assertEqual(not_found, velora_prepare_async:status(<<"nope">>))
    after gen_server:stop(Pid) end.

%% submit a local fixture, poll until the background warp is done
submit_poll_test_() ->
    {timeout, 60, fun() ->
        case gdal() of
            false -> ok;
            true  -> do_submit_poll()
        end
    end}.

do_submit_poll() ->
    {ok, Reg} = velora_render_registry:start_link(),
    {ok, Pa}  = velora_prepare_async:start_link(),
    application:set_env(velora, allowed_schemes, [file, https, s3, gs, work]),
    try
        velora_storage:ensure_gdal_env(),
        Dir = velora_worker_tests:tmp_dir(),
        Scene = velora_worker_tests:make_2band_u16(Dir, "prepasync", 16, 16),
        {ok, Id} = velora_prepare_async:submit(list_to_binary("file://" ++ Scene)),
        ?assertEqual(processing, velora_prepare_async:status(Id)),  %% not instant
        velora_test_util:wait_until(
            fun() -> velora_prepare_async:status(Id) =/= processing end, 30000),
        ?assertMatch({ok, _PId, [[_, _], [_, _]], _NZ}, velora_prepare_async:status(Id))
    after
        application:unset_env(velora, allowed_schemes),
        gen_server:stop(Pa), gen_server:stop(Reg)
    end.

%% A prepare that fails (here: a disallowed scheme, rejected before any GDAL
%% call) must reach a terminal {error,_} state — never stay stuck `processing'.
%% This guards the worker-lifecycle contract the /prepare poll depends on.
submit_error_terminal_test() ->
    {ok, Reg} = velora_render_registry:start_link(),
    {ok, Pa}  = velora_prepare_async:start_link(),
    application:set_env(velora, allowed_schemes, [https, s3, gs, work, asset]),
    try
        {ok, Id} = velora_prepare_async:submit(<<"file:///etc/passwd">>),
        velora_test_util:wait_until(
            fun() -> velora_prepare_async:status(Id) =/= processing end, 10000),
        ?assertMatch({error, _}, velora_prepare_async:status(Id))
    after
        application:unset_env(velora, allowed_schemes),
        gen_server:stop(Pa), gen_server:stop(Reg)
    end.

gdal() ->
    case velora_storage:scene_meta("/nonexistent") of
        {error, {gdalinfo_failed, {spawn_failed, _}}} -> false; _ -> true
    end.
