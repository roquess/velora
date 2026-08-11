-module(velora_cluster_tests).
-include_lib("eunit/include/eunit.hrl").

members_includes_self_test() ->
    Members = velora_cluster:members(),
    ?assert(lists:member(node(), Members)).

connect_empty_test() ->
    application:set_env(velora, peers, []),
    ?assertEqual([], velora_cluster:connect()).
