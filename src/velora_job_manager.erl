%%% @doc Accepts jobs, builds the job context (scene metadata + tile grid), starts
%%% a coordinator, announces the job to every node's worker pool, and assembles the
%%% output COG on completion. Job state is in-memory (persistence is a later slice).
-module(velora_job_manager).
-behaviour(gen_server).

-export([start_link/0, submit/1, status/1, list/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(job, {id, status = running, total = 0, coord, out_vsi, tile_paths = [], error}).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec submit(map()) -> {ok, binary()} | {error, term()}.
submit(Req) -> gen_server:call(?MODULE, {submit, Req}, infinity).

-spec status(binary()) -> map() | {error, not_found}.
status(JobId) -> gen_server:call(?MODULE, {status, JobId}, infinity).

-spec list() -> [map()].
list() -> gen_server:call(?MODULE, list, infinity).

init([]) -> {ok, #{}}.

handle_call({submit, Req}, _From, Jobs) ->
    case start_job(Req) of
        {ok, Job}      -> {reply, {ok, Job#job.id}, Jobs#{Job#job.id => Job}};
        {error, _} = E -> {reply, E, Jobs}
    end;
handle_call({status, Id}, _From, Jobs) ->
    case Jobs of
        #{Id := J} -> {reply, job_view(J, Jobs), Jobs};
        _          -> {reply, {error, not_found}, Jobs}
    end;
handle_call(list, _From, Jobs) ->
    {reply, [job_view(J, Jobs) || J <- maps:values(Jobs)], Jobs}.

handle_cast({completed, Id, TilePaths}, Jobs) ->
    case Jobs of
        #{Id := J} ->
            OutVsi = J#job.out_vsi,
            case velora_storage:assemble(OutVsi, TilePaths) of
                {ok, _}     -> {noreply, Jobs#{Id => J#job{status = done, tile_paths = TilePaths}}};
                {error, E}  -> {noreply, Jobs#{Id => J#job{status = error, error = E}}}
            end;
        _ -> {noreply, Jobs}
    end;
handle_cast({failed, Id, Reason}, Jobs) ->
    case Jobs of
        #{Id := J} -> {noreply, Jobs#{Id => J#job{status = error, error = Reason}}};
        _ -> {noreply, Jobs}
    end.

handle_info(_I, S) -> {noreply, S}.
terminate(_R, _S) -> ok.

start_job(#{op := Op, sources := Sources, out_uri := OutUri} = Req) ->
    {TW, TH} = maps:get(tile, Req, velora_config:tile()),
    [#{uri := FirstUri} | _] = Sources,
    SceneVsi = velora_storage:to_vsi(FirstUri),
    case velora_storage:scene_meta(SceneVsi) of
        {ok, #{width := W, height := H, gt := GT, srs := Srs, dtype := DType}} ->
            Id = new_id(),
            OutVsi = velora_storage:to_vsi(OutUri),
            OutBase = filename:rootname(OutVsi) ++ "_tiles",
            _ = filelib:ensure_dir(filename:join(OutBase, "x")),
            Tiles = rast_tiling:tile_grid(W, H, TW, TH),
            Ctx = #{op => Op, out_base => OutBase, sources => Sources,
                    gt => GT, srs => Srs, dtype => DType},
            Mgr = self(),
            OnDone = fun(Acked) ->
                Paths = [tile_path(OutBase, X, Y) || #{x := X, y := Y} <- Acked],
                gen_server:cast(Mgr, {completed, Id, Paths})
            end,
            {ok, C} = velora_coordinator:start_link(
                        #{tiles => Tiles, ctx => Ctx, on_done => OnDone}),
            announce(C),
            {ok, #job{id = Id, total = length(Tiles), coord = C, out_vsi = OutVsi}};
        {error, E} ->
            {error, E}
    end.

announce(Coordinator) ->
    _ = velora_worker_pool:take(Coordinator),
    N = velora_config:workers_per_node(),
    [gen_server:cast({velora_worker_pool, Node}, {take, Coordinator, N})
     || Node <- nodes()],
    ok.

tile_path(OutBase, X, Y) ->
    filename:join(OutBase, lists:flatten(io_lib:format("tile_~w_~w.tif", [X, Y]))).

job_view(#job{id = Id, status = St, total = T, coord = C, out_vsi = O, error = E}, _Jobs) ->
    Done = case (St =:= running andalso is_pid(C) andalso is_process_alive(C)) of
               true  -> element(1, velora_coordinator:progress(C));
               false -> T
           end,
    #{job_id => Id, status => St, progress => #{done => Done, total => T},
      result_uri => O, error => E}.

new_id() ->
    list_to_binary(integer_to_list(erlang:system_time(millisecond))
                   ++ "-" ++ integer_to_list(erlang:unique_integer([positive]))).
