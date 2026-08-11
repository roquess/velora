%%% @doc Data-plane storage: URI translation, scene metadata, georeferenced tile
%%% writes, and VRT->COG assembly. GDAL is driven via spawn_executable, never a shell.
-module(velora_storage).

-export([to_vsi/1, tile_ullr/2, scene_meta/1, write_tile/6, assemble/2]).

-define(TIMEOUT, 120000).

-spec to_vsi(binary() | string()) -> string().
to_vsi(Uri) when is_binary(Uri) -> to_vsi(binary_to_list(Uri));
to_vsi("s3://" ++ Rest)   -> "/vsis3/" ++ Rest;
to_vsi("gs://" ++ Rest)   -> "/vsigs/" ++ Rest;
to_vsi("file://" ++ Rest) -> Rest;
to_vsi(Path)              -> Path.

-spec tile_ullr({float(),float(),float(),float(),float(),float()},
                rast_tiling:tile()) ->
        {float(), float(), float(), float()}.
tile_ullr({G0,G1,G2,G3,G4,G5}, #{x := X, y := Y, w := W, h := H}) ->
    Ulx = G0 + X*G1 + Y*G2,
    Uly = G3 + X*G4 + Y*G5,
    Lrx = G0 + (X+W)*G1 + (Y+H)*G2,
    Lry = G3 + (X+W)*G4 + (Y+H)*G5,
    {Ulx, Uly, Lrx, Lry}.

%% @doc Read scene metadata via `gdalinfo -json': dims, dtype, geotransform, SRS WKT.
-spec scene_meta(string()) -> {ok, map()} | {error, term()}.
scene_meta(VsiUri) ->
    case run(exe("gdalinfo"), ["-json", VsiUri]) of
        {ok, Json} ->
            try json:decode(Json) of
                M ->
                    [W, H] = maps:get(<<"size">>, M),
                    Bands  = maps:get(<<"bands">>, M, []),
                    DType  = case Bands of [B|_] -> maps:get(<<"type">>, B, <<"UInt16">>); _ -> <<"UInt16">> end,
                    GT     = list_to_tuple([float(N) || N <- maps:get(<<"geoTransform">>, M, [0,1,0,0,0,1])]),
                    Srs    = srs_wkt(M),
                    {ok, #{width=>W, height=>H, dtype=>DType, gt=>GT, srs=>Srs}}
            catch _:_ -> {error, {gdalinfo_parse, VsiUri}} end;
        {error, R} -> {error, {gdalinfo_failed, R}}
    end.

srs_wkt(M) ->
    case M of
        #{<<"coordinateSystem">> := #{<<"wkt">> := Wkt}} -> binary_to_list(Wkt);
        _ -> ""
    end.

%% @doc Write an f32 result tile as a georeferenced GeoTIFF at Path.
-spec write_tile(Path :: string(), Bin :: binary(), W :: pos_integer(),
                 H :: pos_integer(), Srs :: string(),
                 {float(),float(),float(),float()}) -> ok | {error, term()}.
write_tile(Path, Bin, W, H, Srs, {Ulx,Uly,Lrx,Lry}) ->
    Raw = tmp(".img"),
    Hdr = filename:rootname(Raw) ++ ".hdr",
    ok = file:write_file(Raw, Bin),
    ok = file:write_file(Hdr, envi_hdr(W, H)),
    SrsArgs = case Srs of "" -> []; _ -> ["-a_srs", Srs] end,
    Args = ["-q", "-of", "GTiff"] ++ SrsArgs ++
           ["-a_ullr", f(Ulx), f(Uly), f(Lrx), f(Lry), Raw, Path],
    R = case run(exe("gdal_translate"), Args) of
            {ok, _} -> ok;
            {error, E} -> {error, {write_tile_failed, E}}
        end,
    _ = [file:delete(P) || P <- [Raw, Hdr, Raw ++ ".aux.xml"]],
    R.

%% @doc Mosaic tile GeoTIFFs into a single COG at OutVsi.
-spec assemble(OutVsi :: string(), TilePaths :: [string()]) ->
        {ok, string()} | {error, term()}.
assemble(OutVsi, TilePaths) ->
    Vrt  = tmp(".vrt"),
    List = tmp(".txt"),
    ok = file:write_file(List, lists:join("\n", TilePaths)),
    case run(exe("gdalbuildvrt"), ["-q", "-input_file_list", List, Vrt]) of
        {ok, _} ->
            R = case run(exe("gdal_translate"),
                         ["-q", "-of", "COG", Vrt, OutVsi]) of
                    {ok, _} -> {ok, OutVsi};
                    {error, E} -> {error, {assemble_failed, E}}
                end,
            _ = [file:delete(P) || P <- [Vrt, List]],
            R;
        {error, E} ->
            _ = [file:delete(P) || P <- [Vrt, List]],
            {error, {buildvrt_failed, E}}
    end.

%%% --- GDAL exec plumbing (mirrors rast_gdal) ---
run(Exe, Args) ->
    try open_port({spawn_executable, Exe},
                  [{args, Args}, {env, gdal_env()}, binary, exit_status,
                   stderr_to_stdout, in]) of
        Port -> collect(Port, <<>>)
    catch error:Reason -> {error, {spawn_failed, Reason}} end.

%% GDAL/PROJ need to be pointed at their support data directories explicitly:
%% the installer does not always register PROJ_LIB/PROJ_DATA/GDAL_DATA, and
%% without them `gdal_translate -a_srs' fails with "Cannot find proj.db".
gdal_env() ->
    case gdal_dir() of
        "" -> [];
        Dir ->
            ProjLib = filename:nativename(filename:join(Dir, "projlib")),
            GdalData = filename:nativename(filename:join(Dir, "gdal-data")),
            [{"PROJ_LIB", ProjLib}, {"PROJ_DATA", ProjLib}, {"GDAL_DATA", GdalData}]
    end.

collect(Port, Acc) ->
    receive
        {Port, {data, D}}        -> collect(Port, <<Acc/binary, D/binary>>);
        {Port, {exit_status, 0}} -> {ok, Acc};
        {Port, {exit_status, N}} -> {error, {exit_status, N, Acc}}
    after ?TIMEOUT -> catch port_close(Port), {error, timeout} end.

exe(Name) ->
    Full = Name ++ case os:type() of {win32,_} -> ".exe"; _ -> "" end,
    case gdal_dir() of
        "" -> case os:find_executable(Full) of false -> filename:nativename(Full); P -> P end;
        Dir -> filename:nativename(filename:join(Dir, Full))
    end.

gdal_dir() ->
    case os:getenv("GDAL_BIN_DIR") of
        false -> case os:type() of {win32,_} -> "C:/Program Files/GDAL"; _ -> "" end;
        D -> D
    end.

envi_hdr(W, H) ->
    iolist_to_binary(io_lib:format(
        "ENVI~nsamples = ~w~nlines = ~w~nbands = 1~nheader offset = 0~n"
        "data type = 4~ninterleave = bsq~nbyte order = 0~n", [W, H])).

f(X) -> lists:flatten(io_lib:format("~.10f", [X])).

tmp(Ext) ->
    Dir = case os:getenv("TMP") of false -> case os:getenv("TMPDIR") of false -> "."; D -> D end; D -> D end,
    filename:join(Dir, lists:flatten(io_lib:format("velora_~p~s",
        [erlang:unique_integer([positive]), Ext]))).
