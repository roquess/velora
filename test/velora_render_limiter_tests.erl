-module(velora_render_limiter_tests).
-include_lib("eunit/include/eunit.hrl").

setup()    -> application:set_env(velora, max_concurrent_renders, 2),
              application:set_env(velora, render_queue_timeout_ms, 300),
              {ok, P} = velora_render_limiter:start_link(), P.
cleanup(P) -> gen_server:stop(P),
              application:unset_env(velora, max_concurrent_renders),
              application:unset_env(velora, render_queue_timeout_ms).

runs_fun_test_()   -> {setup, fun setup/0, fun cleanup/1,
    fun(_) -> ?_assertEqual(42, velora_render_limiter:with_slot(fun() -> 42 end)) end}.

sheds_when_full_test_() -> {setup, fun setup/0, fun cleanup/1, fun(_) ->
    Parent = self(),
    %% occupy both slots with blockers
    Hold = fun() -> spawn(fun() ->
                 velora_render_limiter:with_slot(fun() -> Parent ! ready, receive stop -> ok end end)
             end) end,
    _ = Hold(), _ = Hold(),
    receive ready -> ok end, receive ready -> ok end,
    %% third caller cannot get a slot within the 300ms queue timeout
    ?_assertEqual({error, overloaded},
                  velora_render_limiter:with_slot(fun() -> 1 end))
    end}.

frees_on_holder_death_test_() -> {setup, fun setup/0, fun cleanup/1, fun(_) ->
    Parent = self(),
    Pid = spawn(fun() -> velora_render_limiter:with_slot(
             fun() -> Parent ! in, receive never -> ok end end) end),
    receive in -> ok end,
    exit(Pid, kill),                 %% holder dies mid-slot
    timer:sleep(50),
    %% slot must have been reclaimed
    ?_assertEqual(ok, velora_render_limiter:with_slot(fun() -> ok end))
    end}.

%% ---- "not started" fallback: unit suites that call velora_web:prepare/1
%% directly (without the supervised app running) must still work ----

not_started_fallback_test() ->
    ?assertEqual(undefined, whereis(velora_render_limiter)),
    ?assertEqual(99, velora_render_limiter:with_slot(fun() -> 99 end)).
