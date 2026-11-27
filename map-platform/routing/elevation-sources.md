# Regional terrain models for routing elevation

[elevation-sources.json](elevation-sources.json) lists the terrain sources
approved for routing. This file is the survey of candidates behind it.

The planet bicycle graph is ungraded because every worldwide elevation source
tried so far reads buildings as hills
([Refresh and rollback](refresh-runbook.md#elevation-sources-on-city-samples)).
The plan is a hybrid: a bare-earth terrain model where an approved one exists
and Copernicus GLO-30 opened at 400 m elsewhere. USGS 3DEP is approved for the
United States, and Canada's MRDEM-30 fixes Toronto on a sample.

On 2026-11-27 the terrain models of other regions were surveyed from their
publishers' pages, and five of them were tried on city samples against
Copernicus opened at 400 m. Nothing in a build, in `elevation-sources.json` or
in production changed. A new source still needs Chris's approval by name.

## Recommendation

A terrain model pays in two kinds of place, and nowhere else in the samples:

- **Cities with hills narrower than about 800 m.** The 400 m opening cuts
  them down. Lisbon gets 67% more climb back on the same routes and
  `use_hills` then changes all four legs instead of two. Wellington gets 35%
  back, Tokyo's short slopes 86%.
- **Tower districts on flat ground.** Along Hong Kong's tram corridor the
  opened tiles read up to 10% of the direct route as 6% or steeper, and the
  lidar terrain model reads none. That is two legs; Tokyo's flat legs were
  already quiet on the opened tiles.

It does not pay where the slopes are broad. Zurich's climb is the same on
swissALTI3D as on the opened tiles (822 m against 847 m) and Stuttgart's is
10% higher.

Sources to put to Chris for approval, in this order:

1. **Sonny's LiDAR Digital Terrain Models of Europe, 1 arc-second, version
   25**, for the countries it builds wholly from national lidar or
   photogrammetry, cut to each country's boundary. It is the only candidate
   that covers many countries in the tile format the build already writes,
   and it carries Portugal's 2024 lidar, which Portugal's own data centre
   serves only to registered accounts. Two things to accept with it: it is one
   person's compilation of about forty national sources, each with its own
   credit line, and it fills gaps with SRTM without a per-post mask.
2. **LINZ New Zealand LiDAR 1 m DEM** (CC BY 4.0), where it has data.
3. **GSI elevation tiles of Japan**: DEM5A where it has data and DEM10B
   elsewhere (Public Data License 1.0, credit only).
4. **CEDD LiDAR DTM 2020 of Hong Kong**, once someone has read its terms for
   derived products: they list copying and distribution, not adaptation.

Do not approve: the Lands Department's 5 m "DTM" of Hong Kong (it keeps
vegetation and elevated roads), São Paulo's lidar terrain model (share-alike),
ANADEM (buildings kept), MERIT (non-commercial or share-alike) or a licensed
worldwide terrain model (list prices put global land above a billion euros).

Worth a sample before anyone asks: Geoscience Australia's 5 m lidar DEM
(Melbourne, Sydney), INEGI's terrain models of Mexico (Mexico City,
Monterrey), Taiwan's 20 m DTM (Taipei) and Italy inside Sonny's tiles
(Naples). South Korea, Singapore, the Gulf states, China, India and most of
Latin America have no open terrain model that this survey found; they stay on
opened Copernicus.

## How a source was judged

`compare_elevation.py` reports four things that matter here:

- **6%+ on the direct route.** The share of the ungraded route's length on
  edges whose steepest 60 m section is 6% or more, read from the graded
  graph (`ungradedRouteGrades.share`). On flat ground it is phantom
  steepness. In a hilly city it is how much of the real slope the source
  still shows.
- **Climb on the direct routes.** Metres climbed along the ungraded routes,
  from each graph's tiles every 20 m, counting a rise once it reaches 3 m.
  The routes are the same for every source, so the figure compares heights
  and not routing. Road and Everyday routes are summed.
- **`use_hills` changes.** Hilly legs where the Everyday route differs
  between `use_hills` 0 and 1.
- **Longest length change.** The gate's "no flat leg more than 5% longer".

