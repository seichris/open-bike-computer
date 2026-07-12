# Offline Map Platform Backend

This backend creates ESP32-compatible offline map packs from OpenStreetMap PBF
sources. It implements the production contract described in
`docs/offline-map-platform-implementation-plan.md`.

## What is implemented

- `POST /v1/map-jobs` for curated, custom bbox, custom polygon, and route
  corridor requests, with installation-scoped idempotency metadata.
- Installation-scoped job, list, map-pack, and download-URL reads. The client
  installation ID is required for reads; legacy jobs without an owner remain
  recoverable by ID.
- Source-region resolution from `backend/config/source-regions.json`, with a
  cached Geofabrik catalog fallback for any requested area covered by
  Geofabrik.
- File-backed job storage for local/Coolify deployment.
- Worker wrapper for `osmium extract` plus `OSM_Extract`.
- Map-pack manifest generation with file hashes and OSM attribution.
- Local `.zip` artifact packaging.
- Coolify-oriented compose file and Dockerfile.

## Local API

```sh
cd backend
python -m venv .venv
. .venv/bin/activate
python -m pip install -e ".[api]"
uvicorn map_platform.api:app --reload --port 8080
```

Create a custom bbox job:

```sh
curl -s http://localhost:8080/v1/map-jobs \
  -H 'content-type: application/json' \
  -d '{
    "mode": "custom_bbox",
    "displayName": "Singapore central",
    "bbox": [103.75, 1.24, 103.93, 1.37],
    "clientInstallationId": "installation-12345678",
    "clientRequestId": "request-12345678",
    "installOnDevice": false,
    "target": { "renderer": "esp32-fmb", "firmwareVersion": "0.0.0" }
  }'
```

Run a job:

```sh
python -m map_platform.cli run-job <job-id>
```

Run the production-style queue worker:

```sh
python -m map_platform.cli worker-loop
```

The configured source PBF must exist under `backend/data/source-pbf/` before a
worker can run, or the worker will download it into the configured data root
through the source cache. Static sources are stored in the source index; other
areas are resolved from the cached Geofabrik catalog at job creation time and
persisted with the job before the worker downloads the matching PBF.

## Coolify

Use `backend/docker-compose.yml` as the first Coolify deployment shape. The
service stores mutable state in the `map-platform-data` volume. The host needs
enough CPU, RAM, and temporary disk for the largest allowed PBF cut-out.

Required Coolify secrets:

- `MAP_PLATFORM_API_TOKEN`: bearer token used by the iOS app for job creation,
  job polling, and signed download URL creation. Treat it as a client token,
  because it is embedded in distributed app builds.
- `MAP_PLATFORM_DOWNLOAD_SECRET`: HMAC secret for signed map-pack downloads.
  Use a separate long random value so signed URLs survive API restarts without
  reusing the API token as the signing key.

Useful production environment variables:

- `MAP_PLATFORM_ADMIN_TOKEN`: separate server-only bearer token for worker,
  source-cache, and maintenance API routes. If unset, those routes are disabled;
  the normal worker loop and CLI maintenance remain available.
- `MAP_PLATFORM_MAX_ACTIVE_JOBS`: maximum queued/running jobs accepted by the
  API, default `25`.
- `MAP_PLATFORM_JOB_RETENTION_DAYS`: days to retain ready job artifacts,
  default `30`; must be between `1` and `3650`.
- `MAP_PLATFORM_MAINTENANCE_INTERVAL_SECONDS`: worker cleanup interval,
  default `3600`.
- `MAP_PLATFORM_DYNAMIC_SOURCE_DISCOVERY`: enable Geofabrik catalog fallback,
  default `1`.
- `MAP_PLATFORM_GEOFABRIK_INDEX_URL`: provider catalog URL, default
  `https://download.geofabrik.de/index-v1.json`.
- `MAP_PLATFORM_GEOFABRIK_INDEX_CACHE`: catalog cache path, default
  `$MAP_PLATFORM_DATA_ROOT/source-catalogs/geofabrik-index-v1.json`.
- `MAP_PLATFORM_GEOFABRIK_INDEX_TTL_SECONDS`: catalog cache TTL, default
  `86400`.

Tailscale SSH can still be used for bootstrap and incident response when browser
authorization has been completed, but normal deploys should go through Coolify.
