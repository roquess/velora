%%% @doc Periodically sweeps the work dir, removing prepared COGs, uploads and
%%% straggler tiles older than a TTL so disk usage stays bounded on a
%%% long-running server. Intervals/TTL come from the app env
%%% (`work_sweep_interval_ms', `work_ttl_ms').
-module(velora_janitor).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    erlang:send_after(interval(), self(), sweep),
    {ok, #{}}.

handle_info(sweep, S) ->
    _ = catch velora_web:sweep(ttl()),
    erlang:send_after(interval(), self(), sweep),
    {noreply, S};
handle_info(_I, S) -> {noreply, S}.

handle_call(_R, _F, S) -> {reply, ok, S}.
handle_cast(_M, S) -> {noreply, S}.
terminate(_R, _S) -> ok.

interval() -> env(work_sweep_interval_ms, 600000).   %% 10 min
ttl()      -> env(work_ttl_ms, 3600000).             %% 1 h

env(Key, Default) ->
    case application:get_env(velora, Key) of
        {ok, V} when is_integer(V), V > 0 -> V;
        _ -> Default
    end.
