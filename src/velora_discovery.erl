%%% @doc Periodically reconciles cluster membership: asks a strategy for target
%%% peer node names and connects to any not yet connected. Strategies: `{static}'
%%% (the configured peer list) and `{dns, Host, Base}' (Base@<ip> from A records).
-module(velora_discovery).
-behaviour(gen_server).

-export([start_link/0, targets/1, reconcile/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    self() ! reconcile,
    {ok, #{}}.

handle_info(reconcile, State) ->
    _ = reconcile(strategy()),
    erlang:send_after(interval(), self(), reconcile),
    {noreply, State};
handle_info(_I, State) ->
    {noreply, State}.

handle_call(_R, _F, S) -> {reply, ok, S}.
handle_cast(_M, S) -> {noreply, S}.
terminate(_R, _S) -> ok.

-spec reconcile(term()) -> [node()].
reconcile(Strategy) ->
    Targets = targets(Strategy),
    Connected = nodes(),
    _ = [net_kernel:connect_node(N) || N <- Targets,
                                       N =/= node(),
                                       not lists:member(N, Connected)],
    Targets.

-spec targets(term()) -> [node()].
targets({static}) ->
    velora_config:peers();
targets({dns, Host, Base}) ->
    case inet_res:lookup(Host, in, a) of
        Addrs when is_list(Addrs) ->
            [list_to_atom(Base ++ "@" ++ inet:ntoa(A)) || A <- Addrs];
        _ ->
            []
    end;
targets(_) ->
    [].

strategy() ->
    case application:get_env(velora, discovery) of
        {ok, S} -> S;
        undefined -> {static}
    end.

interval() ->
    case application:get_env(velora, discovery_interval_ms) of
        {ok, Ms} when is_integer(Ms) -> Ms;
        _ -> 5000
    end.
