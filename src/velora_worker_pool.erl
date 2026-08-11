%%% @doc One pool per node. A supervisor over a fixed set of N persistent
%%% `velora_worker' children (N = configured workers-per-node) that
%%% self-discover and drain active jobs via the `velora_jobs' pg registry.
%%% A crashed worker is restarted to keep the pool at N.
-module(velora_worker_pool).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    N = velora_config:workers_per_node(),
    Children = [#{id => {velora_worker, I},
                  start => {velora_worker, start_link, []},
                  restart => permanent, shutdown => 5000, type => worker}
                || I <- lists:seq(1, N)],
    {ok, {#{strategy => one_for_one, intensity => max(1, N) * 4, period => 10}, Children}}.
