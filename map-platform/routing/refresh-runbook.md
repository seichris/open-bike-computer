# Refresh the worldwide bicycle graph

The first production release used one Valhalla archive for the gaps in Apple
Maps Cycling. The iPhone still tries MapKit for each request. Follow the
[build procedure](README.md) for the commands and use this runbook to reproduce
the infrastructure, transfer, and deployment that passed qualification.

## Build on an ephemeral VM

A planet build runs from the scripts in [builder/](builder/README.md): one
command sets the builder up and starts a chain of systemd units that
downloads the planet, builds the elevation tiles, builds the graph with and
without elevation, probes both archives and runs the elevation gate. Nobody
has to watch it. Run the commands below from a checkout at the commit whose
tools should build; that commit must be on GitHub. `JOB` names the run, for
example `r400-261116`, and `VPS` is the Coolify VPS.

The scripts were written on 2026-11-26 and have not yet run on a real
builder; see [what that leaves open](builder/README.md#not-verified-on-a-real-builder).

1. Confirm the intended Google Cloud project, linked billing account, available
   credits, and quota. See [Cloud Billing Reports](https://console.cloud.google.com/billing)
   and check promotional credit eligibility before creating the machine.
   Creating it needs Chris's go-ahead for that build.
2. Generate the job's SSH key on the VPS and keep its public half:

   ```sh
   ssh root@VPS "ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/bicino-valhalla-JOB \
     -C bicino-valhalla-JOB && cat /root/.ssh/bicino-valhalla-JOB.pub" > job.pub
   ```

3. Print the plan, then create the builder:

   ```sh
   map-platform/routing/builder/provision.sh --job JOB --ssh-source VPS_PUBLIC_ADDRESS/32 --ssh-key job.pub
   map-platform/routing/builder/provision.sh --job JOB --ssh-source VPS_PUBLIC_ADDRESS/32 --ssh-key job.pub --create
   ```

   It creates a VPC, subnet and SSH firewall rule for this job alone, with
   SSH allowed from the VPS only, and an on-demand `c4-highmem-24-lssd` in
   `europe-west4-b` with Ubuntu 24.04 amd64, no service account, an
   auto-deleting boot disk and a 24-hour lifetime after which it deletes
   itself. For a graded build that should restore the
   [kept elevation tiles](builder/README.md#kept-elevation-tiles), add
   `--cache-reader bicino-routing-builder@chiho-prod.iam.gserviceaccount.com`:
   the builder then runs as that account, which can read the tile bucket
   and nothing else. The account must exist first
   (`builder/cache-access.sh`); on 2026-11-27 it did not.
4. Read the builder's Ed25519 host key through the authenticated Compute
   Engine serial console, before the first connection:

   ```sh
   map-platform/routing/builder/provision.sh --job JOB --host-key
   ```

   It prints `ADDRESS ssh-ed25519 KEY`. On the VPS, put that line in
   `/root/.ssh/bicino-valhalla-JOB.d/known_hosts` and write
   `/root/.ssh/bicino-valhalla-JOB.d/config`:

   ```text
   Host builder
     HostName ADDRESS
     User bicino
     IdentityFile /root/.ssh/bicino-valhalla-JOB
     IdentitiesOnly yes
     UserKnownHostsFile /root/.ssh/bicino-valhalla-JOB.d/known_hosts
     StrictHostKeyChecking yes
     ServerAliveInterval 30
   ```

5. Set the builder up and start the chain, in one command:

   ```sh
   ssh root@VPS "ssh -F /root/.ssh/bicino-valhalla-JOB.d/config builder \
     'bash -s -- --commit $(git rev-parse HEAD) --planet-date 261116 --opening-radius 400 --start'" \
     < map-platform/routing/builder/setup.sh
   ```

   `setup.sh` first masks Ubuntu's package upgrades, which restarted a
   running build on 2026-11-26. It then installs Docker, Osmium, mdadm, rsync,
   curl, GNU time and Git, checks that the four 375 GiB Local SSDs are
   distinct, unmounted and blank, stripes only those with mdadm RAID 0 and
   mounts the ext4 scratch volume at `/srv/bicino-routing-scratch`. It checks
   the tools out at the commit, writes the run's settings and starts the
   chain. Leave out `--opening-radius` to build only the ungraded planet,
   the graph production serves. Add `--terrain usgs-3dep-13` to grade with
   the hybrid of USGS 3DEP and opened Copernicus: the elevation stage then
   also downloads 3DEP's 955 tiles (364 GB) and blends them in, and both
   graphs are built with every bridge marked as one (see
   [the builder's page](builder/README.md#the-chain)). No builder has run
   that yet. Add `--elevation-cache elevation-cache-2026-11-26.json` to
   restore the raw tiles and the tiles opened at 400 m from their bucket
   instead of building them for 2 hours 20 minutes. Every tar and every tile
   is checked against that record; a set that cannot be restored is built,
   and the status says so. No builder has run that yet either.
6. Ask where the build stands whenever you like. Copy
   `builder/builder_status.py` to the VPS once, or run it from a laptop with
   `--via`:

   ```sh
   python3 map-platform/routing/builder/builder_status.py --via root@VPS \
     --ssh-config /root/.ssh/bicino-valhalla-JOB.d/config
   ```

   It exits 3 while the chain runs, 0 or 4 when it is complete (gate met or
   missed), 5 when a stage failed and 7 when it got no usable answer. Exit 7
   means unreachable, never running: fix the connection and ask again. With
   `--wait` it polls until the chain is no longer running. A graded build
   takes about 7.5 hours, an ungraded one about 4.
7. When the chain is complete, pull the result, the logs and the evidence to
   the VPS. The archives stay on the builder until one is approved:

   ```sh
   ssh root@VPS "rsync -a --exclude valhalla_tiles.tar -e 'ssh -F /root/.ssh/bicino-valhalla-JOB.d/config' \
     builder:/srv/bicino-routing-scratch/export/ /root/bicino-routing-releases/builder-JOB/"
   ```

   `result.json` holds every stage's state and times, both archive
   manifests, both elevation manifests, each archive's qualification summary,
   the gate summary and the peak scratch and memory use. Record the build
   times and peaks here for the next sizing decision.
8. If a stage failed, read its log, fix the cause and start the chain again
   (see [When a stage fails](builder/README.md#when-a-stage-fails)). Finished
   stages are kept. To build with another radius or snapshot on the same
   builder, run `setup.sh` again: stages whose settings changed are reported
   as stale and are neither reused nor deleted (see
   [Build again with other settings](builder/README.md#build-again-with-other-settings)).

A worldwide-gap build is not part of the chain. Run `setup.sh` without
`--start` and build by hand on the scratch volume, under a transient systemd
unit so it survives an SSH disconnect. Capture Apple's official Maps Cycling
list and review coverage differences with the versioned policy before building
the mask. Download the pinned Natural Earth inputs and use the GeoJSON Feature
from `coverage_mask.py`; Osmium 1.16 rejected bare geometry on Ubuntu. Run the
pinned Valhalla container offline with eight build threads, verify the
archive, and retain the manifest and exact mask bytes with the release. The
[first release manifest](releases/2026-11-23.json) and
[compressed mask](releases/2026-11-23-mask.geojson.gz) preserve the original
PBF identity, clipping input, and archive identity. For a recovery build,
decompress the mask with `gzip -dc` and verify the uncompressed bytes
against the manifest before building. Verify and qualify the rebuilt graph
before deploying it.

A planet build (`--coverage planet`, no mask) uses the same builder. The
2026-11-24 planet release has no elevation. It took 3 hours 25 minutes,
peaked at 535 GB of scratch and 39 GB of memory, and wrote 209,979 tiles in
104.6 GB. It was built before `build_graph.py` gained `--elevation`, so its
manifest has no `elevation` field. A build graded with the Copernicus DEM was made alongside it and
not shipped (see the elevation check below). Converting the DEM read 589 GB
in about 95 minutes with 16 jobs and wrote 160 GB of tiles. The graded build
took 4 hours 39 minutes, 67 of them in Valhalla's elevation stage, peaked at
41.6 GB of memory and 803 GB of scratch, and wrote 107.6 GB. On 2026-11-25
an ungraded and an opened-Copernicus build ran side by side on one builder
in about 7 hours from the download to both archives, peaking at 1,225 GB of
scratch (see [Planet gate](#planet-gate-for-copernicus-opened-at-200-m)).
Check the VPS for the candidate, the current graph, transfer parts and the
50 GB reserve before transferring.

The first successful attempt took 3 hours 9 minutes from build start through
archive verification. Observed builder scratch use reached about 499 GB before
packaging, so leave margin for a retry and temporary transfer parts. The approved
archive held 165,327 tiles and occupied 66.3 GB before transport compression.
Build and verify off-host. The Coolify VPS serves the resulting archive.

## Qualify before leaving the builder

The chain's `qualify-ungraded` and `qualify-graded` stages run the first two
checks below and the profile probe on each archive, and its `gate` stage the
third. Their summaries are in `result.json`. The audit passes when no unit
fails beyond the 17 known exceptions (`builder/qualification.py`); a new one
fails the stage and needs the investigation described here.

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
- Before shipping a graph built with elevation, serve it beside an ungraded
  build of the same snapshot. Check that `use_hills` changes routes in hilly
  cities and that flat cities keep theirs. On 2026-11-24 the
  Copernicus-graded planet passed the first check: with `use_hills` 0 and 1,
  all 7 city pairs (two in San Francisco, and Lisbon, Stuttgart, Zurich,
  Wellington and Amsterdam) changed, and none changed ungraded. It failed
  the second. Across 40 Road and Everyday legs in 20 cities its routes were
  2.1% longer at the median and 11 were more than 5% longer. Everyday legs
  grew 21% in Buenos Aires, 17% in New York, 15% in Amsterdam, 12% in Tokyo
  and 11% in Houston. The DEM is a surface model, so buildings and trees
  read as terrain. It put 53–64% of a Buenos Aires leg on grades of 6% or
  more, and 13–37% of legs in Amsterdam, Houston and Berlin. Production
  stayed ungraded. City samples on 2026-11-25 found a source that passes
  both checks (see [Elevation sources on city samples](#elevation-sources-on-city-samples)),
  but the planet graded with it lengthened a Midtown Manhattan leg by 5.9%
  and stayed unshipped too (see [Planet gate](#planet-gate-for-copernicus-opened-at-200-m)).
  A planet opened at 400 m then lengthened one leg each in New York and
  Chicago, which a lidar terrain model kept on samples (see
  [USGS 3DEP](#usgs-3dep-for-the-united-states-on-city-samples)).
  Run `compare_elevation.py` against the two planet services as this check.
- Include a direct Valhalla miss in the Apple-listed interior near Fairview,
  Oklahoma. A live MapKit request there can still succeed. The first release
  also returned no route from either provider at Great Bear Lake in Canada.

## Elevation sources on city samples

On 2026-11-25 five elevation sources were compared on sample graphs of eight
cities, following [Compare elevation sources](README.md#compare-elevation-sources-on-city-samples).
Each city was built six times from the same box: ungraded, and graded with
each source. Then `compare_elevation.py` routed its legs with the backend's
Road and Everyday bodies.

- **Copernicus**: the production-approved GLO-30 tiles from
  `build_elevation.py`, as on the 2026-11-24 planet.
- **GEDTM30**: GEDTM30 v1.2.0 (OpenGeoHub), a 30 m bare-earth model.
- **Copernicus opened 100 m / 200 m**: the Copernicus tiles after a
  grey-scale morphological opening (`sample_elevation.py opening`) over an
  ellipse of 100 m or 200 m radius. The opening removes anything raised that
  is narrower than the ellipse, such as buildings and rows of trees.
- **GEDTM30 opened 200 m**: GEDTM30 after the same opening.

The flat cities were Buenos Aires, Amsterdam, Houston and Berlin. Each had
four street legs, and Amsterdam and Houston also had a leg through a wood
(the Amsterdamse Bos and Memorial Park). The hilly cities were Lisbon,
San Francisco, Zurich and Wellington, with four legs each.

The samples reproduce the planet failure. On the Copernicus sample, Buenos
Aires Everyday legs grew by up to 20.6% (21% on the planet), and 55% of the
ungraded routes' length read as 6%+ grade (53–64% on the planet).

| Source | Flat cities: median length change | Longest | Routes >5% longer | Median 6%+ share | Hilly legs changed by `use_hills` | Median 6%+ share removed by avoiding hills | Targets |
|---|---|---|---|---|---|---|---|
| Copernicus | +1.1% | +31.5% | 10 of 36 | 21% | 15 of 16 | 3 pts | missed |
| GEDTM30 | +0.6% | +15.4% | 8 of 36 | 14% | 15 of 16 | 5 pts | missed |
| Copernicus opened 100 m | 0.0% | +14.3% | 1 of 36 | 3% | 14 of 16 | 3 pts | missed |
| **Copernicus opened 200 m** | **0.0%** | **+1.1%** | **0 of 36** | **2%** | **12 of 16** | **4 pts** | **met** |
| GEDTM30 opened 200 m | 0.0% | +6.4% | 1 of 36 | 1% | 12 of 16 | 4 pts | missed |

"6%+ share" is the share of a route's length on edges whose steepest 60 m
section is 6% or more, as the graph itself reports. The last column judges
the hilly legs on the mean of every graded graph's heights, so no source
grades itself. The result holds with Copernicus, GEDTM30 or opened Copernicus
as the only referee. Using `use_hills` 0 instead of 1 rarely saved total climb
(median −1 to +1 m for every source). Valhalla penalises grade, not ascent, so
hill-avoiding routes often climb the same height more gently. The ungraded
graphs gave identical routes for both `use_hills` values on all 16 hilly
legs, and no route or `/trace_attributes` call failed.

Flat cities, by source (median length change, longest, median 6%+ share):

| City | Copernicus | GEDTM30 | Copernicus opened 200 m |
|---|---|---|---|
| Buenos Aires | +7.3%, +20.6%, 39% | +5.7%, +9.2%, 40% | 0.0%, +0.3%, 5% |
| Amsterdam | +3.5%, +31.5%, 24% | +0.9%, +15.4%, 10% | 0.0%, 0.0%, 0% |
| Houston | +0.2%, +1.1%, 11% | +0.2%, +5.8%, 5% | 0.0%, +0.4%, 1% |
| Berlin | +1.1%, +5.1%, 16% | 0.0%, +4.7%, 14% | 0.0%, +1.1%, 1% |

- **GEDTM30 does not remove the buildings of dense cities.** Along Avenida
  Rivadavia in Buenos Aires, a street at about 20–25 m, GEDTM30 ranges from
  18 to 47 m, as Copernicus does (19–49 m). The opened Copernicus ranges from
  16 to 26 m. GEDTM30 also left 17–20% of the forest legs on 6%+ grades.
- **The wood legs were the opening's expected weak point, and it held.**
  Through the Amsterdamse Bos, Copernicus made the route 31.5% longer and put
  29% of it on 6%+ grades. The opened Copernicus kept the route, with 3.5% on
  6%+ grades. Through Memorial Park it cut the 6%+ share from 39% to 1%.
- **The opening also lowers ridges and hilltops narrower than 400 m.** So
  `use_hills` changed fewer hilly legs (12 of 16, against 15 with
  Copernicus): Lisbon 4, San Francisco 3, Zurich 3 and Wellington 2. Where it
  acts, it removes as much steep riding as Copernicus does. Every source had
  one or two hilly legs where the hill-avoiding route had more than 2 points
  more 6%+ share; for the opened Copernicus these were −3 and −4 points.
- **Everyday detours can be long in steep cities.** In Lisbon, Baixa to
  Estrela grew from 2.5 to 3.7 km (+49%) with the opened Copernicus. Its
  6%+ share fell from 36% to 11%. That comes from Everyday's `use_hills`
  0.25, not from noise. Revisit the value once a graded graph ships.

GEDTM30's terms would allow production use, but it lost on the routes, so
its terms are moot for now:

- It is CC BY 4.0, so commercial use is allowed with attribution. Credit
  "GEDTM30 (Ho, Hengl et al., OpenGeoHub), CC BY 4.0". Its authors also
  credit the modified Copernicus DEM (© DLR e.V. 2010–2014 and © Airbus
  Defence and Space GmbH 2014–2018, provided under COPERNICUS by the European
  Union and ESA) and JAXA's AW3D30.
- The authors left FABDEM and FathomDEM out for licence reasons. Zenodo
  record 18887460 calls v1.2.0 a first release "for testing purposes only".
- The 30 m data is not archived on Zenodo, which holds only 240 m versions.
  It is one 432,407,644,715-byte COG on `s3.opengeohub.org` (ETag
  `8bf9b35f45e9befaa9b91d877bf230d7-3107`, modified 2026-09-23). A
  production build would need its own copy.

**Recommendation: grade the next planet build with Copernicus opened at
200 m. Do not use GEDTM30 or raw Copernicus.** The opening uses only the
production-approved Copernicus sources, so the topography source policy does
not change. It does change the production elevation, so it needed Chris's
approval. **Chris approved it on 2026-11-25.** The planet built that way
missed the gate in Midtown Manhattan and was not shipped (see
[Planet gate](#planet-gate-for-copernicus-opened-at-200-m)). The steps were:

1. Done: `build_elevation.py --opening-radius 200 --raw DIR` opens every
   cell with margins from its neighbours' raw tiles and records the method,
   radius and raw manifest in the elevation manifest and in each receipt;
   `build_graph.py` carries the method into the graph manifest (see
   [Build and release](README.md#build-and-release) for its cost). On the
   Buenos Aires cell S35W059 it gave the same tile as
   `sample_elevation.py opening --radius 200` run over the cell's 3 x 3
   neighbourhood. Against the single-cell tile these samples were graded
   with, 11,116 posts differ, all within 14 posts (430 m) of the cell's
   edge, where the sample repeated its edge posts instead of reading the
   neighbours: up to 8 m, median 1 m. Every Buenos Aires leg lies more than
   0.3° inside the cell.
2. Done: build the planet graded and ungraded from the same snapshot.
3. Done, missed: run `compare_elevation.py` against both planet services,
   with no `--city`, as the release gate. `elevation-probes.json` then held
   these eight cities and, marked `planetOnly`, the cities of the 2026-11-24
   planet check that they lack: Copenhagen, Paris, London, Munich, New York,
   Tokyo, Dubai and Stuttgart (16 cities, 45 legs). That check had 27 legs
   over the same 16 cities: 20 city legs and 7 hill legs. All 27 are in the
   file with the same coordinates, some under other names.

The samples used the pinned Valhalla image under amd64 emulation on a
laptop. One elevation-stage build segfaulted there and passed on a retry. The
OSM data was dated Geofabrik extracts of 2026-11-24 (SHA-256 prefixes):

- Argentina `692465776c6e`, used for Buenos Aires
- Noord-Holland `bca771baeede`, used for Amsterdam
- Texas `ed9e06b79ef6`, used for Houston
- Berlin `a9de543c5348`
- Portugal `4911a6ce24c4`, used for Lisbon
- California `7dc35f58ac74`, used for San Francisco. NorCal cuts the state
  boundary and leaves Valhalla's admin database empty.
- Switzerland `6c9b5e4d8f28`, used for Zurich
- New Zealand `ca1e09b6801d`, used for Wellington

### Planet gate for Copernicus opened at 200 m

On 2026-11-25 the planet was built twice from `planet-261116` (SHA-256
`297f73cc…`, the snapshot production serves): once graded with Copernicus
opened at 200 m, once without elevation. Both archives passed the smoke
(17 of 17), cross-border (4 of 4) and profile probes. The coverage audit
routed 281 of 298 units on each, with the same 17 exceptions as the
2026-11-24 planet. `compare_elevation.py run` then routed every city against
both services on the builder, with no `--city`. It missed one target:

| Check | Target | Result |
|---|---|---|
| Flat routes, median length change | at most 1% | 0.0% (56 routes in 11 cities) |
| Flat routes, longest | no route more than 5% longer | **+5.9%** (New York, Everyday): missed |
| Flat routes, median 6%+ share | at most 5% | 2% |
| Hilly legs that `use_hills` changes | at least half | 12 of 17 |
| 6%+ share of the hill-avoiding route | lower at the median | 6 points lower |
| Routes and grade lookups that failed | none | none |

| City | Routes | Median length change | Longest | Median 6%+ share | `use_hills` changed |
|---|---|---|---|---|---|
| Buenos Aires | 8 | 0.0% | +0.3% | 5% | – |
| Amsterdam | 10 | 0.0% | 0.0% | 0% | – |
| Houston | 10 | 0.0% | +0.4% | 1% | – |
| Berlin | 8 | 0.0% | +0.3% | 1% | – |
| Copenhagen | 4 | 0.0% | 0.0% | 0% | – |
| Paris | 4 | 0.0% | +0.4% | 3% | – |
| London | 4 | 0.0% | 0.0% | 1% | – |
| Munich | 2 | 0.0% | 0.0% | 0% | – |
| New York | 2 | +5.1% | **+5.9%** | 8% | – |
| Tokyo | 2 | 0.0% | 0.0% | 9% | – |
| Dubai | 2 | 0.0% | 0.0% | 0% | – |
| Lisbon | 8 | +1.6% | +48.8% | 25% | 4 of 4 |
| San Francisco | 8 | +0.8% | +13.1% | 18% | 2 of 4 |
| Zurich | 8 | +1.6% | +29.0% | 11% | 3 of 4 |
| Wellington | 8 | +3.3% | +21.6% | 28% | 2 of 4 |
| Stuttgart | 2 | −0.9% | +0.4% | 29% | 1 of 1 |

- **Midtown Manhattan keeps phantom hills.** Midtown to Brooklyn became
  4.3% longer on Road (9.00 to 9.40 km) and 5.9% longer on Everyday (8.87 to
  9.40 km). The ungraded routes take 5th Avenue or Broadway. On the opened
  graph these streets have 60 m sections of 13% to 32% on ground that
  barely slopes, so the graded routes take 7th Avenue, which has fewer. It
  seems that within 200 m of these streets, among the towers, Copernicus has
  no post at street level, so the opening cannot reach the ground. The other
  54 flat routes grew by at most 0.5%. Copenhagen's Everyday leg became 5.5%
  shorter, and Tokyo's Shibuya to Shinjuku leg did not change.
- **Hills work much as on the samples.** `use_hills` changed 11 of the 16
  hilly legs of the sample cities, one San Francisco leg fewer than on the
  city samples, and Stuttgart's one leg. Two hill-avoiding routes have more of their length on 6%+ grades than
  the direct ones: Lisbon, Rossio to Campo de Ourique (9 points more), and
  Stuttgart, Hauptbahnhof to Degerloch (7 points more). With one graded
  graph, routes are judged on its own heights. Without elevation, every
  hilly leg gave the same route for both `use_hills` values.
- **Chris rejected the candidate on 2026-11-26.** Production stays ungraded
  (`abe5e72e`). A wider ellipse reaches more street posts but also flattens
  more real ridges; the samples below test 300 m and 400 m (see
  [Opening radius](#opening-radius-on-city-samples)).

Build facts, on a `c4-highmem-24-lssd`:

- Raw tiles: 72 minutes with 20 jobs, reading 589.25 GB and writing
  160.40 GB, the same cells as on 2026-11-24. Four cells ran past the
  15-minute deadline; each built in seconds when retried. Because the fourth
  broke the third and last round, the run stopped, and running the same
  command again resumed from the receipts.
- Opening: 67 minutes with 20 jobs beside the ungraded Valhalla build, about
  3 s per cell per worker. It wrote 104.1 GB (65% of the raw tiles), and a
  worker peaked at 0.92 GB.
- Graphs: 4 hours 51 minutes each, ungraded with 16 threads and graded with
  20, overlapping for 3 hours. The graded build spent 57 minutes in
  Valhalla's elevation stage. Both together peaked at 1,225 GB of scratch,
  with both tile sets and the PBF on disk, and 49 GB of memory.
- Archives: ungraded 209,979 tiles, 104,563,353,600 bytes, `b9421752…` (the
  same tile count and size as production's `abe5e72e`). Graded 209,979
  tiles, 107,554,304,000 bytes, `ce870e0f…`, whose manifest records
  `grey-opening` with `radiusMetres` 200, elevation manifest `31e23896…` and
  raw manifest `d53d9beb…`.
- The logs, manifests and gate report are on the map VPS in
  `/root/bicino-routing-releases/builder-g261116/evidence.tgz`. The builder,
  its network and its keys were deleted on 2026-11-26.
- After the builds the builder sat idle for about 8 hours. A wait loop read
  an unreachable SSH hop as "still running". A loop that waits on the
  builder must stop and report when its check gets no answer.

### Opening radius on city samples

On 2026-11-26 the opening was repeated at 300 m and 400 m on city samples,
to see whether a wider ellipse reaches the street posts between Midtown's
towers. The samples were the eight cities above plus New York and Stuttgart,
built from Geofabrik extracts of 2026-11-24 (New York `0537ef31d952`,
Baden-Württemberg `bfe0f0225dca`). Each city's tiles were opened at 200, 300
and 400 m by `build_elevation.py --opening-radius R --raw RAW --bounds ...`,
the production code path with neighbour margins. Each city was then built
ungraded and once per radius from the same box. `compare_elevation.py`
judged hill avoidance on the mean of the three graded graphs' heights.

| Radius | Flat routes: longest | Flat routes: median 6%+ share | New York Everyday | Hilly legs `use_hills` changes | Median 6%+ share saved | Climb on the same 17 hilly routes | Targets |
|---|---|---|---|---|---|---|---|
| 200 m | +5.9% | 2% | +5.9% | 13 of 17 | 3 pts | 2,102 m | missed |
| 300 m | +5.9% | 0.5% | +5.9% | 15 of 17 | 0 pts | 1,900 m | missed |
| **400 m** | **+0.4%** | **0%** | **0.0%** | **12 of 17** | **4 pts** | **1,762 m** | **met** |

The flat columns cover 38 routes in Buenos Aires, Amsterdam, Houston, Berlin
and New York; the median length change was 0.0% at every radius. No route or
grade lookup failed, and the ungraded graphs gave the same route for both
`use_hills` values on all 17 hilly legs. 400 m also meets the targets when
the hilly legs are judged on the 200 m or on the 400 m heights alone.

- **The 200 m sample reproduces the planet's New York result.** Everyday
  went from 8.87 to 9.40 km (+5.9%), as on the planet. The sample's
  ungraded Road route already takes 7th Avenue, unlike the planet's, so its
  Road leg does not show the detour.
- **300 m is not enough.** It cuts the 6%+ share of the direct New York
  route from 12% to 3%, but Everyday still takes the 7th Avenue detour. It
  also made one Amsterdam Everyday leg 2.7% longer.
- **400 m keeps every flat route and still avoids hills, but flattens
  narrow ones.** The opening removes anything narrower than about twice the
  radius, and some real hills are that narrow. On the same 17 routes, the
  400 m tiles report 16% less climb than the 200 m tiles. The losses fall
  on short, steep hills: Cais do Sodré to Graça in Lisbon (99 to 59 m),
  North Beach to Pacific Heights over Russian Hill in San Francisco (96 to
  54 m), and the railway station to Hataitai over Mount Victoria in
  Wellington (154 to 77 m). `use_hills` changes 2 of Lisbon's 4 legs at
  400 m, against 4 at 200 m. The broad slopes of Zurich and Stuttgart lose
  at most 5% of their climb, while the Ferry Building to Twin Peaks loses
  21% (277 to 218 m).

**Recommendation: if a graded planet is still wanted, grade it with
Copernicus opened at 400 m.** It is the first radius that passes the gate on
the samples. Riders in cities with short, steep hills such as Lisbon get
weaker hill avoidance than 200 m would give. Today's ungraded graph gives
them none, and in dense high-rise cores like Midtown 400 m does not invent
hills. The samples hold one high-rise core, New York. The planet gate covers
Tokyo and Dubai as well, but none of São Paulo, Hong Kong, Singapore or
Chicago. A planet build at 400 m (about 7.5 hours on the builder, then
the gate) needs Chris's approval.

The New York state extract lacks one member of the New York State boundary
relation (r61320): way 29307896, the NY/VT/MA tri-state marker, last edited
in 2022. Without it Valhalla builds no admin polygon. For the sample, that way
was fetched from the OpenStreetMap API and merged into the admin input. The
reports, tile and graph manifests, and the merged admin input are on the
map VPS in
`/root/bicino-routing-releases/opening-radius-samples-20261126/samples-evidence.tgz`.

That planet was built on 2026-11-26 and missed the gate on two legs, both in
the United States (see [USGS 3DEP](#usgs-3dep-for-the-united-states-on-city-samples)).

### USGS 3DEP for the United States on city samples

The planet graded with Copernicus opened at 400 m (2026-11-26, archive
`33ec2c77…`) met every target except "no flat leg more than 5% longer". Two
Road legs missed it. New York, Port Authority to the United Nations, went
from 2.09 to 2.68 km (+28.2%). Chicago, Magnificent Mile to the South Loop,
went from 2.71 to 2.97 km (+9.5%). Every other flat leg stayed within +0.4%.
A wider ellipse is not an option, because 400 m already removes 16% of the
real climb on hilly routes. Both cities are in the United States, where the
USGS publishes 3DEP, a terrain model made from lidar with buildings and
trees removed. On 2026-11-26 it was tried on samples of New York, Chicago,
San Francisco and Houston, and at seven border crossings.

**3DEP fixes both legs, and a hybrid elevation set is worth a planet build:
3DEP where it has data, Copernicus opened at 400 m elsewhere.** Chris
approved 3DEP as an elevation source for routing on 2026-11-26, and
`build_elevation.py` now writes the hybrid (see the recommendation below).
No planet has been built with it. Nothing in production, in development or
in the topography source policy changed.

The source:

- **Product.** USGS 3D Elevation Program, 1/3 arc-second seamless DEM: one
  GeoTIFF per degree, named by its north-west corner, 10,812 pixels square
  with six pixels of overlap, float32 metres, no data as −999999. Heights
  are bare earth, with water flattened.
- **Where.** `https://prd-tnm.s3.amazonaws.com/StagedProducts/Elevation/13/TIFF/`
  has each tile under `current/` and every dated version under
  `historical/`. The tiles change as new lidar arrives, so a build must name
  dated files. On 2026-11-26 `current/` held 1,449 tiles and 494 GB: 968
  tiles in the conterminous United States, 442 in Alaska and 39 in Hawaii,
  Puerto Rico and the territories.
- **Licence.** Public domain. The USGS asks for an acknowledgement and that
  anyone who modifies the data describes the changes, without implying its
  endorsement. A build resamples the tiles and blends their edge.
- **Coverage.** The newest tiles hold no data beyond the border. In the
  tiles of the crossings tested here, dated 2019 to 2026, Tijuana, Ciudad
  Juárez and Windsor are all no data, as is the open sea. Older tiles are
  different: they carry fill for Mexico and Canada from other sources. The
  2013 tile of cell N30W107 lies wholly in Chihuahua and has a height at
  every post, and so do the Mexican parts of the tiles beside El Paso's.
  Nobody tested or approved that fill, so a build cuts every tile to the
  United States (see the recommendation). The review of the build change
  caught this; the samples of this section lie in cells without such fill.
- **Datums.** NAD 83 and, in the conterminous states, NAVD 88. Copernicus
  uses WGS 84 and EGM2008. NAD 83 differs from WGS 84 by a metre or two on
  the ground, far less than the 30 m between posts. The height datums differ
  by a slowly varying offset: in seven border windows raw Copernicus read
  0 to 1 m above 3DEP at the median. A constant offset makes no grade, so
  the datum matters only where the two sources meet, and there it is the
  smaller part of the step (see the seam below).
- **Resampling.** `sample_elevation.py tiles` writes each cell from its own
  tile with the bilinear resampling the other tiles use. A 1 arc-second post
  lies on the corner of four 1/3 arc-second pixels. GDAL widens the kernel
  by the ratio of the grids, so each post is a weighted mean of the six by
  six pixels around it, not a point sample.

| HGT cell | Tile (`historical/`) | Bytes | SHA-256 |
|---|---|---|---|
| N40W074 (New York) | `USGS_13_n41w074_20260917.tif` | 165,776,270 | `76c761bf69dd` |
| N40W075 (New York) | `USGS_13_n41w075_20261028.tif` | 496,124,434 | `063663abd575` |
| N41W088 (Chicago) | `USGS_13_n42w088_20260902.tif` | 348,304,242 | `a9839a5e6fe3` |
| N37W123 (San Francisco) | `USGS_13_n38w123_20250826.tif` | 222,936,410 | `73c9935d3b75` |
| N29W096 (Houston) | `USGS_13_n30w096_20260623.tif` | 487,781,914 | `33a986ecb9ab` |
| N32W118 (San Ysidro) | `USGS_13_n33w118_20260915.tif` | 58,516,034 | `f75008dd2e97` |
| N32W117 (Otay Mesa) | `USGS_13_n33w117_20260915.tif` | 202,223,291 | `4926f045b973` |
| N31W107 (El Paso) | `USGS_13_n32w107_20240416.tif` | 126,302,566 | `359942a09209` |
| N42W084 (Detroit) | `USGS_13_n43w084_20190412.tif` | 422,168,827 | `5db0e3989b66` |
| N31W111 (Nogales) | `USGS_13_n32w111_20240401.tif` | 279,886,312 | `df2c30b25f0a` |
| N32W116 (Calexico) | `USGS_13_n33w116_20240327.tif` | 172,746,979 | `3ae2c0f1121e` |
| N45W073 (Derby Line) | `USGS_13_n46w073_20260331.tif` | 9,834,031 | `e26d02871d3f` |

#### A sample needs the country relation

The first Chicago sample did not reproduce the planet. Its opened-400 graph
made the Road leg 1.5% longer, not 9.5%, because its ungraded route was
already another one: 2.729 km by Wabash Avenue, where the planet's is
2.711 km down State Street.

- **It was not the map data.** The sample used the Geofabrik extract of
  2026-11-24 and the planet a snapshot of 2026-11-16. No way of either
  route had changed since 2026-09-26, and no node of the streets where the
  routes differ since 2026-11-15.
- **It was not the size of the box.** A box of half a degree gave the same
  route.
- **It was the admin input.** A state extract cuts the country relation, so
  Valhalla builds the state polygon alone and writes no `admin_access` row.
  That row holds a country's default access rules. The United States row
  gives bicycles pedestrian streets, bridleways and paths, and a sample
  without it falls back to Valhalla's own defaults for them.

With the complete United States relation (r148838, from the OpenStreetMap
API's `relation/148838/full`) merged into the admin input, the samples match
the planet's gate report. Of the 28 Road and Everyday routes of the four
cities, 22 have the planet's ungraded and opened-400 lengths to the metre,
and the six San Francisco routes are within 1 m with the same change. The
samples of 2026-11-25 and 2026-11-26 above were built without the relation.
Their graded and ungraded graphs share that fault, so each comparison is
still like for like, but their routes are not always the planet's. Every figure below
comes from samples with the relation, built from the extracts above and
Illinois `b5fe99c6154b` (2026-11-24), whose state relation also lacked five
ways.

#### Routes

Each city was built ungraded, graded with Copernicus opened at 400 m by
`build_elevation.py`, and graded with 3DEP. San Francisco also has the 200 m
opening.

| City | Source | Routes | Longest leg change | Routes over 5% longer | 6%+ share of the ungraded routes | `use_hills` changed | Climb on the ungraded routes |
|---|---|---|---|---|---|---|---|
| New York | Copernicus opened 400 m | 6 | **+28.2%** | 1 | 11% | – | 134 m |
| New York | **3DEP** | 6 | **0.0%** | 0 | 0% | – | 103 m |
| Chicago | Copernicus opened 400 m | 4 | **+9.5%** | 1 | 9% | – | 102 m |
| Chicago | **3DEP** | 4 | **0.0%** | 0 | 3% | – | 50 m |
| Houston | Copernicus opened 400 m | 10 | +0.4% | 0 | 0% | – | 109 m |
| Houston | **3DEP** | 10 | +0.2% | 0 | 0% | – | 161 m |
| San Francisco | Copernicus opened 200 m | 8 | +13.1% | – | 18% | 2 of 4 | 893 m |
| San Francisco | Copernicus opened 400 m | 8 | +2.7% | – | 13% | 4 of 4 | 709 m |
| San Francisco | **3DEP** | 8 | +3.4% | – | 25% | 2 of 4 | 912 m |

The shares are medians. Over the 20 flat routes 3DEP changed lengths by 0.0%
at the median and by +0.2% at most, with a median 6%+ share of 0%, and
`compare_elevation.py summary` reports that it meets every target. No route
or grade lookup failed, and the ungraded graphs gave the same route for both
`use_hills` values.

- **Both failed legs keep their route.** Along 42nd Street, 3DEP reads 13 m
  at 8th Avenue, 22 m at the crest and 15 m at 1st Avenue, and its steepest
  60 m section is 3.3%. The opened tiles read 20, 46 and 26 m, with a
  section of 11.6%: a plateau of towers that the 400 m ellipse cannot reach
  under. State Street is level at 181 m on 3DEP. On the opened tiles it
  runs from 174 to 198 m and back, over the same four edges of 8% to 13% as
  on the planet.
- **Houston holds as the flat control.** 3DEP reports more climb there than
  the opened tiles, because it keeps small real relief that the opening
  removes. One example is a 9 m rise on the West Lawn path in Memorial
  Park, which the opened tiles lack; it is most likely the land bridge over
  Memorial Drive, which is newer than Copernicus's 2011–2015 radar. It puts
  7% of that leg on 6%+ grades and moved no route.
- **San Francisco gets its hills back.** On the same eight routes 3DEP reads
  912 m of climb. The 400 m opening reads 709 m, 22% less, and half the
  6%+ share. `use_hills` changes two legs on 3DEP. The Wiggle falls from 25%
  to 6% of its length on 6%+ grades for 24 m more, and the leg to Twin Peaks
  becomes 3% longer for the same climb. The other two legs keep their
  route. On the opened-400 graph all four legs change, but three by 2 m of
  length. Judged on 3DEP's heights, its hill-avoiding route from North Beach
  to Pacific Heights climbs 21 m more than its direct one and has 7 points
  more of its length on 6%+ grades. With 3DEP as `--referee`, avoiding hills
  saves 9 points of 6%+ share at the median on the 3DEP graph, 1 point on
  the 200 m graph and none on the 400 m graph.
- **A terrain model reads the water under a bridge that Valhalla does not
  know is one.** Valhalla grades a bridge from its two ends, but the sample
  graphs mark only some `bridge` values as bridges. Michigan Avenue crosses
  the Chicago River on a bascule bridge tagged `bridge=movable`. Its 101 m
  edge is not marked, and on 3DEP it reads 12% down and up with a weighted
  grade of 8.3%, against 5% and 3.3% on the opened tiles, which hold the
  deck. Both Magnificent Mile routes cross it, which is where Chicago's 3%
  comes from, and neither moved. Of the highway bridges in the four samples,
  7% in New York, 15% in Chicago, 4% in San Francisco and 1% in Houston
  carry a value other than `yes`: `movable`, `covered`, `viaduct`,
  `boardwalk` or `pier`.

#### The seam at the border

Because 3DEP, cut to the United States, stops at the border, a hybrid is
made per post, not per cell:
3DEP where it has data, opened Copernicus elsewhere. `sample_elevation.py
tiles --fill` writes such a cell, and the seam runs along the border line.
The two sources were compared in a window around each crossing: over the
United States side, and at every post on the seam, where their difference
is the false part of the step a street would meet:

| Crossing | 3DEP above opened Copernicus on the US side: median (10th to 90th percentile) | Difference at the seam: median, 90th percentile, largest |
|---|---|---|
| San Ysidro, San Diego to Tijuana | 2 m (0 to 16) | 1, 18, 42 m |
| Otay Mesa, San Diego to Tijuana | 2 m (0 to 6) | 2, 5, 10 m |
| El Paso to Ciudad Juárez | 1 m (0 to 5) | 1, 2, 4 m |
| Detroit to Windsor | 2 m (0 to 6) | 5, 5, 5 m (in the river) |
| Nogales to Nogales | 8 m (0 to 27) | 9, 37, 72 m |
| Calexico to Mexicali | 1 m (0 to 2) | 1, 2, 4 m |
| Derby Line to Stanstead | 2 m (−3 to 15) | 3, 19, 31 m |

- **The step comes from the opening, not from the datum.** Raw Copernicus
  agrees with 3DEP to within a metre at the median. The opening never raises
  a post, so the opened surface lies under the ground: by a metre or two on
  flat land, and by 8 m at the median in the hills of Nogales, where it cuts
  ridges down.
- **On streets it makes a false grade, a small one.** Sample graphs of six
  crossings were graded with the hybrid and with opened Copernicus alone,
  and 33 car, bicycle and walking routes were sent across in both
  directions. Where the streets cross, 3DEP lies between 3 m below and 4 m
  above the opened tiles, and the hybrid turns that into a step over one
  post. At Calexico the edges at the crossing read a steepest grade of up
  to 6% and a weighted grade of up to 3.3%, where opened Copernicus alone
  gives 2% and 0%. At San Ysidro the steepest grade was 4% against 2%, at
  Otay Mesa 5% against 4%, and on El Paso's bridges, which Valhalla grades
  from their ends, 3% against 1%. Nogales and Derby Line read the same
  either way. Detroit and Windsor are joined by one bridge and one tunnel;
  the seam lies in the river, where 3DEP's water surface is 2 to 5 m above
  Copernicus's.
- **It does not steer routes today, but it should not ship as it is.** Every
  route across a border meets the seam once, so no crossing is favoured.
  The streets that cross lie in valleys, where the opening changes little.
  A street across a hillside would meet the larger steps of the table.
- **The build lifts the Copernicus side to meet 3DEP.** A first scratch
  test ramped 3DEP down to the opened surface over the 16 posts inside its
  own edge. That removed the step, but it also pulled real ground down: the
  Calexico crossing stands on the bank of the New River's valley, which
  3DEP and raw Copernicus both show about 10 m deep, and the opening had flattened
  the bank. `build_elevation.py --terrain-sources` therefore leaves 3DEP's
  posts alone. It lifts the opened posts within 16 posts (about 500 m) of
  3DEP's data by the difference at the edge, fading to nothing. On the
  Calexico cell built that way, 3DEP's 4,355,711 posts are unchanged and
  the opened posts beside them are lifted. The difference between the two
  sides of the edge fell from 2 m at the median, 5 m at the 90th percentile
  and 164 m at the most to 0 m, 0 m and 13 m. The 164 m was a 528 m summit
  in the mountains at the west end of the cell, which raw Copernicus also
  reads as 528 m and the opening had cut to 365 m. In Valhalla the outbound
  crossing edge reads 2% in place of 4%, and the inbound one 4% in place of
  6%, where opened Copernicus alone reads 1% and 2%. What is left is the
  valley's bank.

#### Recommendation

**Build a hybrid planet, if Chris approves 3DEP as a source.** On the gate's
legs it turns the two missed legs into 0.0%. If the other legs repeat the
400 m planet's results, no flat leg is then more than 0.4% longer and
`use_hills` changes 10 of 17 hilly legs (San Francisco two instead of
four), which still meets the target of half. Riders in the United States
also get real hills in place of the opened ones. Before a planet build:

1. **Chris approves USGS 3DEP 1/3 arc-second as an elevation source for
   routing.** Done on 2026-11-26. The approval is recorded in
   [elevation-sources.json](elevation-sources.json), a source list for
   routing alone, and not in `config/topography-source-policy-v2.json`.
   That file's loader accepts only the Copernicus tiles
   (`copernicus-cog-v1`, a surface model on EGM2008), and it is an input of
   the map-platform image and of the offline-map worker's build identity,
   so a change to it would rebuild the image and move the signed worker.
   The list covers the conterminous United States, where the samples
   tested 3DEP. It pins the area, OpenStreetMap's boundary of the country
   with its territorial sea, and
   [a catalog](usgs-3dep-13-tiles-20261126.txt) of the 955 dated tiles
   (364 GB) whose cells touch it; 13 more tiles of the bucket lie wholly in
   Mexico or Canada. Alaska's tiles come from
   radar, and Hawaii and the territories use other height datums; they stay
   on opened Copernicus until someone tests them.
2. **`build_elevation.py` learns the hybrid.** Done:
   `--terrain-sources` downloads the catalog's tiles, checks each against
   its size and ETag, cuts it to the area, and writes 3DEP's posts over the
   opened Copernicus tiles, lifting the Copernicus side at 3DEP's edge (see
   [Build and release](README.md#build-and-release)). The Calexico and El
   Paso cells were built that way on a laptop, each with the tiles around
   it: about 11 minutes a cell, most of it downloading six or seven 3DEP
   tiles. In both, the terrain tile equals the one `sample_elevation.py
   tiles` wrote wherever it keeps data, and the hybrid equals 3DEP at every
   post 3DEP has. The cut matters at El Paso. Its own tile, of 2024, held
   10,271 posts just beyond the boundary, and the tiles west and south-east
   of it held 10.2 and 11.7 million posts of fill for Mexico. With those
   dropped, the difference across 3DEP's edge fell from 1 m at the median,
   3 m at the 90th percentile and 38 m at the most to 0, 1 and 2 m.
   Calexico's figures are with the seam above. One catalog tile, N34W076
   in the Atlantic off North Carolina, has no Copernicus cell and is left
   out.
3. **Every bridge is graded as a bridge.** Done: Valhalla's tagging rules
   call a way a bridge only when `bridge` is `yes` or `1`.
   `build_graph.py --all-bridges` builds with those rules changed in one
   line, so that every value but `no`, `false` and `0` is a bridge (see
   [graph_lua.py](graph_lua.py)). On the Chicago sample the Michigan Avenue
   edge then reads 0% up and 1% down on 3DEP, with a weighted grade of 0.0,
   where it read 12% both ways. The 6%+ share of the Magnificent Mile Road
   route fell from 8% to 4%; what is left is Upper Wacker Drive, a deck that
   OpenStreetMap does not tag as a bridge. All four Chicago routes kept
   their length on 3DEP, the opened-400 graph still made the Road leg 9.5%
   longer, and the ungraded routes have the same lengths with and without
   the rule. Build the ungraded twin with it too, so that the gate compares
   graphs that differ in elevation alone. `build_graph.py` refuses a
   terrain-graded elevation set without the flag.

   A bridge mapped in several pieces is still graded piece by piece, so a
   node over water takes the water's height. El Paso's Santa Fe bridge is
   split at the border, and its 116 m piece reads 3% on 3DEP, from a levee
   at 1,132 m down to the river at 1,128 m; opened Copernicus, which
   flattens the levees, reads 1%. On six bridges in New York (Brooklyn,
   Manhattan, Williamsburg, Queensboro, Pulaski and Roosevelt Island) no
   bridge edge reads 5% or more on either source, and all six routes are
   the ungraded ones. A bridge split in mid-span over a deep gorge should
   read far worse on either source; no leg tests one.
4. **Build the planet and run the gate.** Reading 3DEP adds up to 494 GB of
   downloads to the elevation stage.

What a hybrid does not fix: high-rise cores outside the United States stay
on Copernicus opened at 400 m. The gate's Singapore, Shanghai, Dubai and
Tokyo legs kept their routes on the 400 m planet, and a survey of 36 more
downtowns found one that did not, Toronto (see
[below](#toronto-a-tower-downtown-the-hybrid-does-not-fix)). Hill avoidance
outside the United States also stays as weak as the 400 m opening leaves it.

The reports, tile and graph manifests and the scratch scripts were not
copied to the map VPS, because this work was not to touch the hosts. They
are in the sessions' notes folder on Chris's Mac, under
`usgs-3dep-samples-20261126/`.

#### Toronto: a tower downtown the hybrid does not fix

On 2026-11-26 another session routed 58 legs in 36 tower downtowns outside
the United States on the 400 m planet's two gate services, with New York
and Chicago as controls. Its report and scripts are on the map VPS in
`/root/bicino-routing-releases/opened-400-downtown-survey-20261126/`. Of
92 routes in flat cities one breaks the 5% rule: Toronto, Rogers Centre to St Lawrence Market, Everyday
from 2.006 to 2.710 km (+35.1%), leaving Front Street West for Adelaide
Street. Union Station to Yonge-Dundas Square is 2.8% longer on Road, and 22%
of it reads 6% or more. Melbourne's Collins Street (Road +7.5%) and Seoul's
Teheran-ro (Everyday +8.2%) change on real slopes and were not judged; no
other leg is more than 2.9% longer.

Both Toronto legs are now in `elevation-probes.json` as a flat city, so a
planet gate sees them. **A hybrid planet built as approved grades Toronto
with the same opened tiles and would miss the gate on the first leg.**

A city sample shows the same, and that a terrain model repairs it. Toronto's
box was cut from Geofabrik's `ontario-261125.osm.pbf` (1,016,225,213 bytes,
SHA-256 `0edd1904…`, MD5 as published) by `prepare_sample.py`, with Canada's
relation 1428125 merged in; Ontario's boundary is whole in the extract.
Three sample graphs were built from it with `build_graph.py`'s build, none
with `--all-bridges`: ungraded, graded with the cell opened at 400 m by
`build_elevation.py`, and graded with MRDEM-30's terrain model read over
the cell on 2026-11-26 (bilinear, onto the cell's own posts, heights left
in CGVD2013) and written by `sample_elevation.py tiles`.

| Leg, profile | Ungraded | Opened at 400 m | MRDEM-30 terrain |
|---|---|---|---|
| Rogers Centre to St Lawrence Market, Road | 2.006 km | 2.006 km, 20% at 6%+ | 2.006 km, 9% at 6%+ |
| Rogers Centre to St Lawrence Market, Everyday | 2.006 km | **2.710 km (+35.1%)**, other streets | 2.006 km, 9% at 6%+ |
| Union Station to Yonge-Dundas Square, Road | 1.416 km | 1.455 km (+2.8%), other streets | 1.416 km, 0% at 6%+ |
| Union Station to Yonge-Dundas Square, Everyday | 1.455 km | 1.455 km, 16% at 6%+ | 1.455 km, 0% at 6%+ |

The opened sample gives the survey's numbers, 2.006 to 2.710 km on the
first leg and +2.8% on the second, so the sample stands for the planet here
as it does in New York and Chicago. On MRDEM-30 all four routes are the
ungraded ones. 9% of the first leg still reads 6% or more; the terrain model
falls from 89 m at the Rogers Centre to 81 m at Simcoe Street, and which
edges read steep was not looked at. The sample went through the tools by
hand, not through `builder/rehearse.sh`.

The heights below were read on a laptop from four sources: the Copernicus
cell N43W080 built raw and opened at 400 m by `build_elevation.py`, the
3DEP tile the catalog pins for that cell
(`USGS_13_n44w080_20230227.tif`), and Canada's MRDEM-30 terrain model.
Metres, each in its own height datum; the lake shows how far those differ.

| Point | Copernicus raw | Opened at 400 m | USGS tile | MRDEM-30 terrain |
|---|---|---|---|---|
| Rogers Centre, Front Street West | 79 | 71 | 89.9 | 89.0 |
| Front Street at Simcoe | 87 | 65 | 79.8 | 81.3 |
| Union Station | 96 | 75 | 79.8 | 79.7 |
| Front Street at Bay | 82 | 75 | 79.8 | 79.6 |
| St Lawrence Market, Front Street East | 80 | 71 | 78.8 | 76.4 |
| King at Bay | 106 | 77 | 82.7 | 82.8 |
| Adelaide at Bay | 89 | 78 | 85.3 | 85.0 |
| Queen at Bay | 85 | 79 | 87.9 | 89.9 |
| Yonge-Dundas Square | 94 | 89 | 91.9 | 91.9 |
| Lake Ontario off the harbour | 75 | 74 | 75.8 | 75.1 |

- **The opening spreads pits.** In the downtown box (43.635° to 43.66° N,
  79.40° to 79.36° W, 13,195 posts) raw Copernicus has 202 posts below the
  lake's 74 m, the lowest at 53 m. Whether they are excavations open at
  the time of the radar survey or radar errors between the towers was not
  found out. Opened, 2,961 posts (22%) read below the lake. An opening gives a post the highest of
  the lowest heights within 400 m, so where pits lie closer together than
  that, every disk holds one and the ground between them sinks to the
  pits. On the straight line between the first leg's ends the opened tile
  reads 65 to 75 m, median 71 m, and both terrain models a median of 80 m:
  Front Street becomes a trench up to 9 m below the lake, under King,
  Adelaide and Queen Street at 77 to 79 m. This is the opposite of
  Midtown's humps, and a larger radius would spread it further.
- **3DEP holds heights there, and the build drops them on purpose.** The
  tile has a height at every post of the cell and reads Front Street at 79
  to 80 m. The footprint table published beside it
  (`USGS_13_n44w080_20230227.gpkg`) names two New York lidar projects of
  2019 and 2020 for the United States' shore, and for the rest only
  "Photogrammetric mass points and breaklines" or "Unknown", without dates.
  The approval covers lidar terrain inside the United States, and such fill
  exists only in the cells that touch it, so the cut at the border stays.
- **Canada publishes a terrain model that covers it.** MRDEM-30 of Natural
  Resources Canada (Open Government Licence - Canada, record
  `18752265-bda3-498c-a4ba-9dfe68cb98da` on open.canada.ca) is a 30 m
  terrain model of all of Canada: the lidar mosaic (HRDEM) resampled from
  1 m where it exists, and elsewhere Copernicus GLO-30 with a forest and a
  settlement removal model applied. It is one cloud-optimised GeoTIFF of
  83,854,027,098 bytes, last changed 2026-06-24, made to be read in ranges:
  `https://canelevation-dem.s3.ca-central-1.amazonaws.com/mrdem-30/mrdem-30-dtm.tif`,
  in Canada Atlas Lambert (EPSG:3979) with heights in CGVD2013. At the ten
  points it is within 2.4 m of the USGS tile. Its source layer reads 10 in
  downtown Toronto, Montreal, Vancouver, Calgary and Ottawa and 1 in
  Nunavut, northern Quebec, Yukon and on the Minnesota side of the border;
  that was read here as lidar and Copernicus, without the product
  specification. The part that
  comes from Copernicus carries the Copernicus notice.
- **MRDEM-30 is not an approved source, and the build cannot read it.**
  Using it needs Chris's approval, an entry in `elevation-sources.json`, a
  reader for one projected file in place of 3DEP's degree tiles, Canada's
  boundary as its area, a look at the seam with 3DEP along the border, and
  samples of other Canadian downtowns.

The readings, the sample's report and manifests and the scripts are in the
sessions' notes folder on Chris's Mac, under
`usgs-3dep-samples-20261126/toronto/`.

### Tower-city samples

On 2026-11-26 the gate's seven high-rise cores were built as city samples
for the first time, to see whether a sample predicts the planet gate there.
Each was one run of `builder/rehearse.sh --city CITY --radius 400` on a
laptop: the city's box cut from its Geofabrik extract (files dated
2026-11-24 or 2026-11-25), the Copernicus cells around it opened at 400 m by
the production code path, an ungraded and a graded sample graph, and the gate
on that city. The planet rows are those of the 400 m planet's gate log (see
[USGS 3DEP](#usgs-3dep-for-the-united-states-on-city-samples)).

| City | Extract (SHA-256 prefix) | Sample: routes, longest, median 6%+ share | Planet gate | Sample run |
|---|---|---|---|---|
| Shanghai | `asia/china/shanghai` (`58bf1ece308b`) | 4, 0.0%, 0% | 4, 0.0%, 0% | 3 min |
| Hong Kong (report only) | `asia/china/hong-kong` (`0fa7e9c37b4a`) | 4, 0.0%, 6%; `use_hills` 0 of 2 | 4, 0.0%, 6%; 0 of 2 | 3 min |
| Singapore | `asia/malaysia-singapore-brunei` (`31b9cde91db4`) | 4, 0.0%, 2% | 4, 0.0%, 2% | 5 min |
| Dubai | `asia/gcc-states` (`8b0ac30242ee`) | 6, 0.0%, 0% | 6, 0.0%, 0% | 6 min |
| New York | `north-america/us/new-york` (`0537ef31d952`) | 6, **+28.2%**, 9% | 6, **+28.2%**, 9% | 9 min |
| Chicago | `north-america/us/illinois` (`b5fe99c6154b`) | 4, **+9.5%**, 7% | 4, **+9.5%**, 7% | 7 min |
| São Paulo (report only) | `south-america/brazil/sudeste` (`13205c5a3d00`) | 4, 0.0%, 15%; `use_hills` 1 of 2 | 4, 0.0%, 15%; 1 of 2 | 11 min |

- **All seven rows equal the planet's, in every column of the gate's
  table.** The two legs the planet missed are the two the samples miss:
  Port Authority to the United Nations in New York, Road from 2.09 to
  2.68 km (+28.2%), and the Magnificent Mile to the South Loop in Chicago,
  Road from 2.71 to 2.97 km (+9.5%). `compare_elevation.py summary` over the
  seven samples' reports reads "opened-400: misses: a flat leg is +28.2%
  longer", word for word the planet gate's. The samples took 44 minutes
  together; the planet build took about 7.5 hours to reach the same answer.
- **Only with the country relation.** The first runs used each extract's
  boundaries as they were. Chicago's worst route was then 1.5% longer, not
  9.5%, and São Paulo had a Road leg 6.8% longer that the planet lacks.
  New York still showed its +28.2%, with an Everyday change of +12.5% that
  the planet does not have. A box two and a half times as wide and three
  times as tall changed nothing in Chicago. With the complete relation of
  the United States, China and Brazil merged in (see
  [A sample needs the country relation](#a-sample-needs-the-country-relation)),
  every row matched. `prepare_sample.py` now does that for a city that
  lists the relation as `adminRelations`. Singapore's and Dubai's extracts
  hold their whole country.
- **State boundaries.** Illinois lacks five of the 349 ways of its state
  boundary in its extract, and New York State one. Without them Valhalla
  builds no admin polygon and the build stops, which is how the first
  Chicago run failed. Both cities list the ways as `adminWays`.
- **A sample run is mostly the download.** Geofabrik served 1 to 1.5 MB/s
  that day. With the extract on disk a city takes 2 to 3 minutes.
- **Judge all cities together.** One city's `summary` applies the pooled
  targets to that city alone: New York by itself also misses "flat median
  6%+ share" with 9%, which the pooled flat cities meet.

So an elevation method should pass the tower-city samples before a planet
is built with it. The 400 m opening would not have: the samples that chose
it on the morning of 2026-11-26 held only New York's first leg, which does
not change at 400 m. Copenhagen, Paris, London, Munich and Tokyo are still
planet-only, and Amsterdam, Berlin and Stuttgart do not list their country's
relation yet. Each run's result file, stage logs and gate report are in the
sessions' notes folder on Chris's Mac, in
`planet-builder-rehearsal-evidence-20261126.tgz`; the map VPS could not be
reached that day.

### Switching elevation off in tower zones

On 2026-11-27 another way to get past the towers was tried on city samples:
keep the 200 m opening, which keeps the hills, and write no data into the
tiles where tall buildings dominate, so that Valhalla grades those streets
as the graph without elevation does. [tower_mask.py](tower_mask.py) is that
step. It is a sample tool: its manifests record `bounds`, so `build_graph.py`
takes its tiles only for a `--sample` build.

**On these samples the masked tiles meet every gate target: all 14 routes of
the seven tower-city legs are the ungraded ones, and the hills keep 11% more
climb than at 400 m. They are not ready for a planet build, because a tower
zone on a real slope becomes a flat corridor; Wellington shows it** (see the
recommendation below). Nothing in production or development changed.

Eight cities were built four times each from the same box: ungraded, opened
at 400 m, opened at 200 m, and opened at 200 m with the mask. The boxes are
those of the earlier samples, cut by `prepare_sample.py` with the country
relation where the city lists one, from Geofabrik extracts of 2026-11-24
(Toronto's of 2026-11-25). The tiles were opened by `build_elevation.py
--opening-radius R --raw RAW --bounds ...`. The opened-400 sample rows equal
the 400 m planet's: New York +28.2%, Chicago +9.5%, Toronto +35.1% and +2.8%.

#### What Valhalla does with a post without data

Valhalla 3.9.2, the pinned image, was read and then tested. In its source,
the height of a point is the bilinear mean of the four posts around it,
leaving out those without data (`skadi/sample.cc`), an edge is sampled every
60 m, and a section with a sample without data gets the grade 0
(`skadi/util.cc`, `weighted_grade`). Bicycle costing reads only an edge's
weighted grade.

The test was a Chicago sample graded with a synthetic tile: a plane that
rises 4% to the east and 4% to the north, once whole and once with a
rectangle of no data over the Loop (4,745 posts). On a plane every street
has a known grade, so anything steeper is an artefact. 8,743 edge traversals
were read back from both graphs and from the ungraded one with
`/trace_attributes`:

| Where the edge lies | Edges read | On the graph with the hole |
|---|---|---|
| Inside the hole | 1,542 | Every one reads 0% up, 0% down and a weighted grade of 0, bridges and tunnels too |
| Outside | 6,943 | Every one reads what it reads on the whole plane |
| Across the boundary, streets | 225 | No cliff: the steepest section is 5%, against 7% on the whole plane. 15 traversals of edges up to 127 m long read 1 point steeper than on the plane |
| Across the boundary, bridges, tunnels and a ferry | 33 | 14 read a weighted grade of 3.3 and a steepest section of 3%, uphill out of the hole and downhill into it; 12 of them read something else on the plane |

- **A bridge, tunnel or ferry with one end in the hole is the one artefact.**
  Valhalla grades these from the heights of their two ends, takes the end
  without data as −32,768 m, and then clamps such edges to 3%. So the edge
  reads as a gentle slope, never as a cliff. On the masked sample graphs of
  this section, 0 such edges were found around New York's, Toronto's and
  Wellington's legs, 4 around Chicago's (0.34 km; 3 of them read 3%) and 2
  around San Francisco's (neither reads 3%).
- **`/height` answers `null` for such a point.** `compare_elevation.py`
  leaves those samples out of a route's climb. The backend never asks
  Valhalla for heights; its route profiles come from its own elevation
  providers.

#### The mask

- **Source.** GHS-BUILT-H R2023A of the European Commission's Joint
  Research Centre: the average net building height (ANBH) of 2018 on a
  3 arc-second grid in WGS 84, made from AW3D30, SRTM30 and Sentinel-2. Its
  pixel edges lie half an arc-second off whole arc-seconds, so every grid
  cell holds exactly three by three posts. It is published as 10-degree
  tiles (up to about 80 MB each) and as one 5.5 GB archive under
  `https://jeodpp.jrc.ec.europa.eu/ftp/jrc-opendata/GHSL/GHS_BUILT_H_GLOBE_R2023A/GHS_BUILT_H_ANBH_E2018_GLOBE_R2023A_4326_3ss/V1-0/`.
- **Licence.** CC BY 4.0, © European Union (the `copyright.txt` beside the
  data): reuse is allowed with credit and a note of what was changed. It is
  not an approved input of any build. Using it for a planet needs Chris's
  approval and a place for the credit.
- **OpenStreetMap heights were not used.** A rule on them would mask by
  how well a city is mapped. Of the building ways in the eight boxes, 98%
  carry `height` or `building:levels` in New York and 85% in San
  Francisco, but 49% in Chicago, 19% in Toronto and 7% in Wellington
  (Lisbon and Stuttgart 29%, Zurich 26%).
- **Rule.** A post's building height is that of its grid cell. A post is in
  a tower zone when the mean of those heights over an ellipse of 150 m is
  30 m or more, and so is every post within 200 m of such a post. The mean
  leaves a single tower among low roofs alone; the margin covers the slope
  that the plateau's edge left in the opened tiles.
- **Why 30 m and 200 m.** Around each city's legs every edge of a grid of
  routes was read from the 200 m graph (66 to 192 km of streets a city),
  and each rule was scored by how much of the length that reads 6% or more
  it switches off. That steepness is phantom in the three tower cities and
  real in the five hilly ones:

  | Threshold, mean, margin | New York | Chicago | Toronto | Lisbon | San Francisco | Zurich | Wellington | Stuttgart |
  |---|---|---|---|---|---|---|---|---|
  | 25 m, 150 m, 200 m | 75% | 96% | 98% | 12% | 17% | 1% | 23% | 2% |
  | **30 m, 150 m, 200 m** | **62%** | **95%** | **98%** | **1%** | **9%** | **0%** | **12%** | **0%** |
  | 30 m, 150 m, 100 m | 48% | 92% | 94% | 1% | 7% | 0% | 7% | 0% |
  | 35 m, 150 m, 200 m | 35% | 94% | 93% | 0% | 7% | 0% | 5% | 0% |

  At 30 m and 200 m the direct routes of all seven tower-city legs lose
  their steep sections (at most 3% of a route is left, on Midtown to
  Brooklyn, which reads 2 to 4% at 400 m too). A margin of 100 m leaves 9% of
  Port Authority to the United Nations steep. At 25 m the whole of
  Wellington's CBD to Kelburn leg is masked; at 30 m, 38% of it. In New
  York the rule covers 89% of the length that reads 10% or more; the rest
  of the steep length lies among lower buildings.
- **What it masks.** Share of each city's box, and places checked by name:

  | City | Masked | Inside | Outside |
  |---|---|---|---|
  | New York | 20.4 of 211 km² (9.7%) | Times Square, 5th Avenue at 42nd Street, Port Authority, United Nations, Wall Street, City Hall, Upper East Side, Downtown Brooklyn | Central Park, Greenwich Village, Park Slope, Williamsburg |
  | Chicago | 11.0 of 65 km² (17.0%) | The Loop, Magnificent Mile, Union Station, South Loop, West Loop | Lincoln Park, Pilsen |
  | Toronto | 8.0 of 76 km² (10.5%) | Union Station, Rogers Centre, St Lawrence Market, Yonge-Dundas Square, King at Bay | Kensington Market, the Annex, Cabbagetown |
  | Lisbon | 2.4 of 197 km² (1.2%) | Saldanha | Baixa, Graça, Castelo, Estrela, Campo de Ourique, Amoreiras |
  | San Francisco | 4.8 of 204 km² (2.4%) | Financial District, Ferry Building, SoMa | Nob Hill, Russian Hill, Pacific Heights, Twin Peaks, Castro, the Wiggle |
  | Zurich | 0 of 181 km² | – | Hauptbahnhof, Hardbrücke, Fluntern, Oerlikon, Hönggerberg |
  | Wellington | 4.4 of 182 km² (2.4%) | Lambton Quay, The Terrace, Kelburn | Te Aro, Mount Victoria, Hataitai, the railway station, Brooklyn |
  | Stuttgart | 0 of 245 km² | – | Hauptbahnhof, Schlossplatz, Degerloch |

- **The grid overstates heights on a steep slope.** It reads 26 m at the
  houses of Kelburn and 27 to 31 m at Victoria University, on the hillside
  above Wellington's towers (44 to 48 m on Lambton Quay and The Terrace),
  and 3 m in the Botanic Garden beside them. That is why Kelburn is masked.
- **Cost.** The step took 1.5 s a cell on a laptop.

#### Routes

`compare_elevation.py run` routed every leg of the eight cities against the
four services, and `summary` judged the reports together. The flat columns
cover the 14 routes of New York, Chicago and Toronto; the hilly ones the 17
legs of Lisbon, San Francisco, Zurich, Wellington and Stuttgart.

| Source | Flat routes: median length change | Longest | Routes over 5% longer | Median 6%+ share | 6%+ share of the direct routes: median, most | Hilly legs `use_hills` changes | Median 6%+ share saved | Targets |
|---|---|---|---|---|---|---|---|---|
| Opened at 400 m | 0.0% | +35.1% | 3 | 9% | 13%, 28% | 12 of 17 | 2 pts | missed |
| Opened at 200 m | +2.3% | +62.0% | 5 | 16% | 27%, 59% | 12 of 17 | 5 pts | missed |
| **Opened at 200 m, tower zones masked** | **0.0%** | **0.0%** | **0** | **0%** | **0%, 3%** | **11 of 17** | **6 pts** | **met** |

"Direct routes" are the ungraded routes measured on the graded graph: how
steep the source thinks the streets are that a rider would take. No route or
grade lookup failed, the ungraded graphs gave the same route for both
`use_hills` values on all 17 hilly legs, and the verdicts are the same with
any one source as `--referee`.

| Leg, profile | Ungraded | Opened at 400 m | Opened at 200 m | 200 m, masked |
|---|---|---|---|---|
| New York, Midtown to Brooklyn, Road | 9.01 km | 0.0% | +4.3% | 0.0% |
| New York, Midtown to Brooklyn, Everyday | 8.87 km | 0.0% | +5.9% | 0.0% |
| New York, Port Authority to the United Nations, Road | 2.09 km | **+28.2%** | **+62.0%** | 0.0% |
| New York, Port Authority to the United Nations, Everyday | 2.68 km | 0.0% | **+29.6%** | 0.0% |
| New York, City Hall to Bowling Green, both | 1.21 km | 0.0% | 0.0% | 0.0% |
| Chicago, Union Station to Michigan Avenue, Road | 2.56 km | 0.0% | −0.5% | 0.0% |
| Chicago, Union Station to Michigan Avenue, Everyday | 2.56 km | 0.0% | **+29.8%** | 0.0% |
| Chicago, Magnificent Mile to the South Loop, Road | 2.71 km | **+9.5%** | +1.9% | 0.0% |
| Chicago, Magnificent Mile to the South Loop, Everyday | 2.97 km | 0.0% | −7.0% | 0.0% |
| Toronto, Rogers Centre to St Lawrence Market, Road | 2.01 km | 0.0% | 0.0% | 0.0% |
| Toronto, Rogers Centre to St Lawrence Market, Everyday | 2.01 km | **+35.1%** | **+35.1%** | 0.0% |
| Toronto, Union Station to Yonge-Dundas Square, Road | 1.42 km | +2.8% | +2.8% | 0.0% |
| Toronto, Union Station to Yonge-Dundas Square, Everyday | 1.46 km | 0.0% | 0.0% | 0.0% |

- **Every tower-city route is the ungraded route again**, shape for shape.
  City Hall to Bowling Green shows why length alone is a poor judge: its
  route never moved, but 36% of it read 6% or more at 200 m and 13% at
  400 m. Masked, it reads 0%.
- **Around the legs the phantom steepness is gone, not only on them.** Of
  the streets read around New York's legs, 9.5 of 164 km had a section of
  6% or more on the 200 m graph and 3.5 km have one on the masked graph;
  around Chicago's, 5.3 of 98 km became 0.3 km; around Toronto's, 1.8 of
  66 km became none.
- **Lisbon, Zurich and Stuttgart are untouched.** Every route and every
  figure of theirs equals the 200 m graph's.
- **San Francisco keeps its routes.** All eight are within 2 m of the
  200 m graph's lengths, and `use_hills` changes the same two legs. The masked Financial
  District takes the lower end of Market Street out of the legs from the
  Ferry Building.
- **Wellington is worse than at 200 m.** `use_hills` changes one leg of
  four where it changed two, and the Everyday leg from the railway station
  to Hataitai is 6.62 km (+42.5%), where the 200 m graph gives 5.53 km
  (+19.1%) and the 400 m graph the direct 4.64 km. Its Road leg is 19.1%
  longer where the 200 m graph kept it. The longer route buys nothing:
  judged on the 200 m heights it climbs 175 m with 21% of its length on
  6%+ grades, against 158 m and 20% for the 200 m graph's route. From the
  CBD to Kelburn the masked graph gives one route for both `use_hills`
  values, and reads it as flat with no climb, where the 200 m tiles see
  97 m. The gate's targets do not judge any of this: Wellington is a hilly
  city, where only the count of changed legs and the pooled 6%+ share
  count.

#### Climb

Climb along the ungraded Everyday route of each hilly leg, from each tile
set's heights every 20 m, counting a rise once it reaches 3 m. For the
masked tiles only stretches with heights count, which is the climb Valhalla
still grades:

| Leg | Opened at 400 m | Opened at 200 m | 200 m, masked | Route without data |
|---|---|---|---|---|
| Lisbon, Cais do Sodré to Graça | 59 m | 99 m | 99 m | 0% |
| San Francisco, North Beach to Pacific Heights (Russian Hill) | 53 m | 92 m | 87 m | 8% |
| Wellington, railway station to Hataitai (Mount Victoria) | 73 m | 173 m | 172 m | 22% |
| Wellington, CBD to Kelburn | 82 m | 93 m | 79 m | 38% |
| Wellington, Thorndon to Karori | 170 m | 185 m | 102 m | 41% |
| San Francisco, Ferry Building to Castro | 62 m | 62 m | 38 m | 50% |
| All 17 hilly legs | 1,723 m | 2,070 m | 1,919 m | – |

The 400 m tiles report 17% less climb than the 200 m tiles, as on
2026-11-26. The masked tiles keep 93% of the 200 m climb, 11% more than
400 m, and 95% or more of it on the three hills the 400 m opening
flattened most. What they lose is in Wellington's masked hillside and on
Market Street.

#### Toronto's pits

The mask also covers the pits. In the downtown box of
[Toronto](#toronto-a-tower-downtown-the-hybrid-does-not-fix) (13,195 posts)
the 200 m tiles read 1,136 posts below the lake's 74 m, against 2,961 at
400 m and 202 raw: a smaller ellipse spreads the pits less. 891 of the
1,136 lie in the mask. Of the 245 outside, 143 are water or shore and 102
are land that the terrain model reads at 77 to 83 m and the tiles at 63 to
73 m. Measured against MRDEM-30, 1,844 posts read 5 m or more too low and
1,659 of them (90%) are masked; the rest lie west of the Rogers Centre and
east of the St Lawrence Market, outside the tower zone. Front Street is
masked from end to end, and no street read around the two legs keeps a
section of 6% or more. The pits need no rule of their own for these legs.
The ones outside the mask were not routed over.

#### Recommendation

**Do not build a planet with this mask as it is. Take the idea further.**

- **It does what it was meant to do.** On these samples 200 m with the mask
  meets every gate target, which neither radius does alone, and it keeps
  Lisbon's Graça at 99 m of climb against 59 m at 400 m, Russian Hill at
  87 m against 53 m and Mount Victoria at 172 m against 73 m.
- **A tower zone on a slope is the open problem.** Switching elevation off
  is right where the ground is flat and wrong where it climbs: the graph
  then prefers the masked streets because it cannot see their slope.
  Wellington's CBD is the one case in these samples. Hong Kong's Central
  and São Paulo's Avenida Paulista, both in the gate as report-only, were
  not run and are likely to be the same, and so is the hillside behind any
  tower core where the grid overstates heights.
- **Two ways to close it, neither tested.** Fill a tower zone with a smooth
  surface spanned from the heights around it, instead of no data: the
  towers go and a slope across the zone stays, and the 3% on bridges goes
  too. Or leave elevation on where the ground under the zone slopes; the
  broad slope of the 200 m tiles inside the masks does not separate the
  cases cleanly (Wellington's median is 6.8% over 300 m, but the plateaus
  of Chicago and New York reach 6 to 8% at their edges).
- **The rule was chosen on the cities it was judged on.** Three tower
  cities picked the threshold. Before a planet build, run the rule on the
  gate's other sample cities: Singapore, Shanghai, Dubai, Hong Kong and São
  Paulo for the towers, and Buenos Aires, Amsterdam, Houston and Berlin to
  see that it leaves low cities alone.
- **A planet build would also need:** Chris's approval of GHS-BUILT-H as an
  input and its credit; the step inside `build_elevation.py`, reading the
  5.5 GB grid per cell and recording it in the receipts; and a look at the
  grid's date. It describes 2018, and Copernicus was flown from 2011 to
  2015, so the grid should hold every tower the tiles hold.

The reports, summaries, tile and graph manifests, the mask pictures and the
scratch scripts are on the map VPS in
`/root/bicino-routing-releases/tower-mask-samples-20261127/`.

## Pull, assemble, and install on Coolify

Expose the approved immutable archive and receipt through a dedicated
read-only `rrsync` SSH identity on the builder. Generate its private key on
the VPS. Use a separate SSH config and pinned host key. Keep graph artifacts
on VPS disk and transfer them directly from the builder.

On a builder set up with [builder/](builder/README.md), the chain has linked
both archives into `export/`, and `authorize-export-key.sh` gives the
transfer key a user of its own, `bicino-export`, that can only read that
folder with rsync:

```sh
ssh -F "$job_config" builder "sudo /srv/bicino-routing-scratch/tools/repo/map-platform/routing/builder/authorize-export-key.sh" \
  < transfer-key.pub
```

The stager's source is then `bicino-export@ADDRESS:ungraded/valhalla_tiles.tar`,
or `graded/` for a graded graph, and its manifest is `export/ungraded/manifest.json`.

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
rule, subnet, and VPC. `builder/teardown.sh --job JOB` prints those deletions
and `--delete` runs them, then fails unless the instance, its disks, the
firewall rule, the subnet and the network are all gone. Deleting the builder
destroys everything on its scratch volume, so pull `export/` first. Its
elevation tiles go too. Those of the 2026-11-26 builder, raw and opened at
400 m, are kept in a bucket (see
[what is kept](builder/elevation-cache-proposal.md#what-is-kept)) and a
build can [restore them](builder/README.md#kept-elevation-tiles); tiles of
another method are not kept. Revoke and
remove the one-time transfer keys and remove
transfer segments and unused development sample archives from the VPS. Keep
the active graph, rollback archives, release manifest, and small test records.
