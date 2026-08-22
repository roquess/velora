%%% @doc Asynchronous prepare: run the heavy warp in the background and let the
%%% client poll, instead of holding a synchronous request open. `submit/1'
%%% returns a prepare id immediately; a worker runs `velora_render:prepare/1'
%%% (through the render limiter) and stores the result; `status/1' reports
%%% `processing' until it is `{ok, Id, Bounds, NativeZoom}' or `{error, Reason}'.
%%% Finished entries are swept after a TTL so the table stays bounded.
-module(velora_prepare_async).
-behaviour(gen_server).

-export([start_link/0, submit/1, status/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(TAB, ?MODULE).
-define(SWEEP_MS, 60000).
-define(TTL_MS,   600000).

-spec start_link() -> {ok, pid()}.
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Kick off a background prepare; returns its poll id right away.
-spec submit(binary() | string()) -> {ok, binary()}.
submit(Uri) -> gen_server:call(?MODULE, {submit, Uri}).

%% @doc Current state of a prepare id.
-spec status(binary()) ->
        processing | {ok, binary(), [[float()]], integer()} | {error, term()} | not_found.
status(Id) ->
    case ets:lookup(?TAB, Id) of
        [{_, State, _Ts}] -> State;
        []                -> not_found
    end.

%% State is a map of the live workers' monitor refs => prepare id, so a worker
%% that dies before reporting can be turned into an error instead of a row that
%% stays `processing' forever.
init([]) ->
    ets:new(?TAB, [named_table, public, {read_concurrency, true}]),
    erlang:send_after(?SWEEP_MS, self(), sweep),
    {ok, #{}}.

handle_call({submit, Uri}, _From, Refs) ->
    Id = integer_to_binary(erlang:unique_integer([positive])),
    store(Id, processing),
    Self = self(),
    %% spawn_monitor: if the worker crashes/gets killed before it casts {done},
    %% the DOWN below marks the prepare failed so the client stops polling.
    {_Pid, Ref} = spawn_monitor(fun() ->
        Result = try normalize(velora_render:prepare(Uri))
                 catch C:E -> {error, {C, E}} end,
        gen_server:cast(Self, {done, Id, Result})
    end),
    {reply, {ok, Id}, Refs#{Ref => Id}};
handle_call(_R, _F, S) -> {reply, ok, S}.

handle_cast({done, Id, Result}, Refs) ->
    store(Id, Result),
    {noreply, Refs};
handle_cast(_M, S) -> {noreply, S}.

%% Worker exited. On a normal exit the {done} cast has already stored the result
%% (cast is enqueued before the DOWN), so status/1 is no longer `processing' and
%% we leave it. On a crash/kill the row is still `processing' → mark it failed.
handle_info({'DOWN', Ref, process, _Pid, Reason}, Refs) ->
    case maps:take(Ref, Refs) of
        {Id, Refs1} ->
            case status(Id) of
                processing -> store(Id, {error, {worker_died, Reason}});
                _          -> ok
            end,
            {noreply, Refs1};
        error ->
            {noreply, Refs}
    end;
handle_info(sweep, S) ->
    Cutoff = now_ms() - ?TTL_MS,
    %% only sweep finished entries; leave in-flight `processing' ones
    ets:select_delete(?TAB,
        [{{'_', '$1', '$2'}, [{'=/=', '$1', processing}, {'<', '$2', Cutoff}], [true]}]),
    erlang:send_after(?SWEEP_MS, self(), sweep),
    {noreply, S};
handle_info(_I, S) -> {noreply, S}.

terminate(_R, _S) -> ok.

store(Id, State) -> ets:insert(?TAB, {Id, State, now_ms()}).

normalize({ok, Id, Bounds, NZ}) -> {ok, Id, Bounds, NZ};
normalize({error, _} = E)       -> E;
normalize(Other)                -> {error, Other}.

now_ms() -> erlang:monotonic_time(millisecond).
