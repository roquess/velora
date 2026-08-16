# velora

**Distributed satellite-raster processing on the BEAM.** velora is a tool, not a
library: you run it as a cluster of connected Erlang nodes behind an HTTP API,
submit a satellite scene plus an operation, and velora spreads that scene's tiles
across the whole cluster, processes each tile on whatever node picked it up, and
assembles a georeferenced GeoTIFF result — alongside a reduction (summary stats +
histogram) and a per-tile k-NN index you can query for similar regions. Nodes can
join or die mid-job: work is reassigned so the result is always complete and
exactly-once.

![Screenshot](priv/www/assets/screen1.jpg)

[![CI](https://github.com/roquess/velora/actions/workflows/ci.yml/badge.svg)](https://github.com/roquess/velora/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

It also ships a **browser viewer** on the same HTTP port: drop in (or paste a URL
to) any GDAL-readable raster — GeoTIFF/COG, JP2, PNG/JPEG, FITS, georeferenced or
not — and velora warps it to a web-mercator COG server-side and streams it as
on-demand map tiles. Gigapixel images open by fetching only the tiles currently in
view; the browser never loads the whole raster.

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
- **Demand-driven pull for latency.** A per-job coordinator leases tiles; a fixed
  pool of workers on every node pulls the next tile when it has a free core and
  self-discovers active jobs through an OTP `pg` registry. A faster or less-loaded
  node naturally pulls more, so one scene finishes as fast as the whole cluster can
  carry it, and a node that joins mid-job starts contributing immediately.
- **Fault tolerance, exactly-once.** The coordinator monitors each worker; if one
  dies mid-tile (or its whole node leaves), that tile is reassigned. Tile outputs
  are written to deterministic names (idempotent) and acks are deduped, so every
  tile lands in the raster once and is counted once in the reduction — regardless
  of failures or reassignments. A tile that repeatedly crashes workers fails the
  job cleanly instead of looping.

The pixel crunching is a thin, fast kernel from
[rast](https://hex.pm/packages/rast) (SIMD NDVI, windowed GDAL I/O, tile
geometry); similarity search rides on [kvex](https://hex.pm/packages/kvex). velora
adds the distribution, fault tolerance, the HTTP surface, output assembly, the
reduction, and the index.

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
# -> {"status":"done","progress":{"done":441,"total":441},"result_uri":"...",
#     "stats":{"count":...,"min":...,"max":...,"mean":...,"stddev":...,
#              "histogram":{"range":[-1,1],"bins":64,"counts":[...]}}}
```

`uri` may be `s3://…` (mapped to GDAL `/vsis3`) or `file://…` for local files. The
completed job carries a **reduction** (`stats`): summary statistics and a histogram
of the output values, computed as mergeable per-tile partials.

Find tiles similar to a given one (k-NN over per-tile histogram vectors):

```bash
curl -XPOST localhost:8080/jobs/<job_id>/search \
  -H 'content-type: application/json' -d '{"tile": "3_5", "k": 10}'
# -> {"results": [{"tile_id":"3_5","score":1.0}, {"tile_id":"4_5","score":0.98}, ...]}
```

## Web viewer

Open `http://localhost:8080/` in a browser. Choose a raster (a local file, a
drag-and-drop, or a URL) and hit **Render**: velora ingests it once into a local
web-mercator COG with overviews (`POST /render`) and then serves 256×256 PNG map
tiles on demand (`GET /tiles/:id/:z/:x/:y`), cutting only the window each visible
tile needs from the COG's overviews. The client is a plain Leaflet map that just
draws the tiles — no raster parsing in the browser — so even a gigapixel image
opens quickly. Non-georeferenced images (a JPEG, a telescope photo) are given a
valid near-equator extent so they display undistorted.

```bash
curl -XPOST localhost:8080/render -H 'content-type: application/json' \
  -d '{"uri":"https://…/scene.tif"}'
# -> {"id":"1234","bounds":[[S,W],[N,E]],"maxNativeZoom":13}
# then the browser fetches /tiles/1234/{z}/{x}/{y}
```

`uri` may be `file://…`, `s3://…` (→ `/vsis3`), `gs://…`, or `http(s)://…`
(→ `/vsicurl`). Uploads (`POST /uploads`, multipart) return a `work://` URI.

## HTTP API

| Method & path              | Purpose                                             |
|----------------------------|-----------------------------------------------------|
| `GET  /`, `GET /assets/…`  | The browser viewer (static SPA)                     |
| `POST /uploads`            | Upload a raster (multipart) → `{"uri":"work://…"}`   |
| `POST /render`             | Ingest a source for tiling → `{id, bounds, maxNativeZoom}` |
| `GET  /tiles/:id/:z/:x/:y` | On-demand PNG map tile of a rendered source          |
| `POST /jobs`               | Submit a processing job → `202 {"job_id": …}`       |
| `GET  /jobs/:id`           | Job status, progress, result URI, and `stats`       |
| `GET  /jobs/:id/result`    | Stream a done job's local COG (HTTP Range)          |
| `GET  /jobs`               | List jobs                                           |
| `POST /jobs/:id/search`    | k-NN similar tiles (`{"tile":"x_y"}` or `{"vector":[…]}`, `"k"`) |
| `GET  /cluster`            | Connected nodes                                     |
| `GET  /health`             | Liveness                                            |

## Running a cluster

Every node runs the same release; submit to any node. A `velora_discovery` process
periodically reconciles membership from a strategy, so nodes join without
per-request coordination:

```erlang
%% config/sys.config
{discovery, {static}}, {peers, ['velora@10.0.0.2', 'velora@10.0.0.3']}
%% or, for Kubernetes (Base@<ip> from a headless service's A records):
{discovery, {dns, "velora-headless", "velora"}}
```

Only tile descriptors, acks, and small per-tile vectors cross the cluster — pixels
stay between each node and object storage. Nodes may join or leave at any time:
joiners pick up active jobs via the `pg` registry, and a leaver's in-flight tiles
are reassigned (exactly-once).

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
rebar3 eunit        # unit tests (GDAL/kvex-backed ones skip if GDAL is absent)
rebar3 ct           # end-to-end: single-node NDVI, multi-node exactly-once,
                    # node-death reassignment, and node-join elasticity
```

## Capabilities

- **Web viewer**: display any GDAL raster as on-demand web-mercator PNG tiles
  (`POST /render` + `GET /tiles/…`); only the visible tiles are cut, so large
  images stay responsive. A background janitor sweeps prepared COGs/uploads after
  a TTL so the work dir stays bounded.
- **NDVI** over tiled COG scenes → a georeferenced GeoTIFF (`op: "ndvi"`;
  `op: {"decode", scale}` also available). Adding index kernels is a rast concern.
- **Reduction**: per-scene count/min/max/mean/stddev + histogram, mergeable per
  tile, on `GET /jobs/:id`.
- **Fault tolerance**: worker/node death, a caught processing error, or a stuck
  lease → tile reassignment; a source-open failure aborts the job instead of
  hanging; idempotent writes + ack dedup → exactly-once; poison-tile cap fails a
  job cleanly. Coordinators run under a dedicated dynamic supervisor and the job
  manager only *monitors* them, so a coordinator crash fails just its own job
  rather than taking the manager (and every other job) down. Finished jobs are
  evicted after a TTL, so the cluster's memory is bounded over long runs.
- **Elasticity**: fixed per-node worker pool self-discovering jobs via `pg`;
  periodic membership discovery (static / DNS); a node joining mid-job contributes
  immediately.
- **Similarity search**: per-tile k-NN index (L2-normalized histograms via kvex),
  `POST /jobs/:id/search`.

Not yet: persistence of job state across a job-manager restart (jobs are held in
memory); learned (ONNX) embeddings as the search feature; zonal statistics.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
