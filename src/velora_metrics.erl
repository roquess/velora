%%% @doc Operational metrics for velora, gathered on demand for `GET /metrics'.
%%% Every section is guarded so collection never crashes, even if a subsystem is
%%% not running or the cache NIF is absent — missing data reports as zeros.
-module(velora_metrics).
-export([collect/0]).

-spec collect() -> map().
collect() ->
    #{jobs       => jobs(),
      tiles      => cache(fun velora_web:tiles_cache/0),
      prepare    => cache(fun velora_web:prepare_cache/0),
      render     => render(),
      uptime_ms  => element(1, erlang:statistics(wall_clock))}.

jobs() ->
    try
        Jobs  = velora_job_manager:list(),
        Count = fun(St) -> length([x || #{status := S} <- Jobs, S =:= St]) end,
        #{total => length(Jobs), running => Count(running),
          done => Count(done), error => Count(error)}
    catch _:_ ->
        #{total => 0, running => 0, done => 0, error => 0}
    end.

%% Ensure/probe a velora_web cache and report its stats, or zeros when the cache
%% NIF is unavailable.
cache(Ensure) ->
    try
        case Ensure() of
            {ok, Name} -> velora_cache:stats(Name);
            _          -> zero_stats()
        end
    catch _:_ ->
        zero_stats()
    end.

zero_stats() -> #{hits => 0, misses => 0, len => 0, capacity => 0}.

render() ->
    #{in_flight => guard(fun velora_render_limiter:in_flight/0, 0),
      rejected  => guard(fun velora_render_limiter:rejected_count/0, 0),
      slots     => application:get_env(velora, max_concurrent_renders, 4)}.

guard(Fun, Default) ->
    try Fun() catch _:_ -> Default end.
