%%% @doc One coordinator per job. Leases tiles to workers, monitors them, and
%%% reassigns a dead worker's in-flight tile. Acks are deduped against a done-set
%%% (exactly-once reduction); a tile that repeatedly kills workers fails the job
%%% past `max_attempts'. `next_tile' returns `wait' when the queue is drained but
%%% not all tiles are done, so workers stay alive to pick up reassignments.
-module(velora_coordinator).
-behaviour(gen_server).

-export([start_link/1, next_tile/1, ack/2, ack/3, job_ctx/1, progress/1, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(MAX_ATTEMPTS, 3).

-type tkey() :: {integer(), integer()}.

-record(state, {
    queue        :: [{rast_tiling:tile(), non_neg_integer()}],
    ctx          :: map(),
    total        :: non_neg_integer(),
    leases       :: #{pid() => {reference(), rast_tiling:tile(), non_neg_integer()}},
    done         :: #{tkey() => rast_tiling:tile()},
    stats        :: velora_stats:partial(),
    max_attempts :: pos_integer(),
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

-spec job_ctx(pid()) -> {ok, map()}.
job_ctx(Pid) -> gen_server:call(Pid, job_ctx, infinity).

-spec progress(pid()) -> {non_neg_integer(), non_neg_integer()}.
progress(Pid) -> gen_server:call(Pid, progress, infinity).

-spec stop(pid()) -> ok.
stop(Pid) -> gen_server:stop(Pid).

init({Tiles, Ctx, OnDone, OnFail}) ->
    Bins = maps:get(bins, Ctx, 1),
    velora_jobs:register(self()),
    {ok, #state{queue = [{T, 0} || T <- Tiles], ctx = Ctx, total = length(Tiles),
                leases = #{}, done = #{}, stats = velora_stats:empty(Bins),
                max_attempts = ?MAX_ATTEMPTS, on_done = OnDone, on_fail = OnFail,
                failed = false}}.

handle_call(next_tile, _From, #state{failed = true} = S) ->
    {reply, done, S};
handle_call(next_tile, {WorkerPid, _}, #state{queue = [{T, A} | Rest], leases = L} = S) ->
    MRef = erlang:monitor(process, WorkerPid),
    {reply, {ok, T}, S#state{queue = Rest, leases = L#{WorkerPid => {MRef, T, A}}}};
handle_call(next_tile, _From, #state{queue = [], done = D, total = Tot} = S)
        when map_size(D) =:= Tot ->
    {reply, done, S};
handle_call(next_tile, _From, #state{queue = []} = S) ->
    {reply, wait, S};
handle_call(job_ctx, _From, S) ->
    {reply, {ok, S#state.ctx}, S};
handle_call(progress, _From, #state{done = D, total = T} = S) ->
    {reply, {map_size(D), T}, S}.

handle_cast({ack, WorkerPid, Tile, Partial},
            #state{done = D, stats = St, total = Tot,
                   ctx = Ctx, on_done = OnDone} = S) ->
    Key = key(Tile),
    case maps:is_key(Key, D) of
        true ->
            {noreply, clear_lease(WorkerPid, S)};
        false ->
            S1  = clear_lease(WorkerPid, S),
            D2  = D#{Key => Tile},
            St2 = case Partial of undefined -> St; _ -> velora_stats:merge(St, Partial) end,
            S2  = S1#state{done = D2, stats = St2},
            case map_size(D2) of
                Tot -> velora_jobs:unregister(self()),
                       _ = OnDone(done_tiles(D2),
                                  velora_stats:finalize(St2, maps:get(range, Ctx, undefined))),
                       {noreply, S2};
                _   -> {noreply, S2}
            end
    end.

handle_info({'DOWN', MRef, process, WorkerPid, _Reason},
            #state{leases = L, done = D, queue = Q, max_attempts = Max,
                   on_fail = OnFail} = S) ->
    case maps:get(WorkerPid, L, undefined) of
        {MRef, T, A} ->
            L2 = maps:remove(WorkerPid, L),
            case maps:is_key(key(T), D) of
                true  -> {noreply, S#state{leases = L2}};
                false ->
                    case A + 1 >= Max of
                        true  -> velora_jobs:unregister(self()),
                                 _ = OnFail({poison_tile, T}),
                                 {noreply, S#state{leases = L2, failed = true}};
                        false -> {noreply, S#state{leases = L2, queue = Q ++ [{T, A + 1}]}}
                    end
            end;
        _ ->
            {noreply, S}
    end;
handle_info(_I, S) ->
    {noreply, S}.

terminate(_R, _S) -> ok.

key(Tile) -> {maps:get(x, Tile), maps:get(y, Tile)}.

done_tiles(D) -> maps:values(D).

clear_lease(WorkerPid, #state{leases = L} = S) ->
    case maps:take(WorkerPid, L) of
        {{MRef, _, _}, L2} -> erlang:demonitor(MRef, [flush]), S#state{leases = L2};
        error              -> S
    end.
