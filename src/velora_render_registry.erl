%%% @doc Maps a prepared source id to the node that holds its COG, so tile
%%% requests can be served from (or proxied to) the right node. Backed by a
%%% public ETS table for lock-free reads from the cowboy handlers. Ephemeral:
%%% a prepared source lives only on its node's work dir.
-module(velora_render_registry).
-behaviour(gen_server).

-export([start_link/0, put/2, get/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(TAB, velora_render_hosts).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec put(binary(), node()) -> ok.
put(Id, Node) -> _ = (catch ets:insert(?TAB, {Id, Node})), ok.

%% @doc The node holding Id's COG; defaults to the local node if unknown.
-spec get(binary()) -> node().
get(Id) ->
    case (catch ets:lookup(?TAB, Id)) of
        [{_, Node}] -> Node;
        _           -> node()
    end.

init([]) ->
    ?TAB = ets:new(?TAB, [named_table, public, set, {read_concurrency, true}]),
    {ok, #{}}.

handle_call(_R, _F, S) -> {reply, ok, S}.
handle_cast(_M, S) -> {noreply, S}.
handle_info(_I, S) -> {noreply, S}.
terminate(_R, _S) -> ok.
