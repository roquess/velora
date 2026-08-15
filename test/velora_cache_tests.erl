%%%-------------------------------------------------------------------
%%% @doc EUnit tests for velora_cache.
%%%
%%% NIF-gated: if the native library is not loaded (e.g. no prebuilt artifact
%%% for this platform and cargo unavailable at build time), every test skips
%%% cleanly rather than failing, mirroring the rast/sied-dependent guards.
%%% @end
%%%-------------------------------------------------------------------
-module(velora_cache_tests).

-include_lib("eunit/include/eunit.hrl").

%% @doc True if the NIF is available. `new/2' returns `{error, nif_not_loaded}'
%% (rather than raising) when the native library did not load.
nif_available() ->
    try velora_cache:new('$probe$', #{capacity => 1, policy => lru}) of
        ok ->
            velora_cache:clear('$probe$'),
            true;
        {error, nif_not_loaded} -> false;
        {error, _} -> false
    catch
        error:nif_not_loaded -> false;
        error:undef -> false
    end.

put_get_roundtrip_test() ->
    case nif_available() of
        false -> skip();
        true ->
            ok = velora_cache:new(rt, #{capacity => 2, policy => lru}),
            ok = velora_cache:put(rt, <<"k">>, <<"hello world">>),
            ?assertEqual({ok, <<"hello world">>}, velora_cache:get(rt, <<"k">>))
    end.

get_missing_test() ->
    case nif_available() of
        false -> skip();
        true ->
            ok = velora_cache:new(miss, #{capacity => 2, policy => lru}),
            ?assertEqual(miss, velora_cache:get(miss, <<"absent">>))
    end.

capacity_eviction_test() ->
    case nif_available() of
        false -> skip();
        true ->
            ok = velora_cache:new(ev, #{capacity => 2, policy => lru}),
            ok = velora_cache:put(ev, <<"a">>, <<"1">>),
            ok = velora_cache:put(ev, <<"b">>, <<"2">>),
            ok = velora_cache:put(ev, <<"c">>, <<"3">>),
            %% LRU with capacity 2: inserting "c" evicts the earliest key "a".
            ?assertEqual(miss, velora_cache:get(ev, <<"a">>)),
            ?assertEqual({ok, <<"2">>}, velora_cache:get(ev, <<"b">>)),
            ?assertEqual({ok, <<"3">>}, velora_cache:get(ev, <<"c">>))
    end.

delete_test() ->
    case nif_available() of
        false -> skip();
        true ->
            ok = velora_cache:new(del, #{capacity => 4, policy => lru}),
            ok = velora_cache:put(del, <<"k">>, <<"v">>),
            ok = velora_cache:delete(del, <<"k">>),
            ?assertEqual(miss, velora_cache:get(del, <<"k">>))
    end.

stats_test() ->
    case nif_available() of
        false -> skip();
        true ->
            ok = velora_cache:new(st, #{capacity => 4, policy => lru}),
            ok = velora_cache:put(st, <<"a">>, <<"1">>),
            {ok, <<"1">>} = velora_cache:get(st, <<"a">>),   %% hit
            miss = velora_cache:get(st, <<"x">>),            %% miss
            #{hits := Hits, misses := Misses, len := Len, capacity := Cap} =
                velora_cache:stats(st),
            ?assertEqual(1, Hits),
            ?assertEqual(1, Misses),
            ?assertEqual(1, Len),
            ?assertEqual(4, Cap)
    end.

default_policy_test() ->
    case nif_available() of
        false -> skip();
        true ->
            %% No policy given -> default 2Q (scan-resistant).
            ok = velora_cache:new(def, #{capacity => 4}),
            ok = velora_cache:put(def, <<"k">>, <<"v">>),
            ?assertEqual({ok, <<"v">>}, velora_cache:get(def, <<"k">>))
    end.

%% Emit a visible skip note without failing the suite.
skip() ->
    ?debugMsg("velora_cache NIF not loaded; skipping"),
    ok.
