-module(velora_query_tests).
-include_lib("eunit/include/eunit.hrl").

classify_uri_test() ->
    ?assertEqual({raster_uri, <<"https://x/y.tif">>},
                 velora_query:classify(<<"https://x/y.tif">>)),
    ?assertEqual({raster_uri, <<"s3://bucket/scene.tif">>},
                 velora_query:classify(<<"s3://bucket/scene.tif">>)).

classify_place_test() ->
    ?assertEqual({place, <<"chernobyl">>}, velora_query:classify(<<"chernobyl">>)),
    ?assertEqual({place, <<"mont blanc">>}, velora_query:classify(<<"  mont blanc  ">>)).

classify_unknown_test() ->
    ?assertEqual(unknown, velora_query:classify(<<>>)),
    ?assertEqual(unknown, velora_query:classify(<<"   ">>)).
