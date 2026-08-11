-module(velora_jobs_tests).
-include_lib("eunit/include/eunit.hrl").

with_scope(F) ->
    {ok, Pid} = pg:start_link(velora_jobs:scope()),
    try F() after gen_server:stop(Pid) end.

register_active_unregister_test() ->
    with_scope(fun() ->
        Self = self(),
        ?assertEqual([], velora_jobs:active()),
        ok = velora_jobs:register(Self),
        ?assert(lists:member(Self, velora_jobs:active())),
        ok = velora_jobs:unregister(Self),
        ?assertEqual([], velora_jobs:active())
    end).

dead_member_auto_removed_test() ->
    with_scope(fun() ->
        P = spawn(fun() -> receive stop -> ok end end),
        ok = velora_jobs:register(P),
        ?assert(lists:member(P, velora_jobs:active())),
        P ! stop,
        timer:sleep(50),
        ?assertNot(lists:member(P, velora_jobs:active()))
    end).

no_scope_is_noop_test() ->
    ?assertEqual(ok, velora_jobs:register(self())),
    ?assertEqual([], velora_jobs:active()),
    ?assertEqual(ok, velora_jobs:unregister(self())).
