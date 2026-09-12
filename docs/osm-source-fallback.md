# PBF download fallback: OpenStreetMap France

The backend keeps Geofabrik primary. When a PBF download fails with an eligible
upstream availability error, `SourceCache.ensure` tries one OpenStreetMap France
candidate. Worker downloads and source-cache refreshes share this behavior.

## Per-request resolution

For an unpinned, canonical HTTPS Geofabrik `-latest.osm.pbf` URL:

1. Extract the path without the hostname or `-latest.osm.pbf` suffix.
2. Stop if that exact source scope is in the documented exception table.
3. Apply an exact researched alias when present; otherwise retain the path.
4. Download from `https://download.openstreetmap.fr/extracts/` using that path.

For example, Shanghai needs **no table entry**:

```text
https://download.geofabrik.de/asia/china/shanghai-latest.osm.pbf
https://download.openstreetmap.fr/extracts/asia/china/shanghai-latest.osm.pbf
```

The pure `fallback_url` function in
`map-platform/backend/map_platform/osmfr_fallback.py` performs no network calls.
There is no separate HEAD probe, remote catalogue fetch, directory crawl, or
trial of multiple guessed names. The actual download is the availability test.
A 404 from the candidate reports both provider failures instead of trying a
larger parent, downloading an entire country, or replacing a combined source
with one component. Existing bounded same-provider resume behavior is retained.

`ALIASES` contains only naming/directory differences, not an allowlist of
supported regions. Unknown valid paths receive the same-path candidate too;
this is best-effort discovery, **not guaranteed worldwide coverage**. Aliases
and exceptions match full source paths, not basenames or arbitrary prefixes.
A parent's alias is not automatically inherited by its children. There is no
blanket hyphen-to-underscore replacement: OSM.fr itself uses both conventions.

See [the researched alias and exception table](osmfr-alias-research.md) for
all entries, evidence, corrections to the original examples, and limitations.

## Eligibility and errors

Only `provider="geofabrik"` sources without a configured checksum or publication
timestamp can switch. Dated snapshots and other formats remain pinned to their
original source. Full URL matching rejects custom/lookalike hosts, credentials,
ports, query strings (even empty ones), fragments, whitespace/control characters,
encoded separators, dot segments, empty path components and backslashes. URLs
are not decoded or normalized into eligibility.

Fallback follows HTTP 404, 408, 410, 429 or 5xx, network URL errors, timeouts,
connection failures, or interrupted HTTP reads. Authentication errors, TLS trust
failures, checksum mismatches, invalid resume responses, cancellation and local
storage failures do not trigger switching. The existing 60-second per-request
socket timeout is not a whole-job deadline.

## Cache and integrity

Each attempt retains the existing per-source locks, data-volume admission lock,
free-space reserve, cancellation checks, hashing and atomic replacement path.
Failed responses are closed and temporary bytes removed before switching.
Fallback starts from byte zero. Range, If-Range, ETag and Last-Modified values
never cross providers. Both providers failing preserves the stable file and
its metadata; an HTML error page or partial download is not published.

Metadata records the successful `sourceUrl`, final `resolvedUrl`, SHA-256,
byte count and HTTP validators. Local cache paths and source IDs stay stable;
fallback does not inherit a Geofabrik publication timestamp. A fresh fallback
entry is reused for `MAP_PLATFORM_SOURCE_CACHE_REVALIDATE_SECONDS` (24 hours by
default). Revalidation tries Geofabrik first again, then may revalidate the
fallback's own bytes with its own validators, including HTTP 304. `force=True`
bypasses cached bytes and conditional validators.

Before publication, fallback downloads must have a complete, bounded initial
`OSMHeader` blob and a final URL beneath the trusted HTTPS extracts prefix.
This is **not whole-file PBF validation or geographic coverage validation**;
the extraction pipeline still parses the downloaded PBF. The providers create
independent snapshots: even matching names do not prove identical boundaries,
border buffers, relation completeness, disputed-area treatment or timestamps.
Pin source checksums for reproducibility. Boundary-sensitive jobs need actual
polygon/required-area checks, not just HTTP 200 or the alias table.

## Configuration and scope

Fallback is enabled by default. Set `MAP_PLATFORM_OSMFR_FALLBACK=0` in the backend
environment to disable it (`false`, `no` and `off` also work). With it disabled,
a fresh fallback entry requires primary-source revalidation instead of staying
accepted as fresh.

This handles **PBF downloads after source resolution**. It does not implement
an independent OSM.fr source catalogue. Configured sources and a cached Geofabrik
catalogue remain usable during outages; cold dynamic discovery without a cached
catalogue still depends on Geofabrik. No API, iOS, firmware, deployment or
production image pins are changed. Production promotion remains separate as
described in `AGENTS.md`.

## Tests

From a complete checkout with backend dependencies installed:

```sh
cd map-platform/backend
python -m unittest discover -s tests -p 'test_osmfr_url_resolution.py'
python -m unittest discover -s tests -p 'test_osmfr_fallback.py'
python -m unittest discover -s tests -p 'test_source_cache.py'
```

Tests use deterministic synthetic responses, not live provider availability.
URL tests cover the full table, unknown paths, exact matching, pinned sources,
host/path attacks, semantic exceptions, and research-document consistency.
Downloader regressions additionally cover new same-path sources, researched
aliases, missing candidates without extra guesses, primary redirects/304,
provider-isolated validators, resumes, cancellation, storage reserve, TTL,
force/disable behavior, invalid bodies and preservation of stable bytes.
