%%% @doc cowboy handler for velora's HTTP surface.
-module(velora_api_h).
-export([init/2, decode_submit/1, decode_search/1]).

init(Req, health) ->
    {ok, reply(Req, 200, #{status => <<"ok">>}), health};
init(Req, cluster) ->
    Nodes = [atom_to_binary(N, utf8) || N <- velora_cluster:members()],
    {ok, reply(Req, 200, #{nodes => Nodes}), cluster};
init(Req0, jobs) ->
    case cowboy_req:method(Req0) of
        <<"POST">> ->
            {ok, Body, Req1} = cowboy_req:read_body(Req0),
            case decode_submit(Body) of
                {ok, JobReq} ->
                    case velora_job_manager:submit(JobReq) of
                        {ok, Id}    -> {ok, reply(Req1, 202, #{job_id => Id}), jobs};
                        {error, E}  -> {ok, reply(Req1, 400, #{error => errbin(E)}), jobs}
                    end;
                {error, R} ->
                    {ok, reply(Req1, 400, #{error => errbin(R)}), jobs}
            end;
        <<"GET">> ->
            {ok, reply(Req0, 200, #{jobs => velora_job_manager:list()}), jobs};
        _ ->
            {ok, reply(Req0, 405, #{error => <<"method_not_allowed">>}), jobs}
    end;
init(Req, job) ->
    Id = cowboy_req:binding(id, Req),
    case velora_job_manager:status(Id) of
        {error, not_found} -> {ok, reply(Req, 404, #{error => <<"not_found">>}), job};
        View               -> {ok, reply(Req, 200, View), job}
    end;
init(Req0, search) ->
    Id = cowboy_req:binding(id, Req0),
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    case decode_search(Body) of
        {ok, Query, K} ->
            case velora_job_manager:search(Id, Query, K) of
                {ok, Results} ->
                    Rs = [#{tile_id => TileId, score => Score} || {TileId, Score} <- Results],
                    {ok, reply(Req1, 200, #{results => Rs}), search};
                {error, not_ready} ->
                    {ok, reply(Req1, 409, #{error => <<"not_ready">>}), search};
                {error, not_found} ->
                    {ok, reply(Req1, 404, #{error => <<"not_found">>}), search};
                {error, E} ->
                    {ok, reply(Req1, 400, #{error => errbin(E)}), search}
            end;
        {error, R} ->
            {ok, reply(Req1, 400, #{error => errbin(R)}), search}
    end.

decode_search(Body) ->
    try
        M = jsx:decode(Body, [return_maps]),
        K = maps:get(<<"k">>, M, 10),
        case M of
            #{<<"tile">> := T}   -> {ok, {tile, T}, K};
            #{<<"vector">> := V} -> {ok, {vector, V}, K};
            _ -> {error, missing_tile_or_vector}
        end
    catch _:_ -> {error, bad_request} end.

decode_submit(Body) ->
    try
        M = jsx:decode(Body, [return_maps]),
        Op = decode_op(M),
        Sources = [#{uri => maps:get(<<"uri">>, S), 'band' => maps:get(<<"band">>, S)}
                   || S <- maps:get(<<"sources">>, M)],
        Req0 = #{op => Op, sources => Sources, out_uri => maps:get(<<"out_uri">>, M)},
        Req1 = with_tile(M, Req0),
        Req2 = with_stats(M, Req1),
        {ok, Req2}
    catch _:_ -> {error, bad_request} end.

decode_op(#{<<"op">> := <<"decode">>} = M) -> {decode, num(maps:get(<<"scale">>, M))};
decode_op(#{<<"op">> := Op})               -> binary_to_existing_atom(Op, utf8).

with_tile(#{<<"tile">> := [TW, TH]}, Req) -> Req#{tile => {TW, TH}};
with_tile(_, Req) -> Req.

with_stats(#{<<"stats">> := #{<<"range">> := [Lo, Hi], <<"bins">> := B}}, Req) ->
    Req#{stats => #{range => {float(Lo), float(Hi)}, bins => B}};
with_stats(_, Req) -> Req.

num(N) when is_integer(N) -> float(N);
num(N) -> N.

reply(Req, Code, Map) ->
    cowboy_req:reply(Code, #{<<"content-type">> => <<"application/json">>},
                     jsx:encode(normalize(Map)), Req).

%% Make any term jsx-safe: atoms->binary (keep null), tuples/pids->inspected binary,
%% strings never leak here because job views binarify them.
normalize(null) -> null;
normalize(M) when is_map(M) -> maps:map(fun(_, V) -> normalize(V) end, M);
normalize(A) when is_atom(A) -> atom_to_binary(A, utf8);
normalize(B) when is_binary(B) -> B;
normalize(N) when is_number(N) -> N;
normalize(L) when is_list(L) -> [normalize(V) || V <- L];
normalize(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).

errbin(E) -> iolist_to_binary(io_lib:format("~p", [E])).
