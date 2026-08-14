-module(velora_emergence_vec_tests).
-include_lib("eunit/include/eunit.hrl").

dim_bytes_test() ->
    ?assertEqual(256, byte_size(velora_emergence_vec:from_capabilities([<<"raster">>], 64))).

unit_norm_test() ->
    V = velora_emergence_vec:from_capabilities([<<"raster">>, <<"ndvi">>, <<"geo">>], 64),
    ?assert(abs(norm(V) - 1.0) < 1.0e-5).

empty_uniform_test() ->
    V = velora_emergence_vec:from_capabilities([], 64),
    ?assert(abs(norm(V) - 1.0) < 1.0e-5),
    Fs = floats(V),
    ?assert(lists:all(fun(F) -> abs(F - hd(Fs)) < 1.0e-6 end, Fs)).

deterministic_test() ->
    A = velora_emergence_vec:from_capabilities([<<"a">>, <<"b">>], 32),
    ?assertEqual(A, velora_emergence_vec:from_capabilities([<<"a">>, <<"b">>], 32)).

accepts_atom_and_string_test() ->
    B = velora_emergence_vec:from_capabilities([<<"raster">>], 16),
    ?assertEqual(B, velora_emergence_vec:from_capabilities([raster], 16)),
    ?assertEqual(B, velora_emergence_vec:from_capabilities(["raster"], 16)).

norm(V) -> math:sqrt(lists:sum([F * F || F <- floats(V)])).
floats(<<>>) -> [];
floats(<<F:32/float-little, R/binary>>) -> [F | floats(R)].
