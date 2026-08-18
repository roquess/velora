-module(velora_metrics_tests).
-include_lib("eunit/include/eunit.hrl").

%% collect/0 never crashes and always returns the documented sections, even with
%% no app running (every section is guarded and defaults to zeros).
collect_shape_test() ->
    M = velora_metrics:collect(),
    ?assert(is_map(maps:get(jobs, M))),
    ?assert(is_map(maps:get(tiles, M))),
    ?assert(is_map(maps:get(prepare, M))),
    ?assert(is_map(maps:get(render, M))),
    ?assert(is_integer(maps:get(uptime_ms, M))),
    Jobs = maps:get(jobs, M),
    ?assert(is_integer(maps:get(total, Jobs))),
    Render = maps:get(render, M),
    ?assert(is_integer(maps:get(in_flight, Render))),
    ?assert(is_integer(maps:get(rejected, Render))),
    ?assert(is_integer(maps:get(slots, Render))),
    Tiles = maps:get(tiles, M),
    ?assert(is_integer(maps:get(hits, Tiles))),
    ?assert(is_integer(maps:get(capacity, Tiles))).
