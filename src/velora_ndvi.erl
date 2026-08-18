%%% @doc Full-resolution NDVI through velora's distributed job engine.
%%%
%%% `submit/2' launches a tiled NDVI job over a Nir and a Red source, producing a
%%% full-resolution NDVI COG in the work dir. `result_tile/4' serves that result
%%% as web-mercator XYZ tiles once the job is done: it warps the NDVI COG to a
%%% mercator COG via `velora_web:prepare/1' (memoized, so the warp happens once)
%%% and cuts the tile with `velora_render:tile/4'. The agent returns a
%%% "processing" card immediately (plus an instant capped preview from
%%% `velora_web:prepare_ndvi/2'); the client polls `/jobs/:id' and, once done,
%%% loads `/jobs/:id/tiles/{z}/{x}/{y}'.
-module(velora_ndvi).
-export([submit/2, result_tile/4]).

%% @doc Submit a full-resolution NDVI job over the Red and Nir sources. Sources
%% are passed as [Nir, Red] to match `velora_worker:apply_op(ndvi, [Nir, Red])'.
-spec submit(binary() | string(), binary() | string()) ->
        {ok, binary()} | {error, term()}.
submit(RedUri, NirUri) ->
    Rid = integer_to_list(erlang:unique_integer([positive])),
    OutUri = list_to_binary("work://ndvi_" ++ Rid ++ ".tif"),
    Req = #{op => ndvi,
            sources => [#{uri => to_bin(NirUri), 'band' => 1},
                        #{uri => to_bin(RedUri), 'band' => 1}],
            out_uri => OutUri},
    velora_job_manager:submit(Req).

%% @doc Serve one XYZ tile of a finished NDVI job's result. `processing' while
%% the job is still running; `{error, _}' on failure or a missing/remote result.
-spec result_tile(binary(), integer(), integer(), integer()) ->
        {ok, binary()} | processing | {error, term()}.
result_tile(JobId, Z, X, Y) ->
    case velora_job_manager:status(JobId) of
        #{status := done} ->
            case velora_job_manager:result_path(JobId) of
                {ok, Path} ->
                    %% the result lives in the work dir; render it via the
                    %% internal work:// scheme (allowed by default), warping to a
                    %% mercator COG once (memoized by prepare).
                    Uri = <<"work://", (list_to_binary(filename:basename(Path)))/binary>>,
                    case velora_render:prepare(Uri) of
                        {ok, Id, _Bounds, _NZ} -> velora_render:tile(Id, Z, X, Y);
                        {error, _} = E -> E
                    end;
                {error, R} -> {error, R}
            end;
        #{status := error} -> {error, job_failed};
        #{status := _} -> processing;
        {error, not_found} -> {error, not_found}
    end.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L)   -> list_to_binary(L).
