%%% @private
-module(velora_app).
-behaviour(application).
-export([start/2, stop/1]).

start(_Type, _Args) ->
    velora_storage:ensure_gdal_env(),
    velora_sup:start_link().

stop(_State) ->
    ok.
