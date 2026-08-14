-module(velora_render_tests).
-include_lib("eunit/include/eunit.hrl").

choose_node_test() ->
    ?assertEqual(node(), velora_render:choose_node([])),
    ?assert(lists:member(velora_render:choose_node(['a@h', 'b@h']), ['a@h', 'b@h'])).

registry_test() ->
    {ok, Pid} = velora_render_registry:start_link(),
    try
        ?assertEqual(node(), velora_render_registry:get(<<"unknown">>)),   %% default self
        ok = velora_render_registry:put(<<"x">>, 'peer@h'),
        ?assertEqual('peer@h', velora_render_registry:get(<<"x">>))
    after gen_server:stop(Pid) end.

%% With no peers everything runs locally; prepare records the local node and the
%% tile is cut locally.
prepare_tile_local_test_() ->
    {timeout, 60, fun() ->
        case gdal_available() of
            false -> ?debugMsg("GDAL not available, skipping"), ok;
            true  -> do_local()
        end
    end}.

do_local() ->
    {ok, Reg} = velora_render_registry:start_link(),
    application:set_env(velora, render_offload, self),
    try
        velora_storage:ensure_gdal_env(),
        Dir = velora_worker_tests:tmp_dir(),
        Scene = velora_worker_tests:make_2band_u16(Dir, "renderscene", 16, 16),
        {ok, Id, [[S, W], [N, E]], _} = velora_render:prepare(list_to_binary(Scene)),
        ?assertEqual(node(), velora_render_registry:get(Id)),
        {X, Y} = lonlat_to_xy((W + E) / 2, (S + N) / 2, 4),
        ?assertMatch({ok, <<137, 80, 78, 71, _/binary>>}, velora_render:tile(Id, 4, X, Y))
    after
        application:unset_env(velora, render_offload),
        gen_server:stop(Reg)
    end.

gdal_available() ->
    case velora_storage:scene_meta("/nonexistent") of
        {error, {gdalinfo_failed, {spawn_failed, _}}} -> false; _ -> true
    end.

lonlat_to_xy(Lon, Lat, Z) ->
    N = math:pow(2, Z),
    X = trunc((Lon + 180.0) / 360.0 * N),
    LatR = Lat * math:pi() / 180.0,
    Y = trunc((1.0 - math:log(math:tan(LatR) + 1.0 / math:cos(LatR)) / math:pi()) / 2.0 * N),
    {X, Y}.
