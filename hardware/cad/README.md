# CAD Files

This folder contains the source and printable CAD files for the Waveshare ESP32-S3 Touch AMOLED 1.75 bottom plate.

- `waveshare_amoled_175_bottom_plate.py`: Blender Python source for the plain circular bottom plate.
- `waveshare_amoled_175_bottom_board.blend`: Blender scene generated from the plain bottom plate source.
- `waveshare_amoled_175_bottom_board.stl`: Printable plain bottom plate and input for the Garmin mount generator.
- `garmin-mount.stl`: Source Garmin male mount geometry used by the Garmin bottom plate generator.
- `waveshare_amoled_175_bottom_board_garmin.py`: Blender Python source that combines the plain bottom plate with the Garmin mount locking features.
- `waveshare_amoled_175_bottom_board_garmin.stl`: Printable bottom plate with the Garmin mount, using the tested no-extra-base design.
- `waveshare_amoled_175_bottom_board_garmin_top_holes_tighter.stl`: Garmin bottom plate variant with the top edge of each top connector cutout moved inward by 0.5 mm.
- `*.png`: Rendered previews generated from the STL files.

## Screws

- `waveshare_amoled_175_bottom_board.stl`: uses three M2x3.5 screws.
- `waveshare_amoled_175_bottom_board_garmin.stl`: uses three M2x6 screws.
- `waveshare_amoled_175_bottom_board_garmin_top_holes_tighter.stl`: uses three M2x6 screws.

## STL Previews

| STL | Preview |
| --- | --- |
| `waveshare_amoled_175_bottom_board.stl` | ![Plain Waveshare bottom plate](waveshare_amoled_175_bottom_board.png) |
| `garmin-mount.stl` | ![Garmin male mount source geometry](garmin-mount.png) |
| `waveshare_amoled_175_bottom_board_garmin.stl` | ![Waveshare bottom plate with Garmin mount](waveshare_amoled_175_bottom_board_garmin.png) |
| `waveshare_amoled_175_bottom_board_garmin_top_holes_tighter.stl` | ![Waveshare bottom plate with Garmin mount and tighter top holes](waveshare_amoled_175_bottom_board_garmin_top_holes_tighter.png) |

Regenerate the printable files from this folder with Blender:

```sh
cd hardware/cad
blender -b --python waveshare_amoled_175_bottom_plate.py
blender -b --python waveshare_amoled_175_bottom_board_garmin.py
```

The Garmin generator exports both `waveshare_amoled_175_bottom_board_garmin.stl` and `waveshare_amoled_175_bottom_board_garmin_top_holes_tighter.stl`.
