# iPhone bike lanes

The Bike Lanes switch in Layers shows a transparent cycling layer.
MapKit places it below the saved route and map labels, and above downloaded
contours. In a pitched view, MapKit can show the cycling lines faintly through
buildings.

The 3D Terrain switch saves a preference for realistic ground. MapKit
flattens the ground while bike lanes, a saved route, a route being created, a
detour, or downloaded contours are visible; routes from MapKit directions keep
the terrain. The 3D
Terrain switch is unchecked and unavailable during that time. Bicino retains
the saved preference. Realistic ground can return when the last affected
overlay is removed and the basemap supports it.

## Tile configuration

Bicino and Bicino Dev builds both use the public CyclOSM Lite endpoint with
its original colors. The layer is opt-in. [Issue #863](https://github.com/seichris/open-bike-computer/issues/863)
tracks tile-source alternatives, including the Bicino backend.

Set two build settings to choose a tile source:

- `BICINO_BIKE_LANES_TILE_HOST`: the HTTPS host name only, such as
  `tiles.example.com`, with no scheme, port, or path.
- `BICINO_BIKE_LANES_TILE_PATH`: the absolute path template, such as
  `/cyclosm-lite/{z}/{x}/{y}.png`. It must contain `{z}`, `{x}`, and `{y}`.

The app joins them as `https://<host><path>`. A full URL cannot go in an
xcconfig file, because `//` starts a comment there and would cut the value to
`https:`. The service should return transparent, 256-pixel XYZ PNG tiles
at zooms 12–18. With either setting empty or invalid, the Bike
Lanes option is hidden. The app shows attribution with the map controls while
the layer is enabled; like the other map chrome, it hides while destination
search is expanded.

## Zoom range and caching

MapKit draws a level-z tile from map zoom z − 1 up to z: it shrinks tiles but
never enlarges them. With z13 as its lowest tile level, the layer disappeared
at zoom 12.0. It now stays visible until zoom 11.415, which is 1.5 times
further out. Tile levels are whole numbers, so the overlay requests z12 tiles,
which cover zoom 11 to 12, and the renderer hides the layer below
`BikeLanesZoomRange.minimumVisibleZoom`. That zoom is measured across the
middle of the map, so tilting the map does not change it. While the layer is
hidden it neither draws nor downloads tiles, and the overlay stays on the map,
so the 3D Terrain behavior above is unchanged.

Tiles load through `BikeLanesTileStore`:

- An in-memory cache of up to 12 MiB and 1,024 tiles, with the least recently
  used tiles evicted first and everything dropped on a memory warning. A tile
  seen earlier in the session appears at once after a zoom or drag.
- A 64 MiB `URLCache` in `Caches/BikeLanesTiles`. It follows the server's
  `Cache-Control` and `ETag` headers: CyclOSM sends `max-age=86400`, so a tile
  comes from disk for a day and is then revalidated with `If-None-Match`.
- Only HTTP 200 image responses are shown and cached: an `image/*` content
  type, or PNG, JPEG or WebP bytes from a host that sends no image type. Errors,
  empty bodies and other pages are not kept in memory or on disk. When the network fails or the server
  returns a 5xx error, an expired tile on disk is shown rather than an empty
  map; it is not added to memory, so the next load retries the network.
- Concurrent requests for the same tile share one download. Tiles are not
  prefetched, which keeps load on the public tile server to what the map shows.

Debug builds launched with `--bike-lanes-tile-diagnostics` log each tile's zoom
and source (`memory`, `disk`, `revalidated`, `network`, `stale` or `failed`)
with running totals, and each time the layer is shown or hidden. The log leaves
out tile coordinates.

For a Debug Simulator trial, place a small styled sample in the app's
`Documents/CyclOSMLiteTeal/<z>/<x>/<y>.png` folder before launch. The local
sample takes priority over the configured service in that build.
`ios-app/scripts/style-cyclosm-lite-fixture.py` restyles a local set of
CyclOSM Lite PNGs with the teal color used in the Simulator trial.
