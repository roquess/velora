-module(velora_api_tests).
-include_lib("eunit/include/eunit.hrl").

gdal_available() ->
    case velora_storage:scene_meta("/nonexistent") of
        {error, {gdalinfo_failed, {spawn_failed, _}}} -> false; _ -> true
    end.

api_health_test() ->
    {ok, _} = application:ensure_all_started(velora),
    try
        Port = velora_config:http_port(),
        {ok, {{_,200,_}, _, _}} =
            httpc:request(get, {url(Port, "/health"), []}, [], [])
    after application:stop(velora) end.

api_submit_test_() ->
    {timeout, 120, fun() ->
        case gdal_available() of false -> ok; true -> do_api_submit() end
    end}.

do_api_submit() ->
    {ok, _} = application:ensure_all_started(velora),
    try
        Port = velora_config:http_port(),
        Dir = os:getenv("TMP"),
        Scene = velora_worker_tests:make_2band_u16(Dir, "apiscene", 8, 8),
        Out = filename:join(Dir, "api_out_" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".tif"),
        Body = jsx:encode(#{op => <<"ndvi">>,
            sources => [#{uri => list_to_binary(Scene), <<"band">> => 1},
                        #{uri => list_to_binary(Scene), <<"band">> => 2}],
            out_uri => list_to_binary("file://" ++ Out),
            tile => [4,4]}),
        {ok, {{_,202,_}, _, RB}} = httpc:request(post,
            {url(Port,"/jobs"), [], "application/json", Body}, [], []),
        #{<<"job_id">> := JobId} = jsx:decode(list_to_binary(RB), [return_maps]),
        ok = poll(Port, JobId, 60),
        ?assert(filelib:is_regular(Out)),
        {ok, {{_,200,_},_,SB}} = httpc:request(get, {url(Port,"/jobs/"++binary_to_list(JobId)), []}, [], []),
        #{<<"stats">> := S} = jsx:decode(list_to_binary(SB), [return_maps]),
        ?assert(is_map(S)),
        ?assert(abs(maps:get(<<"mean">>, S) - (1.0/3.0)) < 1.0e-4),
        #{<<"histogram">> := #{<<"bins">> := 64}} = S,
        SBody = jsx:encode(#{tile => <<"0_0">>, k => 4}),
        {ok, {{_,200,_},_,RB2}} = httpc:request(post,
            {url(Port,"/jobs/"++binary_to_list(JobId)++"/search"), [], "application/json", SBody}, [], []),
        #{<<"results">> := Results} = jsx:decode(list_to_binary(RB2), [return_maps]),
        ?assert(is_list(Results)),
        ?assert(length(Results) >= 1),
        #{<<"score">> := TopScore} = hd(Results),
        ?assert(abs(TopScore - 1.0) < 1.0e-4)
    after application:stop(velora) end.

poll(_P,_J,0) -> {error,timeout};
poll(P,J,N) ->
    {ok, {{_,200,_},_,B}} = httpc:request(get, {url(P,"/jobs/"++binary_to_list(J)), []}, [], []),
    case jsx:decode(list_to_binary(B), [return_maps]) of
        #{<<"status">> := <<"done">>} -> ok;
        #{<<"status">> := <<"error">>} = S -> {error, S};
        _ -> timer:sleep(1000), poll(P,J,N-1)
    end.

url(Port, Path) -> "http://127.0.0.1:" ++ integer_to_list(Port) ++ Path.
