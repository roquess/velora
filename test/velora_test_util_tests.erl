-module(velora_test_util_tests).
-include_lib("eunit/include/eunit.hrl").

returns_early_on_success_test() ->
    Ref = erlang:make_ref(),
    Counter = counter_start(3),
    Result = velora_test_util:wait_until(
        fun() -> case counter_tick(Counter) of true -> Ref; false -> false end end,
        1000, 5),
    ?assertEqual(Ref, Result).

errors_on_timeout_test() ->
    ?assertError({wait_until_timeout, false},
                 velora_test_util:wait_until(fun() -> false end, 50, 10)).

%% A tiny process-based counter: the Nth call (and every call after) returns
%% true, earlier calls return false -- simulates a condition that becomes true
%% after a few polls.
counter_start(N) -> spawn(fun() -> counter_loop(N) end).

counter_tick(Pid) ->
    Pid ! {tick, self()},
    receive {tock, R} -> R end.

counter_loop(N) ->
    receive
        {tick, From} when N =< 1 -> From ! {tock, true}, counter_loop(0);
        {tick, From} -> From ! {tock, false}, counter_loop(N - 1)
    end.
