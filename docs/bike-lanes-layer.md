# iPhone bike lanes

The Bike Lanes switch in Layers shows a transparent teal CyclOSM Lite layer.
MapKit places it below the saved route and map labels. In a pitched view,
MapKit can show the cycling lines faintly through buildings.

The 3D Terrain switch saves a preference for realistic ground. MapKit can
temporarily flatten the ground while bike lanes, a saved route, a detour, or
downloaded contours are visible. The 3D Terrain switch is unchecked and
unavailable during that time. Bicino retains the saved preference. Realistic
ground can return when the last affected overlay is removed and the basemap
supports it.

## Tile configuration

Set `BICINO_BIKE_LANES_TILE_URL_TEMPLATE` at build time to the HTTPS URL
template for a managed tile service. It must contain `{z}`, `{x}`, and `{y}`.
The service should return transparent, 256-pixel XYZ PNG tiles styled in thin
teal at zooms 13–18. With no tile service configured, the Bike Lanes option
is hidden. The app shows attribution when the layer is enabled.

For a Debug Simulator trial, place a small styled sample in the app's
`Documents/CyclOSMLiteTeal/<z>/<x>/<y>.png` folder before launch. The local
sample takes priority over the configured service in that build.
`ios-app/scripts/style-cyclosm-lite-fixture.py` restyles a local set of
CyclOSM Lite PNGs with the teal color used in the Simulator trial.
