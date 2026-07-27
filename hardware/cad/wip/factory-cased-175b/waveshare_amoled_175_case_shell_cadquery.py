"""Generate the measured Waveshare AMOLED 1.75 outer shell.

This OpenCascade/CadQuery generator is the authoritative STL/STEP exporter.
Dimensions are millimeters. Z=0 is the top/display edge, positive Z points
down into the case, and the center of the SD-card opening faces +Y.
"""

import math
from pathlib import Path

import cadquery as cq


OUT_DIR = Path(__file__).resolve().parent
SHELL_STL_PATH = OUT_DIR / "waveshare_amoled_175_case_shell.stl"
SHELL_STEP_PATH = OUT_DIR / "waveshare_amoled_175_case_shell.step"
PREVIEW_PATH = OUT_DIR / "waveshare_amoled_175_case_shell_preview.png"
NORMAL_GARMIN_BOTTOM_STL = OUT_DIR / "waveshare_amoled_175_bottom_board_garmin.stl"


# These are direct measurements of the disassembled factory-cased 1.75-B shell
# from 2026-07-21 and 2026-07-22, not dimensions of Waveshare's case-less module
# and its translucent carrier. Arc lengths are measured on the outside wall.
# Screw openings remain deferred until their geometry is measured.
PARAMS = {
    "outer_dia": 51.00,
    "shell_height": 10.50,
    "wall_thickness": 0.50,
    "top_to_first_ledge": 0.50,
    "first_ledge_inset": 1.00,
    "first_ledge_height": 1.00,
    "second_ledge_extra_inset": 2.00,
    "second_ledge_short_height": 0.50,
    "second_ledge_full_height": 3.00,
    "sd_side_angle_deg": 90.00,
    "sd_short_ledge_arc_length": 18.00,
    "sd_opening_width": 13.00,
    "sd_opening_height": 2.00,
    "sd_opening_top_z": 2.00,
    "sd_wall_cut_depth": 2.00,
    "button_access_dia": 3.80,
    "button_opening_top_z": 5.00,
    "button_center_spacing_arc_length": 30.50,
    "button_cut_depth": 8.00,
    "usb_side_angle_deg": 270.00,
    "usb_opening_width": 10.00,
    "usb_opening_top_z": 6.00,
    "usb_opening_bottom_z": 9.50,
    "usb_corner_radius": 1.50,
    "usb_wall_cut_depth": 2.00,
    "mic_access_dia": 1.00,
    "mic_edge_to_center_arc_length": 9.50,
    "mic_cut_depth": 2.00,
}


def annulus(outer_radius, inner_radius, height, z):
    return (
        cq.Workplane("XY")
        .circle(outer_radius)
        .circle(inner_radius)
        .extrude(height)
        .translate((0.0, 0.0, z))
    )


def circular_sector(
    cut_radius,
    measurement_radius,
    center_angle_deg,
    arc_length,
    height,
    z,
    segments=64,
):
    """Extrude a sector whose outside arc has the requested measured length."""
    half_angle_deg = math.degrees((arc_length / 2.0) / measurement_radius)
    start_angle = center_angle_deg - half_angle_deg
    end_angle = center_angle_deg + half_angle_deg
    points = [(0.0, 0.0)]
    for index in range(segments + 1):
        fraction = index / segments
        angle = math.radians(start_angle + (end_angle - start_angle) * fraction)
        points.append(
            (cut_radius * math.cos(angle), cut_radius * math.sin(angle))
        )
    return (
        cq.Workplane("XY")
        .moveTo(*points[0])
        # polyline() treats its first point as a fresh starting point, so draw
        # the radial edge explicitly before following the sampled outer arc.
        .lineTo(*points[1])
        .polyline(points[2:])
        .close()
        .extrude(height)
        .translate((0.0, 0.0, z))
    )


