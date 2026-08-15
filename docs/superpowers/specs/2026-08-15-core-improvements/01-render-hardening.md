# 01 — /render hardening (SSRF + DoS)

## Problem

`POST /render` (and the agent `tiles`/`ndvi`/`info` intents) call
`velora_web:prepare/1` → `velora_storage:cmd("gdalwarp"/"gdal_translate", ...)`
on a **user-supplied URI**. Three gaps make this dangerous on an exposed deploy:

1. **Scheme allowlist defaults to permissive.** `velora_web:allowed/1` reads app
   env `allowed_schemes`; when unset, all schemes pass. So `file:///etc/hosts`,
   `http://169.254.169.254/…`, `http://127.0.0.1:PORT/…` are all fetchable
   (SSRF / local file read) unless an operator has already locked it down.
2. **No concurrency cap.** Every request synchronously spawns GDAL subprocesses.
   A handful of concurrent `/render` calls against large remote COGs saturate
   CPU/RAM/disk (the Pi has 4 GB) — a trivial DoS.
3. **No source-size / fetch-timeout guard.** A caller can point velora at an
   enormous or a hanging remote raster; the warp runs unbounded.

## Design

### 1. Default-deny schemes
Change the effective default of `allowed_schemes` from "unset ⇒ all allowed" to
a safe allowlist: `[https, s3, gs, work]` (blocks `file` and plain `http`).
`work://` (internal uploads) and object storage stay allowed; the JWST sample is
origin-relative https. Keep it operator-overridable via app env. Document the
change (behavior change: `file://`/`http://` sources now rejected by default).

`allowed/1` and `scheme/1` already exist; only the default in the lookup changes:
```erlang
allowed(Uri) -> lists:member(scheme(Uri),
    application:get_env(velora, allowed_schemes, [<<"https">>,<<"s3">>,<<"gs">>,<<"work">>])).
```
(Match the existing scheme representation — binary vs atom — read `scheme/1`.)

### 2. Concurrency limiter
New `velora_render_limiter` gen_server holding N tokens
(`max_concurrent_renders`, default 4; on the Pi set lower). `velora_render_h`
(and the agent path) wrap the prepare in `with_slot/1`:
- `acquire()` — non-blocking; returns `ok` or `busy` when no token free (bounded
  wait `render_queue_timeout_ms`, default 5000, via a monitored checkout queue).
- On `busy`/timeout the HTTP layer replies **503** `{"error":"overloaded"}`.
- `release()` in an `after`/monitor so a crashed request frees its token.

Interface:
```erlang
velora_render_limiter:with_slot(fun() -> velora_web:prepare(Uri) end).
%% -> {ok, Result} | {error, overloaded}
```
Add the gen_server to `velora_sup`. Config: `max_concurrent_renders`,
`render_queue_timeout_ms`.

### 3. Source bound + timeout
Before warping, `prepare_1/1` already calls `raw_info/1` (gdalinfo). Use it to
reject oversized sources: if `width*height > max_source_megapixels*1_000_000`
(default 500 MP), return `{error, {source_too_large, MP}}`. Set GDAL fetch
timeouts in `velora_storage:gdal_env/0`: `GDAL_HTTP_TIMEOUT`,
`GDAL_HTTP_CONNECTTIMEOUT` (e.g. 30 s), and cap redirects. Config:
`max_source_megapixels`.

## Config summary (app env)

| key | default | meaning |
|-----|---------|---------|
| `allowed_schemes` | `[https,s3,gs,work]` | permitted source schemes (was: unset⇒all) |
| `max_concurrent_renders` | 4 | simultaneous GDAL prepares |
| `render_queue_timeout_ms` | 5000 | wait for a slot before 503 |
| `max_source_megapixels` | 500 | reject larger sources pre-warp |

## Testing

- `allowed/1` default now denies `file://`/`http://`, allows `https/s3/gs/work`
  (pure test, no GDAL).
- `velora_render_limiter`: acquire N tokens → N+1th returns busy; released token
  frees a slot; a crashed holder (killed pid) frees its token (monitor).
- `prepare/1` rejects an oversized source — unit-test the size check with a
  stubbed `raw_info` map (`#{<<"size">> => [100000,100000]}`) → `source_too_large`
  without invoking GDAL.
- Handler-level: a `file://` query to `/render` returns 4xx; an over-limit
  scenario returns 503 (can be exercised against the limiter directly).

## Risks / notes

- **Behavior change**: existing callers using `file://` or `http://` break
  unless they set `allowed_schemes`. Call this out in the changelog/README.
- The limiter must never leak tokens — always release via monitor, not just
  `after`, since the caller may be a cowboy process that dies mid-request.
