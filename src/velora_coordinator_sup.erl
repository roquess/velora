%%% @doc Dynamic supervisor for per-job coordinators. Isolates a coordinator
%%% crash from the job manager: coordinators are linked to this supervisor (not
%%% to the job manager), and are `temporary' — a crashed coordinator is not
%%% restarted (its in-memory job state is gone); the job manager monitors it and
%%% marks the job failed instead.
-module(velora_coordinator_sup).
-behaviour(supervisor).

-export([start_link/0, start_coordinator/1, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec start_coordinator(map()) -> {ok, pid()} | {error, term()}.
start_coordinator(Arg) ->
    supervisor:start_child(?MODULE, [Arg]).

init([]) ->
    SupFlags = #{strategy => simple_one_for_one, intensity => 20, period => 10},
    Child = #{id => velora_coordinator,
              start => {velora_coordinator, start_link, []},
              restart => temporary,
              shutdown => 5000,
              type => worker},
    {ok, {SupFlags, [Child]}}.
