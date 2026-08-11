-module(velora_multi_node_SUITE).
-compile(export_all).
-compile(nowarn_export_all).
-include_lib("common_test/include/ct.hrl").

all() -> [tiles_distributed_exactly_once].

init_per_suite(Config) ->
    case net_kernel:get_state() of
        #{started := no} ->
            {ok, _} = net_kernel:start(velora_ct, #{name_domain => shortnames});
        _ -> ok
    end,
    Config.
end_per_suite(_) -> ok.

tiles_distributed_exactly_once(_Config) ->
    Paths = [filename:dirname(code:which(?MODULE)) | code:get_path()],
    {ok, P1, N1} = start_peer(velora_n1, Paths),
    {ok, P2, N2} = start_peer(velora_n2, Paths),
    try
        Collector = spawn(fun() -> collector([]) end),
        Tiles = [#{x=>X, y=>0, w=>1, h=>1} || X <- lists:seq(0, 59)],
        Parent = self(),
        Ctx = #{op => noop, out_base => "/tmp", sources => [],
                gt => {0.0,1.0,0.0,0.0,0.0,-1.0}, srs => "", dtype => <<"UInt16">>},
        {ok, C} = velora_coordinator:start_link(
                    #{tiles => Tiles, ctx => Ctx,
                      on_done => fun(Acked, _Stats) -> Parent ! {done, Acked} end,
                      on_fail => fun(_) -> ok end}),
        %% Spawn pullers everywhere in "wait for go" state first, then release
        %% them all at once. Without this barrier, the local pullers (pure
        %% in-VM gen_server:call, no network hop) drain the whole queue
        %% before the rpc:call round-trip to N1/N2 even lands their first
        %% next_tile request, so the peers never get a look-in.
        LocalPids = spawn_pullers(C, Collector, 4),
        N1Pids = rpc:call(N1, ?MODULE, spawn_pullers, [C, Collector, 4]),
        N2Pids = rpc:call(N2, ?MODULE, spawn_pullers, [C, Collector, 4]),
        [Pid ! go || Pid <- LocalPids ++ N1Pids ++ N2Pids],
        Acked = receive {done, A} -> A after 30000 -> ct:fail(timeout) end,
        60 = length(Acked),
        Tiles = lists:sort(Acked),                 %% exactly once, none missing/dup
        timer:sleep(300),                          %% let late tile_on stragglers arrive
        Nodes = get_nodes(Collector),
        ct:pal("Nodes tally: ~p~nUsort: ~p", [Nodes, lists:usort(Nodes)]),
        true = length(lists:usort(Nodes)) >= 2
    after
        peer:stop(P1), peer:stop(P2)
    end.

spawn_pullers(C, Collector, K) ->
    [spawn(fun() -> pull_loop_wait(C, Collector) end) || _ <- lists:seq(1, K)].

pull_loop_wait(C, Collector) ->
    receive go -> pull_loop(C, Collector) end.

pull_loop(C, Collector) ->
    case velora_coordinator:next_tile(C) of
        done -> ok;
        wait -> timer:sleep(10), pull_loop(C, Collector);
        {ok, T} ->
            Collector ! {tile_on, node(), T},
            %% Stand-in for the real per-tile op (GDAL work, in production):
            %% without it, a same-node next_tile/ack round trip is a bare
            %% in-VM gen_server:call with ~0 latency, while a peer's round
            %% trip pays real distribution I/O. That asymmetry lets the
            %% local node's pullers win every race and drain the whole
            %% queue before a peer's first request even lands. A few ms of
            %% simulated work makes per-tile latency dominated by the work
            %% itself rather than by which node is asking, so demand-driven
            %% pulling actually spreads across nodes the way it would with
            %% real (non-trivial) tile processing.
            timer:sleep(5),
            velora_coordinator:ack(C, T),
            pull_loop(C, Collector)
    end.

collector(Acc) ->
    receive
        {tile_on, N, _T} -> collector([N | Acc]);
        {get, From}      -> From ! {nodes, Acc}, collector(Acc)
    end.

get_nodes(Collector) ->
    Collector ! {get, self()},
    receive {nodes, Ns} -> Ns after 5000 -> [] end.

start_peer(Name, Paths) ->
    {ok, Peer, Node} = peer:start(#{name => Name, connection => standard_io}),
    _ = [rpc:call(Node, code, add_pathz, [P]) || P <- Paths],
    {ok, Peer, Node}.
