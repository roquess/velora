%%% @doc A persistent, self-discovering worker. Each worker loops forever: pick
%%% an active job from the `velora_jobs' pg registry, drain it fully (pull tile
%%% -> read each source window -> run the op's rast kernel -> write a
%%% georeferenced result tile -> ack), repeating until the coordinator reports
%%% `done', then pick another job. When no job is active, idle-wait. If the
%%% chosen coordinator dies mid-drain (or anything else throws), the error is
%%% caught and the worker simply moves on to pick again -- the worker process
%%% itself never crashes on a job failure. Reads/writes go to object storage;
%%% tile pixels never travel between nodes.
-module(velora_worker).
-export([start_link/0, run/0]).

-define(IDLE_MS, 200).
-define(WAIT_MS, 50).

-spec start_link() -> {ok, pid()}.
start_link() ->
    {ok, spawn_link(?MODULE, run, [])}.

%% @private
-spec run() -> no_return().
run() ->
    case pick() of
        none -> timer:sleep(?IDLE_MS);
        C    -> serve(C)
    end,
    run().

pick() ->
    case velora_jobs:active() of
        [] -> none;
        Cs -> lists:nth(rand:uniform(length(Cs)), Cs)
    end.

serve(C) ->
    try
        {ok, Ctx} = velora_coordinator:job_ctx(C),
        serve_job(C, Ctx)
    catch
        _:_ -> ok            %% coordinator gone; just pick again
    end.

serve_job(C, Ctx) ->
    case open_sources_safe(Ctx) of
        {ok, Handles} ->
            try drain(C, Ctx, Handles)
            after close_handles(Handles)
            end;
        {error, Reason} ->
            velora_coordinator:abort(C, {open_sources, Reason})
    end.

drain(C, Ctx, Handles) ->
    case velora_coordinator:next_tile(C) of
        done ->
            ok;
        wait ->
            timer:sleep(?WAIT_MS),
            case length(velora_jobs:active()) > 1 of
                true  -> ok;    %% yield so this worker can help other active jobs
                false -> drain(C, Ctx, Handles)
            end;
        {ok, Tile} ->
            case process_safe(Ctx, Handles, Tile) of
                {ok, Partial} -> velora_coordinator:ack(C, Tile, Partial);
                {error, _}    -> velora_coordinator:nack(C, Tile)
            end,
            drain(C, Ctx, Handles)
    end.

open_sources_safe(Ctx) ->
    try {ok, open_sources(Ctx)}
    catch _:R -> {error, R} end.

process_safe(Ctx, Handles, Tile) ->
    try {ok, process_tile(Ctx, Handles, Tile)}
    catch _:R -> {error, R} end.

close_handles(Handles) ->
    _ = [catch rast_gdal:close(H) || {H, _Band} <- Handles],
    ok.

open_sources(#{sources := Sources}) ->
    [begin
         {ok, H} = rast_gdal:open(velora_storage:to_vsi(Uri)),
         {H, Band}
     end || #{uri := Uri, 'band' := Band} <- Sources].

process_tile(#{op := Op, out_base := OutBase, gt := GT, srs := Srs,
               range := Range, bins := Bins}, Handles, Tile) ->
    Windows = [begin {ok, B} = rast_gdal:read_window(H, Tile, Band), B end
               || {H, Band} <- Handles],
    {ok, Out} = apply_op(Op, Windows),
    #{x := X, y := Y, w := W, h := H} = Tile,
    Path = tile_path(OutBase, X, Y),
    ok = velora_storage:write_tile(Path, Out, W, H, Srs,
                                   velora_storage:tile_ullr(GT, Tile)),
    velora_stats:tile_stats(Out, Range, Bins).

apply_op(ndvi, [Nir, Red]) -> rast:ndvi_u16(Nir, Red);
apply_op({decode, Scale}, [Bin]) -> rast:decode_u16(Bin, Scale).

tile_path(OutBase, X, Y) ->
    filename:join(OutBase, lists:flatten(io_lib:format("tile_~w_~w.tif", [X, Y]))).