def radial_rounded_box(
    angle_deg,
    width,
    depth,
    height,
    z,
    center_radius,
    corner_radius=None,
):
    """Rounded tangential-by-vertical box extruded through the radial wall."""
    radius = corner_radius or min(width, height) * 0.23
    cutter = (
        cq.Workplane("XY")
        .box(width, depth, height, centered=(True, True, True))
        .edges("|Y")
        .fillet(radius)
    )
    angle = math.radians(angle_deg)
    return (
        cutter.rotate((0, 0, 0), (0, 0, 1), angle_deg - 90.0)
        .translate(
            (
                center_radius * math.cos(angle),
                center_radius * math.sin(angle),
                z,
            )
        )
    )


def radial_cylinder(angle_deg, diameter, depth, z, center_radius):
    """Circular through-wall cutter with its axis pointing radially."""
    angle = math.radians(angle_deg)
    return (
        cq.Workplane("XY")
        .circle(diameter / 2.0)
        .extrude(depth / 2.0, both=True)
        .rotate((0, 0, 0), (0, 1, 0), 90.0)
        .rotate((0, 0, 0), (0, 0, 1), angle_deg)
        .translate(
            (
                center_radius * math.cos(angle),
                center_radius * math.sin(angle),
                z,
            )
        )
    )


def build_shell():
    outer_radius = PARAMS["outer_dia"] / 2.0
    wall_inner_radius = outer_radius - PARAMS["wall_thickness"]
    first_ledge_inner_radius = wall_inner_radius - PARAMS["first_ledge_inset"]
    second_ledge_inner_radius = (
        first_ledge_inner_radius - PARAMS["second_ledge_extra_inset"]
    )
    height = PARAMS["shell_height"]

    # Base round wall: its top edge is exactly 0.5 mm wide radially.
    shell = annulus(outer_radius, wall_inner_radius, height, 0.0)

    # First step begins 0.5 mm below the top edge, projects 1.0 mm inward,
    # and continues for 1.0 mm before the second display shoulder begins.
    first_ledge = annulus(
        wall_inner_radius + 0.05,
        first_ledge_inner_radius,
        PARAMS["first_ledge_height"],
        PARAMS["top_to_first_ledge"],
    )
    shell = shell.union(first_ledge)

    # Second step projects another 2.0 mm inward (3.0 mm total from the wall).
    # It is 3.0 mm high around the case, except for the measured 18 mm SD-side
    # sector, where it stops after 0.5 mm.
    second_ledge_z = (
        PARAMS["top_to_first_ledge"] + PARAMS["first_ledge_height"]
    )
    second_ledge = annulus(
        wall_inner_radius + 0.05,
        second_ledge_inner_radius,
        PARAMS["second_ledge_full_height"],
        second_ledge_z,
    )

    shortened_sector_z = second_ledge_z + PARAMS["second_ledge_short_height"]
    shortened_sector = circular_sector(
        wall_inner_radius + 0.10,
        outer_radius,
        PARAMS["sd_side_angle_deg"],
        PARAMS["sd_short_ledge_arc_length"],
        PARAMS["second_ledge_full_height"]
        - PARAMS["second_ledge_short_height"],
        shortened_sector_z,
    )
    # Relief is applied to the ledge before it is fused to the wall. Cutting
    # the assembled shell would put a cutter face exactly on the wall's inner
    # face, which creates a fragile coincident-face boolean in OpenCascade.
    second_ledge = second_ledge.cut(shortened_sector)
    shell = shell.union(second_ledge)

    # The upper edge of the 2 x 13 mm SD opening is the lower edge of the
    # shortened ledge: Z=0.5 + 1.0 + 0.5 = 2.0 mm.
    sd_opening = radial_rounded_box(
        PARAMS["sd_side_angle_deg"],
        PARAMS["sd_opening_width"],
        PARAMS["sd_wall_cut_depth"],
        PARAMS["sd_opening_height"],
        PARAMS["sd_opening_top_z"] + PARAMS["sd_opening_height"] / 2.0,
        outer_radius,
    )
    shell = shell.cut(sd_opening)

    # 30.5 mm is interpreted as center-to-center arc distance measured on the
    # outside wall. Both button openings start at Z=5.0, 1.0 mm below the SD
    # slot's lower edge.
    button_half_angle_deg = math.degrees(
        (PARAMS["button_center_spacing_arc_length"] / 2.0) / outer_radius
    )
    button_center_z = (
        PARAMS["button_opening_top_z"] + PARAMS["button_access_dia"] / 2.0
    )
    for angle in (
        PARAMS["sd_side_angle_deg"] - button_half_angle_deg,
        PARAMS["sd_side_angle_deg"] + button_half_angle_deg,
    ):
        shell = shell.cut(
            radial_cylinder(
                angle,
                PARAMS["button_access_dia"],
                PARAMS["button_cut_depth"],
                button_center_z,
                outer_radius,
            )
        )

    # The USB-side measurements use explicit upper and lower edges. They imply
    # a 3.5 mm opening; that takes precedence over the approximate 4 mm height.
    # A 10 x 3.5 mm rounded opening comfortably clears the USB-IF's nominal
    # 8.34 x 2.56 mm Type-C receptacle shell.
    usb_height = (
        PARAMS["usb_opening_bottom_z"] - PARAMS["usb_opening_top_z"]
    )
    usb_center_z = (
        PARAMS["usb_opening_top_z"] + PARAMS["usb_opening_bottom_z"]
    ) / 2.0
    shell = shell.cut(
        radial_rounded_box(
            PARAMS["usb_side_angle_deg"],
            PARAMS["usb_opening_width"],
            PARAMS["usb_wall_cut_depth"],
            usb_height,
            usb_center_z,
            outer_radius,
            PARAMS["usb_corner_radius"],
        )
    )

    # Each 1 mm microphone opening is 9.5 mm along the outside arc from the
    # adjacent USB opening edge. Its lower edge aligns with the USB centerline.
    usb_edge_half_angle_deg = math.degrees(
        math.asin((PARAMS["usb_opening_width"] / 2.0) / outer_radius)
    )
    mic_gap_angle_deg = math.degrees(
        PARAMS["mic_edge_to_center_arc_length"] / outer_radius
    )
    mic_center_z = usb_center_z - PARAMS["mic_access_dia"] / 2.0
    mic_offset_angle_deg = usb_edge_half_angle_deg + mic_gap_angle_deg
    for angle in (
        PARAMS["usb_side_angle_deg"] - mic_offset_angle_deg,
        PARAMS["usb_side_angle_deg"] + mic_offset_angle_deg,
    ):
        shell = shell.cut(
            radial_cylinder(
                angle,
                PARAMS["mic_access_dia"],
                PARAMS["mic_cut_depth"],
                mic_center_z,
                outer_radius,
            )
        )

    return shell.clean()


