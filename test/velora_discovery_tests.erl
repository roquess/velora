-module(velora_discovery_tests).
-include_lib("eunit/include/eunit.hrl").

%% em_pop peer maps -> Base@host Erlang node names (deduped, sorted).
empop_targets_test() ->
    Peers = [#{host => <<"192.168.1.94">>, port => 9100},
             #{host => <<"192.168.1.50">>, port => 9100},
             #{host => <<"192.168.1.94">>, port => 9101}],   %% same host, other port
    ?assertEqual(['velora@192.168.1.50', 'velora@192.168.1.94'],
                 velora_discovery:empop_targets("velora", Peers)),
    ?assertEqual([], velora_discovery:empop_targets("velora", [])).

empop_targets_custom_base_test() ->
    ?assertEqual(['node@h1'],
                 velora_discovery:empop_targets("node", [#{host => <<"h1">>, port => 9100}])).
