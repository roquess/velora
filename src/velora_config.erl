%%% @doc Typed accessors over the `velora' application environment.
-module(velora_config).
-export([http_port/0, peers/0, tile/0, workers_per_node/0]).

-spec http_port() -> inet:port_number().
http_port() -> get(http_port, 8080).

-spec peers() -> [node()].
peers() -> get(peers, []).

-spec tile() -> {pos_integer(), pos_integer()}.
tile() -> get(tile, {512, 512}).

%% @doc Workers to run per node; `undefined' => number of dirty CPU schedulers.
-spec workers_per_node() -> pos_integer().
workers_per_node() ->
    case get(workers_per_node, undefined) of
        undefined -> max(1, erlang:system_info(dirty_cpu_schedulers));
        N when is_integer(N), N >= 1 -> N
    end.

get(Key, Default) ->
    case application:get_env(velora, Key) of
        {ok, V} -> V;
        undefined -> Default
    end.
