%%% @doc One coordinator per job. Leases tiles to workers, monitors them, and
%%% reassigns a dead worker's in-flight tile. Acks are deduped against a done-set
%%% (exactly-once reduction); a tile that repeatedly kills workers fails the job
%%% past `max_attempts'. `next_tile' returns `wait' when the queue is drained but
%%% not all tiles are done, so workers stay alive to pick up reassignments.
-module(velora_coordinator).
-behaviour(gen_server).

-export([start_link/1, next_tile/1, ack/2, ack/3, nack/2, abort/2,
         job_ctx/1, progress/1, search/3, vectors/1, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(MAX_ATTEMPTS, 3).

-type tkey() :: {integer(), integer()}.

-record(state, {
    queue        :: [{rast_tiling:tile(), non_neg_integer()}],
    ctx          :: map(),
    total        :: non_neg_integer(),
    leases       :: #{pid() => {reference(), rast_tiling:tile(), non_neg_integer(), integer()}},
    done         :: #{tkey() => rast_tiling:tile()},
    stats        :: velora_stats:partial(),
    vectors      :: [{binary(), [number()]}],
    index        :: term() | undefined,
    max_attempts :: pos_integer(),
    lease_ttl    :: pos_integer(),
    on_done      :: fun(([rast_tiling:tile()], map()) -> any()),
    on_fail      :: fun((term()) -> any()),
    failed       :: boolean()
}).

-spec start_link(map()) -> {ok, pid()}.
start_link(#{tiles := Tiles, ctx := Ctx, on_done := OnDone} = Arg) ->
    OnFail = maps:get(on_fail, Arg, fun(_) -> ok end),
    gen_server:start_link(?MODULE, {Tiles, Ctx, OnDone, OnFail}, []).

-spec next_tile(pid()) -> {ok, rast_tiling:tile()} | wait | done.
next_tile(Pid) -> gen_server:call(Pid, next_tile, infinity).

-spec ack(pid(), rast_tiling:tile()) -> ok.
ack(Pid, Tile) -> gen_server:cast(Pid, {ack, self(), Tile, undefined}).

-spec ack(pid(), rast_tiling:tile(), velora_stats:partial() | undefined) -> ok.
ack(Pid, Tile, Partial) -> gen_server:cast(Pid, {ack, self(), Tile, Partial}).

-spec nack(pid(), rast_tiling:tile()) -> ok.
nack(Pid, Tile) -> gen_server:cast(Pid, {nack, self(), Tile}).

-spec abort(pid(), term()) -> ok.
abort(Pid, Reason) -> gen_server:cast(Pid, {abort, self(), Reason}).

-spec job_ctx(pid()) -> {ok, map()}.
job_ctx(Pid) -> gen_server:call(Pid, job_ctx, infinity).

-spec progress(pid()) -> {non_neg_integer(), non_neg_integer()}.
progress(Pid) -> gen_server:call(Pid, progress, infinity).

-spec search(pid(), {tile, binary()} | {vector, [number()]}, pos_integer()) ->
        {ok, [{binary(), float()}]} | {error, term()}.
search(Pid, Query, K) -> gen_server:call(Pid, {search, Query, K}, infinity).

%% @doc The per-tile feature vectors (in build order) and their bin count, so the
%% job manager can persist them and rebuild the index if this coordinator dies.
-spec vectors(pid()) -> {ok, pos_integer(), [{binary(), [number()]}]}.
vectors(Pid) -> gen_server:call(Pid, vectors, infinity).

-spec stop(pid()) -> ok.
stop(Pid) -> gen_server:stop(Pid).

init({Tiles, Ctx, OnDone, OnFail}) ->
    Bins = maps:get(bins, Ctx, 1),
    Ttl = maps:get(lease_ttl, Ctx, app_lease_ttl()),
    velora_jobs:register(self()),
    erlang:send_after(sweep_ms(Ttl), self(), sweep),
    {ok, #state{queue = [{T, 0} || T <- Tiles], ctx = Ctx, total = length(Tiles),
                leases = #{}, done = #{}, stats = velora_stats:empty(Bins),
                vectors = [], index = undefined,
                max_attempts = ?MAX_ATTEMPTS, lease_ttl = Ttl,
                on_done = OnDone, on_fail = OnFail, failed = false}}.

handle_call(next_tile, _From, #state{failed = true} = S) ->
    {reply, done, S};
handle_call(next_tile, {WorkerPid, _}, #state{queue = [{T, A} | Rest]} = S0) ->
    S1 = requeue_existing(WorkerPid, S0#state{queue = Rest}),
    MRef = erlang:monitor(process, WorkerPid),
    Now = erlang:monotonic_time(millisecond),
    L = S1#state.leases,
    {reply, {ok, T}, S1#state{leases = L#{WorkerPid => {MRef, T, A, Now}}}};
handle_call(next_tile, _From, #state{queue = [], done = D, total = Tot} = S)
        when map_size(D) =:= Tot ->
    {reply, done, S};
handle_call(next_tile, _From, #state{queue = []} = S) ->
    {reply, wait, S};
handle_call({search, _Q, _K}, _From, #state{index = undefined} = S) ->
    {reply, {error, not_ready}, S};
handle_call({search, {tile, TileId}, K}, _From, #state{index = Ix, vectors = V} = S) ->
    case lists:keyfind(TileId, 1, V) of
        {TileId, Hist} -> {reply, {ok, velora_index:search(Ix, velora_index:vector(Hist), K)}, S};
        false          -> {reply, {error, unknown_tile}, S}
    end;
handle_call({search, {vector, Vec}, K}, _From, #state{index = Ix} = S) ->
    {reply, {ok, velora_index:search(Ix, Vec, K)}, S};
handle_call(vectors, _From, #state{vectors = V, ctx = Ctx} = S) ->
    {reply, {ok, maps:get(bins, Ctx, 1), lists:reverse(V)}, S};
handle_call(job_ctx, _From, S) ->
    {reply, {ok, S#state.ctx}, S};
handle_call(progress, _From, #state{done = D, total = T} = S) ->
    {reply, {map_size(D), T}, S}.

handle_cast({ack, WorkerPid, _Tile, _Partial}, #state{failed = true} = S) ->
    {noreply, clear_lease(WorkerPid, S)};
handle_cast({ack, WorkerPid, Tile, Partial},
            #state{done = D, stats = St, total = Tot, vectors = Vectors,
                   ctx = Ctx, on_done = OnDone} = S) ->
    Key = key(Tile),
    case maps:is_key(Key, D) of
        true ->
            {noreply, clear_lease(WorkerPid, S)};
        false ->
            S1  = clear_lease(WorkerPid, S),
            D2  = D#{Key => Tile},
            St2 = case Partial of undefined -> St; _ -> velora_stats:merge(St, Partial) end,
            V2  = case Partial of
                      undefined -> Vectors;
                      _         -> [{tile_id(Tile), maps:get(hist, Partial)} | Vectors]
                  end,
            S2  = S1#state{done = D2, stats = St2, vectors = V2},
            case map_size(D2) of
                Tot -> Index = velora_index:build(maps:get(bins, Ctx, 1), lists:reverse(V2)),
                       velora_jobs:unregister(self()),
                       _ = OnDone(done_tiles(D2),
                                  velora_stats:finalize(St2, maps:get(range, Ctx, undefined))),
                       {noreply, S2#state{index = Index}};
                _   -> {noreply, S2}
            end
    end;
handle_cast({nack, WorkerPid, _Tile}, #state{leases = L} = S) ->
    case maps:take(WorkerPid, L) of
        {{MRef, T, A, _}, L2} ->
            erlang:demonitor(MRef, [flush]),
            {noreply, fail_attempt(T, A, S#state{leases = L2})};
        error ->
            {noreply, S}
    end;
handle_cast({abort, _WorkerPid, Reason}, #state{failed = false, on_fail = OnFail} = S) ->
    velora_jobs:unregister(self()),
    _ = OnFail({setup_failed, Reason}),
    {noreply, S#state{failed = true}};
handle_cast({abort, _WorkerPid, _Reason}, S) ->
    {noreply, S}.

handle_info({'DOWN', MRef, process, WorkerPid, _Reason}, #state{leases = L} = S) ->
    case maps:get(WorkerPid, L, undefined) of
        {MRef, T, A, _Start} ->
            {noreply, fail_attempt(T, A, S#state{leases = maps:remove(WorkerPid, L)})};
        _ ->
            {noreply, S}
    end;
handle_info(sweep, #state{leases = L, lease_ttl = Ttl} = S) ->
    Now = erlang:monotonic_time(millisecond),
    Expired = [P || {P, {_M, _T, _A, Start}} <- maps:to_list(L), Now - Start >= Ttl],
    S2 = lists:foldl(fun(P, Acc) ->
             {MRef, T, A, _} = maps:get(P, Acc#state.leases),
             erlang:demonitor(MRef, [flush]),
             fail_attempt(T, A, Acc#state{leases = maps:remove(P, Acc#state.leases)})
         end, S, Expired),
    erlang:send_after(sweep_ms(Ttl), self(), sweep),
    {noreply, S2};
handle_info(_I, S) ->
    {noreply, S}.

terminate(_R, _S) -> ok.

key(Tile) -> {maps:get(x, Tile), maps:get(y, Tile)}.

tile_id(Tile) ->
    {X, Y} = key(Tile),
    list_to_binary(lists:flatten(io_lib:format("~w_~w", [X, Y]))).

done_tiles(D) -> maps:values(D).

%% Requeue-or-poison one failed attempt; a tile already done is dropped.
fail_attempt(_Tile, _Attempts, #state{failed = true} = S) -> S;
fail_attempt(Tile, Attempts, #state{done = D, queue = Q, max_attempts = Max,
                                    on_fail = OnFail} = S) ->
    case maps:is_key(key(Tile), D) of
        true  -> S;
        false ->
            case Attempts + 1 >= Max of
                true  -> velora_jobs:unregister(self()),
                         _ = OnFail({poison_tile, Tile}),
                         S#state{failed = true};
                false -> S#state{queue = Q ++ [{Tile, Attempts + 1}]}
            end
    end.

%% If a worker re-leases without acking, requeue its previous tile instead of
%% silently losing it (and demonitor the stale monitor).
requeue_existing(WorkerPid, #state{leases = L} = S) ->
    case maps:take(WorkerPid, L) of
        {{MRef, OldT, OldA, _}, L2} ->
            erlang:demonitor(MRef, [flush]),
            fail_attempt(OldT, OldA, S#state{leases = L2});
        error -> S
    end.

sweep_ms(Ttl) -> max(50, Ttl div 2).

app_lease_ttl() ->
    case application:get_env(velora, lease_ttl_ms) of
        {ok, N} when is_integer(N), N > 0 -> N;
        _ -> 300000
    end.

clear_lease(WorkerPid, #state{leases = L} = S) ->
    case maps:take(WorkerPid, L) of
        {{MRef, _, _, _}, L2} -> erlang:demonitor(MRef, [flush]), S#state{leases = L2};
        error                 -> S
    end.
