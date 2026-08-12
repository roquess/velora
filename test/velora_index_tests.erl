-module(velora_index_tests).
-include_lib("eunit/include/eunit.hrl").

vector_normalizes_test() ->
    V = velora_index:vector([3, 4]),
    [A, B] = V,
    ?assert(abs(A - 0.6) < 1.0e-6),
    ?assert(abs(B - 0.8) < 1.0e-6),
    ?assert(abs(math:sqrt(A*A + B*B) - 1.0) < 1.0e-6).

vector_zero_test() ->
    ?assertEqual([0.0, 0.0, 0.0], velora_index:vector([0, 0, 0])).

build_and_search_test() ->
    Pairs = [{<<"0_0">>, [10, 0, 0, 0]},
             {<<"1_0">>, [20, 0, 0, 0]},
             {<<"2_0">>, [0, 0, 0, 10]}],
    Ix = velora_index:build(4, Pairs),
    Q  = velora_index:vector([5, 0, 0, 0]),
    R  = velora_index:search(Ix, Q, 3),
    Ids = [Id || {Id, _Score} <- R],
    ?assertEqual([<<"0_0">>, <<"1_0">>], lists:sublist(Ids, 2)),
    ?assertEqual(<<"2_0">>, lists:last(Ids)).
