%%% @doc Cluster-aware routing for the viewer: the heavy prepare (warp) runs on a
%%% chosen node — offloaded to a peer when the cluster has one, so a small
%%% always-on node (e.g. a Pi) can hand the work to a beefier peer (e.g. a PC)
%%% when it is up. Tile requests are then served from, or RPC-proxied to, the node
%%% that holds the prepared COG (tiles are small and cached). With no peers
%%% everything runs locally — velora still works on its own.
-module(velora_render).
-export([prepare/1, tile/4, choose_node/0, choose_node/1]).

-define(PREPARE_TIMEOUT, 300000).
-define(TILE_TIMEOUT,     30000).

%% @doc Prepare a source on the chosen node and record where it landed.
-spec prepare(binary() | string()) ->
        {ok, binary(), [[float()]], integer()} | {error, term()}.
prepare(Uri) ->
    Node = choose_node(),
    case run(Node, prepare, [Uri]) of
        {ok, Id, _B, _NZ} = R ->
            velora_render_registry:put(Id, Node),
            R;
        _Bad when Node =/= node() ->
            %% offload failed — fall back to preparing locally
            case velora_web:prepare(Uri) of
                {ok, Id, _, _} = R2 -> velora_render_registry:put(Id, node()), R2;
                E -> E
            end;
        E -> E
    end.

%% @doc Cut a tile from the node that holds the prepared COG.
-spec tile(binary(), integer(), integer(), integer()) ->
        {ok, binary()} | {error, term()}.
tile(Id, Z, X, Y) ->
    run(velora_render_registry:get(Id), tile, [Id, Z, X, Y]).

%% @doc Node to run the warp on. `render_offload' app env: `self' | a node atom |
%% (default) `auto' = a random peer when the cluster has one, else self.
-spec choose_node() -> node().
choose_node() ->
    case application:get_env(velora, render_offload) of
        {ok, self}              -> node();
        {ok, N} when is_atom(N) -> N;
        _                       -> choose_node(nodes())
    end.

-spec choose_node([node()]) -> node().
choose_node([])    -> node();
choose_node(Peers) -> lists:nth(rand:uniform(length(Peers)), Peers).

run(Node, F, A) when Node =:= node() ->
    apply(velora_web, F, A);
run(Node, F, A) ->
    Timeout = case F of prepare -> ?PREPARE_TIMEOUT; _ -> ?TILE_TIMEOUT end,
    try rpc:call(Node, velora_web, F, A, Timeout) of
        {badrpc, _} -> {error, badrpc};
        R           -> R
    catch _:_ -> {error, rpc_failed} end.
