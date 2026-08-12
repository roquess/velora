-module(velora_elastic_SUITE).
-compile(export_all).
-compile(nowarn_export_all).
-include_lib("common_test/include/ct.hrl").

all() -> [late_node_contributes].

init_per_suite(Config) ->
    case net_kernel:get_state() of
        #{started := no} ->
            _ = os:cmd("epmd -daemon"),
            {ok, _} = net_kernel:start(velora_elastic_ct, #{name_domain => shortnames});
        _ -> ok
    end,
    %% common_test runs init_per_suite in its own short-lived process, distinct
    %% from the one that runs the test case, and that process is gone (with a
    %% non-normal reason, as far as its links are concerned) before the test
    %% case starts. A plain pg:start_link/1 here would die with it, so by the
    %% time the test case ran, whereis(velora_jobs:scope()) was already
    %% undefined (confirmed by instrumenting a first pass: PgPid alive=false).
    %% Unlink right after starting it so the scope process outlives
    %% init_per_suite; we keep its pid to gen_server:stop/1 it explicitly in
    %% end_per_suite.
    {ok, Pg} = pg:start_link(velora_jobs:scope()),
    true = unlink(Pg),
    [{pg, Pg} | Config].
end_per_suite(Config) ->
    gen_server:stop(?config(pg, Config)), ok.

late_node_contributes(_Config) ->
    Tiles = [#{x=>X, y=>0, w=>1, h=>1} || X <- lists:seq(0, 79)],
    Parent = self(),
    Ctx = #{op => noop, out_base => "/tmp", sources => [],
            gt => {0.0,1.0,0.0,0.0,0.0,-1.0}, srs => "", dtype => <<"UInt16">>,
            range => {0.0, 80.0}, bins => 4},
    Collector = spawn(fun() -> collector([]) end),
    {ok, _C} = velora_coordinator:start_link(
                #{tiles => Tiles, ctx => Ctx,
                  on_done => fun(Acked, _S) -> Parent ! {done, length(Acked)} end,
                  on_fail => fun(R) -> Parent ! {failed, R} end}),
    LocalPullers = start_pullers(velora_jobs:scope(), Collector, 2),
    timer:sleep(200),
    Paths = [filename:dirname(code:which(?MODULE)) | code:get_path()],
    {ok, Peer, N1} = peer:start(#{name => velora_e1, connection => standard_io}),
    %% pg's cross-node sync is nodeup-event driven: when a node connects, each
    %% side's pg scope process sends a one-shot discovery message to its peer
    %% scope. If the nodes become mutually visible before both sides' pg scope
    %% process is registered, that handshake has nothing to land on and
    %% membership never converges (confirmed by a repro: peer-side active/0
    %% stayed [] for 2s+ when pg was started on the peer only after the
    %% ordinary rpc:call round-trip had already brought the connection up).
    %% So: use peer:call/4 (the standard_io control channel from peer:start,
    %% distinct from normal Erlang distribution) to add the code path and
    %% start pg on the peer FIRST, with no distributed connection yet. Only
    %% then do we explicitly connect the nodes, so the nodeup discovery fires
    %% with both scopes already up. (peer:call bypasses distribution, so this
    %% works even though the two nodes aren't visible to each other yet.)
    _ = [peer:call(Peer, code, add_pathz, [P]) || P <- Paths],
    {ok, _} = peer:call(Peer, pg, start_link, [velora_jobs:scope()]),
    true = peer:call(Peer, net_kernel, connect_node, [node()]),
    timer:sleep(200),
    _ = rpc:call(N1, ?MODULE, start_pullers, [velora_jobs:scope(), Collector, 4]),
    try
        receive
            {done, N}   -> 80 = N;
            {failed, R} -> ct:fail({unexpected_fail, R})
        after 30000 -> ct:fail(timeout)
        end,
        timer:sleep(200),
        Nodes = get_nodes(Collector),
        Peers = [Nd || Nd <- Nodes, Nd =:= N1],
        true = length(Peers) >= 5
    after
        %% Kill the local pullers so they don't outlive the suite: they loop on
        %% velora_jobs:active/0 forever, and if left alive they would discover a
        %% later suite's job (same pg scope) and ack its tiles WITHOUT processing
        %% them — corrupting that job's output. The peer's pullers die with the
        %% peer node. Then tear down the manual distributed link and settle.
        [exit(P, kill) || P <- LocalPullers],
        erlang:disconnect_node(N1),
        peer:stop(Peer),
        timer:sleep(200)
    end.

start_pullers(_Scope, Collector, K) ->
    [spawn(fun() -> puller(Collector) end) || _ <- lists:seq(1, K)].

puller(Collector) ->
    case velora_jobs:active() of
        [] -> timer:sleep(50), puller(Collector);
        [C | _] -> drain(C, Collector), puller(Collector)
    end.

drain(C, Collector) ->
    case velora_coordinator:next_tile(C) of
        done    -> ok;
        wait    -> timer:sleep(20), drain(C, Collector);
        {ok, T} ->
            timer:sleep(25),
            Collector ! {on, node(), T},
            velora_coordinator:ack(C, T, undefined),
            drain(C, Collector)
    end.

collector(Acc) ->
    receive
        {on, N, _T} -> collector([N | Acc]);
        {get, From} -> From ! {nodes, Acc}, collector(Acc)
    end.

get_nodes(Collector) ->
    Collector ! {get, self()},
    receive {nodes, Ns} -> Ns after 5000 -> [] end.
