# Worldwide bicycle graph

Two coverages build from the same pipeline:

- **`planet`**: the whole planet, so Create a Route's Road, Gravel and
  Everyday routes work everywhere. It takes no mask.
- **`worldwide-gap`**: only the places where Apple Maps has no cycling
  directions, plus border bands. This was the first production graph, for
  saved-route detours.

The iPhone still asks MapKit first for detours with either graph.

Build and qualify the graph off the serving host. The versioned policy maps Apple’s
published Maps Cycling entries to Natural Earth map units. Mainland mappings for
France, the Netherlands, and Portugal intentionally leave separately mapped
overseas areas eligible. Unlisted units and the disputed-area layer are retained.
The mask keeps a nominal 30 km band at excluded boundaries. Add explicit
bike-accessible ferry links and crossings as retained polygons if probes show a
route needs more space. The mask is a build input. No country list participates in
the iPhone’s MapKit-first decision.

For the procedure used for the first production rollout, see
[Refresh and rollback](refresh-runbook.md). The
[first release manifest](releases/2026-11-23.json) records the source and
graph identities. The [archived mask](releases/2026-11-23-mask.geojson.gz)
retains the exact clipping input.

## Build and release

1. Use an on-demand Linux amd64 builder with Docker, Osmium, and Python 3.11 or
   later. The first worldwide run is sized for a Compute Engine
   `c4-highmem-24-lssd` with 1,500 GiB of scratch spread across four local SSDs.
   Confirm the credit-backed project and CPU and SSD quotas before provisioning.
   Stripe the temporary SSDs, keep the boot disk separate, and use a VM lifetime
   limit. The Linux builder only needs access to public inputs.
2. Download the exact two files named in [coverage.json](coverage.json) from
   its pinned boundary base URL. For a policy refresh, fetch the official Apple
   page and run the mask tool with `--apple-html`. A difference must be reviewed
   before updating the versioned mappings. A reproducible rebuild can use the
   existing committed policy. Pass reviewed additional corridor polygons with
   `--corridors` when needed.

   ```sh
   python coverage_mask.py --boundaries "$build_scratch/boundaries" \
     --apple-html "$build_scratch/apple.html" \
     --output "$build_scratch/mask.geojson" --inventory "$build_scratch/inventory.json"
   ```

   This step requires the same Shapely and PyProj versions as the map platform
   Python environment. The inventory records geometric coverage for each unit.
   It does not establish that a routable network exists there.

3. Fetch a dated planet PBF and its published checksum. Verify it and record the
   source SHA-256. Use verified cache extracts for regional development samples.
   Build the worldwide graph from one immutable snapshot. The builder completes
   member references for selected bicycle routes, turn restrictions, and ferries
   against that snapshot and builds the administrative database from the
   unclipped input. It writes a seekable indexed tar and a separate manifest.

   ```sh
   python build_graph.py --source "$planet_pbf" --source-sha256 "$planet_sha" \
     --source-url "$planet_url" --mask "$build_scratch/mask.geojson" \
     --work "$build_scratch/candidate" --threads 8
   ```

   For a planet graph, leave out the mask step and pass `--coverage planet`
   without `--mask`. The manifest then records `"coverage": "planet"` and no
   mask or policy.

   ```sh
   python build_graph.py --coverage planet --source "$planet_pbf" \
     --source-sha256 "$planet_sha" --source-url "$planet_url" \
     --work "$build_scratch/candidate" --threads 8
   ```

   Use `--sample` for development input. Sample results are never worldwide
   release evidence. Record peak scratch and memory, phase times, output size,
   the policy and inventory, source and configuration hashes, and probe results.

