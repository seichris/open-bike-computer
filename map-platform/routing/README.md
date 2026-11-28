# Worldwide bicycle graph

Two coverages build from the same pipeline:

- **`planet`**: the whole planet, so Create a Route's Road, Gravel and
  Everyday routes work everywhere. It takes no mask. Production has served
  it since 2026-11-24: without elevation until 2026-11-28, and since then
  graded with elevation (`releases/2026-11-27.json`).
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
retains the exact clipping input. The
[planet release manifest](releases/2026-11-24.json) records the graph in
production now.

## Build and release

1. Use an on-demand Linux amd64 builder with Docker, Osmium, and Python 3.11 or
   later. The first worldwide run is sized for a Compute Engine
   `c4-highmem-24-lssd` with 1,500 GiB of scratch spread across four local SSDs.
   Confirm the credit-backed project and CPU and SSD quotas before provisioning.
   Stripe the temporary SSDs, keep the boot disk separate, and use a VM lifetime
   limit. The Linux builder only needs access to public inputs; reading the
   [kept elevation tiles](builder/README.md#kept-elevation-tiles) is the one
   exception, and optional.

   For a planet graph, the scripts in [builder/](builder/README.md) create
   that builder, set it up and run steps 3 and 4 and the elevation gate as one
   chain of systemd units that needs nobody watching. The
   [runbook](refresh-runbook.md#build-on-an-ephemeral-vm) has the commands.
   The steps below describe what the chain's stages run.
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

   Grading the graph with elevation makes `use_hills` work, but no
   production graph is graded yet. The Copernicus DEM below is a surface
   model, and on the 2026-11-24 planet it sent flat-city routes around
   buildings and trees (see [Refresh and rollback](refresh-runbook.md)).
   Chris approved on 2026-11-25 grading the next planet with the same
   Copernicus tiles after a 200 m grey-scale morphological opening, which
   kept flat-city routes on city samples while hill avoidance still worked.
   The planet graded that way still lengthened a Midtown Manhattan leg by
   5.9% and was not shipped (see
   [Planet gate](refresh-runbook.md#planet-gate-for-copernicus-opened-at-200-m)).
   A planet opened at 400 m still lengthened one leg each in New York and
   Chicago. On city samples USGS 3DEP, a lidar terrain model of the United
   States, kept both. Chris approved 3DEP as an elevation source for routing
   on 2026-11-26. That hybrid would still lengthen a leg in downtown
   Toronto, where the opening spreads pits of the Copernicus surface, so on
   2026-11-27 Chris also approved MRDEM-30, Natural Resources Canada's
   terrain model, for Canada. `build_elevation.py --terrain-sources` writes
   the hybrid of both and opened Copernicus. No planet has been built with
   it yet (see
   [USGS 3DEP](refresh-runbook.md#usgs-3dep-for-the-united-states-on-city-samples)
   and [MRDEM-30](refresh-runbook.md#mrdem-30-for-canada)).
   Compare a graded planet with an ungraded one before releasing it (see
   [Compare elevation sources](#compare-elevation-sources-on-city-samples)).

   To grade a graph, first write Valhalla's one-degree HGT tiles from the
   production-approved Copernicus sources in
   `config/topography-source-policy-v2.json` (GLO-30, then GLO-90 where
   GLO-30 has no cell). Run it in the map-platform image, which pins
   rasterio, with network access. For the planet (26,475 cells) it reads
   about 1 TB from the public COG mirrors and writes gzipped tiles, which
   Valhalla reads like plain HGT (690 GB unpacked). It keeps a receipt per
   cell, so an interrupted run resumes where it stopped. A cell still running
   after 15 minutes ends its worker, and the run builds the cells left without
   a receipt again, up to three rounds. If the third round also loses a
   worker, the run stops; run the same command again to resume. The first
   planet run read 589 GB in about 95 minutes with 16 jobs and wrote 160 GB.
   The second, on 2026-11-25, took 72 minutes with 20 jobs, including one
   such restart after four cells ran past the deadline.

   `--opening-radius 200 --raw DIR` writes those raw tiles to `DIR`, then
   opens every cell into `--out`. The opening is an erosion and then a
   dilation over an ellipse with 200 m half-axes. It removes anything raised
   that is narrower than about 400 m, such as buildings and rows of trees,
   and never raises a post. An arc-second of longitude shortens with
   cos(latitude), so the ellipse is 13 posts tall and, sized for each post
   row, 13 posts wide at the equator, 27 at 60° and 125 at 84°. Its
   half-width stops at 1,799 posts (half a cell), which binds only within
   0.2° of the poles. Each cell is opened from its own raw posts and a margin
   of its eight neighbours' raw posts two half-heights and two half-widths
   deep. Every post therefore gets the height it would have in an opening of
   the whole planet, whatever order the cells are opened in. Where
   neighbouring raw tiles share border posts, the southern and then the
   eastern tile's posts are used. No-data posts stay no data and take no
   part. With `--bounds`, the raw stage also builds the ring of neighbouring
   cells. Keep `--raw` outside `--out`, because Valhalla reads every tile
   below its elevation directory. Each opened cell's receipt records the
   method, the cell's raw receipt and the SHA-256 of every raw tile it read.
   A cell is opened again when one of those tiles or the radius changes, and
   a raw tile that no longer matches its receipt stops the run.

   ```sh
   docker run --rm -u "$(id -u):$(id -g)" -v "$routing_tools:/routing:ro" \
     -v "$build_scratch/elevation-raw:/raw" -v "$build_scratch/elevation:/out" \
     --entrypoint python3 "$map_platform_image" \
     /routing/build_elevation.py --raw /raw --out /out --opening-radius 200 --jobs 20 \
     --policy /app/map-platform/config/topography-source-policy-v2.json
   ```

   The opening stage reads only local raw tiles. On 2026-11-25 one Apple M3
   Pro core opened a cell in about 0.5 s at Buenos Aires (35° S), 0.6 s at
   Svalbard (78° N) and 0.65 s at the South Pole (S90E000, the widest
   window). About half of that is reading and hashing the nine raw tiles.
   Each row of the ellipse is a run of posts, and the minimum or maximum of
   a run is that of two overlapping power-of-two runs, so the cost grows
   with the logarithm of the ellipse's width. `sample_elevation.py`'s filter
   visits every post of the ellipse instead (1 s at 52°, 3 s at 80°, and
   minutes near the poles). The catalog has 26,475 cells; 3,996 of them lie
   beyond 80°, including 720 Antarctic cells south of 88° S. Cells are
   opened in catalog order, so neighbouring tiles are read close together.
   Plan about an hour on the builder. On 2026-11-25 a
   `c4-highmem-24-lssd` opened the planet in 67 minutes with 20 jobs, while
   a Valhalla build ran beside it: about 3 s per cell per worker, against
   0.5–0.65 s on the laptop core. A worker peaked at 0.92 GB. The opened
   tiles took 104 GB, 65% of the raw tiles' 160 GB, so `--out` needs at
   most another 160 GB beside `--raw`.

   `--terrain-sources` puts terrain models over the opened tiles.
   [elevation-sources.json](elevation-sources.json) lists the terrain
   sources approved for routing. It is kept apart from the topography source
   policy, which accepts only Copernicus and is an input of the map-platform
   image and of the offline-map worker's identity. A build uses every source
   of the list, each inside its own area. It holds four:

   - **USGS 3DEP**, the 1/3 arc-second lidar tiles of the conterminous
     United States, approved on 2026-11-26.
   - **MRDEM-30**, Natural Resources Canada's 30 m terrain model of Canada,
     approved on 2026-11-27. It is one 84 GB raster on a Lambert grid, made
     for reading in parts. It is lidar where Canada has lidar, which
     includes the centre of every larger city, and elsewhere Copernicus
     GLO-30 with forests and settlements taken out by NRCan.
   - **Sonny's LiDAR Digital Terrain Models of Europe**, version 25,
     approved on 2026-11-27 for the 20 countries it builds from national
     lidar and photogrammetry terrain models and for mainland Portugal
     outside a patch of SRTM around Porto (see
     [Regional terrain models](elevation-sources.md)). One person's
     compilation, one zip of an HGT file per cell in a public Google Drive
     folder; the posts are the cell's own, in each country's height datum.
   - **LINZ's New Zealand LiDAR 1m DEM**, approved on 2026-11-27: 424
     cloud-optimised sheets in a versioned public bucket, read at their 8 m
     overview inside LINZ's capture area, about 90% of the mainland.
   - **CEDD's LiDAR DTM 2020 of Hong Kong**, approved on 2026-11-27: 3,253
     zips of 0.5 m GeoTIFFs, made once into two cells kept in the elevation
     bucket, which a build reads alone (see
     [CEDD's lidar in the build](elevation-sources.md#cedds-lidar-in-the-build)).
   - **GSI's elevation tiles of Japan**, approved on 2026-11-27: DEM5A
     (lidar) where it has data and DEM10B (contours) elsewhere, crawled once
     from GSI's PNG tile pyramid into 122 cells kept in the elevation
     bucket (see [GSI's tiles in the build](elevation-sources.md#gsis-tiles-in-the-build)).

   Each source pins two files:

   - **The area**: OpenStreetMap's boundary of the country with its
     territorial sea, as a gzipped GeoJSON polygon. The newest 3DEP tiles
     hold no data beyond the border, but older ones carry fill for Mexico
     and Canada from other sources, and MRDEM-30 reaches into the United
     States along shared watersheds. Nobody tested or approved either there,
     so every post outside a source's area is dropped. The two countries'
     relations share the border's ways. Their areas overlap only in the sea
     around Machias Seal Island, which both claim; the source listed first
     gives the posts it has there. Sonny's area is the union of the 21
     countries' relations, Portugal cut to its mainland and less the patch
     where Sonny's tiles hold SRTM's posts, which `terrain_catalog.py
     srtm-fill` finds by comparing them with SRTM post by post.
   - **A catalog** of the cells that touch the area. For 3DEP it names
     [955 dated tiles](usgs-3dep-13-tiles-20261126.txt) (364 GB), each with
     its date, size and S3 ETag. MRDEM-30 has no dated copies, so
     [its catalog](nrcan-mrdem-30-cells-20261127.txt) names 2,480 cells and
     the source list pins the size and ETag of the one object. Sonny's
     [catalog](sonny-dtm-europe-1s-v25-tiles-20261127.txt) names each
     cell's Drive file, with the resource key a file made before 2021
     needs, and pins its size and SHA-256: Drive gives no ETag, and answers
     a file that has had too many downloads that day with a page of its
     own, which the hash stops. A copy of every file is kept in the
     elevation bucket, which the source list names as Sonny's `mirror`.
     LINZ's [catalog](linz-nz-lidar-1m-dem-sheets-20261127.txt) names each
     sheet's version, size, ETag and NZTM bounds, and the sheets each of its
     60 cells reads. CEDD's [catalog](cedd-hk-lidar-dtm-2020-tiles-20261127.txt)
     pins each kept tile's size and SHA-256 and that of the provenance file
     beside it, which names every zip the tile was made from; GSI's
     [catalog](gsi-japan-dem5a-dem10b-tiles-20261127.txt) does the same, its
     provenance naming every PNG tile read with its layer and ETag.

   [terrain_catalog.py](terrain_catalog.py) writes the files: an area from
   an `osmium export` of the relation, or of several for Sonny, 3DEP's
   catalog from the USGS bucket, MRDEM-30's from its area and Sonny's by
   downloading every tile of its Drive folder that touches the area. Record their sizes and SHA-256, the tile
   count and MRDEM-30's size, ETag and date in the source list. When NRCan
   replaces the object, a build stops until the new size and ETag are
   pinned; an earlier version cannot be read again.

   ```sh
   docker run --rm -u "$(id -u):$(id -g)" -v "$routing_tools:/routing:ro" \
     -v "$build_scratch/elevation-raw:/raw" -v "$build_scratch/elevation-opened:/opened" \
     -v "$build_scratch/elevation-terrain:/terrain" -v "$build_scratch/elevation:/out" \
     --entrypoint python3 "$map_platform_image" \
     /routing/build_elevation.py --raw /raw --opened /opened --terrain /terrain --out /out \
     --opening-radius 400 --terrain-sources /routing/elevation-sources.json --jobs 20 \
     --policy /app/map-platform/config/topography-source-policy-v2.json
   ```

   With `--terrain-files DIR` a source with a `mirror` reads its files
   from `DIR/SOURCE-ID/` first, where
   `builder/elevation_cache.py fetch-terrain --sources elevation-sources.json --into DIR`
   put them from the bucket; the builder's elevation stage does both. A
   file that is not there is read from the source's origin.

   The run then has four stages, each resumed from its receipts:

   - **Raw** Copernicus tiles in `--raw`, as before.
   - **Opened** tiles in `--opened`, where `--out` would hold them without
     a terrain source.
   - **Terrain** tiles in `--terrain`, one per cell that a source has a
     tile for; the 95 cells on the border of the two countries read both.
     - A 3DEP tile is downloaded over eight parallel ranges, and the cell
       stops if its size or ETag is not the catalog's, because the USGS has
       then replaced the tile. The tile must be laid out as its cell's 3DEP
       tile is: float32, NAD 83, three pixels per post, six pixels of
       overlap.
     - MRDEM-30 is read in ranges: the pixels under the cell's posts, about
       60 MB of them. The object's size and ETag must be the pinned ones
       before and after the read. The raster must be laid out as MRDEM-30
       is: float32, Canada Atlas Lambert, 30 m pixels. Its lidar part has
       pits at shorelines, down to -695 m. A pixel below -10 m or above
       7,000 m cannot be ground: it is dropped with the pixels within four
       of it, and the hybrid fills the hole from opened Copernicus. The
       raster is pinned, so a build does not stop on them.

     Each source's posts are cut to its area and put into one HGT tile. The
     receipt names, for each source, what it read, its SHA-256 (the tile's,
     or that of the pixels read), the pixels dropped as not ground and the
     posts it gave. A tile is built again when a source's area, tile or
     object changes, or the rule by which its pixels are dropped.

     A cell that fails does not end the run: every other cell is still
     built, and the run then stops with the names of all that failed.
   - **Hybrid** tiles in `--out`. A post is the terrain tile's where it has
     data and opened Copernicus's elsewhere.

   The terrain ends at the outer borders of the two countries and at sea,
   and the opened surface lies under the ground (a metre or two on flat
   land, far more on ridges), so the two would meet in a step. The hybrid
   therefore lifts the Copernicus side. A post within 16 posts of the
   terrain's data takes the difference between the two surfaces at the
   terrain's edge, carried outward as the mean of the posts a step nearer,
   with a weight that falls linearly to nothing beyond the sixteenth post
   (about 500 m north to south). The terrain's own posts are never changed,
   so a waterfront beside towers keeps its lidar heights. Each cell is
   blended from its own tiles and a margin of 16 posts of its neighbours',
   which gives every post the value a blend of the whole planet would. A
   cell with no terrain tile of its own or beside it is its opened tile
   unchanged.

   3DEP and MRDEM-30 meet at the border as they are. Their heights are in
   different datums, NAVD 88 and CGVD2013, and the tiles hold whole metres
   (see [the seam](refresh-runbook.md#the-seam-between-3dep-and-mrdem-30)).

   A hybrid cell's receipt records the opened and terrain tiles it read, and
   it is blended again when one of them changes. The manifest lists every
   source, the terrain sources with the terrain tiles they gave posts to,
   and its `method` is `terrain-over-opening` with the opening and
   the opened and terrain manifests. The terrain tiles have their own
   `terrain-manifest.json`, with a schema `build_graph.py` does not accept,
   so they cannot grade a graph by mistake. With `--bounds`, the run also
   builds what the blend reads around the box: the opened and terrain tiles
   of the neighbouring cells and the raw tiles two cells out.

   The terrain carries artifacts that the hybrid passes on: lidar pits on
   lakes and farmland, blocks of zero heights. [terrain_artifacts.py](terrain_artifacts.py)
   reads the terrain, opened and hybrid tiles for them, then measures the
   graded graph's edges beside every steep hollow it found and reports the
   roads with a false step. The planet builder runs it after every graded
   build with terrain sources (see
   [Terrain scan](builder/README.md#terrain-scan)).

   Then pass `--elevation "$build_scratch/elevation"` to `build_graph.py`. The
   build fails if Valhalla skips its elevation stage. Grade at build time: a
   finished build cannot be graded afterwards. Running the elevation stage on
   finished tiles, with or without validate, gave a graph that answered some
   `/locate` calls with HTTP 500. The manifest's `elevation` records the
   elevation manifest, its cell count, the checksum of its cell list, the
   sources used and the `method`: null for raw tiles, or the opening with
   its radius and the identity of the raw manifest it opened.

   Valhalla grades a bridge from the heights at its two ends, but its
   tagging rules call a way a bridge only when `bridge` is `yes` or `1`. A
   `movable`, `viaduct` or `boardwalk` bridge is graded from what lies under
   the deck, and a terrain model holds the water or the ground there. Pass
   `--all-bridges` when the elevation holds a terrain model, and to the
   ungraded build it is compared with; `build_graph.py` stops when a hybrid
   elevation set comes without the flag. [graph_lua.py](graph_lua.py) then
   writes out the rules the pinned image carries, with every `bridge` value
   but `no`, `false` and `0` made a bridge, and the build stops unless
   Valhalla's log shows it read them. The rules are checked against the SHA-256 of the image's
   own, so a new image needs the change reviewed again. The manifest's
   `builder.graphLua` records the changed rules.

   A terrain model also holds the ground at a bridge's ends, which are often
   mapped on the channel's bank, and the channel it cuts through a road's
   fill over a culvert, so the road beside them reads a false step.
   `--crossings SITES...` grades the road over such a crossing from its
   ends, as Valhalla grades a bridge: [crossing_split.py](crossing_split.py)
   reads the road's heights from `--elevation` at every site of the site
   files [crossing_steps.py](crossing_steps.py) writes, cuts the road where
   it meets solid ground on either side and tags the stretch between
   `bridge=yes`, `bicino:interpolated=crossing`, through an osmChange file
   that `osmium apply-changes` applies to the roads. The terrain is not
   changed. The manifest's `crossings` records the site files, the rule and
   what changed. It is opt-in, and no chain stage writes the planet's site
   files yet (see
   [False steps at crossings](refresh-runbook.md#false-steps-at-crossings)).

   Use `--sample` for development input, such as a city cut from a regional
   extract by [prepare_sample.py](prepare_sample.py). A sample's relations may
   lack members that lie outside the extract, and `--admin-source` takes its
   administrative boundaries from the uncut extract. Sample results are never
   worldwide release evidence. Record peak scratch and memory, phase times,
   output size, the policy and inventory, source and configuration hashes, and
   probe results.

4. Run [probes.json](probes.json) with the pinned build image against the archive
   alone, passing `probe_graph.py --coverage planet` for a planet graph. A
   fixture's `route` is its worldwide-gap expectation. `planet` overrides it,
   `coverages` limits where it runs, and `pushAllowed` accepts pedestrian
   push stretches of at most 100 m each, the bicycle route service's rule. On a planet graph, generate the audit inventory
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

## Compare elevation sources on city samples

Judge an elevation source on small city graphs before grading a planet.
[elevation-probes.json](elevation-probes.json) lists four flat cities
(Buenos Aires, Amsterdam, Houston, Berlin) and four hilly ones (Lisbon,
San Francisco, Zurich, Wellington), each with a box and four or five legs.
The 2026-11-25 results and the recommendation are in
[Refresh and rollback](refresh-runbook.md#elevation-sources-on-city-samples).
Terrain models of other regions, surveyed and sampled on 2026-11-27, are in
[Regional terrain models](elevation-sources.md).

A city that names a Geofabrik `extract` builds as a sample. To build one
city at one opening radius and run the gate on it in one command, use
[builder/rehearse.sh](builder/README.md#rehearse-on-a-city-sample); the steps
below do the same by hand and also take other elevation sources.

Cities marked `planetOnly` have never been built as samples and run only
against planet services: Copenhagen, Paris, London and Munich, with one or
two legs each of the 2026-11-24 planet check. With New York, Dubai,
Stuttgart and Tokyo, which do build as samples (Tokyo from the Kanto
extract, to try GSI's tiles), the file holds all 27 legs of
that check. All cities together are the release gate for a graded planet:
serve the graded and the ungraded planet from the same snapshot and run every
city in one report, with no `--city`.

The 200 m planet failed only in Midtown's tower core, so on 2026-11-26 Chris
added high-rise cores to the gate. These are flat and judged like the rest:
- Chicago: two legs through the Loop.
- Singapore: two legs through the CBD and Marina Bay.
- Shanghai: two legs through Lujiazui.
- Dubai: one leg through Downtown and Business Bay, one through the Marina.
- New York: two more Manhattan legs, a Midtown crosstown and one down
  Broadway through the Financial District.

Every leg was checked on the ungraded planet to run through the towers
rather than around them.

Hong Kong (Central to Causeway Bay) and São Paulo (Avenida Paulista) are
hilly high-rise cores where a longer graded route can be right. They are
marked `reportOnly`: `compare_elevation.py` routes and tabulates them, but
no target counts them, and a person judges their length change and 6%+
share.

Pittsburgh, added on 2026-11-27, holds a bridge over a hollow where the
3DEP terrain reads a false step at the bridge's ends: on the hybrid the
Road route across Schenley Park's Panther Hollow Bridge is 6.5% longer and
a detour. Three flat river crossings downtown keep the city's median
honest. It is the gate's check on false steps at crossings (see
[False steps at crossings](refresh-runbook.md#false-steps-at-crossings)).

All seven tower cities build as samples since 2026-11-26. At 400 m their
rows equalled the planet gate's in every column, and the two legs the planet
missed are the two the samples miss (see
[Tower-city samples](refresh-runbook.md#tower-city-samples)). Run them
before building a planet with a new elevation method.

1. Download the city's Geofabrik extract, which `elevation-probes.json` names
   as `extract`, and record its SHA-256. It holds the whole city and its
   state or province boundary: Valhalla keeps only country and state
   polygons, so a cut state such as NorCal gives an empty admin database.
   [prepare_sample.py](prepare_sample.py) cuts the city's box with complete
   ways into `roads.osm.pbf` and takes the boundaries of the whole extract
   as `admin.osm.pbf`. Two things an extract cuts are fetched from the
   OpenStreetMap API and merged in, for a city that lists them:
   - `adminWays`: members its state's boundary lacks. The New York extract
     lacks one and the Illinois extract five, and Valhalla then builds no
     admin polygon and the build stops. For a new city, Valhalla's build log
     names them one at a time: `Illinois (122586) is missing way member
     814758098`.
   - `adminRelations`: the country's relation, complete, where the extract
     is a part of the country (see step 3). The United States is r148838,
     China r270056 and Brazil r59470.

   `sample.json` records what was cut and `elevationBounds`, the
   whole-degree bounds for step 2.

   ```sh
   python prepare_sample.py --city Chicago --region "$scratch/illinois-latest.osm.pbf" \
     --region-url https://download.geofabrik.de/north-america/us/illinois-latest.osm.pbf \
     --out "$scratch/chicago"
   ```

   Build each graph with `build_graph.py --sample --source
   "$scratch/chicago/roads.osm.pbf" --admin-source
   "$scratch/chicago/admin.osm.pbf"`, with and without `--elevation`. A city
   builds in 10 seconds to 2 minutes on a laptop under amd64 emulation; one
   build segfaulted in the elevation stage there and passed on a retry.
2. Write the elevation tiles for the city's one-degree cells.
   `build_elevation.py --bounds W S E N` writes the production Copernicus
   tiles for those cells. [sample_elevation.py](sample_elevation.py) writes
   candidates: `cog` resamples a global Cloud Optimized GeoTIFF such as
   GEDTM30, and `opening --radius` applies a grey-scale morphological
   opening to tiles that `build_elevation.py` or `cog` wrote. Its manifests
   always record `bounds`, so `build_graph.py` accepts them only for samples.
   To try an opening radius on Copernicus, use
   `build_elevation.py --opening-radius R --raw RAW --bounds W S E N`
   instead. It builds the raw tiles with the ring of neighbouring cells and
   opens them as a planet build would, with neighbour margins.

   `tiles` resamples one GeoTIFF per cell, such as the USGS 3DEP 1/3
   arc-second tiles of the United States. Pass `--tile CELL=SOURCE` once for
   every cell of `--bounds`, where the source is an HTTPS URL or a local
   file; the manifest records each file's size and SHA-256. A 3DEP tile is
   named by its north-west corner, so cell N40W074 comes from `n41w074`, and
   its dated versions are under `historical/` in the USGS bucket. The newest
   3DEP tiles have no data outside the United States; older ones carry fill
   there, which this sample tool does not remove. `--fill DIR` takes the
   posts without data from another elevation directory. That gives a border
   cell's hybrid without the blend `build_elevation.py --terrain-sources`
   applies.

   ```sh
   python sample_elevation.py cog --source-id gedtm30-v1.2 --bounds -59 -35 -58 -34 \
     --url https://s3.opengeohub.org/global/dtm/v1.2/gedtm_rf_m_30m_s_20060101_20151231_go_epsg.4326.3855_v1.2.tif \
     --out "$scratch/dem/buenos-aires/gedtm30"
   python sample_elevation.py opening --radius 200 --bounds -59 -35 -58 -34 \
     --input "$scratch/dem/buenos-aires/copernicus" --out "$scratch/dem/buenos-aires/opening-200"
   python sample_elevation.py tiles --source-id usgs-3dep-13 --bounds -117 32 -116 33 \
     --tile N32W117=https://prd-tnm.s3.amazonaws.com/StagedProducts/Elevation/13/TIFF/historical/n33w117/USGS_13_n33w117_20260915.tif \
     --fill "$scratch/dem/san-diego/opening-400" --out "$scratch/dem/san-diego/hybrid"
   ```

   `crossing_steps.py restore --kept releases/elevation-cache-2026-11-27.json
   --set hybrid-400 --bounds W S E N` writes the cells of a box from the
   hybrid set kept in the tile bucket, read by byte range from its tars and
   checked against its cell list; it needs the set's `meta.tar` and a token
   file (see [Kept elevation tiles](builder/README.md#kept-elevation-tiles)).

   [tower_mask.py](tower_mask.py) takes any of these tile sets and writes
   no data where tall buildings dominate, so that Valhalla grades those
   streets flat, as the graph without elevation does. The zones come from
   the building heights of GHS-BUILT-H R2023A (ANBH, 3 arc-seconds, WGS 84;
   CC BY 4.0, © European Union): pass the grid's GeoTIFFs that cover the
   cells as `--heights`. It is a sample tool like the others. The rule, what
   it masks and why no data is not ready for a planet are in
   [Switching elevation off in tower zones](refresh-runbook.md#switching-elevation-off-in-tower-zones).
   `--fill membrane` spans each zone with a surface from the heights around
   it instead; with its default threshold of 25 m it met the gate on the
   samples (see
   [A membrane in place of no data](refresh-runbook.md#a-membrane-in-place-of-no-data)).

   ```sh
   python tower_mask.py --input "$scratch/dem/new-york/opening-200" --bounds -75 40 -73 41 \
     --heights "$scratch/ghsl/GHS_BUILT_H_ANBH_E2018_GLOBE_R2023A_4326_3ss_V1_0_R5_C11.tif" \
     --fill membrane --out "$scratch/dem/new-york/opening-200-membrane"
   ```

3. Build each city once without elevation and once per source. The admin
   input must also hold the country's relation with all its members. A state
   extract cuts it, and Valhalla then builds the state polygon alone and no
   `admin_access` row, the country's default access rules. A sample without
   it takes other ungraded routes than a planet graph: the United States row
   gives bicycles pedestrian streets, bridleways and paths.
   `prepare_sample.py` does this for a city that lists the relation as
   `adminRelations`: it fetches `relation/148838/full` from the
   OpenStreetMap API, removes its objects from the extract's admin input
   with `osmium removeid`, and merges the two with `osmium merge` (see
   [A sample needs the country relation](refresh-runbook.md#a-sample-needs-the-country-relation)).
   Amsterdam, Berlin and Stuttgart do not list their country yet.
   Serve every archive from the pinned image on its own port, and mount each
   graded graph's tiles too so that `/height` works:

   ```sh
   docker run -d --rm --platform linux/amd64 -p 127.0.0.1:18101:8002 \
     -v "$work/copernicus/valhalla_tiles.tar:/graph/valhalla_tiles.tar:ro" \
     -v "$scratch/dem/buenos-aires/copernicus:/elevation:ro" --entrypoint /bin/bash "$valhalla_image" -ec '
       valhalla_build_config --mjolnir-tile-extract /graph/valhalla_tiles.tar \
         --additional-data-elevation /elevation > /tmp/valhalla.json
       exec valhalla_service /tmp/valhalla.json 2'
   ```

4. Run [compare_elevation.py](compare_elevation.py) once per city, then
   summarise. It routes every leg with the backend's own Road and Everyday
   bodies, compares lengths with the ungraded routes, reads the share of
   route length on 6%+ grades back with `/trace_attributes`, and in hilly
   cities flips `use_hills` between 0 and 1. `summary` exits non-zero when
   a source misses a target. A flat route more than 5% longer misses one
   as a detour, where its direct route reads steep on that source.
   Otherwise it is a swap, listed under the table, and misses one only when
   it is more than 15% longer or swaps are many (see
   [Detours and swaps](refresh-runbook.md#detours-and-swaps-how-a-longer-flat-route-is-judged)).
   The same commands, without `--city`, are the planet release gate.

   ```sh
   tools/dev-env --map-backend python map-platform/routing/compare_elevation.py run \
     --city "Buenos Aires" --ungraded http://127.0.0.1:18100 \
     --graded copernicus=http://127.0.0.1:18101 --graded opening-200=http://127.0.0.1:18104 \
     --out "$scratch/results/buenos-aires.json"
   tools/dev-env --map-backend python map-platform/routing/compare_elevation.py summary "$scratch"/results/*.json
   ```

## Focused checks

```sh
tools/dev-env --map-backend python -m unittest discover -s map-platform/routing -v
```

`tools/dev-check --check map-routing-tests` runs the same tests, and the Map
Backend CI job runs them on every map-platform change. They cover these tools
and the planet builder: its chain, its status command and, where `shellcheck`
is installed, its shell scripts.

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
