# World Radio wire fixtures

`world-radio-v1.txt` contains independently specified request/status bytes and
malformed inputs. It is intentionally not generated from either codec.
`test_world_radio_protocol.cpp` checks firmware decoding and encoding;
`WorldRadioTests.swift` checks phone decoding and status encoding against the
same file. Run the tests from the repository root (C++ also supports `esp32/`).
The optional first C++ argument overrides the fixture path.

Coverage includes negative and boundary E7 coordinates, `UInt32.max` request
identity, full UTF-8 byte budgets (48/28/24), NFC accents, reserved bytes,
unknown versions/commands/states, zero IDs and short/overlong packets.
There are no protocol layout or version changes in the reuse refactor.

# Route elevation fixtures

`route-elevation-v1/` is generated from the backend processing reference by
`tools/generate_route_elevation_fixtures.py`; `--check` fails on drift.

- `processing.json`: route geometry, raw or GPX-vertex heights and structure
  spans with the expected canonical samples, statistics, quality, display
  points and progress queries. Python and Swift reprocess every case within the
  listed tolerances; display points and queries are exact.
- `transfer-v1.txt`: `name hex` ELV1 bodies, frames, progress, state and EAK1
  bytes derived from the committed rounded values, plus malformed bodies.
  `RouteElevationTests.swift` checks the phone encoder and
  `test_route_elevation_protocol.cpp` the firmware decoder against them.
- `service-response-v1.json`: a ready `POST /v1/route-elevation-profiles`
  answer the Swift decoder validates.

Terrain values are synthetic; no case claims measured accuracy.

# Map reader capability fixture

`map-reader-capabilities-v1.txt` holds the exact `mapReader` objects that
firmware reports in its authenticated map transfer status: `production` for
profiles without the POI reader and `map_pois` for profiles with it.
`test_map_compatibility_corpus.cpp` requires the firmware string to match for
both builds; `MapCompatibilityContractTests.swift` decodes both lines and
installs the frozen durable map corpus against them. See
[durable map compatibility](../../docs/map-compatibility-contract.md).
