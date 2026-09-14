# Ride Stats device preview

The iPhone settings preview is composed from sample tiles rendered by the
**actual ESP32 screen helpers and LVGL 9.2.2**. It is not a SwiftUI grid with
approximate fonts. The renderer is `esp32/lib/gui/src/rideTelemetryScr.cpp`;
`generate_ride_stats_preview.py` extracts its production helpers and compiles
those helpers with the production layout, presenters, fonts and typography.

The app uses the paired device's `firmwareTarget` to select the round 466 × 466
1.75-inch display or the rectangular 410 × 502 2.06-inch display. Before device
metadata is available, the example defaults to the round 1.75-inch model.

## Regeneration

Use a clean local checkout of `lvgl/lvgl` at
`7f07a129e8d77f4984fff8e623fd5be18ff42e74` (v9.2.2). The generator verifies both
the Git identity, when available, and the digest of all LVGL source/CMake
inputs against `lvgl-source.lock.json`; exported source is also supported.
Do not update that lock independently of the firmware's LVGL pin.

From the repository root, with CMake, a C/C++17 compiler and Pillow installed
(the repository's `esp32/tools/preconnection-assets-requirements.txt` pins
Pillow 11.3.0):

```sh
python3 tools/generate_ride_stats_preview.py \
  --lvgl-source /path/to/lvgl \
  --build-dir /path/to/disposable-preview-build
python3 tools/generate_ride_stats_preview.py \
  --lvgl-source /path/to/lvgl \
  --build-dir /path/to/disposable-preview-build --check
python3 tools/tests/test_ride_stats_preview.py
```

The build is a headless host renderer, not firmware and not a device flash.
Assertions remain enabled. It verifies actual nontransparent pixels against
the round panel's eight-pixel clearance and exercises live paired altitude
font selection. The normal root Python test discovery verifies generation
input hashes, sprite bounds, all widget/slot/row-pair coverage and the Swift
composition contract when a Swift compiler is installed. `--check` compares
PNG decoded pixels, avoiding differences caused only by zlib/Pillow encoding.

## Generated app resources

`RideStatsPreview.dataset/preview.json` contains native tile bounds, font-size
inspection data, sprite coordinates and generator-input hashes.
`RideStatsPreviewAtlas.imageset/atlas.png` contains only rendered sample widget
text/icons, not a font library. Duplicate tiles are shared. Resource loading
uses the app asset catalog; no network, font installation or on-device LVGL
runtime is required by the iPhone preview.

Every supported widget can occupy every slot. Paired row tiles reproduce the
font adjustment when altitude is on the right, including Smart fields that
resolve to altitude and a heart-rate field on the left. Four coherent sensor
examples (no optional sensors, power, cadence, both) keep Smart fields
consistent with selected sensor widgets. These are example values, not live
ride telemetry. Widget positions update immediately when the user reorders.

The circular shape, true glyphs, label order, title sizes, heart, zone strip,
unit text and pair sizing come from the firmware. Canvas scales the composed
native-resolution result uniformly; it never independently shrinks text.
