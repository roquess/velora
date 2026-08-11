-module(velora_coordinator_tests).
-include_lib("eunit/include/eunit.hrl").

ctx() -> #{op => ndvi, out_base => "/tmp/out", sources => [],
           gt => {0.0,1.0,0.0,0.0,0.0,-1.0}, srs => "", dtype => <<"UInt16">>,
           range => {0.0, 4.0}, bins => 4}.

pull_ack_completion_test() ->
    Tiles = [#{x=>X, y=>0, w=>1, h=>1} || X <- lists:seq(0, 3)],
    Parent = self(),
    {ok, C} = velora_coordinator:start_link(
                #{tiles => Tiles, ctx => ctx(),
                  on_done => fun(Acked, Stats) -> Parent ! {done, length(Acked), Stats} end}),
    Got = drain(C, []),
    ?assertEqual(4, length(Got)),
    ?assertEqual(lists:usort(Tiles), lists:usort(Got)),
    [ velora_coordinator:ack(C, T, velora_stats:tile_stats(f32([maps:get(x,T)]), {0.0,4.0}, 4)) || T <- Got ],
    receive {done, N, Stats} ->
        ?assertEqual(4, N),
        ?assertEqual(4, maps:get(count, Stats)),
        ?assert(abs(maps:get(mean, Stats) - 1.5) < 1.0e-6)
    after 2000 -> ?assert(false) end.

drain(C, Acc) ->
    case velora_coordinator:next_tile(C) of
        {ok, T} -> drain(C, [T | Acc]);
        done    -> Acc
    end.

job_ctx_test() ->
    {ok, C} = velora_coordinator:start_link(
                #{tiles => [], ctx => ctx(), on_done => fun(_A, _S) -> ok end}),
    {ok, Ctx} = velora_coordinator:job_ctx(C),
    ?assertEqual(ndvi, maps:get(op, Ctx)).

f32(Vals) -> << <<(float(V)):32/float-little>> || V <- Vals >>.