def render_preview(shell_stl, bottom_stl, output_path):
    """Render a headless print-set preview with VTK."""
    import vtk

    renderer = vtk.vtkRenderer()
    renderer.SetBackground(0.76, 0.79, 0.84)
    renderer.SetBackground2(0.46, 0.51, 0.60)
    renderer.GradientBackgroundOn()

    def add_stl(path, position, color):
        reader = vtk.vtkSTLReader()
        reader.SetFileName(str(path))
        reader.Update()

        normals = vtk.vtkPolyDataNormals()
        normals.SetInputConnection(reader.GetOutputPort())
        normals.SetFeatureAngle(35.0)
        normals.ConsistencyOn()
        normals.SplittingOn()

        mapper = vtk.vtkPolyDataMapper()
        mapper.SetInputConnection(normals.GetOutputPort())
        actor = vtk.vtkActor()
        actor.SetMapper(mapper)
        actor.SetPosition(*position)
        actor.GetProperty().SetColor(*color)
        actor.GetProperty().SetInterpolationToPhong()
        actor.GetProperty().SetAmbient(0.34)
        actor.GetProperty().SetDiffuse(0.78)
        actor.GetProperty().SetSpecular(0.18)
        actor.GetProperty().SetSpecularPower(28.0)
        renderer.AddActor(actor)
        return actor

    shell_actor = add_stl(
        shell_stl, (-31.0, 0.0, 0.0), (0.30, 0.33, 0.39)
    )
    # Face the newly measured USB/microphone side toward the preview camera.
    shell_actor.RotateZ(180.0)
    add_stl(bottom_stl, (31.0, 0.0, -0.15), (0.52, 0.55, 0.62))

    key = vtk.vtkLight()
    key.SetPosition(-25.0, -70.0, 115.0)
    key.SetFocalPoint(0.0, 0.0, 3.0)
    key.SetIntensity(1.05)
    renderer.AddLight(key)

    fill = vtk.vtkLight()
    fill.SetPosition(90.0, 35.0, 65.0)
    fill.SetFocalPoint(0.0, 0.0, 2.0)
    fill.SetIntensity(0.55)
    renderer.AddLight(fill)

    camera = renderer.GetActiveCamera()
    camera.SetPosition(0.0, 135.0, 92.0)
    camera.SetFocalPoint(0.0, 0.0, 4.3)
    camera.SetViewUp(0.0, 0.0, 1.0)
    camera.SetViewAngle(31.0)

    window = vtk.vtkRenderWindow()
    window.SetOffScreenRendering(1)
    window.SetSize(1400, 900)
    window.AddRenderer(renderer)
    window.Render()

    capture = vtk.vtkWindowToImageFilter()
    capture.SetInput(window)
    capture.SetScale(1)
    capture.SetInputBufferTypeToRGB()
    capture.ReadFrontBufferOff()
    capture.Update()

    writer = vtk.vtkPNGWriter()
    writer.SetFileName(str(output_path))
    writer.SetInputConnection(capture.GetOutputPort())
    writer.Write()
    window.Finalize()


