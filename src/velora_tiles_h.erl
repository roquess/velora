%%% @doc GET /tiles/:id/:z/:x/:y — render one XYZ map tile of a prepared source
%%% as PNG, on demand, via GDAL. Out-of-data tiles return 204 (blank).
-module(velora_tiles_h).
-export([init/2]).

init(Req, State) ->
    Id = cowboy_req:binding(id, Req),
    try
        Z = binary_to_integer(cowboy_req:binding(z, Req)),
        X = binary_to_integer(cowboy_req:binding(x, Req)),
        Y = binary_to_integer(cowboy_req:binding(y, Req)),
        case velora_render:tile(Id, Z, X, Y) of
            {ok, Png} ->
                {ok, cowboy_req:reply(200,
                    #{<<"content-type">> => <<"image/png">>,
                      <<"cache-control">> => <<"max-age=3600">>}, Png, Req), State};
            {error, _} ->
                {ok, cowboy_req:reply(204, #{}, <<>>, Req), State}
        end
    catch _:_ ->
        {ok, cowboy_req:reply(400, #{}, <<>>, Req), State}
    end.
