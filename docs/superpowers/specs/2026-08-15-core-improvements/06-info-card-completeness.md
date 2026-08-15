# 06 — info card completeness (bbox + overviews)

## Problem

`velora_web:info/1` returns `#{size, bands, crs, driver}`. The design of the
Emergence "info" intent (and useful metadata generally) expects a geographic
**bbox** and the raster's **overview** levels; the final review flagged this as
spec drift (the agent `info_card/1` never populates `bbox`/`overviews`).

## Design

Extend `info/1` to also extract, from the same `gdalinfo -json` output:

- `bbox` — the corner coordinates. `gdalinfo -json` provides
  `wgs84Extent` (GeoJSON polygon) and/or `cornerCoordinates`. Prefer
  `wgs84Extent` → compute `[minLon, minLat, maxLon, maxLat]`. If absent
  (non-georeferenced), omit `bbox` (do not fabricate).
- `overviews` — per band, `bands[].overviews` lists overview sizes; return the
  count (or the list of `[w,h]`). Return `overviews => N` (0 when none).

New shape:
```erlang
#{size => [W,H], bands => N, crs => Wkt, driver => Drv,
  bbox => [MinLon,MinLat,MaxLon,MaxLat] | undefined,
  overviews => non_neg_integer()}
```
`velora_agent:info_card/1` passes it through (adds `type => info`); update its
spec/comment to match.

## Testing

- GDAL-gated: `info/1` on the 2-band fixture returns `bbox` (a 4-float list or
  `undefined`) and `overviews` (integer). On a fixture with overviews built,
  `overviews > 0`.
- Pure extraction helper (parse a canned `gdalinfo -json` map → bbox/overviews)
  unit-tested without GDAL, covering the `wgs84Extent`-present and -absent cases.

## Risks / notes

- Keep the scheme gate from 01 in `info/1` (already added). This item only
  enriches the returned map.
- `wgs84Extent` polygon vertex order varies; compute min/max over all vertices
  rather than assuming a corner order.
