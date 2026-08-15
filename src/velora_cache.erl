%%%-------------------------------------------------------------------
%%% @doc velora_cache - bounded in-memory cache backed by fulgurance.
%%%
%%% A thin Erlang API over a rustler NIF wrapping the Rust `fulgurance' cache.
%%% Keys and values are binaries. Each named cache is an independent bounded
%%% cache with a chosen eviction policy (default 2Q, which is scan-resistant so
%%% a pan across a whole scene does not evict the hot centre).
%%%
%%% == Design ==
%%%
%%% The NIF side is a plain per-cache actor: `new/2' spins up a dedicated OS
%%% thread that owns the (`!Send') `FulgranceCache' and returns a resource
%%% holding only a channel `Sender'. The name->resource mapping lives entirely
%%% on the Erlang side in a `persistent_term', so the Rust side needs no global
%%% registry.
%%%
%%% The NIF `.so'/`.dll' is loaded the same platform-suffixed way the other
%%% velora NIFs (sied, rast) are: a `velora_cache-<os>-<arch>' file under the
%%% velora app's `priv/', selected at load time.
%%% @end
%%%-------------------------------------------------------------------
-module(velora_cache).

-export([
    new/2,
    put/3,
    get/2,
    delete/2,
    clear/1,
    stats/1
]).

%% Raw NIFs (do not call directly; use the name-based API above).
-export([
    nif_new/2,
    nif_get/2,
    nif_put/3,
    nif_delete/2,
    nif_clear/1,
    nif_stats/1
]).

-on_load(init/0).

-define(APPNAME, velora).
-define(POLICIES, [lru, twoq, arc, slru, clock, lfu, fifo]).

-type policy() :: lru | twoq | arc | slru | clock | lfu | fifo.
-type opts() :: #{
    capacity => pos_integer(),
    policy => policy(),
    prefetch => none | sequential
}.

%%%===================================================================
%%% NIF loading (mirrors sied/rast)
%%%===================================================================

%% @private
init() ->
    PrivDir = case code:priv_dir(?APPNAME) of
        {error, bad_name} ->
            case filelib:is_dir(filename:join(["..", priv])) of
                true  -> filename:join(["..", priv]);
                false -> "priv"
            end;
        Dir ->
            Dir
    end,
    Base = "velora_cache-" ++ os_tag() ++ "-" ++ arch_tag(),
    erlang:load_nif(filename:join(PrivDir, Base), 0).

os_tag() ->
    case os:type() of
        {unix, darwin} -> "darwin";
        {win32, _}     -> "windows";
        {unix, _}      -> "linux"
    end.

arch_tag() ->
    Low = string:lowercase(erlang:system_info(system_architecture)),
    case string:find(Low, "aarch64") =/= nomatch
        orelse string:find(Low, "arm64") =/= nomatch of
        true  -> "aarch64";
        false -> "x86_64"
    end.

%%%===================================================================
%%% Public API (name-based; Erlang-side registry)
%%%===================================================================

%% @doc Create a named cache. Opts:
%% <ul>
%%   <li>`capacity' :: pos_integer() (default 1024)</li>
%%   <li>`policy'   :: lru|twoq|arc|slru|clock|lfu|fifo (default twoq)</li>
%%   <li>`prefetch' :: none|sequential (accepted; only `none' is wired in v1)</li>
%% </ul>
%% Returns `ok', or `{error, Reason}' if the NIF is not loaded or Opts invalid.
-spec new(Name :: atom(), Opts :: opts()) -> ok | {error, term()}.
new(Name, Opts) when is_atom(Name), is_map(Opts) ->
    Capacity = maps:get(capacity, Opts, 1024),
    Policy = maps:get(policy, Opts, twoq),
    case valid(Capacity, Policy) of
        ok ->
            PolicyBin = atom_to_binary(Policy, utf8),
            try nif_new(Capacity, PolicyBin) of
                Res ->
                    persistent_term:put(key(Name), Res),
                    ok
            catch
                error:nif_not_loaded -> {error, nif_not_loaded}
            end;
        {error, _} = Err ->
            Err
    end;
new(_Name, _Opts) ->
    {error, badarg}.

%% @doc Store `Val' under `Key' in cache `Name'.
-spec put(Name :: atom(), Key :: binary(), Val :: binary()) -> ok.
put(Name, Key, Val) when is_binary(Key), is_binary(Val) ->
    nif_put(resource(Name), Key, Val).

%% @doc Fetch `Key' from cache `Name'. Returns `{ok, Bin}' or `miss'.
-spec get(Name :: atom(), Key :: binary()) -> {ok, binary()} | miss.
get(Name, Key) when is_binary(Key) ->
    nif_get(resource(Name), Key).

%% @doc Remove `Key' from cache `Name' (idempotent).
-spec delete(Name :: atom(), Key :: binary()) -> ok.
delete(Name, Key) when is_binary(Key) ->
    nif_delete(resource(Name), Key).

%% @doc Drop all entries (and reset stats) of cache `Name'.
-spec clear(Name :: atom()) -> ok.
clear(Name) ->
    nif_clear(resource(Name)).

%% @doc Return counters for cache `Name'.
-spec stats(Name :: atom()) ->
    #{hits => integer(), misses => integer(),
      len => integer(), capacity => integer()}.
stats(Name) ->
    {Hits, Misses, Len, Capacity} = nif_stats(resource(Name)),
    #{hits => Hits, misses => Misses, len => Len, capacity => Capacity}.

%%%===================================================================
%%% Internal
%%%===================================================================

key(Name) -> {?MODULE, Name}.

resource(Name) ->
    persistent_term:get(key(Name)).

valid(Capacity, Policy) ->
    case is_integer(Capacity) andalso Capacity >= 1 of
        false -> {error, {invalid_capacity, Capacity}};
        true ->
            case lists:member(Policy, ?POLICIES) of
                true  -> ok;
                false -> {error, {invalid_policy, Policy}}
            end
    end.

%%%===================================================================
%%% NIF stubs (replaced at load; fall back to nif_not_loaded)
%%%===================================================================

%% @private
nif_new(_Capacity, _PolicyBin) ->
    erlang:nif_error(nif_not_loaded).

%% @private
nif_get(_Res, _Key) ->
    erlang:nif_error(nif_not_loaded).

%% @private
nif_put(_Res, _Key, _Val) ->
    erlang:nif_error(nif_not_loaded).

%% @private
nif_delete(_Res, _Key) ->
    erlang:nif_error(nif_not_loaded).

%% @private
nif_clear(_Res) ->
    erlang:nif_error(nif_not_loaded).

%% @private
nif_stats(_Res) ->
    erlang:nif_error(nif_not_loaded).
