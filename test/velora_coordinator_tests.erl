-module(velora_coordinator_tests).
-include_lib("eunit/include/eunit.hrl").

-define(CTX(Tiles), #{
    tiles => Tiles,
    ctx   => #{op => ndvi, out_base => "/tmp/out", sources => [], gt => {0.0,1.0,0.0,0.0,0.0,-1.0}, srs => "", dtype => <<"UInt16">>},
    on_done => fun(Acked) -> self() ! {assembled, length(Acked)} end
}).

pull_ack_completion_test() ->
    Tiles = [#{x=>X, y=>0, w=>1, h=>1} || X <- lists:seq(0, 9)],
    Parent = self(),
    Cfg = ?CTX(Tiles),
    {ok, C} = velora_coordinator:start_link(Cfg#{
        on_done => fun(Acked) -> Parent ! {assembled, length(Acked)} end}),
    Got = drain(C, []),
    ?assertEqual(10, length(Got)),
    ?assertEqual(lists:usort(Tiles), lists:usort(Got)),
    [ velora_coordinator:ack(C, T) || T <- Got ],
    receive {assembled, N} -> ?assertEqual(10, N)
    after 2000 -> ?assert(false) end.

drain(C, Acc) ->
    case velora_coordinator:next_tile(C) of
        {ok, T} -> drain(C, [T | Acc]);
        done    -> Acc
    end.

job_ctx_test() ->
    {ok, C} = velora_coordinator:start_link(?CTX([])),
    {ok, Ctx} = velora_coordinator:job_ctx(C),
    ?assertEqual(ndvi, maps:get(op, Ctx)).
