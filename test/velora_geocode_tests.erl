-module(velora_geocode_tests).
-include_lib("eunit/include/eunit.hrl").

parse_with_bbox_test() ->
    Results = [#{<<"lat">> => <<"48.85">>, <<"lon">> => <<"2.35">>,
                 <<"bbox">> => [2.2, 48.8, 2.5, 48.9]}],
    ?assertEqual({ok, #{lat => 48.85, lon => 2.35,
                        bbox => [2.2, 48.8, 2.5, 48.9]}},
                 velora_geocode:parse_result(Results, 0.05)).

parse_without_bbox_test() ->
    Results = [#{<<"lat">> => 10.0, <<"lon">> => 20.0}],
    {ok, #{bbox := [MinX, MinY, MaxX, MaxY]}} =
        velora_geocode:parse_result(Results, 0.5),
    ?assertEqual({19.5, 9.5, 20.5, 10.5}, {MinX, MinY, MaxX, MaxY}).

parse_empty_test() ->
    ?assertEqual({error, not_found}, velora_geocode:parse_result([], 0.05)).

parse_nominatim_test() ->
    R = [#{<<"lat">> => <<"48.85">>, <<"lon">> => <<"2.35">>,
           <<"boundingbox">> => [<<"48.8">>, <<"48.9">>, <<"2.2">>, <<"2.5">>]}],
    ?assertEqual({ok, #{lat => 48.85, lon => 2.35, bbox => [2.2, 48.8, 2.5, 48.9]}},
                 velora_geocode:parse_nominatim(R, 0.05)).

parse_nominatim_no_bbox_test() ->
    R = [#{<<"lat">> => <<"10.0">>, <<"lon">> => <<"20.0">>}],
    {ok, #{bbox := [MinX, MinY, MaxX, MaxY]}} = velora_geocode:parse_nominatim(R, 0.5),
    ?assertEqual({19.5, 9.5, 20.5, 10.5}, {MinX, MinY, MaxX, MaxY}).

parse_nominatim_empty_test() ->
    ?assertEqual({error, not_found}, velora_geocode:parse_nominatim([], 0.05)).
