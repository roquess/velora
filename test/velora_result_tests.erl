-module(velora_result_tests).
-include_lib("eunit/include/eunit.hrl").

range_test() ->
    ?assertEqual({ok, 0, 100},  velora_result_h:parse_range(<<"bytes=0-99">>, 1000)),
    ?assertEqual({ok, 990, 10}, velora_result_h:parse_range(<<"bytes=990-">>, 1000)),
    ?assertEqual({ok, 900, 100},velora_result_h:parse_range(<<"bytes=-100">>, 1000)),
    ?assertEqual(error,         velora_result_h:parse_range(<<"weird">>, 1000)).
