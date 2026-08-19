%%% @doc GET /prepare/:id — poll an asynchronous prepare. Returns
%%% {"status":"processing"} until the warp is done, then {"status":"done", id,
%%% bounds, maxNativeZoom, tiles}; {"status":"error", error} on failure.
-module(velora_prepare_h).
-export([init/2]).

init(Req, State) ->
    Id = cowboy_req:binding(id, Req),
    {Code, Body} = case velora_prepare_async:status(Id) of
        processing ->
            {200, #{status => processing}};
        {ok, PId, Bounds, NZ} ->
            {200, #{status => done, id => PId, bounds => Bounds,
                    maxNativeZoom => NZ,
                    tiles => <<"/tiles/", PId/binary, "/{z}/{x}/{y}">>}};
        {error, R} ->
            {200, #{status => error, error => errbin(R)}};
        not_found ->
            {404, #{status => not_found}}
    end,
    {ok, cowboy_req:reply(Code,
        #{<<"content-type">> => <<"application/json">>}, jsx:encode(Body), Req), State}.

errbin(A) when is_atom(A) -> atom_to_binary(A, utf8);
errbin(E) -> iolist_to_binary(io_lib:format("~p", [E])).
