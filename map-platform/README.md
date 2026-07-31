# Map Platform

This directory groups the hosted offline-map service and its operational
configuration:

- [`backend/`](backend/) contains the FastAPI application, workers, tests, and
  local Docker Compose setup.
- [`config/`](config/) contains the checked-in map-stream trust, rollout, and
  hardware-gate configuration.
- [`deploy/`](deploy/) contains the digest-pinned production Compose lock and
  image-promotion tooling.

The map-generation pipeline remains in [`tools/OSM_Extract/`](../tools/OSM_Extract/)
because it is independently licensed and usable outside the hosted service.

Start with the [backend guide](backend/README.md) for local development or the
[deployment guide](deploy/README.md) for production operations.

## License

Project-authored software, tests, scripts, and configuration under
[`backend/`](backend/) and [`config/`](config/) are licensed
AGPL-3.0-only unless a more specific notice applies. Project-authored software
and configuration under [`deploy/`](deploy/) follow the repository's
GPL-3.0-only license.

See the repository's [licensing guide](../LICENSES.md) for the exact
path-by-path boundaries and third-party notices.
