-module(velora_discovery_tests).
-include_lib("eunit/include/eunit.hrl").

static_targets_test() ->
    application:set_env(velora, peers, ['a@h', 'b@h']),
    ?assertEqual(['a@h', 'b@h'], velora_discovery:targets({static})).

static_empty_reconcile_test() ->
    application:set_env(velora, peers, []),
    ?assertEqual([], velora_discovery:reconcile({static})).

dns_targets_shape_test() ->
    ?assertEqual([], velora_discovery:targets({dns, "no.such.host.invalid", "velora"})).
