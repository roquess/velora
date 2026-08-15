# 05 — prepare memoization by source

**Depends on:** 03 (`velora_cache`).

## Problem

`velora_web:prepare_1/1` mints `Id = erlang:unique_integer(...)` on **every**
call, so rendering the same source URI twice re-runs the full
gdalwarp + gdal_translate and writes a second `web_<id>` COG. Repeated views of
the same scene waste CPU and accumulate COGs on disk (only reclaimed by the TTL
janitor). There is no dedup.

## Design

Memoize `prepare/1` on a stable key derived from the source:

- Key: `Hash = crypto:hash(sha256, canonical(Uri))` (hex binary).
  `canonical/1` normalizes the URI (trim; keep scheme+path; do NOT include
  volatile query tokens like signed-S3 credentials — for `s3://`/`https://`
  strip query string when hashing, or hash the whole URI if that risks
  collisions across differently-authed same-path objects; default: hash the
  full URI, documented).
- Memo store: `velora_cache:new(prepare, #{capacity => PrepEntries,
  policy => lru})`. Value: an encoded `#{id, bounds, native_zoom}` (term_to_binary).
- `prepare/1`:
  1. compute `Hash`;
  2. `velora_cache:get(prepare, Hash)`:
     - `{ok, Bin}` → decode `#{id,bounds,nz}`; **validate the COG still exists**
       (`filelib:is_regular(source_path(Id))`). If present → return it (no warp).
       If the COG was swept → treat as miss.
     - `miss` → run the existing warp, then
       `velora_cache:put(prepare, Hash, term_to_binary(#{id,bounds,nz}))`.

### Coherence with the janitor
The janitor sweeps `web_*`/COGs by TTL. A memoized entry can outlive its COG.
The `is_regular` re-validation above handles that (stale memo ⇒ re-warp). To
reduce churn, set the prepare memo capacity/TTL sympathetically and have the
janitor optionally `velora_cache:delete(prepare, Hash)` when it deletes a COG
(nice-to-have; the re-validation already makes it correct without this).

## Config (app env)

| key | default | meaning |
|-----|---------|---------|
| `prepare_cache_entries` | 256 | memoized prepared sources |

## Testing

- NIF-gated + GDAL-gated: `prepare` the same local source twice; assert the
  second returns the **same `Id`** and does not spawn a new warp (render seam /
  no new `web_*` file created on the second call).
- Stale-COG path: memoize, delete the COG file, `prepare` again → new warp, new
  or same id, valid result (no crash).
- Distinct sources produce distinct ids.
- `canonical/1` is pure and unit-tested (trim, scheme handling).

## Risks / notes

- **Security interaction with 01:** two different callers with different S3
  credentials pointing at the same `s3://bucket/key` would share a memoized
  render. Since the object content is the same, sharing the rendered COG is
  acceptable; document it. Do not memoize across *different* object paths.
- Keep the memo per-node (like the tile cache). Under render-offload, the node
  that prepared the COG owns both the COG and the memo entry.
