%%% @private
-module(velora_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 10, period => 10},
    Children = [
        #{id => velora_pg, start => {pg, start_link, [velora_jobs:scope()]}},
        #{id => velora_coordinator_sup,
          start => {velora_coordinator_sup, start_link, []},
          type => supervisor},
        #{id => velora_worker_pool,
          start => {velora_worker_pool, start_link, []},
          type => supervisor},
        #{id => velora_job_manager,
          start => {velora_job_manager, start_link, []}},
        velora_api:child_spec(),
        #{id => velora_discovery, start => {velora_discovery, start_link, []}},
        #{id => velora_janitor, start => {velora_janitor, start_link, []}}
    ],
    {ok, {SupFlags, Children}}.
