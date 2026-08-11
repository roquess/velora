%%% @private
-module(velora_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 10, period => 10},
    Children = [
        #{id => velora_worker_pool,
          start => {velora_worker_pool, start_link, []}},
        #{id => velora_job_manager,
          start => {velora_job_manager, start_link, []}},
        velora_api:child_spec()
    ],
    {ok, {SupFlags, Children}}.
