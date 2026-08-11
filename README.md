# velora

Distributed satellite-raster processing tool. Spreads one scene's tiles across a
BEAM cluster (native distributed Erlang), runs a [rast](https://hex.pm/packages/rast)
kernel (NDVI) on each tile on whatever node pulled it, and assembles a
georeferenced COG. Pixels never travel between nodes: each node reads its windows
from shared object storage (GDAL `/vsis3`) and writes its result tiles back.

## Build & run

    rebar3 compile
    rebar3 shell           # single node, HTTP on :8080

## Submit a job

    curl -XPOST localhost:8080/jobs -H 'content-type: application/json' -d '{
      "op": "ndvi",
      "sources": [ {"uri":"s3://bucket/scene.tif","band":8},
                   {"uri":"s3://bucket/scene.tif","band":4} ],
      "out_uri": "s3://bucket/out/ndvi.tif",
      "tile": [512,512]
    }'
    # -> {"job_id":"..."}
    curl localhost:8080/jobs/<job_id>

## Cluster

Set `peers` in `config/sys.config` (or start nodes with a shared cookie and let
them connect). Every node runs the same release; submit to any node. Pixels are
never shipped between nodes — only tile descriptors and acks cross the cluster.

## Requirements

Erlang/OTP 27, GDAL CLI (`gdalinfo`, `gdal_translate`, `gdalbuildvrt`) on PATH or
at `GDAL_BIN_DIR`. Object storage reachable via GDAL `/vsis3` (S3/MinIO).
`epmd` must be running for distributed clustering.

Slice 1 scope: NDVI, georeferenced raster output, fail-fast. Reduction/stats,
fault-tolerant retry, elasticity, and kvex indexing are later slices.
