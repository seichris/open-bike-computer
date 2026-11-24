# Refresh the worldwide bicycle graph

The first production release used one Valhalla archive for the gaps in Apple
Maps Cycling. The iPhone still tries MapKit for each request. Follow the
[build procedure](README.md) for the commands and use this runbook to reproduce
the infrastructure, transfer, and deployment that passed qualification.

## Build on an ephemeral VM

1. Confirm the intended Google Cloud project, linked billing account, available
   credits, and quota. See [Cloud Billing Reports](https://console.cloud.google.com/billing)
   and check promotional credit eligibility before creating the machine.
2. Use an on-demand `c4-highmem-24-lssd` in `europe-west4-b` with Ubuntu 24.04
   amd64, a 24-hour auto-delete lifetime, and an auto-deleting boot disk.
   Provision a dedicated VPC, subnet, and SSH firewall rule for the job. Allow
   SSH from the Coolify VPS only. Use a job-specific SSH key and a VM with no
   service account. Read its Ed25519 host key through the authenticated Compute
   Engine serial console before trusting it for the transfer.
3. Install Docker, Osmium, mdadm, rsync, curl, and GNU time. Verify the four
   375 GiB Local SSDs are distinct, unmounted, and blank. Stripe only those
   disks with mdadm RAID0 and mount the ext4 scratch volume at
   `/srv/bicino-routing-scratch`. Keep the verified input, build directory, and
   export directory on scratch. Run the build under a transient systemd unit
   so it survives an SSH disconnect. Keep build logs on scratch and record the
   build start, end, and peak disk use for the next sizing decision.
4. Capture Apple's official Maps Cycling list and review coverage differences
   with the versioned policy before building the mask. Download the pinned
   Natural Earth inputs and use the GeoJSON Feature from `coverage_mask.py`.
   Osmium 1.16 rejected bare geometry on Ubuntu. Download the dated planet
   snapshot with a resumable transfer, verify the published checksum, and
   record SHA-256. Keep the verified PBF during retries. Run the pinned Valhalla
   container offline with eight build threads, verify the archive, and retain
   the manifest and exact mask bytes with the release. The
   [first release manifest](releases/2026-11-23.json) and
   [compressed mask](releases/2026-11-23-mask.geojson.gz) preserve the original
   PBF identity, clipping input, and archive identity. For a recovery build,
   decompress the mask with `gzip -dc` and verify the uncompressed bytes
   against the manifest before building. Verify and qualify the rebuilt graph
   before deploying it.

A planet build (`--coverage planet`, no mask) uses the same builder. The
2026-11-24 planet release was graded with elevation. Converting the
Copernicus DEM read 589 GB in about 95 minutes with 16 jobs and wrote 160 GB
of tiles. The graph build then took 4 hours 39 minutes, 67 of them in
Valhalla's elevation stage, and peaked at 41.6 GB of memory. Scratch use
peaked at 803 GB, which included the elevation tiles and a kept build
without elevation. The archive held 209,979 tiles in 107.6 GB. The same
build without elevation took 3 hours 25 minutes and wrote 104.6 GB. Check
the VPS for the candidate, the current graph, transfer parts and the 50 GB
reserve before transferring.

The first successful attempt took 3 hours 9 minutes from build start through
archive verification. Observed builder scratch use reached about 499 GB before
packaging, so leave margin for a retry and temporary transfer parts. The approved
archive held 165,327 tiles and occupied 66.3 GB before transport compression.
Build and verify off-host. The Coolify VPS serves the resulting archive.

## Qualify before leaving the builder

- Load the archive with no network in the pinned image. Run [smoke probes](probes.json)
  and [cross-border probes](cross-border-probes.json) with `probe_graph.py --probes`.
  Both directions across Austria–Slovakia and Mexico–Guatemala passed.
- Generate the country and territory inventory with `coverage_audit.py generate`
  and the pinned Natural Earth `ne_10m_populated_places_simple.geojson` from the
  same boundary release as the mask. Use `coverage_audit.py check` on the exact
  candidate. An exit code of 2 identifies units that need investigation. For a
  failed or missing fixture, inspect the exact merged OSM input near that unit
  and try a pair on mapped bicycle-accessible ways. Use the input snapshot to
  substantiate any reviewed exception. The first audit routed in 243 of 254
  units after targeting mapped roads in five small units. The other 11 had
  neither mapped highway ways nor bicycle or ferry relations in their source
  checks. These were ATC, BJN, BVT, CLP, CSI, FQI, HMD, HQI, KQI, SCR, and SER.
  Recheck those exceptions on every refresh. The 2026-11-24 planet audit
  (`generate --all-units`) routed in 281 of 298 units. Its 17 exceptions are
  those 11 plus ATF, IOT, KAS, PCN, TKL and VAT: remote islands and reefs, a
  glacier and Vatican City. Their fixture seeds lie at sea, give a
  zero-length route, or were never generated.
- On a graph built with elevation, check that `use_hills` changes routes.
  Serve the graded and the previous ungraded archive side by side and route
  city pairs with `use_hills` 0 and 1. On 2026-11-24 all 7 pairs (two in San
  Francisco, and Lisbon, Stuttgart, Zurich, Wellington and Amsterdam) changed
  on the graded graph and none changed on the ungraded one.
- Include a direct Valhalla miss in the Apple-listed interior near Fairview,
  Oklahoma. A live MapKit request there can still succeed. The first release
  also returned no route from either provider at Great Bear Lake in Canada.

## Pull, assemble, and install on Coolify

Expose the approved immutable archive and receipt through a dedicated
read-only `rrsync` SSH identity on the builder. Generate its private key on
the VPS. Use a separate SSH config and pinned host key. Keep graph artifacts
on VPS disk and transfer them directly from the builder.

Start with Zstandard-compressed rsync and keep the 50 GB free-space reserve in
`stage_graph.py`. Check available space for the current, candidate, previous,
and temporary transfer files. The VPS stages in
`/var/lib/bicino-valhalla/graphs/.${sha}.incoming/valhalla_tiles.tar` and serves
archives only after verification and atomic placement under the digest path.

```sh
root=/var/lib/bicino-valhalla/graphs
python3 stage_graph.py --root "$root" --manifest "$manifest" \
  --expected-sha256 "$sha" --ssh-config "$ssh_config" \
  --source "$builder_host:valhalla_tiles.tar" --compress-transfer
```

When one SSH stream stalls below the needed rate, use the parallel tail procedure
that finished the first transfer.

1. Pick an aligned prefix length reachable by the existing transfer. The
   first run used 30 GiB. On the builder, hash that prefix and split the
   remainder in three contiguous segments. Publish byte offsets, lengths,
   per-segment SHA-256 values, and the original archive manifest. Keep the
   original export available until VPS verification.
2. Pull the segments into a temporary VPS directory with three bounded
   `rsync -z --compress-choice=zstd` streams. The first run capped each
   segment stream at 4096 KiB/s. Verify every length and checksum and wait
   for the direct transfer to contain the selected prefix. Check the spare
   disk needed by the temporary segments.
3. Stop the installer that owns the incoming file before writing it. Verify
   the local prefix against the builder's prefix checksum. Write the segments
   at their declared offsets, check that they cover the remainder with no
   gaps or overlaps, and check the final byte count. If a segment or prefix
   fails verification, resume the original transfer while the builder is
   still available.
4. Finalize the assembled file locally. The stager rechecks the full
   SHA-256, tar index, tile count, and disk reserve before installing.
   `--verify-incoming` avoids sending the completed archive through rsync
   again. If verification fails, the assembled file remains in the incoming
   directory for repair. Delete the segment files after the installed archive
   passes the offline VPS probes.

```sh
python3 stage_graph.py --root "$root" --manifest "$manifest" \
  --expected-sha256 "$sha" --verify-incoming
```

## Switch development, then production

1. Repeat the archive smoke, coverage, and border checks from the exact staged
   mount. Try both cities from the development API network. Switch the private
   development Valhalla sidecar to the candidate while keeping the previous
   sidecar and archive available for rollback. Verify the sidecar's mount and
   the real API container's route to it before the phone test.
2. Replay saved routes on an enrolled Bicino Dev iPhone in Buenos Aires and
   Dubai. Confirm MapKit-first fallback through the App Attest-protected API,
   both route lines, confirmed rejoin, and resumed GPX guidance. Check a
   MapKit-only success such as Amsterdam and run the shared Swift offline
   tests. Clear simulated location after the phone runs.
3. Place the verified archive under
   `/var/lib/bicino-valhalla-production/graphs/${sha}/valhalla_tiles.tar`.
   On the same filesystem, hard-link the sealed archive and copy its manifest
   to a temporary directory under the production root. Verify the two paths
   refer to the same inode with `test file1 -ef file2`, verify mode 0444,
   and rename the directory to the digest path. This preserves an independent
   production path without allocating a second graph. Re-run offline smoke
   probes against that exact production path.
4. Change only the Valhalla archive bind source in the
   [production Compose lock](../deploy/compose.yaml). Run the lock render and
   required GitHub CI, then merge. Coolify watches the production Compose
   path on `main`. Wait for the matching merge commit to finish, then check the
   production API and Valhalla health and the exact read-only bind mount.
5. From the running production API container, instantiate
   `BicycleDetourService.from_environment()` and call `create_detour` for
   Buenos Aires and Dubai using the points in [probes.json](probes.json).
   The request uses `bicino-bicycle-detour-request-v1`, a fresh UUID,
   `routeSource: gpx`, and `origin` and `rejoin` with latitude and longitude
   multiplied by 1,000,000. Require `ready`, `bicycle`, the
   `bicino.valhalla` provider, and usable geometry and maneuvers.
   Check the public production `/healthz` and HTTP 401 for an
   unauthenticated request to `/v1/bicycle-detours`.
   [Production rollout #853](https://github.com/seichris/open-bike-computer/pull/853)

## Rollback and cleanup

Keep the immediate previous verified graph and the original GCC archive on the
VPS. Roll back by restoring the previous digest path in the production Compose
lock and redeploying through Coolify. For an incident, Coolify can redeploy the
last known-good release immediately, followed by the Git revert so the
declared and running states agree. After fallback to GCC, verify Dubai still
routes and Buenos Aires returns the expected no-route response.

After the verified archive and development server probes pass on Coolify,
delete the dedicated Compute Engine instance and confirm the auto-deleting
boot disk, Local SSD data, and external IP are gone. Remove the job's firewall
rule, subnet, and VPC. Revoke and remove the one-time transfer keys and remove
transfer segments and unused development sample archives from the VPS. Keep
the active graph, rollback archives, release manifest, and small test records.
