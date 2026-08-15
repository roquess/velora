# 07 — observability

**Depends on:** 03/04 (cache stats).

## Problem

velora exposes `/health` and `/info` (node/nodes/workers/jobs summary) but no
operational metrics: cache hit rates, render/tile latencies, prepare counts,
limiter rejections. Debugging performance or capacity on the Pi is guesswork.

## Design

### `/metrics` endpoint
Add `GET /metrics` returning a compact JSON (not Prometheus text v1; JSON keeps
the zero-dependency stance — a Prometheus exposition format can come later):

```json
{
  "jobs":   {"total":N,"running":N,"done":N,"error":N},
  "tiles":  {"hits":N,"misses":N,"len":N,"capacity":N},
  "prepare":{"hits":N,"misses":N,"len":N,"capacity":N},
  "render": {"in_flight":N,"rejected":N,"slots":N},
  "uptime_ms": N
}
```
- `tiles`/`prepare` come from `velora_cache:stats/1` (04/05).
- `render` from `velora_render_limiter` (01): current in-flight, cumulative
  `rejected` (503s), total `slots`.
- `jobs` from the existing job-manager summary used by `/info`.

### Structured logging
Standardize a few high-value `logger` events with structured metadata (maps),
at `notice`/`warning`:
- render start/finish with `uri_scheme`, `duration_ms`, `intent`;
- limiter rejection (`overloaded`);
- prepare memo hit/miss;
- source rejected (`scheme_not_allowed`, `source_too_large`).
Keep messages English, one map per event, no PII (log the scheme, not the full
signed URL).

## Config (app env)

| key | default | meaning |
|-----|---------|---------|
| `metrics_enabled` | true | serve `/metrics` |

## Testing

- `GET /metrics` returns 200 with the documented keys and integer values
  (start the app, hit it; NIF-gated for the cache sections — if the cache NIF
  isn't loaded, those sections report zeros rather than crashing).
- A render + a limiter rejection increment the respective counters (drive the
  limiter to `busy`, assert `render.rejected` increments).

## Risks / notes

- Counters must be cheap (atomics / ETS counters), never a bottleneck on the hot
  tile path.
- `/metrics` may expose capacity/usage; it carries no source URLs or user data.
  If a deploy wants it private, `metrics_enabled => false` disables the route.
