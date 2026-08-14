-module(velora_coordinator_sup_tests).
-include_lib("eunit/include/eunit.hrl").

%% A coordinator crash must not take down the supervisor, and the supervisor
%% must keep starting new coordinators (temporary children, not restarted).
isolation_test() ->
    {ok, Sup} = velora_coordinator_sup:start_link(),
    try
        Arg = #{tiles => [#{x => 0, y => 0, w => 1, h => 1}],
                ctx => #{bins => 1},
                on_done => fun(_, _) -> ok end,
                on_fail => fun(_) -> ok end},
        {ok, C1} = velora_coordinator_sup:start_coordinator(Arg),
        ?assert(is_process_alive(C1)),

        %% kill it hard; the supervisor survives and does not restart it
        exit(C1, kill),
        timer:sleep(60),
        ?assert(is_process_alive(Sup)),
        ?assertNot(is_process_alive(C1)),

        %% new coordinators still start
        {ok, C2} = velora_coordinator_sup:start_coordinator(Arg),
        ?assert(is_process_alive(C2)),
        ?assertNotEqual(C1, C2)
    after
        unlink(Sup),
        exit(Sup, shutdown)
    end.