The first two lead. A survey of 252 tower downtowns on the 400 m planet
(2026-11-27, 3,938 routes, on the map VPS in
`/root/bicino-routing-releases/opened-400-downtown-survey-wide-20261127/`)
found that the length rule gives false alarms and misses as legs are added.
Of 2,572 routes in flat-labelled centres, 29 were more than 5% longer and 20
more than 5% shorter, most of them near-ties that flipped. Only 8 of the 29
had a direct route reading 6%+ on at least 8% of its length. Computed here
from that survey's report, 67 of the 252 centres average 5% or more on their
direct routes, 51 of them on ground the survey itself labels as having some
relief. Of the 165 it labels flat, the highest are Tseung Kwan O (24% of
route length), Sha Tin (22%), Busan Centum City (16%), New York Midtown
(14%) and Naples Centro Direzionale (10%). The first two were sampled here,
and their steepness is mostly real (see below).

## Sample results

Each city was built three or more times from the same box: ungraded, graded
with Copernicus opened at 400 m, and graded with each candidate. Flat and
tower legs first, then hilly legs.

| City (legs) | Source | Longest length change | 6%+ on direct routes: median, most | Climb on direct routes | `use_hills` changed |
|---|---|---|---|---|---|
| Hong Kong, tram corridor (2) | opened 400 m | 0.0% | 6%, 10% | 38 m | 0 of 2 |
| | CEDD lidar 2020 | 0.0% | **0%, 0%** | 6 m | 0 of 2 |
| | Lands Dept 5 m | 0.0% | 6%, 7% | 76 m | 0 of 2 |
| Sha Tin (8) | opened 400 m | +0.1% | 27%, 42% | 1,224 m | – |
| | CEDD lidar 2020 | +0.1% | 33%, 49% | 1,380 m | – |
| Tseung Kwan O (8) | opened 400 m | 0.0% | 23%, 53% | 1,283 m | – |
| | CEDD lidar 2020 | +0.9% | 19%, 37% | 1,253 m | – |
| Tokyo, flat (4) | opened 400 m | +2.9% | 0%, 3% | 94 m | – |
| | GSI DEM5A | +1.4% | 0%, 2% | 99 m | – |
| | GSI DEM10B | +1.4% | 0%, 0% | 48 m | – |
| Lisbon (4) | opened 400 m | +23.1% | 20%, 23% | 546 m | 2 of 4 |
| | Sonny (DGT lidar) | +6.3% | 42%, 43% | **913 m** | **4 of 4** |
| Wellington (4) | opened 400 m | +21.6% | 20%, 37% | 910 m | 2 of 4 |
| | LINZ lidar 1 m | +41.5% | 39%, 41% | **1,228 m** | 3 of 4 |
| | LINZ contour 8 m | +18.9% | 35%, 41% | 1,215 m | 2 of 4 |
| Zurich (4) | opened 400 m | +18.0% | 14%, 46% | 847 m | 3 of 4 |
| | swissALTI3D 2 m | +29.1% | 13%, 51% | 822 m | 2 of 4 |
| | Sonny (swissALTI3D) | +16.9% | 14%, 54% | 855 m | 2 of 4 |
| Stuttgart (1) | opened 400 m | 0.0% | 25%, 28% | 480 m | 1 of 1 |
| | Sonny (LGL lidar) | 0.0% | 30%, 31% | 526 m | 1 of 1 |
| Tokyo, hills (4) | opened 400 m | +0.4% | 1%, 11% | 121 m | 1 of 4 |
| | GSI DEM5A | +0.4% | 8%, 16% | **225 m** | 0 of 4 |
| | GSI DEM10B | +0.1% | 8%, 16% | 140 m | 2 of 4 |
| Hong Kong, hills (4) | opened 400 m | +0.5% | 32%, 45% | 1,098 m | 1 of 4 |
| | CEDD lidar 2020 | 0.0% | 24%, 40% | 848 m | 1 of 4 |
| | Lands Dept 5 m | +17.7% | 27%, 47% | 1,034 m | 1 of 4 |

No route, grade lookup or height lookup failed, and every ungraded graph gave
the same route for both `use_hills` values.

- **Lisbon is the case for a terrain model.** Cais do Sodré to Graça climbs
  59 m on the opened tiles and 118 m on the lidar; the 200 m opening read
  99 m. Castelo goes from 58 to 126 m and Estrela from 71 to 112 m. With the
  real slopes in the graph `use_hills` changes every leg, and the Everyday
  detour from Baixa to Estrela shrinks from 23.1% to 3.2%. In the city's box
  the opened tile lies a median 4 m below the lidar posts and 25 m below at
  the fifth percentile.
