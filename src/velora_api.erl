%%% @doc cowboy routing and listener child spec.
-module(velora_api).
-export([child_spec/0]).

-spec child_spec() -> supervisor:child_spec().
child_spec() ->
    Port = velora_config:http_port(),
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/",                 cowboy_static, {priv_file, velora, "www/index.html"}},
            {"/assets/[...]",     cowboy_static, {priv_dir,  velora, "www/assets"}},
            {"/health",           velora_api_h, health},
            {"/cluster",          velora_api_h, cluster},
            {"/info",             velora_api_h, info},
            {"/uploads",          velora_upload_h, []},
            {"/render",           velora_render_h, []},
            {"/tiles/:id/:z/:x/:y", velora_tiles_h, []},
            {"/jobs",             velora_api_h, jobs},
            {"/jobs/:id",         velora_api_h, job},
            {"/jobs/:id/result",  velora_result_h, []},
            {"/jobs/:id/search",  velora_api_h, search}
        ]}
    ]),
    ranch:child_spec(velora_http, ranch_tcp, #{socket_opts => [{port, Port}]},
                     cowboy_clear, #{env => #{dispatch => Dispatch}}).
