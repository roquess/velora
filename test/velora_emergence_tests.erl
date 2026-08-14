-module(velora_emergence_tests).
-include_lib("eunit/include/eunit.hrl").

%% Disabled by default: velora runs standalone, no mesh node.
disabled_by_default_test() ->
    application:unset_env(velora, emergence),
    {ok, _} = application:ensure_all_started(velora),
    try
        ?assertNot(velora_emergence:enabled()),
        ?assertEqual(undefined, velora_emergence:node()),
        ?assertEqual([], velora_emergence:peers())
    after application:stop(velora) end.

%% Enabled: an em_pop mesh node starts and advertises velora's capabilities.
enabled_starts_node_test_() ->
    {timeout, 30, fun() ->
        application:set_env(velora, emergence,
            #{enabled => true, port => 9199, seed => []}),
        {ok, _} = application:ensure_all_started(velora),
        try
            ?assert(velora_emergence:enabled()),
            ?assert(is_pid(velora_emergence:node())),
            ?assert(is_list(velora_emergence:peers()))
        after
            application:stop(velora),
            application:unset_env(velora, emergence)
        end
    end}.
