-module(velora_coordinator_tests).
-include_lib("eunit/include/eunit.hrl").

f32(Vals) -> << <<(float(V)):32/float-little>> || V <- Vals >>.

ctx() -> #{op => ndvi, out_base => "/tmp/out", sources => [],
           gt => {0.0,1.0,0.0,0.0,0.0,-1.0}, srs => "", dtype => <<"UInt16">>,
           range => {0.0, 4.0}, bins => 4}.

start(Tiles, OnDone, OnFail) ->
    velora_coordinator:start_link(#{tiles => Tiles, ctx => ctx(),
                                    on_done => OnDone, on_fail => OnFail}).

part(X) -> velora_stats:tile_stats(f32([X]), {0.0, 4.0}, 4).

drain_ack(C) ->
    case velora_coordinator:next_tile(C) of
        done    -> ok;
        wait    -> timer:sleep(10), drain_ack(C);
        {ok, T} -> velora_coordinator:ack(C, T, part(maps:get(x, T))), drain_ack(C)
    end.

completion_test() ->
    Tiles = [#{x=>X,y=>0,w=>1,h=>1} || X <- lists:seq(0,3)],
    Parent = self(),
    {ok, C} = start(Tiles, fun(A,S) -> Parent ! {done, length(A), S} end, fun(_) -> ok end),
    drain_ack(C),
    receive {done, N, Stats} ->
        ?assertEqual(4, N),
        ?assertEqual(4, maps:get(count, Stats)),
        ?assert(abs(maps:get(mean, Stats) - 1.5) < 1.0e-6)
    after 2000 -> ?assert(false) end.

dedup_test() ->
    Tiles = [#{x=>0,y=>0,w=>1,h=>1}, #{x=>1,y=>0,w=>1,h=>1}],
    Parent = self(),
    {ok, C} = start(Tiles, fun(_A,S) -> Parent ! {done, maps:get(count, S)} end, fun(_) -> ok end),
    {ok, T0} = velora_coordinator:next_tile(C),
    velora_coordinator:ack(C, T0, part(0)),
    velora_coordinator:ack(C, T0, part(0)),
    {ok, T1} = velora_coordinator:next_tile(C),
    velora_coordinator:ack(C, T1, part(1)),
    receive {done, Count} -> ?assertEqual(2, Count) after 2000 -> ?assert(false) end.

reassign_test() ->
    Tiles = [#{x=>X,y=>0,w=>1,h=>1} || X <- lists:seq(0,4)],
    Parent = self(),
    {ok, C} = start(Tiles, fun(A,S) -> Parent ! {done, length(A), maps:get(count, S)} end, fun(_) -> ok end),
    Bad = spawn(fun() -> velora_coordinator:next_tile(C), receive never -> ok end end),
    timer:sleep(50),
    exit(Bad, kill),
    drain_ack(C),
    receive {done, N, Count} -> ?assertEqual(5, N), ?assertEqual(5, Count)
    after 3000 -> ?assert(false) end.

poison_test() ->
    Tiles = [#{x=>0,y=>0,w=>1,h=>1}],
    Parent = self(),
    {ok, C} = start(Tiles,
                    fun(_,_) -> Parent ! wrongly_done end,
                    fun(R)   -> Parent ! {failed, R} end),
    spawn(fun L() ->
              W = spawn(fun() -> velora_coordinator:next_tile(C), receive never -> ok end end),
              timer:sleep(40), exit(W, kill), timer:sleep(40), L()
          end),
    receive {failed, {poison_tile, _}} -> ok after 5000 -> ?assert(false) end,
    receive wrongly_done -> ?assert(false) after 200 -> ok end.

job_ctx_test() ->
    {ok, C} = start([], fun(_,_) -> ok end, fun(_) -> ok end),
    {ok, Ctx} = velora_coordinator:job_ctx(C),
    ?assertEqual(ndvi, maps:get(op, Ctx)).

index_search_test() ->
    Tiles = [#{x=>0,y=>0,w=>1,h=>1}, #{x=>1,y=>0,w=>1,h=>1}, #{x=>2,y=>0,w=>1,h=>1}],
    Parent = self(),
    {ok, C} = start(Tiles, fun(_A,_S) -> Parent ! done end, fun(_) -> ok end),
    P = fun(Hist) -> #{count => lists:sum(Hist), min => 0.0, max => 1.0,
                       sum => 0.0, sumsq => 0.0, hist => Hist} end,
    {ok, T0} = velora_coordinator:next_tile(C),
    velora_coordinator:ack(C, T0, P([10,0,0,0])),
    {ok, T1} = velora_coordinator:next_tile(C),
    velora_coordinator:ack(C, T1, P([20,0,0,0])),
    {ok, T2} = velora_coordinator:next_tile(C),
    velora_coordinator:ack(C, T2, P([0,0,0,10])),
    receive done -> ok after 2000 -> ?assert(false) end,
    {ok, R} = velora_coordinator:search(C, {tile, <<"0_0">>}, 3),
    Ids = [Id || {Id, _} <- R],
    ?assertEqual([<<"0_0">>, <<"1_0">>], lists:sublist(Ids, 2)),
    ?assertEqual(<<"2_0">>, lists:last(Ids)).
