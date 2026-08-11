%%% @doc Native distributed-Erlang cluster membership. Slice 1 connects to a
%%% static, configured peer list; dynamic discovery is a later slice.
-module(velora_cluster).
-export([connect/0, members/0]).

%% @doc Connect to every configured peer. Returns the peers that answered.
-spec connect() -> [node()].
connect() ->
    [P || P <- velora_config:peers(), net_kernel:connect_node(P) =:= true].

%% @doc All known cluster members (self + connected nodes).
-spec members() -> [node()].
members() ->
    lists:usort([node() | nodes()]).
