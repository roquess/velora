-module(velora_agent_tests).
-include_lib("eunit/include/eunit.hrl").

tiles_card_test() ->
    Card = velora_agent:tiles_card(<<"42">>, [[1.0,2.0],[3.0,4.0]], 7),
    ?assertMatch(#{type := <<"raster">>, id := <<"42">>,
                   tiles := <<"/tiles/42/{z}/{x}/{y}">>,
                   maxNativeZoom := 7}, Card).

info_card_test() ->
    Card = velora_agent:info_card(#{size => [16,16], bands => 2,
                                    crs => <<"x">>, driver => <<"GTiff">>}),
    ?assertMatch(#{type := <<"info">>, bands := 2}, Card).

empty_test() ->
    ?assertEqual([], velora_agent:handle(#{intent => tiles, query => <<>>})).

tiles_local_test_() ->
    {timeout, 60, fun() ->
        case gdal() of
            false -> ok;
            true ->
                velora_storage:ensure_gdal_env(),
                Dir = velora_worker_tests:tmp_dir(),
                Scene = velora_worker_tests:make_2band_u16(Dir, "agentscene", 16, 16),
                Cards = velora_agent:handle(#{intent => tiles,
                                              query => list_to_binary("file://" ++ Scene)}),
                ?assertMatch([#{type := <<"raster">>, tiles := _} | _], Cards)
        end
    end}.

gdal() ->
    case velora_storage:scene_meta("/nonexistent") of
        {error, {gdalinfo_failed, {spawn_failed, _}}} -> false; _ -> true
    end.
