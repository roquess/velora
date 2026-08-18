%%% @doc Optional participation in the Emergence gossip mesh. When enabled (app
%%% env `emergence' => #{enabled => true, ...}) velora runs an em_pop node that
%%% advertises a capability vector and gossips with peers, so the mesh can
%%% discover and route work to it. Disabled by default, and it degrades to
%%% standalone if the node can't start — velora always works on its own.
-module(velora_emergence).
-behaviour(gen_server).

-export([start_link/0, enabled/0, node/0, peers/0, peers_for/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec enabled() -> boolean().
enabled() -> gen_server:call(?MODULE, enabled).

%% @doc The em_pop node pid (or undefined when not in the mesh).
-spec node() -> pid() | undefined.
node() -> gen_server:call(?MODULE, node).

-spec peers() -> [map()].
peers() -> gen_server:call(?MODULE, peers).

%% @doc Top-K mesh peers by capability similarity to a query vector.
-spec peers_for(binary(), pos_integer()) -> [{map(), float()}].
peers_for(QueryVec, K) -> gen_server:call(?MODULE, {peers_for, QueryVec, K}).

init([]) ->
    case config() of
        #{enabled := true} = C -> {ok, start_node(C)};
        _                      -> {ok, #{enabled => false, node => undefined}}
    end.

start_node(C) ->
    Caps = maps:get(capabilities, C, default_caps()),
    Dim  = maps:get(dim, C, 64),
    Vec  = velora_emergence_vec:from_capabilities(Caps, Dim),
    %% query_port advertises velora's HTTP /agent/query port so mesh peers can
    %% route work to it (honoured by em_pop >= 0.3.0; ignored by older nodes).
    Opts = #{port => maps:get(port, C, 9100), vector => Vec,
             query_port => application:get_env(velora, http_port, 8080),
             gossip_interval => maps:get(gossip_interval, C, 5000)},
    try em_pop:start_link(Opts) of
        {ok, Node} ->
            _ = [catch em_pop:add_peer(Node, H, P) || {H, P} <- maps:get(seed, C, [])],
            #{enabled => true, node => Node};
        {error, _} ->
            #{enabled => false, node => undefined}   %% degrade to standalone
    catch _:_ ->
        #{enabled => false, node => undefined}
    end.

handle_call(enabled, _F, S) -> {reply, maps:get(enabled, S, false), S};
handle_call(node, _F, S)    -> {reply, maps:get(node, S, undefined), S};
handle_call(peers, _F, #{node := N} = S) when is_pid(N) ->
    {reply, (catch em_pop:peers(N)), S};
handle_call(peers, _F, S) -> {reply, [], S};
handle_call({peers_for, Q, K}, _F, #{node := N} = S) when is_pid(N) ->
    {reply, (catch em_pop:peers_for(N, Q, K)), S};
handle_call({peers_for, _Q, _K}, _F, S) -> {reply, [], S};
handle_call(_R, _F, S) -> {reply, ok, S}.

handle_cast(_M, S) -> {noreply, S}.
handle_info(_I, S) -> {noreply, S}.
terminate(_R, _S) -> ok.

config() ->
    case application:get_env(velora, emergence) of
        {ok, C} when is_map(C) -> C;
        _ -> #{enabled => false}
    end.

default_caps() ->
    [<<"raster">>, <<"satellite">>, <<"geotiff">>, <<"geo">>,
     <<"ndvi">>, <<"render">>, <<"map">>, <<"tiles">>].
