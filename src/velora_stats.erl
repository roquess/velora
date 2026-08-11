%%% @doc Mergeable partial statistics over an f32 tile: count/min/max/sum/sumsq
%%% and a fixed-range histogram. Partials merge associatively so the reduction is
%%% independent of tile processing order. Assumes finite float values (NDVI).
-module(velora_stats).
-export([empty/1, tile_stats/3, merge/2, finalize/2]).

-type partial() :: #{count := non_neg_integer(),
                     min := float() | undefined,
                     max := float() | undefined,
                     sum := float(), sumsq := float(),
                     hist := [non_neg_integer()]}.
-export_type([partial/0]).

-spec empty(pos_integer()) -> partial().
empty(Bins) ->
    #{count => 0, min => undefined, max => undefined,
      sum => 0.0, sumsq => 0.0, hist => lists:duplicate(Bins, 0)}.

-spec tile_stats(binary(), {number(), number()}, pos_integer()) -> partial().
tile_stats(Bin, {Lo, Hi}, Bins) ->
    C = counters:new(Bins, [atomics]),
    {Count, Min, Max, Sum, Sq} =
        fold(Bin, float(Lo), float(Hi), Bins, C, 0, undefined, undefined, 0.0, 0.0),
    #{count => Count, min => Min, max => Max, sum => Sum, sumsq => Sq,
      hist => [counters:get(C, I) || I <- lists:seq(1, Bins)]}.

fold(<<V:32/float-little, Rest/binary>>, Lo, Hi, Bins, C, N, Min, Max, Sum, Sq) ->
    Idx = bin_index(V, Lo, Hi, Bins),
    counters:add(C, Idx + 1, 1),
    fold(Rest, Lo, Hi, Bins, C, N + 1, minu(Min, V), maxu(Max, V), Sum + V, Sq + V*V);
fold(<<>>, _Lo, _Hi, _Bins, _C, N, Min, Max, Sum, Sq) ->
    {N, Min, Max, Sum, Sq}.

bin_index(V, Lo, Hi, Bins) ->
    I = trunc((V - Lo) / (Hi - Lo) * Bins),
    max(0, min(Bins - 1, I)).

minu(undefined, V) -> V;
minu(M, V) -> min(M, V).
maxu(undefined, V) -> V;
maxu(M, V) -> max(M, V).

-spec merge(partial(), partial()) -> partial().
merge(A, B) ->
    #{count => maps:get(count, A) + maps:get(count, B),
      min   => cmb(fun erlang:min/2, maps:get(min, A), maps:get(min, B)),
      max   => cmb(fun erlang:max/2, maps:get(max, A), maps:get(max, B)),
      sum   => maps:get(sum, A) + maps:get(sum, B),
      sumsq => maps:get(sumsq, A) + maps:get(sumsq, B),
      hist  => lists:zipwith(fun(X, Y) -> X + Y end, maps:get(hist, A), maps:get(hist, B))}.

cmb(_F, undefined, V) -> V;
cmb(_F, V, undefined) -> V;
cmb(F, A, B) -> F(A, B).

-spec finalize(partial(), {number(), number()} | undefined) -> map().
finalize(#{count := 0, hist := H}, Range) ->
    #{count => 0, min => null, max => null, mean => null, stddev => null,
      histogram => #{range => range_json(Range), bins => length(H), counts => H}};
finalize(#{count := N, min := Mn, max := Mx, sum := S, sumsq := Sq, hist := H}, Range) ->
    Mean = S / N,
    Var  = max(0.0, Sq / N - Mean * Mean),
    #{count => N, min => Mn, max => Mx, mean => Mean, stddev => math:sqrt(Var),
      histogram => #{range => range_json(Range), bins => length(H), counts => H}}.

range_json(undefined) -> null;
range_json({Lo, Hi}) -> [float(Lo), float(Hi)].
