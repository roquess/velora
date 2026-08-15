# velora core improvements — roadmap

**Date:** 2026-08-15
**Scope:** velora core (not the Emergence adapters). Correctness, security,
robustness, performance, DX.

Each item has its own spec file. They are ordered by implementation sequence;
the cache NIF (03) is a prerequisite for the tile cache (04) and prepare
memoization (05).

| # | Spec | Theme | Size | Depends on |
|---|------|-------|------|-----------|
| 01 | [render hardening](01-render-hardening.md) | security + stability | M | — |
| 02 | [test flake fix](02-test-flake-fix.md) | CI reliability | S | — |
| 03 | [fulgurance cache NIF](03-fulgurance-cache-nif.md) | new capability | M | — |
| 04 | [tile cache bound](04-tile-cache-bound.md) | memory/disk bound | S–M | 03 |
| 05 | [prepare memoization](05-prepare-memoization.md) | perf/disk | S–M | 03 |
| 06 | [info card completeness](06-info-card-completeness.md) | contract | S | — |
| 07 | [observability](07-observability.md) | ops | M | 03,04 (stats) |
| 08 | [NDVI full resolution](08-ndvi-fullres.md) | quality | L | — |

## Sequencing rationale

1. **01 first** — `/render` fetches arbitrary user URLs through GDAL with no
   scheme default-deny, no concurrency cap, no source-size/timeout guard. On an
   exposed LAN deploy (the Pi) this is the highest risk. Security + stability.
2. **02** — a flaky coordinator/supervisor teardown test surfaced during the
   Emergence work intermittently reddens CI; fix before piling on changes.
3. **03** — build the `velora_cache` rustler binding around
   [fulgurance](https://github.com/roquess/fulgurance) once; 04 and 05 reuse it.
4. **04, 05** — bound the tile cache and memoize prepare on top of the NIF.
5. **06** — small contract fix (info card gained a real bbox/overviews).
6. **07** — expose cache + job metrics now that the cache reports stats.
7. **08 last** — the biggest change (route full-resolution NDVI through the
   distributed job engine instead of the capped single-shot path).

## Conventions for every item

- English in the repo. `rtk` prefix on shell commands. Commit trailer
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- TDD, `warnings_as_errors` clean, GDAL-gated tests skip when GDAL is absent.
- Each item is built on its own branch, reviewed (spec + quality), merged to
  master with green CI, per subagent-driven-development.
- Execution: brainstorming is complete (this roadmap); each item goes
  spec → writing-plans → subagent-driven when it is picked up.
