-module(velora_config_tests).
-include_lib("eunit/include/eunit.hrl").

defaults_test() ->
    application:unset_env(velora, tile),
    ?assertEqual({512, 512}, velora_config:tile()),
    ?assert(is_integer(velora_config:workers_per_node())),
    ?assert(velora_config:workers_per_node() >= 1).

override_test() ->
    application:set_env(velora, tile, {256, 256}),
    ?assertEqual({256, 256}, velora_config:tile()),
    application:set_env(velora, workers_per_node, 3),
    ?assertEqual(3, velora_config:workers_per_node()),
    application:unset_env(velora, workers_per_node).

peers_test() ->
    application:set_env(velora, peers, ['a@host', 'b@host']),
    ?assertEqual(['a@host', 'b@host'], velora_config:peers()).
