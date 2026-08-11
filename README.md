# velora

**Distributed satellite-raster processing on the BEAM.** velora is a tool, not a
library: you run it as a cluster of connected Erlang nodes behind an HTTP API,
submit a satellite scene plus an operation, and velora spreads that scene's tiles
across the whole cluster, processes each tile on whatever node picked it up, and
assembles a georeferenced GeoTIFF result.

[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

## Why it's built this way

A single Sentinel-2 band is ~120 million pixels; a scene is far larger. Two ideas
shape velora:

- **Pixels never travel between nodes.** Refc-binaries are only cheap within one
  node — shipping a tile over distributed Erlang would serialize and copy it. So
  velora separates two planes:
  - **Data plane:** each node reads the windows it needs directly from shared
    object storage (S3/MinIO) with GDAL `/vsis3`, and writes its result tiles
    straight back. Data flows storage ↔ node, never node ↔ node.
  - **Control plane:** the Erlang cluster carries only tiny messages — tile
    descriptors (`{x, y, w, h}`) and acknowledgements.
- **Demand-driven pull for latency.** A per-job coordinator holds a queue of
  tiles; workers on every node pull the next tile when they have a free core. A
  faster or less-loaded node naturally pulls more, so one scene finishes as fast
  as the whole cluster can carry it.

The pixel crunching is a thin, fast kernel from
[rast](https://hex.pm/packages/rast) (SIMD NDVI, windowed GDAL I/O, tile
geometry). velora adds the distribution, the HTTP surface, and output assembly.

## Quick start (single node)

```bash
rebar3 shell        # starts the app; HTTP API on :8080
```

Submit an NDVI job (NIR and Red bands of one scene) and poll it:

```bash
curl -XPOST localhost:8080/jobs -H 'content-type: application/json' -d '{
  "op": "ndvi",
  "sources": [ {"uri": "s3://bucket/scene.tif", "band": 8},
               {"uri": "s3://bucket/scene.tif", "band": 4} ],
  "out_uri": "s3://bucket/out/ndvi.tif",
  "tile": [512, 512]
}'
# -> {"job_id": "1723380000000-42"}

curl localhost:8080/jobs/1723380000000-42
# -> {"status":"done","progress":{"done":441,"total":441},"result_uri":"..."}
```

`uri` may be `s3://…` (mapped to GDAL `/vsis3`) or `file://…` for local files.

## HTTP API

| Method & path      | Purpose                                             |
|--------------------|-----------------------------------------------------|
| `POST /jobs`       | Submit a job → `202 {"job_id": …}`                  |
| `GET  /jobs/:id`   | Job status, progress, and result URI                |
| `GET  /jobs`       | List jobs                                           |
| `GET  /cluster`    | Connected nodes                                     |
| `GET  /health`     | Liveness                                            |

## Running a cluster

Every node runs the same release; submit to any node. List the other nodes in
`config/sys.config` (`peers`), or start the nodes with a shared cookie and let
them connect. Only tile descriptors and acks cross the cluster — the pixels stay
between each node and object storage.

```erlang
%% config/sys.config
{peers, ['velora@10.0.0.2', 'velora@10.0.0.3']}
```

## Requirements

- Erlang/OTP 27, rebar3.
- GDAL CLI (`gdalinfo`, `gdal_translate`, `gdalbuildvrt`) on `PATH` or at
  `GDAL_BIN_DIR`.
- Object storage reachable via GDAL `/vsis3` (S3 or MinIO); credentials come from
  the environment (`AWS_*`, or `AWS_S3_ENDPOINT` for MinIO).
- `epmd` running (for distributed clustering).

## Build & test

```bash
rebar3 compile
rebar3 eunit        # unit tests (GDAL-backed ones skip if GDAL is absent)
rebar3 ct           # end-to-end: single-node NDVI + multi-node exactly-once
```

## Scope

This is **slice 1**: NDVI, a georeferenced raster output, fail-fast error
handling, and a statically-configured cluster. Planned next: aggregated
reductions/stats, fault-tolerant retry on node loss, elastic membership, and
per-tile kNN indexing via [kvex](https://hex.pm/packages/kvex).

## License

Apache License 2.0 — see [LICENSE](LICENSE).
