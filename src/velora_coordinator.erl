%%% @doc One coordinator per job. Owns the tile-descriptor queue, serves pulls
%%% from workers on all nodes (demand-driven), tracks acks, and runs `on_done'
%%% when every tile has been acknowledged.
-module(velora_coordinator).
-behaviour(gen_server).

-export([start_link/1, next_tile/1, ack/2, ack/3, job_ctx/1, progress/1, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    queue   :: [rast_tiling:tile()],
    ctx     :: map(),
    total   :: non_neg_integer(),
    acked   :: [rast_tiling:tile()],
    stats   :: velora_stats:partial(),
    on_done :: fun(([rast_tiling:tile()], map()) -> any())
}).

-spec start_link(map()) -> {ok, pid()}.
start_link(#{tiles := Tiles, ctx := Ctx, on_done := OnDone}) ->
    gen_server:start_link(?MODULE, {Tiles, Ctx, OnDone}, []).

-spec next_tile(pid()) -> {ok, rast_tiling:tile()} | done.
next_tile(Pid) -> gen_server:call(Pid, next_tile, infinity).

-spec ack(pid(), rast_tiling:tile()) -> ok.
ack(Pid, Tile) -> gen_server:cast(Pid, {ack, Tile, undefined}).

-spec ack(pid(), rast_tiling:tile(), velora_stats:partial() | undefined) -> ok.
ack(Pid, Tile, Partial) -> gen_server:cast(Pid, {ack, Tile, Partial}).

-spec job_ctx(pid()) -> {ok, map()}.
job_ctx(Pid) -> gen_server:call(Pid, job_ctx, infinity).

-spec progress(pid()) -> {non_neg_integer(), non_neg_integer()}.
progress(Pid) -> gen_server:call(Pid, progress, infinity).

-spec stop(pid()) -> ok.
stop(Pid) -> gen_server:stop(Pid).

init({Tiles, Ctx, OnDone}) ->
    Bins = maps:get(bins, Ctx, 1),
    {ok, #state{queue = Tiles, ctx = Ctx, total = length(Tiles),
                acked = [], stats = velora_stats:empty(Bins), on_done = OnDone}}.

handle_call(next_tile, _From, #state{queue = [T | Rest]} = S) ->
    {reply, {ok, T}, S#state{queue = Rest}};
handle_call(next_tile, _From, #state{queue = []} = S) ->
    {reply, done, S};
handle_call(job_ctx, _From, S) ->
    {reply, {ok, S#state.ctx}, S};
handle_call(progress, _From, #state{acked = A, total = T} = S) ->
    {reply, {length(A), T}, S}.

handle_cast({ack, Tile, Partial}, #state{acked = A, total = T, stats = St,
                                         ctx = Ctx, on_done = OnDone} = S) ->
    A2  = [Tile | A],
    St2 = case Partial of
              undefined -> St;
              _         -> velora_stats:merge(St, Partial)
          end,
    S2 = S#state{acked = A2, stats = St2},
    case length(A2) of
        T -> _ = OnDone(A2, velora_stats:finalize(St2, maps:get(range, Ctx, undefined))),
             {noreply, S2};
        _ -> {noreply, S2}
    end.

handle_info(_I, S) -> {noreply, S}.
terminate(_R, _S) -> ok.