- **Wellington gets Mount Victoria back.** The railway station to Hataitai
  runs over the hill by Majoribanks Street and Alexandra Road, not through
  the tunnel. Road climbs 87 m on the opened tiles and 186 m on the lidar.
  With the lidar in the graph Everyday leaves the hill for the Mount
  Victoria Tunnel shared path and Moxham Avenue, 6.57 km in place of 4.64 km
  (+41.5%). On the opened graph it still climbs over.
- **The contour model is close to the lidar here.** LINZ's 8 m model,
  interpolated from 20 m contours, gives the same total climb as the lidar
  (1,215 m against 1,228 m) but differs leg by leg: 226 m against 186 m on
  the Hataitai Road route. LINZ calls it unsuitable for terrain analysis.
- **Zurich and Stuttgart gain little.** Their slopes are wider than the
  ellipse. Sonny's Zurich tile and swissALTI3D resampled here agree within
  2 m on 90% of the box's posts (median 0, largest difference 22 m), so the
  compilation carries the national model.
- **Tokyo's flat legs were already quiet.** Tokyo Station to Toranomon is
  2.9% longer on the opened graph, as on the planet, and unchanged on both
  GSI models, which make Shibuya to Shinjuku 1.4% longer instead. The gain is
  on the short slopes: Shibuya to Roppongi climbs 19 m on the opened tiles
  and 47 m on DEM5A. `use_hills` changes few legs on any source, because
  20 to 30 m of relief leaves few ways round.
- **Hong Kong shows both effects.** On the flat corridor the lidar removes
  the phantom steepness and all but 6 m of the 38 m of climb. On the hill
  legs the opened tiles read 29% more climb than the lidar (Admiralty to
  Kennedy Road 220 m against 149 m): towers standing on a slope survive the
  opening. Wan Chai to Happy Valley reads 11% at 6%+ on the opened tiles and
  none on the lidar.
- **The Lands Department's 5 m model is not a terrain model.** Its
  description says it includes elevated roads and shows vegetation by its
  height. It reads 76 m of climb on the flat corridor and sends Causeway Bay
  to Tai Hang Road 17.7% further.
- **Sha Tin and Tseung Kwan O are not flat.** The wide survey labels both as
  flat ground, and the opened tiles read 27% and 23% of their direct routes
  as 6%+. The lidar reads 33% and 19%. The towns lie in valleys, and legs
  2.4 km long run 3 to 9 km over the hillsides. The lidar lowers single legs
  where towers stand (Tseung Kwan O west to north, from 53% to 37%), but
  most of the steepness is real. A centre's direct routes count as phantom
  steepness only once a terrain model, or the map, says the ground is flat.

### How the samples were built

- **Graphs.** `prepare_sample.py` cut each box from a Geofabrik extract, and
  `build_graph.py --sample --all-bridges` built every graph, the ungraded
  ones too, as a hybrid planet would be built. Stuttgart, Tokyo and Hong
  Kong had their country's relation merged in (Germany 51477, Japan 382313,
  China 270056); the other extracts hold their whole country.
