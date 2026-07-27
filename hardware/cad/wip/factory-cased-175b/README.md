# Factory-cased Waveshare AMOLED 1.75-B case (WIP)

> [!WARNING]
> This design is a work in progress. It has not completed physical fit testing
> and is not ready to be treated as a finished enclosure.

This folder preserves the current enclosure work for the factory-cased
`ESP32-S3-Touch-AMOLED-1.75-B` after disassembly. The AMOLED display rests on
and is adhered to the black case bezel, while the PCB is secured inside that
case structure.

It is **not** a case for the standard bare module whose display and PCB arrive
pre-aligned by a translucent carrier. That mechanically different module will
get a separate design.

## Current state

The current shell models:

- a 51.0 mm outside diameter, 10.5 mm high circular wall;
- the measured two-step display-support ledges;
- the shortened ledge above the SD-card opening;
- the SD-card and two lowered side-button openings;
- the rounded USB-C opening and two microphone openings; and
- a separate flat, normal 0-degree Garmin-mount bottom.

Still missing or unverified:

- the two PCB-to-upper-case screw bosses/holes;
- confirmation of whether those small screws are 1.0 or 1.2 mm self-tappers;
- final print clearances, adhesive allowance, and physical fit testing;
- repair/fusion of the current Garmin-bottom mesh before calling it
  print-ready; and
- any refinements discovered during assembly of the first printed prototype.

The three M2 rear-cover positions are present in the bottom-plate model. Screw
openings are intentionally absent from the upper shell until the remaining
measurements are known.

## Files

| File | Purpose |
| --- | --- |
| `waveshare_amoled_175_case_shell_cadquery.py` | Authoritative parametric upper-shell generator |
| `waveshare_amoled_175_case_shell.step` | Editable upper-shell solid |
| `waveshare_amoled_175_case_shell.stl` | Printable upper-shell snapshot |
| `waveshare_amoled_175_case_shell_preview.png` | Current shell and flat Garmin-bottom preview |
| `waveshare_amoled_175_bottom_plate.py` | Parametric flat bottom-plate generator |
| `waveshare_amoled_175_bottom_board.stl` | Generated flat bottom plate |
| `waveshare_amoled_175_bottom_board_garmin.py` | Normal 0-degree Garmin-bottom generator |
| `waveshare_amoled_175_bottom_board_garmin.stl` | Printable normal Garmin bottom |
| `garmin-mount.stl` | Garmin locking geometry consumed by the bottom generator |

## Measured shell geometry

`Z=0` is the display-side top edge. Positive Z points down into the case. Arc
lengths below were measured along the 51 mm outside wall.

| Feature | Current geometry |
| --- | --- |
| Round wall | 51 mm outside diameter, 10.5 mm high, 0.5 mm radial thickness |
| First display ledge | Starts at `Z=0.5`, projects 1 mm inward, 1 mm high |
| Second display ledge | Starts at `Z=1.5`, projects another 2 mm inward, 3 mm high around most of the circle |
| Short SD sector | 18 mm outside arc; second ledge is only 0.5 mm high and ends at `Z=2.0` |
| SD opening | 13 mm wide x 2 mm high, `Z=2.0` to `Z=4.0` |
| Button openings | 3.8 mm diameter, upper edges at `Z=5.0`, centers 30.5 mm apart along the outside arc |
| USB-C opening | 10 mm wide x 3.5 mm high, `Z=6.0` to `Z=9.5`, 1.5 mm corner radii |
| Microphone openings | Two 1 mm holes, each 9.5 mm along the outside arc from the adjacent USB-C edge |

## Regeneration

The bottom generators require Blender. The upper shell requires CadQuery and
VTK. Generate the files in this order because the shell preview includes the
Garmin bottom:

```sh
blender -b --python waveshare_amoled_175_bottom_plate.py
blender -b --python waveshare_amoled_175_bottom_board_garmin.py
python -m pip install cadquery vtk
python waveshare_amoled_175_case_shell_cadquery.py
```

The shell generator validates the OpenCascade solid and audits the generated
STL for boundary and non-manifold edges.

## Validation snapshot

Regenerated with Blender 5.1.2, CadQuery 2.8.0, and VTK 9.6.2:

- upper shell: valid OpenCascade solid, `50.999 x 51.000 x 10.500 mm`, 15,458
  triangles, zero boundary edges, and zero non-manifold edges;
- plain bottom plate: `51.000 x 51.000 x 1.600 mm`, four boundary edges, and
  zero non-manifold edges; and
- Garmin bottom: `51.000 x 51.000 x 4.600 mm`, 169 boundary edges, and zero
  non-manifold edges.

The shell is geometrically watertight. Both bottom meshes remain WIP; the
Garmin bottom in particular may depend on slicer repair and should be repaired
and physically tested before release.
