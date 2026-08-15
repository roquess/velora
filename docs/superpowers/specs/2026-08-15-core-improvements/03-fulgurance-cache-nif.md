# 03 — fulgurance cache NIF (`velora_cache`)

## Goal

A bounded, scan-resistant in-memory cache for velora, backed by the user's Rust
library [fulgurance](https://github.com/roquess/fulgurance) via a rustler NIF.
Reused by the tile cache (04) and prepare memoization (05).

## fulgurance API (from docs.rs)

`FulgranceCache<K,V,C,P>` with:
`new(policy, prefetch)`, `get(&mut K)->Option<V>`, `insert(K,V)`,
`remove(&mut K)->Option<V>`, `stats()->&CacheStats`, `reset_stats()`,
`len()`, `capacity()`, `clear()`. Policies live in `policies` (LRU, LFU, FIFO,
ARC, Clock, 2Q, SLRU, CAR, MRU, Random); prefetch in `prefetch` (None,
Sequential, Stride, Markov, …).

**Critical constraint:** `FulgranceCache` is `!Send + !Sync`. It therefore
CANNOT be stored in a `rustler::ResourceArc<Mutex<…>>` (that requires `Send`).

## Design: actor thread per cache

Each named cache runs on its own dedicated OS thread that **owns** the
`FulgranceCache`. The NIF resource holds only a `Sender<Cmd>` (Send). NIF calls
send a command with a `oneshot`-style reply channel and block on the reply.
Access is naturally serialized (the cache isn't thread-safe anyway), and `!Send`
is sidestepped because the cache never leaves its thread.

```
Erlang NIF  --Cmd{get|insert|remove|clear|stats, reply}-->  crossbeam::channel
                                                              |
                                              [cache thread owns FulgranceCache]
                                                              |
Erlang NIF  <---------------- reply (bytes / stats) ----------+
```

Keys and values are **binaries** (`Vec<u8>` / `Binary`), so the NIF is generic:
tile PNGs and small metadata blobs both fit. Policy + capacity are chosen at
cache creation.

### Erlang API (`velora_cache` module wrapping the NIF)

```erlang
-spec new(Name :: atom(), Opts :: map()) -> ok | {error, term()}.
%% Opts: #{capacity => pos_integer(), policy => lru|twoq|arc|slru|clock|lfu|fifo,
%%         prefetch => none|sequential}
-spec put(Name :: atom(), Key :: binary(), Val :: binary()) -> ok.
-spec get(Name :: atom(), Key :: binary()) -> {ok, binary()} | miss.
-spec delete(Name :: atom(), Key :: binary()) -> ok.
-spec clear(Name :: atom()) -> ok.
-spec stats(Name :: atom()) -> #{hits => integer(), misses => integer(),
                                 len => integer(), capacity => integer()}.
```

A registry (a `dashmap`/`Mutex<HashMap<atom_name, Sender>>` in Rust, or an
Erlang-side ETS mapping name→ResourceArc) resolves a name to its cache thread.
Prefer an **Erlang-side registry**: `new/2` returns a resource stored in a
persistent_term / ETS under `Name`, and the other functions look it up. Keeps
the Rust side a plain per-cache actor.

### Loader (mirror sied/rast)

The NIF `.so`/`.dll` follows the same platform-suffixed loading the other velora
NIFs use (`velora_cache-<os>-<arch>`). Ship prebuilt for the common targets and
**build from source on unsupported platforms** (see the note in 00-roadmap and
the Pi experience: linux-aarch64 was not prebuilt). Add a `native/velora_cache`
Rust crate (rustler) plus a rebar `pre_hooks`/`provider_hooks` `cargo build`
fallback so `rebar3 compile` produces the `.so` when no prebuilt one matches —
avoiding the manual `cargo build` dance we hit on the Pi.

## Testing

- Rust unit tests in the crate: put/get/miss, capacity eviction (insert
  capacity+1, oldest evicted per policy), remove, clear, stats counts.
- Erlang eunit (`velora_cache_tests`, NIF-gated — skip cleanly if the NIF
  doesn't load, mirroring the rast/sied guards): `new` a small LRU cache,
  `put`/`get` roundtrip returns the exact binary, `get` a missing key → `miss`,
  fill past capacity → early key evicted, `stats` reflects hits/misses/len.

## Risks / notes

- **Portability cost.** This adds a third Rust NIF to build per platform. The
  build-from-source fallback (rebar hook) is part of this spec specifically to
  not repeat the Pi pain; it must be verified on linux-aarch64 conceptually
  (documented steps) even if CI only builds x86_64.
- Big binaries cross the channel twice (into the thread, back out). For tile
  PNGs (tens of KB) this is fine. If profiling shows copies hurt, revisit with a
  shared `Arc<Vec<u8>>` returned as a sub-binary — out of scope for v1.
- Choose **2Q** (or ARC) as the default tile policy: scan-resistant, so a user
  panning across a whole scene doesn't evict the hot centre.