def audit_stl(path):
    import vtk

    reader = vtk.vtkSTLReader()
    reader.SetFileName(str(path))
    reader.Update()

    triangles = vtk.vtkTriangleFilter()
    triangles.SetInputConnection(reader.GetOutputPort())
    triangles.Update()

    def feature_edge_count(boundary=False, non_manifold=False):
        edges = vtk.vtkFeatureEdges()
        edges.SetInputConnection(triangles.GetOutputPort())
        edges.FeatureEdgesOff()
        edges.ManifoldEdgesOff()
        if boundary:
            edges.BoundaryEdgesOn()
        else:
            edges.BoundaryEdgesOff()
        if non_manifold:
            edges.NonManifoldEdgesOn()
        else:
            edges.NonManifoldEdgesOff()
        edges.Update()
        return edges.GetOutput().GetNumberOfCells()

    mass = vtk.vtkMassProperties()
    mass.SetInputConnection(triangles.GetOutputPort())
    mass.Update()
    mesh = triangles.GetOutput()
    return {
        "triangles": mesh.GetNumberOfCells(),
        "points": mesh.GetNumberOfPoints(),
        "bounds": mesh.GetBounds(),
        "volume_mm3": mass.GetVolume(),
        "boundary_edges": feature_edge_count(boundary=True),
        "non_manifold_edges": feature_edge_count(non_manifold=True),
    }


def main():
    shell = build_shell()
    if not shell.val().isValid():
        raise RuntimeError("OpenCascade produced an invalid shell solid")

    cq.exporters.export(
        shell,
        str(SHELL_STL_PATH),
        tolerance=0.010,
        angularTolerance=0.04,
    )
    cq.exporters.export(shell, str(SHELL_STEP_PATH))
    render_preview(SHELL_STL_PATH, NORMAL_GARMIN_BOTTOM_STL, PREVIEW_PATH)

    audit = audit_stl(SHELL_STL_PATH)
    xmin, xmax, ymin, ymax, zmin, zmax = audit["bounds"]
    print(
        "STL bounds: "
        f"{xmax - xmin:.3f} x {ymax - ymin:.3f} x {zmax - zmin:.3f} mm"
    )
    print(f"OpenCascade valid: {shell.val().isValid()}")
    print(
        "STL audit: "
        f"{audit['triangles']} triangles, "
        f"{audit['boundary_edges']} boundary edges, "
        f"{audit['non_manifold_edges']} non-manifold edges, "
        f"volume {audit['volume_mm3']:.2f} mm^3"
    )
    print(f"Exported: {SHELL_STL_PATH}")
    print(f"Exported: {SHELL_STEP_PATH}")
    print(f"Preview: {PREVIEW_PATH}")


if __name__ == "__main__":
    main()
