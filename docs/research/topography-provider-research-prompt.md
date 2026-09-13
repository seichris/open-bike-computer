# Research prompt: free global topographic data

Copy the text below into ChatGPT Deep Research.

---

Research free elevation-data providers for global topographic maps in Bicino / Open Bike Computer:
https://github.com/seichris/open-bike-computer/issues/190

## Product and architecture

- An open-source ESP32 bike computer with an iPhone companion app.
- Topographic maps will be free to users, but the app/product may have commercial uses. Noncommercial-only licenses are not acceptable.
- We generate, host, and redistribute our own offline contour maps. We need downloadable elevation rasters, not a public tile service to scrape.
- The backend derives contours for device vector-map packs and transparent offline iPhone overlays over MapKit.
- Existing OSM/Geofabrik data supplies roads and other vector features; it is not our elevation source.
- Prefer broad global coverage first, then better regional bare-earth terrain models where practical.
- Our current experimental baseline is the public Copernicus GLO-30 2021 S3 catalog, with GLO-90 2021 for additional covered cells. Production approval remains pending. Verify this baseline rather than assuming it is complete or current.

## Research requirements

1. Recommend a global baseline and complementary gap-fill sources. Compare Copernicus GLO-30/GLO-90, ALOS AW3D30, NASADEM/SRTM, and any stronger eligible alternatives.
2. Find practical regional upgrades across Europe, North America, Latin America, Asia, Oceania, Africa, and polar regions. Investigate national/open-government DTMs, including USGS 3DEP, Canadian HRDEM, England's EA LiDAR, IGN France, Spain CNIG, Nordic sources, SwissALTI3D, Netherlands AHN, LINZ, and Australian elevation products.
3. For each viable dataset, verify:
   - Exact geographic coverage and gaps—not merely the provider's country.
   - DTM versus DSM, nominal resolution, actual accuracy, horizontal CRS, vertical datum/units, no-data values, water/quality masks, and known artifacts.
   - Exact available product edition/release and update policy.
   - Official license and terms permitting commercial use, modification, derived contour distribution, offline downloads, server-side bulk acquisition, and our own hosting.
   - Exact attribution/disclaimer obligations and whether combining derived data from different sources adds licensing restrictions.
   - Access method: bulk files, COG/STAC/object storage/API; registration, accepted terms, notification, credentials, rate limits, and any real costs.
   - Stable tile identifiers, catalogs, checksums, immutable versioning, and reproducible ingestion.
4. Distinguish free data from free hosting or unlimited API access. Exclude sources whose terms prohibit our use; explain why.
5. Explain how to combine regional DTMs with global DSM fallbacks without vertical-datum seams, false precision, or invented zero-elevation terrain. Recommend contour intervals and handling for mixed resolutions, source boundaries, voids, coastlines, polar areas, and the antimeridian.
6. Address mainland China separately: lawful acquisition/redistribution, coordinate-reference issues, and alignment with MapKit. Do not recommend an unverified blanket coordinate offset.
7. Assess the engineering effort and ongoing operating cost of each adapter, not just nominal data quality.

## Deliverables

- A concise recommendation: what to ship first and why.
- A country/territory or coverage-area matrix with primary source, fallback, resolution/type, license, access method, and readiness.
- A ranked implementation backlog: ready now, requires registration/legal clarification, research-only, and excluded.
- A proposed versioned source-registry schema and deterministic selection/fallback policy.
- Concrete official catalog/download examples sufficient for an engineer to build each top-priority adapter.
- A gap report: places where coverage, redistribution rights, or app alignment remain unverified.
- A dated source bibliography linking directly to official dataset documentation, licenses, and access endpoints.

Use current primary sources. Cite each material claim, distinguish verified facts from inference, and explicitly flag unanswered questions. Do not equate “open,” “free,” or “worldwide” marketing language with verified redistribution rights or complete coverage.
