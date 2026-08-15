%%% @doc Token semaphore bounding concurrent heavy GDAL prepares (server-side
%%% warps triggered by `velora_web:prepare/1' and `velora_web:prepare_ndvi/2').
%%% Unbounded concurrency here is a DoS on constrained hosts (e.g. a 4 GB Pi):
%%% each prepare spawns external `gdalwarp'/`gdal_translate' subprocesses.
%%%
%%% Holds `max_concurrent_renders' tokens (app env, default 4). `with_slot/1'
%%% acquires a token (blocking up to `render_queue_timeout_ms' ms, app env
%%% default 5000); if none frees up in time it returns `{error, overloaded}'
%%% without running the fun, so callers can shed load with an HTTP 503 instead
%%% of piling up GDAL subprocesses.
%%%
%%% Token-leak safety: the caller (not `with_slot' itself) is monitored while
%%% it holds a token, so a token is reclaimed and handed to the next waiter
%%% even if the holder crashes mid-render.
-module(velora_render_limiter).
-behaviour(gen_server).

-export([start_link/0, with_slot/1, in_flight/0, rejected_count/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(NAME, ?MODULE).

-record(state, {max        :: pos_integer(),
                 free       :: non_neg_integer(),
                 in_use     :: #{reference() => {pid(), reference()}},
                 waiters    :: queue:queue({reference(), pid(), reference()}),
                 rejected   :: non_neg_integer()}).

%% @doc Start the limiter, registered locally. Reads `max_concurrent_renders'
%% (default 4) from the `velora' app env at startup.
-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?NAME}, ?MODULE, [], []).

%% @doc Run `Fun' while holding a token, blocking up to
%% `render_queue_timeout_ms' (app env, default 5000) for one to free up.
%% Returns `Fun()''s value, or `{error, overloaded}' if no token was
%% available in time (Fun is NOT run in that case). The token is always
%% released afterward, even if `Fun' raises.
%%
%% Falls back to running `Fun' directly, uncapped, when the limiter isn't
%% started (e.g. unit tests exercising `velora_web:prepare/1' without the
%% supervised app running) — so those keep working unlimited, as before.
-spec with_slot(fun(() -> T)) -> T | {error, overloaded}.
with_slot(Fun) ->
    case whereis(?NAME) of
        undefined -> Fun();
        _Pid ->
            Timeout = queue_timeout_ms(),
            case acquire(Timeout) of
                {ok, Ref} ->
                    try Fun() after release(Ref) end;
                overloaded ->
                    {error, overloaded}
            end
    end.

%% @doc Number of tokens currently in use.
-spec in_flight() -> non_neg_integer().
in_flight() -> gen_server:call(?NAME, in_flight).

%% @doc Number of `with_slot/1' calls shed with `{error, overloaded}' so far.
-spec rejected_count() -> non_neg_integer().
rejected_count() -> gen_server:call(?NAME, rejected_count).

%% Acquire a token, blocking up to Timeout ms server-side. The gen_server
%% either replies {ok, Ref} immediately (a free token) or enqueues this
%% caller and replies later on release/DOWN, or {error, overloaded} once its
%% own queue timer fires. A generous call timeout leaves the server (not the
%% client) authoritative on when the wait has expired.
acquire(Timeout) ->
    case gen_server:call(?NAME, {acquire, Timeout}, Timeout + 1000) of
        {ok, Ref}  -> {ok, Ref};
        overloaded -> overloaded
    end.

release(Ref) -> gen_server:call(?NAME, {release, Ref}).

%% ---- gen_server ----

init([]) ->
    {ok, #state{max      = max_concurrent(),
                free     = max_concurrent(),
                in_use   = #{},
                waiters  = queue:new(),
                rejected = 0}}.

handle_call({acquire, _Timeout}, {Pid, _} = _From, S = #state{free = Free}) when Free > 0 ->
    Ref = make_ref(),
    MonRef = erlang:monitor(process, Pid),
    {reply, {ok, Ref}, S#state{free   = Free - 1,
                                in_use = maps:put(Ref, {Pid, MonRef}, S#state.in_use)}};
handle_call({acquire, Timeout}, {Pid, _} = From, S = #state{waiters = Waiters}) ->
    %% no free token: enqueue this caller with a timer for the queue timeout.
    WRef = make_ref(),
    TRef = erlang:send_after(Timeout, self(), {queue_timeout, WRef}),
    {noreply, S#state{waiters = queue:in({WRef, From, Pid, TRef}, Waiters)}};
handle_call({release, Ref}, _From, S = #state{in_use = InUse}) ->
    case maps:take(Ref, InUse) of
        {{_Pid, MonRef}, InUse1} ->
            erlang:demonitor(MonRef, [flush]),
            S1 = reclaim(S#state{in_use = InUse1}),
            {reply, ok, S1};
        error ->
            {reply, ok, S}
    end;
handle_call(in_flight, _From, S = #state{in_use = InUse}) ->
    {reply, maps:size(InUse), S};
handle_call(rejected_count, _From, S = #state{rejected = R}) ->
    {reply, R, S}.

handle_cast(_Msg, S) -> {noreply, S}.

handle_info({queue_timeout, WRef}, S = #state{waiters = Waiters}) ->
    case take_waiter(WRef, Waiters) of
        {found, {_WRef, From, _Pid, _TRef}, Waiters1} ->
            gen_server:reply(From, overloaded),
            {noreply, S#state{waiters = Waiters1, rejected = S#state.rejected + 1}};
        not_found ->
            %% already granted (the timer fired after the waiter was served)
            {noreply, S}
    end;
handle_info({'DOWN', MonRef, process, _Pid, _Reason}, S = #state{in_use = InUse}) ->
    case find_by_mon(MonRef, InUse) of
        {ok, Ref} ->
            S1 = reclaim(S#state{in_use = maps:remove(Ref, InUse)}),
            {noreply, S1};
        error ->
            {noreply, S}
    end;
handle_info(_Msg, S) -> {noreply, S}.

terminate(_Reason, _S) -> ok.
code_change(_Old, S, _Extra) -> {ok, S}.

%% ---- internal ----

%% A token freed up (release or DOWN): hand it to the next waiter, if any,
%% else give it back to the free pool.
reclaim(S = #state{waiters = Waiters}) ->
    case queue:out(Waiters) of
        {{value, {_WRef, From, Pid, TRef}}, Waiters1} ->
            _ = erlang:cancel_timer(TRef),
            Ref = make_ref(),
            MonRef = erlang:monitor(process, Pid),
            gen_server:reply(From, {ok, Ref}),
            S#state{waiters = Waiters1,
                    in_use  = maps:put(Ref, {Pid, MonRef}, S#state.in_use)};
        {empty, _} ->
            S#state{free = S#state.free + 1}
    end.

take_waiter(WRef, Waiters) ->
    List = queue:to_list(Waiters),
    case lists:keytake(WRef, 1, List) of
        {value, Item, Rest} -> {found, Item, queue:from_list(Rest)};
        false               -> not_found
    end.

find_by_mon(MonRef, InUse) ->
    Found = maps:fold(fun(Ref, {_Pid, M}, Acc) ->
                             case Acc of
                                 error when M =:= MonRef -> {ok, Ref};
                                 Other -> Other
                             end
                       end, error, InUse),
    Found.

max_concurrent() ->
    application:get_env(velora, max_concurrent_renders, 4).

queue_timeout_ms() ->
    application:get_env(velora, render_queue_timeout_ms, 5000).
