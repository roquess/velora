%%% @doc Streams a done job's local COG output with HTTP Range support so a
%%% browser (geotiff.js) can read overviews/tiles lazily.
-module(velora_result_h).
-export([init/2, parse_range/2]).

init(Req, State) ->
    Id = cowboy_req:binding(id, Req),
    case velora_job_manager:result_path(Id) of
        {ok, Path}         -> {ok, serve(Req, Path), State};
        {error, not_done}  -> {ok, json(Req, 409, <<"not_done">>), State};
        {error, remote}    -> {ok, json(Req, 409, <<"remote_output">>), State};
        {error, _}         -> {ok, json(Req, 404, <<"not_found">>), State}
    end.

serve(Req, Path) ->
    Size = filelib:file_size(Path),
    H0 = #{<<"content-type">> => <<"image/tiff">>,
           <<"accept-ranges">> => <<"bytes">>},
    case cowboy_req:header(<<"range">>, Req) of
        undefined ->
            cowboy_req:reply(200, H0, {sendfile, 0, Size, Path}, Req);
        RangeBin ->
            case parse_range(RangeBin, Size) of
                {ok, Start, Len} ->
                    CR = iolist_to_binary(io_lib:format("bytes ~w-~w/~w",
                            [Start, Start + Len - 1, Size])),
                    cowboy_req:reply(206, H0#{<<"content-range">> => CR},
                                     {sendfile, Start, Len, Path}, Req);
                error ->
                    CR = iolist_to_binary(io_lib:format("bytes */~w", [Size])),
                    cowboy_req:reply(416, H0#{<<"content-range">> => CR}, <<>>, Req)
            end
    end.

-spec parse_range(binary(), non_neg_integer()) ->
        {ok, non_neg_integer(), non_neg_integer()} | error.
parse_range(<<"bytes=", Rest/binary>>, Size) ->
    case binary:split(Rest, <<"-">>) of
        [S, <<>>] -> St = to_i(S), {ok, St, Size - St};
        [<<>>, E] -> N = to_i(E), St = max(0, Size - N), {ok, St, Size - St};
        [S, E]    -> St = to_i(S), En = min(Size - 1, to_i(E)), {ok, St, En - St + 1};
        _         -> error
    end;
parse_range(_, _) -> error.

to_i(B) -> binary_to_integer(B).

json(Req, Code, Msg) ->
    cowboy_req:reply(Code, #{<<"content-type">> => <<"application/json">>},
                     jsx:encode(#{error => Msg}), Req).
