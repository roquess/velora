-module(velora_stats_tests).
-include_lib("eunit/include/eunit.hrl").

f32(Vals) -> << <<(float(V)):32/float-little>> || V <- Vals >>.

tile_stats_test() ->
    P = velora_stats:tile_stats(f32([1,2,3,4]), {0.0, 4.0}, 4),
    ?assertEqual(4, maps:get(count, P)),
    ?assertEqual(1.0, maps:get(min, P)),
    ?assertEqual(4.0, maps:get(max, P)),
    ?assert(abs(maps:get(sum, P) - 10.0) < 1.0e-6),
    ?assert(abs(maps:get(sumsq, P) - 30.0) < 1.0e-6),
    %% bins over [0,4): 1->bin1, 2->bin2, 3->bin3, 4-> clamped to bin3
    ?assertEqual([0,1,1,2], maps:get(hist, P)).

merge_identity_and_commutativity_test() ->
    A = velora_stats:tile_stats(f32([1,2]), {0.0, 4.0}, 4),
    B = velora_stats:tile_stats(f32([3,4]), {0.0, 4.0}, 4),
    E = velora_stats:empty(4),
    ?assertEqual(A, velora_stats:merge(A, E)),
    ?assertEqual(A, velora_stats:merge(E, A)),
    Both = velora_stats:tile_stats(f32([1,2,3,4]), {0.0, 4.0}, 4),
    ?assertEqual(Both, velora_stats:merge(A, B)),
    ?assertEqual(velora_stats:merge(A, B), velora_stats:merge(B, A)).

finalize_test() ->
    P = velora_stats:tile_stats(f32([1,2,3,4]), {0.0, 4.0}, 4),
    F = velora_stats:finalize(P, {0.0, 4.0}),
    ?assert(abs(maps:get(mean, F) - 2.5) < 1.0e-6),
    ?assert(abs(maps:get(stddev, F) - math:sqrt(1.25)) < 1.0e-6),
    ?assertEqual(4, maps:get(count, F)),
    #{range := [+0.0, 4.0], bins := 4, counts := [0,1,1,2]} = maps:get(histogram, F).

finalize_empty_test() ->
    F = velora_stats:finalize(velora_stats:empty(4), undefined),
    ?assertEqual(0, maps:get(count, F)),
    ?assertEqual(null, maps:get(mean, F)),
    ?assertEqual(null, maps:get(stddev, F)),
    #{range := null, bins := 4} = maps:get(histogram, F).
