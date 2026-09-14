# World Radio offline relief map

Made with [Natural Earth I: shaded relief and water](https://www.naturalearthdata.com/downloads/10m-raster-data/10m-natural-earth-1/).
Natural Earth raster data is [public domain](https://www.naturalearthdata.com/about/terms-of-use/).
The downloaded `NE1_LR_LC_SR_W.zip` archive identifies itself as **2.0.0** in
its VERSION file (the current website advertises a newer version). The exact
archive, derived source PNG, output, and decoded pixels are hash-pinned.

`natural-earth.png` is the reproducible 1024x512 RGB reduction of the pinned
16200x8100 GeoTIFF. It is the small, checked-in source, not a runtime download.
The WGS84 plate-carree extent is west=-180, east=180, north=90, south=-90.
The firmware uses the same projection for reticle selection and BLE coordinates.

Generation uses Pillow 11.3.0, Lanczos reduction, 256-color median-cut
quantization without dithering, RGB565 palette conversion, and bounded
literal/run packets. A repeat packet's high bit is set; the low seven bits plus
one are its pixel count. Repeat packets have one index; literal packets have
one index per pixel. Runtime decoding happens once directly into a 1 MiB PSRAM
canvas shared by all three longitude-wrap views. No SD asset, networking,
runtime image codec, additional decode buffer, or per-drag decoding is required.

The generated data is compiled only with `FIRMWARE_DIAGNOSTICS=1`; production
does not contain the preview texture. Allocation/decode failure keeps the
existing "World map unavailable" fallback and the station controls.

From the repository root, using an asset-generation Python environment with
`Pillow==11.3.0` (not the attested firmware runtime):

```sh
python esp32/tools/generate_world_radio_map.py --check
python esp32/tools/generate_world_radio_map.py --preview /tmp/world-radio-map.png
```

For an intentional reimport, download the `sourceUrl` in `manifest.json` and run
`--import-archive /path/to/NE1_LR_LC_SR_W.zip`. Import rejects a different archive
hash or georeferencing. Regenerate and check afterward. Ordinary builds and CI
use the committed reduced source and never download the 183 MiB archive.
