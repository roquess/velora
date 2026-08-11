%%% @doc cowboy handler for velora's HTTP surface.
-module(velora_api_h).
-export([init/2]).

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
    end.

decode_submit(Body) ->
    try
        M = jsx:decode(Body, [return_maps]),
        Op = binary_to_existing_atom(maps:get(<<"op">>, M), utf8),
        Sources = [#{uri => maps:get(<<"uri">>, S), 'band' => maps:get(<<"band">>, S)}
                   || S <- maps:get(<<"sources">>, M)],
        Req0 = #{op => Op, sources => Sources, out_uri => maps:get(<<"out_uri">>, M)},
        Req1 = case maps:get(<<"tile">>, M, undefined) of
                   [TW, TH] -> Req0#{tile => {TW, TH}};
                   _ -> Req0
               end,
        {ok, Req1}
    catch _:_ -> {error, bad_request} end.

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
