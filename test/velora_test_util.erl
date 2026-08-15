%%% @doc Shared eunit test helpers. `wait_until/2,3' polls a condition until it
%%% is truthy or a timeout elapses, so tests can synchronize on the real async
%%% state transition instead of sleeping a fixed, arbitrary delay.
-module(velora_test_util).
-export([wait_until/2, wait_until/3]).

%% @doc Poll `Fun/0' every 20ms until it returns a truthy value (anything other
%% than `false') or `TimeoutMs' elapses; returns the truthy value. Raises
%% `{wait_until_timeout, LastValue}' on timeout so a stuck condition fails the
%% test loudly instead of silently proceeding.
-spec wait_until(fun(() -> term()), non_neg_integer()) -> term().
wait_until(Fun, TimeoutMs) -> wait_until(Fun, TimeoutMs, 20).

-spec wait_until(fun(() -> term()), non_neg_integer(), pos_integer()) -> term().
wait_until(Fun, TimeoutMs, IntervalMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    poll(Fun, Deadline, IntervalMs).

poll(Fun, Deadline, IntervalMs) ->
    case Fun() of
        false -> retry_or_fail(Fun, Deadline, IntervalMs);
        Value -> Value
    end.

retry_or_fail(Fun, Deadline, IntervalMs) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true  -> erlang:error({wait_until_timeout, Fun()});
        false -> timer:sleep(IntervalMs), poll(Fun, Deadline, IntervalMs)
    end.
