# Map Platform

This directory groups the hosted offline-map service and its operational
configuration:

- [`backend/`](backend/) contains the FastAPI application, workers, tests, and
  local Docker Compose setup.
- [`catalog/`](catalog/) contains the Cloudflare Worker and D1 migrations for
  the shared final-map library, aliases, download grants, and share links.
- [`config/`](config/) contains the checked-in map-stream trust, rollout, and
  hardware-gate configuration.
- [`deploy/`](deploy/) contains the digest-pinned production Compose lock and
  image-promotion tooling.

The map-generation pipeline remains in [`tools/OSM_Extract/`](../tools/OSM_Extract/)
because it is independently licensed and usable outside the hosted service.

Start with the [backend guide](backend/README.md) for local development, the
[deployment guide](deploy/README.md) for Coolify operations, or the
[R2 library runbook](../docs/runbooks/cloudflare-r2-final-map-library.md) for
the staging-first shared-map rollout.

## License

Project-authored software, tests, scripts, and configuration under
[`backend/`](backend/), [`catalog/`](catalog/), and [`config/`](config/) are licensed
AGPL-3.0-only unless a more specific notice applies. Project-authored software
and configuration under [`deploy/`](deploy/) follow the repository's
GPL-3.0-only license.

See the repository's [license summary](../README.md#license) for the exact
path-by-path boundaries and third-party notices.
