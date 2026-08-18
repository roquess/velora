%%% @doc GET /jobs/:id/tiles/:z/:x/:y — serve the result of a finished NDVI job
%%% as web-mercator PNG tiles. 204 (blank) while the job is still processing or
%%% on any error, so a polling client simply sees tiles appear once it is done.
-module(velora_job_tiles_h).
-export([init/2]).

init(Req, State) ->
    Id = cowboy_req:binding(id, Req),
    try
        Z = binary_to_integer(cowboy_req:binding(z, Req)),
        X = binary_to_integer(cowboy_req:binding(x, Req)),
        Y = binary_to_integer(cowboy_req:binding(y, Req)),
        case velora_ndvi:result_tile(Id, Z, X, Y) of
            {ok, Png} ->
                {ok, cowboy_req:reply(200,
                    #{<<"content-type">> => <<"image/png">>,
                      <<"cache-control">> => <<"max-age=3600">>}, Png, Req), State};
            _ ->
                {ok, cowboy_req:reply(204, #{}, <<>>, Req), State}
        end
    catch _:_ ->
        {ok, cowboy_req:reply(400, #{}, <<>>, Req), State}
    end.
