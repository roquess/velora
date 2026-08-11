%%% @doc cowboy routing and listener child spec.
-module(velora_api).
-export([child_spec/0]).

-spec child_spec() -> supervisor:child_spec().
child_spec() ->
    Port = velora_config:http_port(),
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/health",     velora_api_h, health},
            {"/cluster",    velora_api_h, cluster},
            {"/jobs",       velora_api_h, jobs},
            {"/jobs/:id",   velora_api_h, job}
        ]}
    ]),
    ranch:child_spec(velora_http, ranch_tcp, #{socket_opts => [{port, Port}]},
                     cowboy_clear, #{env => #{dispatch => Dispatch}}).
