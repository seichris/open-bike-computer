# PBF download fallback: OpenStreetMap France

The backend keeps Geofabrik as its primary PBF provider. If an eligible source
cannot be downloaded because of an upstream availability failure, `SourceCache`
tries its explicitly mapped OpenStreetMap France extract once. This applies to
worker downloads and source-cache refreshes using `SourceCache.ensure`.

For Shanghai the pair is:

```text
https://download.geofabrik.de/asia/china/shanghai-latest.osm.pbf
https://download.openstreetmap.fr/extracts/asia/china/shanghai-latest.osm.pbf
```

## Eligibility and failures

`map-platform/backend/map_platform/osmfr_fallback.py` contains an exact HTTPS URL
allowlist for selected countries and Chinese subdivisions, including Shanghai,
Jiangsu and Zhejiang. There is no blanket hostname replacement. Naming aliases
are explicit, for example `neimenggu` to `inner_mongolia` and `xizang` to `tibet`.

Only `provider="geofabrik"` sources with a known `-latest.osm.pbf` URL and without
a configured checksum or publication timestamp are eligible. Dated snapshots,
checksum-pinned inputs, custom hosts, query strings, fragments and unknown
regions are not translated. In particular, the combined
`malaysia-singapore-brunei` extract must not become only `malaysia`, and
`ireland-and-northern-ireland` must not become only `ireland`. Taiwan and those
combined regions have no mapping in this change.

Fallback is attempted after HTTP 404, 408, 410, 429 or 5xx, network URL errors,
timeouts, connection failures, or an interrupted HTTP read. Authentication
errors, TLS trust failures, checksum mismatches, invalid resume responses,
cancellation and local storage failures do not trigger provider switching.
The existing 60-second per-request socket timeout and bounded same-provider
resume behavior are unchanged; this is not a whole-job deadline.

## Cache and integrity behavior

- Each attempt uses the existing per-source locks, data-volume admission lock,
  free-space reserve, hashing, cancellation checks and atomic replacement path.
  A failed attempt closes its response and removes temporary bytes before the
  next provider starts. The previous stable file is not replaced on failure.
- A provider switch starts from byte zero. `Range`, `If-Range`, ETag and
  Last-Modified validators are never carried from one provider to the other.
- Metadata records the actual successful `sourceUrl`, `resolvedUrl`, SHA-256,
  byte count and HTTP validators. Region IDs and local cache paths stay stable.
  A fallback download does not inherit a Geofabrik publication timestamp.
- A fresh fallback cache entry is reused for the existing cache lifetime
  (`MAP_PLATFORM_SOURCE_CACHE_REVALIDATE_SECONDS`, default 24 hours). When due
  for revalidation, Geofabrik is tried first again. If unavailable, the fallback
  may revalidate its own bytes with its own validators, including HTTP 304.
  `force=True` bypasses cached bytes and conditional validators.
- Before publication, a fallback response must have a bounded, complete first
  `OSMHeader` blob and a final URL beneath the trusted HTTPS extracts prefix.
  This rejects empty bodies, typical HTML error pages, truncated initial blobs
  and off-provider final redirects. It is **not** whole-file PBF validation or
  a check of geographic completeness; the existing extraction pipeline still
  parses the downloaded PBF.
- If both providers fail, the exception identifies both failures. No error page
  or partially downloaded fallback replaces an existing source.

OpenStreetMap France produces independent extracts, not byte-identical
Geofabrik mirrors. Matching regional names do not prove identical boundaries,
coverage near borders, relation completeness, or data timestamps. Check a
provider's polygon and required coverage before extending the mapping or using
it for a boundary-sensitive map. Reproducible jobs should pin their source
checksum rather than rely on interchangeable latest snapshots.

## Configuration and scope

Fallback is enabled by default. Set `MAP_PLATFORM_OSMFR_FALLBACK=0` in the backend
process/container environment to disable it; `false`, `no` and `off` also work.
With fallback disabled, a cache entry from the alternative provider requires
primary-source revalidation rather than remaining accepted as fresh.

This change handles **PBF downloads after source resolution**. It does not add
an OpenStreetMap France discovery catalogue. Configured sources and an existing
cached Geofabrik catalogue remain usable during an outage, but a cold dynamic
lookup with no cached catalogue still depends on Geofabrik. The API contract,
iOS app and firmware are unchanged. Production image promotion remains the
separate digest-pinned deployment workflow described in `AGENTS.md`.

Destination listings used to review the mapping on 2026-09-06:

- <https://download.openstreetmap.fr/extracts/asia/>
- <https://download.openstreetmap.fr/extracts/asia/china/>
- <https://download.openstreetmap.fr/extracts/europe/>

## Regression tests

From a complete repository checkout with backend dependencies installed:

```sh
cd map-platform/backend
python -m unittest discover -s tests -p 'test_osmfr_fallback.py'
python -m unittest discover -s tests -p 'test_source_cache.py'
```

The fallback tests use deterministic synthetic HTTP responses; they do not
require either public provider to be up and do not claim to build a real map.
They cover primary success and redirects, outage classification, interrupted
reads and safe restarts, provider-isolated validators, HTTP 304, recovery after
cache expiry, pinned inputs, cancellation, storage admission, invalid fallback
bodies, trusted final URLs, and preservation of stable bytes and metadata.
