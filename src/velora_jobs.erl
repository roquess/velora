%%% @doc Cluster-wide registry of active job coordinators, over a named `pg' scope.
%%% pg propagates membership across connected nodes automatically. All functions
%%% tolerate the scope being absent (so coordinator-only tests need no pg).
-module(velora_jobs).
-export([scope/0, group/0, register/1, unregister/1, active/0]).

-define(SCOPE, velora_pg).
-define(GROUP, jobs).

-spec scope() -> atom().
scope() -> ?SCOPE.

-spec group() -> atom().
group() -> ?GROUP.

-spec register(pid()) -> ok.
register(Pid) -> try pg:join(?SCOPE, ?GROUP, Pid) catch _:_ -> ok end.

-spec unregister(pid()) -> ok.
unregister(Pid) -> try pg:leave(?SCOPE, ?GROUP, Pid) catch _:_ -> ok end.

-spec active() -> [pid()].
active() -> try pg:get_members(?SCOPE, ?GROUP) catch _:_ -> [] end.
