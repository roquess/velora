-module(velora_fault_SUITE).
-compile(export_all).
-compile(nowarn_export_all).
-include_lib("common_test/include/ct.hrl").

all() -> [reassigns_dead_node_tiles].

init_per_suite(Config) ->
    case net_kernel:get_state() of
        #{started := no} ->
            {ok, _} = net_kernel:start(velora_fault_ct, #{name_domain => shortnames});
        _ -> ok
    end,
    Config.
end_per_suite(_) -> ok.

reassigns_dead_node_tiles(_Config) ->
    Paths = [filename:dirname(code:which(?MODULE)) | code:get_path()],
    {ok, P1, N1} = start_peer(velora_f1, Paths),
    {ok, P2, N2} = start_peer(velora_f2, Paths),
    try
        Tiles = [#{x=>X, y=>0, w=>1, h=>1} || X <- lists:seq(0, 59)],
        Parent = self(),
        Ctx = #{op => noop, out_base => "/tmp", sources => [],
                gt => {0.0,1.0,0.0,0.0,0.0,-1.0}, srs => "", dtype => <<"UInt16">>,
                range => {0.0, 60.0}, bins => 4},
        {ok, C} = velora_coordinator:start_link(
                    #{tiles => Tiles, ctx => Ctx,
                      on_done => fun(Acked, _S) -> Parent ! {done, Acked} end,
                      on_fail => fun(R) -> Parent ! {failed, R} end}),
        spawn_pullers(C, 4),
        ok = rpc:call(N1, ?MODULE, spawn_pullers, [C, 4]),
        ok = rpc:call(N2, ?MODULE, spawn_pullers, [C, 4]),
        timer:sleep(300),
        peer:stop(P2),
        Acked = receive
                    {done, A}   -> A;
                    {failed, R} -> ct:fail({unexpected_fail, R})
                after 30000 -> ct:fail(timeout)
                end,
        60 = length(Acked),
        Keys = lists:sort([{maps:get(x,T), maps:get(y,T)} || T <- Acked]),
        Expect = lists:sort([{X, 0} || X <- lists:seq(0, 59)]),
        Keys = Expect
    after
        peer:stop(P1),
        catch peer:stop(P2)
    end.

spawn_pullers(C, K) ->
    _ = [spawn(fun() -> pull_loop(C) end) || _ <- lists:seq(1, K)],
    ok.

pull_loop(C) ->
    case velora_coordinator:next_tile(C) of
        done    -> ok;
        wait    -> timer:sleep(20), pull_loop(C);
        {ok, T} ->
            timer:sleep(30),
            velora_coordinator:ack(C, T, undefined),
            pull_loop(C)
    end.

start_peer(Name, Paths) ->
    {ok, Peer, Node} = peer:start(#{name => Name, connection => standard_io}),
    _ = [rpc:call(Node, code, add_pathz, [P]) || P <- Paths],
    {ok, Peer, Node}.