- **Opened tiles.** `build_elevation.py --opening-radius 400`, the production
  code path with neighbour margins. Lisbon, Zurich, Wellington and Stuttgart
  reuse the tiles of the
  [opening-radius samples](refresh-runbook.md#opening-radius-on-city-samples).
- **Candidate tiles.** A scratch script warped each source onto the cell's
  one arc-second posts with GDAL's bilinear kernel, which widens with the
  ratio of the grids. The cell is the candidate inside the city's box and a
  margin and the opened tile beyond. LINZ's lidar, GSI's tiles and the CEDD
  tiles hold no data over water, so they were joined to the opened tile with
  `blend_fill` over 16 posts, the production function. A first run without
  the blend gave the same figures within 2%. Sonny's tiles, swissALTI3D and
  the Lands Department grid have a height at every post of the box and were
  cut at its edge. Every leg lies inside the box. Heights stayed in each
  source's own datum.
- **Sources as read.** LINZ's lidar sheet BQ31 was read at its 8 m overview.
  The CEDD tiles were averaged from 0.5 m to 5 m first. GSI's tiles are zoom
  15 for DEM5A (414 tiles; the DEM5B and DEM5C fallbacks added no pixel) and
  zoom 14 for DEM10B (120 tiles). swissALTI3D was the 2 m product, 325 squares of 2026.
  Sonny's tiles were used as they are.
- **Legs.** The gate's legs for Lisbon, Zurich, Wellington, Stuttgart and
  Hong Kong. Added for the samples only, and not part of the gate: three
  flat Tokyo legs of the
  [downtown survey](refresh-runbook.md#toronto-a-tower-downtown-the-hybrid-does-not-fix),
  four Tokyo hill legs (Shibuya to Roppongi, Iidabashi to Waseda, Meguro to
  Nakameguro, Akasaka-mitsuke to Azabu-juban), four Hong Kong hill legs
  (Sheung Wan to Mid-Levels, Wan Chai to Happy Valley, Admiralty to Kennedy
  Road, Causeway Bay to Tai Hang Road), and the wide survey's eight legs each
  for Sha Tin and Tseung Kwan O.
- **Limits.** One to eight legs a city, on a laptop under amd64 emulation.
  The phantom-steepness result rests on two flat legs and one hill leg in
  Hong Kong. No leg crosses a seam between a candidate and the opened tiles,
  a border between two terrain sources, or a bridge split in mid-span.

| City | Extract (SHA-256 prefix) | Candidate files |
|---|---|---|
| Lisbon | `europe/portugal` 261124 (`4911a6ce24c4`) | Sonny `N38W010.zip`, 1,914,899 bytes (`c30fd24b6ae4`) |
| Zurich | `europe/switzerland` 261124 (`6c9b5e4d8f28`) | Sonny `N47E008.zip`, 10,188,486 bytes (`c78ea246e416`); 325 swissALTI3D tiles, 368,032,713 bytes |
| Stuttgart | `europe/germany/baden-wuerttemberg` 261124 (`bfe0f0225dca`) | Sonny `N48E009.zip`, 8,007,607 bytes (`859e65815ea4`) |
| Wellington | `australia-oceania/new-zealand` 261124 (`ca1e09b6801d`) | `new-zealand/new-zealand/dem_1m/2193/BQ31.tiff`, 509,806,020 bytes; `new-zealand/new-zealand-contour/dem_8m/2193/BQ31.tiff`, 10,165,297 bytes |
| Tokyo | `asia/japan/kanto` 261125 (`6cfdcac18ebc`) | 414 `dem5a_png` tiles, 23,964,486 bytes; 120 `dem_png` tiles, 4,666,809 bytes |
| Hong Kong | `asia/china/hong-kong` of 2026-11-27 (`0fa7e9c37b4a`) | `Whole_HK_DTM_5m.zip`, 28,706,079 bytes (`785718f462ae`); 264 CEDD zips, 1,320,394,485 bytes |

## Survey

Read on 2026-11-27 from each publisher's pages and metadata. "Not confirmed"
means the publisher's page did not say. Every licence named below allows
commercial use, asks for credit and has no share-alike clause, unless the
row says otherwise.

### Products that cover many countries

| Source | What it is | Licence and credit | Grid, projection, heights | Download and size | State here |
|---|---|---|---|---|---|
| [Sonny's LiDAR DTMs of Europe](https://sonny.4lima.de), 1″, v25 of 2025-08-08 | One person's compilation of national lidar and photogrammetry terrain models. Whole from such sources: Austria, Belgium, Czechia, Denmark, Estonia, Finland, France, Germany, Latvia, Lithuania, Luxembourg, the Netherlands, Norway, Poland, Slovakia, Slovenia, Spain, Sweden, Switzerland, the United Kingdom. Partly: Portugal (SRTM around Porto), Ireland (mostly SRTM), Italy (TINITALY in the gaps), Romania, Cyprus, Iceland. Croatia and Hungary list no lidar source. Gaps are filled with SRTM, AW3D30 or Viewfinder Panoramas, shown only on a picture | CC BY 4.0, "for any purpose, even commercially"; "Please mention my name (Sonny) and put a link to my Website (sonny.4lima.de)". `_Datasources.txt` names the national sources, some with terms of their own | SRTM-style HGT, 3601 × 3601 int16, whole metres, EPSG:4326; each country's own height system, not harmonised | Google Drive only, 1,056 one-degree zips, 4.8 GB. Single files download without an account; the anonymous "download all" went in 2026 | Sampled: Lisbon, Zurich, Stuttgart |
| [Mapterhorn](https://mapterhorn.com) 0.0.13 of 2026-09-11 | 151 sources: national lidar where open (much of Europe, Japan, Taiwan, New Zealand, Australia, Canada, the United States), Copernicus GLO-30 elsewhere | None of its own; each source's. It aims to leave out non-commercial and share-alike sources | Terrarium WebP tiles, 512 px, Web Mercator; height datum handling not confirmed | `planet.pmtiles` to zoom 12 is 355.6 GB, everything 9.93 TB | Not sampled. A surface model wherever no national source exists, and its source list is a good index of open ones |
| EuroGeographics EuroDEM | National terrain data of about 30 countries, MERIT elsewhere | Open licence, commercial use allowed | 2″ (about 60 m), 8 to 10 m vertical accuracy, ETRS89 and EVRS | One GeoTIFF, 2.3 GB | Too coarse |
| OpenGeoHub EU DTM 30 m v0.3 | Machine-learned ensemble of 2021, predecessor of GEDTM30 | CC BY 4.0 | 30 m, EPSG:3035, EGM2008 | 46 GB | Not sampled; GEDTM30 failed in cities |
| Tilezen terrain tiles | SRTM on most land; national models for a few countries | Per source | HGT and Terrarium | AWS Open Data | Mostly a surface model; unchanged since 2017 |
| EU-DEM v1.1, Copernicus EEA-10 | Surface models | – | – | EEA-10 is restricted to eligible users | No |
| ANADEM (South America) | Copernicus GLO-30 with the vegetation bias removed; "we did not apply bias corrections for urban areas" | CC BY 4.0 | 30 m, EPSG:4674, EGM2008 | By tile from OpenTopography, 66 GB | Buildings kept |
| MERIT DEM | Tree bias removed, buildings kept | CC BY-NC 4.0 or ODbL (share-alike) | 3″ only | Registration | No |
| DeltaDTM, TanDEM-X EDEM, AW3D30 | Coastal lowlands only; scientific-use surface model; surface model | – | – | – | No |

### Europe, national

| Country | Product | Licence and credit | Grid, projection, heights | Download and size |
|---|---|---|---|---|
| Portugal | DGT MDT-2m and MDT-50cm from the 2024–25 lidar, mainland; north-west still missing | CC BY 4.0 | GeoTIFF, EPSG:3763, Cascais datum | The catalogue is public (91,193 two-metre tiles). The files answer 403 without a registered account, checked here |
| Switzerland | swisstopo swissALTI3D, lidar below 2,000 m | Free geodata terms; "©swisstopo" | COG, 0.5 m and 2 m, EPSG:2056, LN02 | Open STAC, 44 GB at 2 m |
| Germany | No open nationwide model between 1 m and 200 m. BKG DGM200 is open; DGM1 nationwide costs 8,000 EUR; state DGM1 is open in at least NRW (dl-de/zero-2-0), Baden-Württemberg, Rheinland-Pfalz, Brandenburg, Hamburg and Sachsen-Anhalt (dl-de/by-2-0), each on its own portal. Bavaria's terms offer CC BY or CC BY-ND by product | As listed | GeoTIFF, UTM | Sixteen portals |
| France | IGN BD ALTI 25 m, kept up from RGE ALTI (1 m and 5 m) | Licence Ouverte 2.0 | ESRI ASCII per département, Lambert-93, NGF-IGN69 | Open ATOM feed |
| Spain | CNIG MDT25, second coverage (lidar 2015–2021), also 2 m and 5 m | "compatible con CC-BY 4.0"; "Obra derivada de MDT25-cob2 2015-2021 CC-BY 4.0 scne.es" | COG by map sheet, 4,287 files, ETRS89 UTM, orthometric | Web portal; 20 files without an account, then a login |
| Italy | INGV TINITALY 1.1, 10 m, merged regional models | CC BY 4.0; cite Tarquini et al. 2023 | GeoTIFF, UTM 32 | 193 zips, no login |
| England | Environment Agency LIDAR Composite DTM, 1 m, 2 m and 10 m, about 99% of England | Open Government Licence; "© Environment Agency copyright and/or database right 2022. All rights reserved." | One GeoTIFF at 10 m, EPSG:27700, Ordnance Datum Newlyn | Open; size not confirmed |
| Great Britain | OS Terrain 50, 50 m, photogrammetry | OGL; "Contains OS data © Crown copyright and database right" with the year | ASCII grid | One 162 MB zip. OS Terrain 5 is not open |
| Wales, Scotland, Northern Ireland | Wales: 1 m lidar mosaic. Scotland: partial lidar. Northern Ireland: 10 m and 50 m DTM | OGL | COG; S3 bucket `srsp-open-data`; zip | Open |
| Norway | Kartverket national height model, DTM at 1, 10 and 50 m | CC BY 4.0; "© Kartverket" | GeoTIFF, EPSG:25833 | Open WCS; a bulk 10 m download was not confirmed |
| Sweden | Lantmäteriet Markhöjdmodell, 1 m | CC BY 4.0; "©Lantmäteriet" | COG, SWEREF 99 TM, RH 2000 | Catalogue open; files need an account |
| Finland | NLS elevation model 10 m, from the 2 m lidar model where it exists | CC BY 4.0; name the NLS, the dataset and its date | GeoTIFF, EPSG:3067, N2000 | Free file service |
| Denmark | DHM/Terræn, 0.4 m lidar | CC BY 4.0 since 2024-05-16 | GeoTIFF | Needs an account and an API key |
| Austria | BEV ALS-DGM 1 m lidar; older DGM grid at 5 to 100 m | CC BY 4.0 | EPSG:3035 (lidar), EPSG:31287 (grid) | Whole-country COGs for the grid: 800 MB at 25 m |
| Netherlands | AHN DTM, 0.5 m and 5 m | CC0 | GeoTIFF, RD New, NAP | Open ATOM feed |
| Czechia, Poland, Ireland, Flanders | Open or free; details and licence texts not read | – | – | – |

### Asia and the Pacific

| Place | Product | Licence and credit | Grid, projection, heights | Download and size |
|---|---|---|---|---|
| New Zealand | LINZ "New Zealand LiDAR 1m DEM", 90% of the mainland, captured 2008–2026, updated 2026-09-17 | CC BY 4.0; "Sourced from LINZ. CC BY 4.0" | COG with overviews, float32, EPSG:2193, NZVD2016 | Public bucket `nz-elevation`, no account: 424 sheets, 376.6 GB, with a checksum per sheet in STAC. Checked here |
| New Zealand | LINZ "New Zealand Contour-Interpolated 8m DEM", from 20 m contours, whole country; "Not suitable for terrain analysis" | CC BY 4.0 | COG, EPSG:2193 | Same bucket: 449 sheets, 8.6 GB |
| Japan | GSI elevation tiles: DEM5A (lidar, about 5 m), DEM5B and DEM5C (photogrammetry), DEM10B (1:25,000 contours, whole country). GSI says the values do not reflect the height of structures | Public Data License 1.0, commercial use allowed; the tiles are listed as usable with a source credit alone | PNG tiles, 0.01 m steps, zoom 15 (5 m sets) and 14 (DEM10B); JGD2011, Tokyo Bay mean sea level | Tile server without a key; GSI may block heavy traffic. About 400,000 zoom-15 tiles for the country (an estimate). The file download needs an account and may need Survey Act approval |
| Australia | Geoscience Australia 5 m lidar DEM: 236 surveys of 2001–2015 over the populated coast and the cities, more than 245,000 km². The national 1″ DEM removes vegetation but "man-made structures … have not been treated" | CC BY 4.0; "© Commonwealth of Australia (Geoscience Australia)" with the year | GDA94 UTM by zone | Direct zips per UTM zone, about 10 GB each |
| Hong Kong | CEDD LiDAR DTM 2020 (and 2010), 0.5 m; "the definition of the ground under trees may be less accurate" | Government terms: copy, distribute and reproduce "for both commercial and non-commercial purposes", with the source named. Adaptation is not listed, and there is an indemnity clause | GeoTIFF, EPSG:2326, HKPD | 3,253 zips with direct links, about 16 GB (from 264 of them) |
| Hong Kong | Lands Department "Digital Terrain Model", 5 m, ±5 m, photogrammetry of 2014–15. Includes elevated roads and shows vegetation by its height | Same terms | ASCII grid, 12,751 × 9,601, whole metres, sea as 0 | One 28.7 MB zip |
| Taiwan | Ministry of the Interior 20 m DTM, photogrammetry; grids of 5 m or finer are restricted | Open Government Data License 1.0, compatible with CC BY 4.0 | TWD97 | Direct zips on tgos.tw, which refused this machine |
| South Korea | NGII lists a free public DEM; the download needs a login and the site refused this machine. Resolution, method and export rules not confirmed | – | – | – |
| Singapore, mainland China, India, Indonesia | No open terrain model confirmed | – | – | – |

### The Americas, the Gulf and Africa

| Place | Product | Licence and credit | Grid, projection, heights | Download and size |
|---|---|---|---|---|
| Mexico | INEGI lidar terrain model, 5 m, partial: central Mexico City and Monterrey from lidar, Guadalajara from photogrammetry | INEGI free-use terms, commercial use allowed; "Fuente: INEGI" with the product name; say what was changed | ASCII by 1:10,000 sheet, UTM, ITRF92 | Sheets of about 10 MB at fixed addresses, no account |
| Mexico | INEGI CEM 3.0 of 2013, 15 m, whole country, interpolated from map sources. CEM 4.0 of 2025 mixes in radar | Same | TIFF, geographic, ITRF92 | One 5.71 GB file |
| São Paulo | GeoSampa MDT 2020, lidar, 0.5 m, whole municipality | CC BY-SA 4.0: share-alike | EPSG:31983 | By map sheet |
| Rio de Janeiro | IPP terrain model from 2019 lidar, 5 m | CC BY 4.0 | – | Tile service only, no files |
| Pernambuco, Santa Catarina | State lidar terrain models | Free with credit; commercial use stated for Santa Catarina | – | Login required |
| Gulf states | None open. Dubai and Saudi Arabia supply data on request; Abu Dhabi shows elevation for viewing only | – | – | – |
| Argentina | IGN MDE-Ar 2.1, 30 m, from AW3D30 and SRTM: a surface model | – | – | – |
| Cape Town | City lidar terrain models of 2019 (5 m) and 2025 (2 m) | No explicit commercial grant | – | On request or as image services |

### A licensed worldwide terrain model

Public list prices only, read on resellers' pages on 2026-11-27. The totals
are arithmetic on those prices over 149 million km² of land, not quotes.

| Product | List price | Minimum | Global land at that price |
|---|---|---|---|
| Airbus WorldDEM Neo DTM, 5 m | 9.64 EUR/km² (UP42) | 1 km² | about 1.4 billion EUR |
| Intermap NEXTMap 6 DTM | 12.75 EUR/km² (UP42) | – | about 1.9 billion EUR |
| Vantor Vivid Terrain DTM, 0.5 m | 27.00 EUR/km² (UP42) | 10 km² | about 4.0 billion EUR |
| Airbus WorldDEM, 24 m (surface or terrain not stated) | 2.17 USD/km² (SkyWatch) | 10,000 km² | about 0.32 billion USD |
| Fathom FABDEM+ and FathomDEM+, NTT Data AW3D | Not published | – | – |

At the WorldDEM Neo DTM rate a million km² of built-up land is about
9.6 million EUR. No published price makes a worldwide licence a first step.

## Ranking

Benefit against effort, best first. Populations are round figures.

| Source | Riders it covers | What the sample showed | Effort | Friction |
|---|---|---|---|---|
| Sonny's Europe tiles | Most of the EU, the UK, Switzerland and Norway | Lisbon +67% climb and `use_hills` on every leg; Zurich and Stuttgart about the same as the opening | Lowest: already one arc-second HGT; a copy and a boundary cut per country | A private compilation; about forty national credits; SRTM fill without a mask; Google Drive as the only host |
| GSI tiles, Japan | About 124 million | Tokyo's short slopes +86% climb; flat tower legs already quiet | Medium: a tile decoder and a polite crawl of the country | Low for the tiles |
| LINZ lidar, New Zealand | About 5 million | Wellington +35% climb | Low: one bucket, one projection, checksums published | None |
| CEDD lidar, Hong Kong | About 7.5 million | Phantom steepness on flat tower streets gone; hill climb no longer overstated | Medium: 3,253 small files, no data over water | Terms need a reading for derived products |
| Geoscience Australia 5 m | About 27 million, cities and coast | Not sampled | Medium: 10 GB zips by UTM zone | None |
| INEGI, Mexico | About 130 million; lidar in three cities | Not sampled | Medium: per-sheet files | Must describe changes |
| Taiwan 20 m | About 23 million | Not sampled | Unknown: host refused this machine | None |
| National models of Europe, one by one | As Sonny, country by country | swissALTI3D: no gain in Zurich | High: a format and portal per country, accounts for Portugal, Sweden, Denmark and Spain | Clean per country |

## What a generic reader needs

`build_elevation.py --terrain-sources` on `main` (0b0f6356) takes exactly one
source and reads it with code written for 3DEP. `load_terrain_source` refuses
any other adapter, origin or projection. The catalog names one tile per cell,
west of Greenwich only, and `terrain_posts` refuses a tile that is not 10,812
pixels square in NAD 83.

The stage after it is already generic. The terrain stage writes plain
one-degree HGT tiles with no data where the source has none, and
`hybrid_cell` and `blend_fill` read only those. So a new region needs a way to
write such tiles, and data:

- **Several sources with an order.** A list in place of one entry, and a
  rule for posts two sources both hold: the United States and Canada at
  their border, lidar and a contour model in New Zealand or Japan.
- **A catalog of files, not of tiles.** One line per file with its address,
  size and SHA-256, and for each cell the files that touch it. That covers
  one file per country (MRDEM-30), a sheet per map square (LINZ, 424), small
  tiles (swissALTI3D, about 43,000; CEDD, 3,253) and a tile pyramid (GSI).
  An S3 ETag is not a checksum everywhere; where the publisher gives a hash
  (LINZ and swisstopo in STAC) pin that, and elsewhere hash at catalog time
  so a changed file stops the build.
- **One resampler.** A GDAL warp from the source's projection onto the
  cell's posts, with the kernel widened to the grid ratio, over a mosaic of
  the files around the cell so that no post is averaged from half a kernel
  at a file's edge. Read an overview or a coarse product where one exists:
  LINZ's 8 m overview holds a sixty-fourth of the pixels of its 377 GB. Pin
  GDAL and PROJ with the image and record the method in each receipt.
- **Per-source constants.** Projection where the file carries none (the
  Lands Department grid), unit scale (GSI's tiles are in centimetres), the
  no-data value, a plausible height range, and whether sea is data (0 in
  some grids) or no data.
- **Height datum.** Record it and leave the heights alone. A national height
  system differs from EGM2008 by a slowly varying offset of a couple of
  metres at most, a constant offset makes no grade, and the 16-post blend
  already lifts the opened side to meet the terrain. A source in ellipsoidal
  heights would need a geoid first; none here is.
- **An area.** The polygon the source is approved for, as today. For a
  source with partial coverage use the publisher's footprint (LINZ ships a
  capture area) and not the country. For Sonny the polygon is the only thing
  that keeps SRTM fill out, so approve it for the countries it covers whole.
- **Seams between two terrain sources.** `blend_fill` blends terrain into
  the opened tiles only. Two terrain sources meeting at a border in
  different height systems leave a step of a few decimetres, which nothing
  smooths today. Sonny's tiles have such steps inside them already.
- **Credit as data.** Each source's licence, credit line and a statement of
  what was changed, carried into the elevation manifest so that the app's
  credits can list exactly the sources a graph was graded with.
- **A sample mode.** `sample_elevation.py tiles` takes only a GeoTIFF in
  geographic coordinates, one per cell. The scratch `warp_cell.py` in the
  evidence does the warp for any projection and is the starting point for a
  `warp` mode, so that a candidate is sampled with the code that would build
  it.

With that in place Sonny's tiles need no reader at all, only the catalog and
the polygons. LINZ needs the catalog and its footprint. GSI and CEDD each
need a small fetcher in front of the same resampler: a PNG decoder for one,
an unzip step for the other.

## Evidence

On the map VPS in
`/root/bicino-routing-releases/regional-terrain-sources-20261127/`: the
comparison and climb reports, the probes with the added legs, the elevation
and graph manifests, the source files' sizes and hashes, the scratch scripts,
the run logs and the four survey reports with their links. The tiles and
graphs themselves were not kept.
