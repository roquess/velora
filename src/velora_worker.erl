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
        Handles = open_sources(Ctx),
        drain(C, Ctx, Handles)
    catch
        _:_ -> ok
    end.

drain(C, Ctx, Handles) ->
    case velora_coordinator:next_tile(C) of
        done ->
            ok;
        wait ->
            timer:sleep(?WAIT_MS),
            drain(C, Ctx, Handles);
        {ok, Tile} ->
            Partial = process_tile(Ctx, Handles, Tile),
            velora_coordinator:ack(C, Tile, Partial),
            drain(C, Ctx, Handles)
    end.

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
