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
   with no `--city`, as the release gate. `elevation-probes.json` holds
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
