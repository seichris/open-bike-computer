# Pinned 2021 Copernicus DEM source review

Review date: 2026-09-25. Scope: only `copernicus-glo30-public-2021` and
`copernicus-glo90-2021` from `map-platform/config/topography-source-policy-v1.json`.
The maintainer accepted use of these exact public sources on 2026-09-25. This
record does not approve the newer registered Copernicus releases.

## Terms and notices

- GLO-30 Public: [WorldDEM-30 free and open licence](https://documentation.dataspace.copernicus.eu/APIs/SentinelHub/Data/DEM/resources/license/License-COPDEM-30.pdf),
  retrieved 2026-09-25, SHA-256
  `9cd37d37ea654bbcaf0a2e059e6a3a5b5f76072824d8dd860ccf274ada8951bd`.
- GLO-90: [Copernicus DEM licence collection](https://dataspace.copernicus.eu/sites/default/files/media/files/2025-06/copernicus_contributing_mission_data_access_v2_cop_dem_licenses.pdf),
  pages 19–20 for the GLO-90 free and open licence, retrieved 2026-09-25,
  SHA-256 `bb4a01dcd7f61acefa81c9ccd76af975e12096158169acf0d7b5c44c26c8701f`.
- Both free and open licences grant reproduction, distribution, public
  communication and adaptation without a fee or geographic/time limit.
  Article 6 requires the original source notice, an adapted-data notice, and
  a programme liability notice. The exact product-specific text is emitted
  into each map archive's `LICENSES/Elevation-Sources.txt` and
  `ATTRIBUTION.txt` by `topography_notices.py`; the iPhone map details show it
  for these two source IDs. Unknown sources fail notice generation.
- [Copernicus DEM collection](https://dataspace.copernicus.eu/explore-data/data-collections/copernicus-contributing-missions/collections-description/COP-DEM)
  identifies GLO-30/GLO-90 as digital surface models and gives their datum,
  resolution, coverage and public-source attribution guidance.

## Exact public input boundary

The [public COG bucket readme](https://copernicus-dem-90m.s3.amazonaws.com/readme.html)
describes anonymous GLO-30 Public and GLO-90 COGs and says that some GLO-30
countries are absent. The configured adapter uses only the two fixed S3
origins and pinned 2021 tile indices. The index SHA-256 values are
`10604e3052c98a09e9216f1a8f0a555a04148419757575f783d4937fd44316dc`
for GLO-30 Public and
`e5a5efe088e70506bc1007d22006bdcb09b0ec03177b62f9652363c13f49ed97`
for GLO-90. GLO-90 fills unavailable GLO-30 cells. These are DSM heights in
metres, horizontal EPSG:4326 and vertical EPSG:3855. The resulting contours
are not surveyed bare-earth terrain.

## Still required before production approval

- Preserve a durable copy of the reviewed terms and define a change check for
  upstream notices and source access.
- Verify regional source boundaries, water/no-data behavior, high latitudes,
  representative raw/derived checksums and exact-input retention under the
  production cache policy.
- Confirm notice visibility in the catalog/shared page and on the physical
  1.75-inch device. The 2.06-inch device is unavailable for its separate gate.
- Record app/device resource and rendering measurements, signed production
  artifact transfer, rollback and the final reviewer decision.

`productionApproved` remains false until these checks are recorded. A map made
under the current unapproved policy cannot be promoted under an approved
policy because the source-policy digest must match.
