%%% @doc One pool per node. Registered under a fixed local name so a coordinator
%%% on any node can announce a job to it. On `take/1' it starts N workers that
%%% drain the given coordinator (N = configured workers-per-node).
-module(velora_worker_pool).
-behaviour(gen_server).

-export([start_link/0, take/1, take/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec take(pid()) -> ok.
take(Coordinator) -> take(Coordinator, velora_config:workers_per_node()).

-spec take(pid(), pos_integer()) -> ok.
take(Coordinator, N) -> gen_server:cast(?MODULE, {take, Coordinator, N}).

init([]) -> {ok, #{}}.

handle_cast({take, Coordinator, N}, State) ->
    _ = [velora_worker:start_link(Coordinator) || _ <- lists:seq(1, N)],
    {noreply, State}.

handle_call(_R, _F, S) -> {reply, ok, S}.
handle_info(_I, S) -> {noreply, S}.
terminate(_R, _S) -> ok.
