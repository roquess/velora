# 08 — full-resolution NDVI via the distributed job engine

## Problem

`velora_web:prepare_ndvi/2` computes NDVI in a single shot on a grid capped at
1024 px (see 03/Task-4 of the Emergence work). That is fine for a quick preview
but throws away resolution on large Sentinel scenes, and it does not use
velora's existing tiled, distributed, fault-tolerant NDVI pipeline
(`velora_job_manager` / `velora_coordinator` / `velora_worker` scatter-gather).

## Design

Route NDVI through the real job engine and serve the result as tiles:

1. **Submit a job.** `velora_agent:do(ndvi, ...)` (or a new
   `velora_web:ndvi_job/2`) submits a tiled NDVI job over the resolved
   red+nir sources via `velora_job_manager` — the same op the original NDVI
   tool ran (`apply_op(ndvi, [Nir, Red])`), producing a full-resolution NDVI
   COG in `work_dir`.
2. **Async contract.** NDVI at full res is not a sub-second synchronous call.
   The agent `ndvi` intent returns a card with a `job` id immediately:
   ```json
   {"type":"ndvi","status":"processing","job":"<id>",
    "poll":"/jobs/<id>","result_tiles":"/tiles/<id>/{z}/{x}/{y}"}
   ```
   On completion the job's output COG is registered (like `prepare`) so
   `GET /tiles/<id>/...` and `GET /jobs/<id>` work. A synchronous convenience
   mode (`wait=true`, bounded) may block up to a timeout then fall back to the
   async card.
3. **Preview + full-res.** Keep `prepare_ndvi/2` as the instant low-res preview
   (returned in the same card as `preview_tiles`) while the full-res job runs —
   best of both: immediate visual, sharp result when ready.
4. **Stats.** Full-res stats come from the job's reduction (mean/min/max +
   histogram) that the pipeline already computes, not the capped preview.

## Config (app env)

| key | default | meaning |
|-----|---------|---------|
| `ndvi_fullres` | true | run the tiled job; false ⇒ preview-only (current behavior) |
| `ndvi_wait_timeout_ms` | 0 | if >0, block up to this long for a synchronous result |

## Testing

- GDAL-gated: submit an NDVI job over the 2-band fixture (red=b1, nir=b2), poll
  to completion, assert a valid NDVI COG is produced and `GET /tiles/<id>/0/0/0`
  returns a PNG; stats present from the reduction.
- The agent `ndvi` intent returns a `processing` card with `job`/`poll`/tiles
  when `ndvi_fullres` and the job is not instantly done; returns the completed
  card when done (or under `wait`).
- `ndvi_fullres => false` still returns the capped preview (regression guard for
  the existing path).

## Risks / notes

- Biggest item; do last. It couples the viewer/agent path to the async job
  lifecycle — keep the sync preview so clients that expect an immediate card
  still get one.
- Full-res over two remote Sentinel COGs is heavy; the concurrency limiter (01)
  and the render-offload (existing) apply — a job can run on a beefier peer.
- Result COGs are swept by the janitor TTL like other prepared COGs; the
  prepare-memoization (05) key scheme extends naturally to `{ndvi, red, nir}`.
