-module(velora_stac_tests).
-include_lib("eunit/include/eunit.hrl").

parse_assets_test() ->
    Body = #{<<"features">> => [
        #{<<"assets">> => #{
            <<"visual">> => #{<<"href">> => <<"https://s/vis.tif">>},
            <<"red">>    => #{<<"href">> => <<"https://s/b04.tif">>},
            <<"nir">>    => #{<<"href">> => <<"https://s/b08.tif">>}}}]},
    Keys = #{visual => <<"visual">>, red => <<"red">>, nir => <<"nir">>},
    ?assertEqual({ok, #{visual => <<"https://s/vis.tif">>,
                        red    => <<"https://s/b04.tif">>,
                        nir    => <<"https://s/b08.tif">>}},
                 velora_stac:parse_assets(Body, Keys)).

parse_assets_empty_test() ->
    Keys = #{visual => <<"visual">>, red => <<"red">>, nir => <<"nir">>},
    ?assertEqual({error, no_scene},
                 velora_stac:parse_assets(#{<<"features">> => []}, Keys)).