4. Run [probes.json](probes.json) with the pinned build image against the archive
   alone, passing `probe_graph.py --coverage planet` for a planet graph. A
   fixture's `route` is its worldwide-gap expectation. `planet` overrides it,
   `coverages` limits where it runs, and `pushAllowed` accepts short
   pedestrian push segments. On a planet graph, generate the audit inventory
   with `coverage_audit.py generate --all-units`. Add probes for the full release across continents and territories and
   for shortlisted road and ferry crossings in both directions. Check the
   inventory against routable OSM coverage and record any territory without a
   bicycle network. For the first pass, generate routing fixtures with
   `coverage_audit.py generate` and the pinned Natural Earth populated-places
   layer. Run `coverage_audit.py check` against the private candidate. Its
   review states require follow-up, including for territories without a
   generated fixture. Rehearse cold and warm runs with four requests and measure
   memory, I/O, and latency alongside map-worker activity. The following
   command exercises the Valhalla archive and keeps the container off-network.

   ```sh
   docker run --rm --network none --platform linux/amd64 --cpus 2 --memory 2g \
     --read-only --tmpfs /tmp:size=64m \
     -v "$candidate/valhalla_tiles.tar:/graph/valhalla_tiles.tar:ro" \
     -v "$routing_tools:/probe:ro" --entrypoint /bin/bash "$valhalla_image" -ec '
       valhalla_build_config --mjolnir-tile-extract /graph/valhalla_tiles.tar > /tmp/valhalla.json
       valhalla_service /tmp/valhalla.json 2 &
       exec python3 /probe/probe_graph.py --concurrency 4
     '
   ```

5. From the Coolify VPS, pull the approved archive over SSH using a temporary,
   read-only builder identity and a verified host key. Keep the production
   credential on the serving side. The staged file and active file paths are
   separate. The script checks the SHA-256, tar index, and tile count before
   installing the candidate in a digest directory. The default free-space
   reserve is 50 GB. Use one immutable archive with a separate hard link under
   the production graph root so staging cleanup cannot remove the production
   path.
   Use `--compress-transfer` when both rsync installations support Zstandard.
   Transfer compression preserves the checksum of the staged archive.

   ```sh
   python stage_graph.py --root /var/lib/bicino-valhalla/graphs \
     --manifest "$approved_manifest" --expected-sha256 "$approved_archive_sha" \
     --source "$builder_host:$builder_archive" --compress-transfer
   ```

6. Qualify the exact staged bytes in development, including the App Attest API
   and enrolled iPhone replays. Reuse the Dubai acceptance harness. Add Buenos
   Aires, a live Amsterdam MapKit success, a Valhalla miss in the Apple-listed
   interior of Oklahoma, offline behavior, and confirmed rejoin. International
   route relations can retain small corridors in otherwise excluded interiors,
   so choose the miss fixture away from those retained roads. Confirm both the
   original and temporary routes are visible during detours. Map downloads use
   the existing separate service.
7. Advance the Coolify production graph lock through reviewed deployment after
   development qualification and CI. Preserve the existing API and map worker
   image pins. Retain the previous verified graph on the VPS and the original
   small GCC archive. Roll back by restoring the previous mount in the
   production Compose lock and redeploying through Coolify. Keep the manifest
   in version control for recovery by rebuild. Delete the builder after the
   VPS archive and development server probes pass. Refresh monthly or after
   a reviewed coverage change.

## Focused checks

```sh
tools/dev-env --map-backend python -m unittest discover -s map-platform/routing -v
```

To prove the road, gravel and everyday route profiles still change Valhalla's
answer on a candidate graph, run [probe_profiles.py](probe_profiles.py) from the
map-backend environment against a private, archive-only Valhalla (for example
the step 4 container with `-p 127.0.0.1:8002:8002` instead of `--network none`).
It drives the backend's own route service over
[profile-probes.json](profile-probes.json) and fails if a profile's maneuvers
report a different bicycle type or no pair yields different road and gravel
geometry; see [Bicycle routes](../../docs/bicycle-routes.md).

```sh
tools/dev-env --map-backend python map-platform/routing/probe_profiles.py --origin http://127.0.0.1:8002
```

See [Saved-route bicycle detours](../../docs/saved-route-detours.md) for the
existing provider contract and GCC baseline.
