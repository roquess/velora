%%% @doc A worker drains a coordinator: pull tile -> read each source window ->
%%% run the op's rast kernel -> write a georeferenced result tile -> ack. Repeats
%%% until the coordinator reports `done'. Reads/writes go to object storage; tile
%%% pixels never travel between nodes.
-module(velora_worker).
-export([start_link/1, run/1]).

-spec start_link(pid()) -> {ok, pid()}.
start_link(Coordinator) when is_pid(Coordinator) ->
    {ok, spawn_link(?MODULE, run, [Coordinator])}.

%% @private
-spec run(pid()) -> ok.
run(Coordinator) ->
    {ok, Ctx} = velora_coordinator:job_ctx(Coordinator),
    Handles = open_sources(Ctx),
    loop(Coordinator, Ctx, Handles),
    ok.

loop(Coordinator, Ctx, Handles) ->
    case velora_coordinator:next_tile(Coordinator) of
        done ->
            ok;
        {ok, Tile} ->
            ok = process_tile(Ctx, Handles, Tile),
            velora_coordinator:ack(Coordinator, Tile),
            loop(Coordinator, Ctx, Handles)
    end.

open_sources(#{sources := Sources}) ->
    [begin
         {ok, H} = rast_gdal:open(velora_storage:to_vsi(Uri)),
         {H, Band}
     end || #{uri := Uri, 'band' := Band} <- Sources].

process_tile(#{op := Op, out_base := OutBase, gt := GT, srs := Srs}, Handles, Tile) ->
    Bins = [begin {ok, B} = rast_gdal:read_window(H, Tile, Band), B end
            || {H, Band} <- Handles],
    {ok, Out} = apply_op(Op, Bins),
    #{x := X, y := Y, w := W, h := H} = Tile,
    Path = tile_path(OutBase, X, Y),
    ok = velora_storage:write_tile(Path, Out, W, H, Srs,
                                   velora_storage:tile_ullr(GT, Tile)),
    ok.

apply_op(ndvi, [Nir, Red]) -> rast:ndvi_u16(Nir, Red);
apply_op({decode, Scale}, [Bin]) -> rast:decode_u16(Bin, Scale).

tile_path(OutBase, X, Y) ->
    filename:join(OutBase, lists:flatten(io_lib:format("tile_~w_~w.tif", [X, Y]))).
