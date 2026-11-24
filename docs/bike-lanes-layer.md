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

Production builds use the public CyclOSM Lite endpoint with its original
colors. The layer is opt-in. [Issue #863](https://github.com/seichris/open-bike-computer/issues/863)
tracks tile-source alternatives, including the Bicino backend.

Set two build settings to choose a tile source:

- `BICINO_BIKE_LANES_TILE_HOST`: the HTTPS host name only, such as
  `tiles.example.com`, with no scheme, port, or path.
- `BICINO_BIKE_LANES_TILE_PATH`: the absolute path template, such as
  `/cyclosm-lite/{z}/{x}/{y}.png`. It must contain `{z}`, `{x}`, and `{y}`.

The app joins them as `https://<host><path>`. A full URL cannot go in an
xcconfig file, because `//` starts a comment there and would cut the value to
`https:`. The service should return transparent, 256-pixel XYZ PNG tiles
at zooms 13–18. With either setting empty or invalid, the Bike
Lanes option is hidden. The app shows attribution with the map controls while
the layer is enabled; like the other map chrome, it hides while destination
search is expanded.

For a Debug Simulator trial, place a small styled sample in the app's
`Documents/CyclOSMLiteTeal/<z>/<x>/<y>.png` folder before launch. The local
sample takes priority over the configured service in that build.
`ios-app/scripts/style-cyclosm-lite-fixture.py` restyles a local set of
CyclOSM Lite PNGs with the teal color used in the Simulator trial.
