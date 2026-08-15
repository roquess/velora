# 04 — bounded tile cache (on the fulgurance NIF)

**Depends on:** 03 (`velora_cache`).

## Problem

`velora_web:tile/4` caches rendered PNG tiles on disk under `work_dir/tc/` and
relies solely on the janitor's TTL sweep to reclaim space. Between sweeps the
tile directory is **unbounded**: a client panning a large scene can write
thousands of PNGs. There is also a disk round-trip on every cache hit.

## Design

Introduce an in-memory, capacity-bounded tile cache in front of (or replacing)
the disk cache, using a `velora_cache` instance:

- Create at startup: `velora_cache:new(tiles, #{capacity => TileCap,
  policy => twoq, prefetch => none})`. `TileCap` from app env
  `tile_cache_entries` (default 2048; on the Pi lower).
- Key: `<<Id/binary,"/",Z,"/",X,"/",Y>>` (a canonical binary of the tile
  coords). Value: the PNG bytes.
- `tile/4` flow: `velora_cache:get(tiles, K)` →
  - `{ok, Png}` → serve (memory hit, no disk, no GDAL);
  - `miss` → render via GDAL (as today), `velora_cache:put(tiles, K, Png)`,
    serve.

### Disk cache: keep as optional L2 or drop?
Default v1: **memory-only** bounded cache; remove the `tc/*.png` disk writes and
the janitor's `tc/*.png` sweep pattern (the prepared COGs are still swept).
Rationale: tiles are cheap to re-render from the local COG (~120 ms) and the
memory cache with 2Q keeps the hot set; disk tiles added durability of little
value while growing unbounded. Keep a config flag `tile_disk_cache => false`
(default) to re-enable the disk L2 if a deploy wants warm restarts.

## Config (app env)

| key | default | meaning |
|-----|---------|---------|
| `tile_cache_entries` | 2048 | max tiles held in memory |
| `tile_disk_cache` | false | also persist tiles to `tc/` (L2) |

## Testing

- NIF-gated: warm a tile (render once), assert the second `tile/4` for the same
  coords is served without spawning GDAL (spy: check no new file / a render
  counter, or assert latency/monotonic call count via a small seam).
- Capacity: with `tile_cache_entries => 2`, request 3 distinct tiles, assert the
  first is evicted (a subsequent request re-renders — observable via the render
  seam).
- Cache key correctness: different `{id,z,x,y}` never collide.

## Risks / notes

- Removing the disk cache changes restart behavior (cold cache after restart).
  The `tile_disk_cache` flag preserves the old behavior for anyone who wants it.
- Ensure the cache is per-node (each node renders its own tiles); with the
  render-offload registry a tile is served by the node holding the COG, so its
  memory cache is the right place.
