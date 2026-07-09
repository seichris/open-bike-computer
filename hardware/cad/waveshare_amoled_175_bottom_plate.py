import math
from pathlib import Path

import bpy


OUT_DIR = Path(__file__).resolve().parent
BLEND_PATH = OUT_DIR / "waveshare_amoled_175_bottom_board.blend"
STL_PATH = OUT_DIR / "waveshare_amoled_175_bottom_board.stl"


# Dimensions are in millimeters. This is intentionally only the flat bottom
# board/plate visible in the protective-case image, not the full side shell.
PARAMS = {
    "bottom_board_dia": 51.00,
    "plate_thickness": 1.60,
    "m2_through_dia": 2.20,
    "screw_countersink_outer_dia": 4.80,
    "screw_countersink_angle_deg": 90.00,
    "bevel_radius": 0.18,
    "header_opening_width": 21.80,
    "header_opening_len": 3.20,
    "connector_cutout_width": 6.90,
    "connector_cutout_len": 5.40,
    "pcb_reference_dia": 46.00,
    "display_assembly_reference_dia": 48.96,
    "top_connector_center_y": 18.10,
    "bottom_screw_center_y": -14.70,
    "bottom_screw_center_x": 13.75,
    "header_center_y": -18.70,
    "top_connector_spacing_x": 13.50,
}


# Origin is the center of the board. Values follow the usable screw pattern
# visible in the official Waveshare bottom/project drawing.
SCREW_CENTERS = [
    (0.00, 20.50),
    (-13.75, -14.70),
    (13.75, -14.70),
]


def clean_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete()


def setup_units():
    scene = bpy.context.scene
    scene.unit_settings.system = "METRIC"
    scene.unit_settings.scale_length = 0.001
    scene.unit_settings.length_unit = "MILLIMETERS"


def material(name, color):
    mat = bpy.data.materials.new(name)
    mat.diffuse_color = color
    return mat


def transparent_material(name, color, alpha):
    mat = bpy.data.materials.new(name)
    mat.diffuse_color = (*color, alpha)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    if bsdf:
        bsdf.inputs["Alpha"].default_value = alpha
        bsdf.inputs["Base Color"].default_value = (*color, alpha)
    mat.blend_method = "BLEND"
    return mat


def add_cylinder(name, radius, depth, loc, vertices=160, mat=None):
    bpy.ops.mesh.primitive_cylinder_add(vertices=vertices, radius=radius, depth=depth, location=loc)
    obj = bpy.context.object
    obj.name = name
    if mat:
        obj.data.materials.append(mat)
    return obj


def add_frustum(name, top_radius, bottom_radius, z_top, z_bottom, loc_xy, vertices=128, mat=None):
    x, y = loc_xy
    verts = []
    faces = []

    for i in range(vertices):
        theta = 2.0 * math.pi * i / vertices
        c = math.cos(theta)
        s = math.sin(theta)
        verts.append((x + top_radius * c, y + top_radius * s, z_top))
        verts.append((x + bottom_radius * c, y + bottom_radius * s, z_bottom))

    for i in range(vertices):
        j = (i + 1) % vertices
        faces.append((2 * i, 2 * j, 2 * j + 1, 2 * i + 1))

    faces.append(tuple(2 * i for i in range(vertices)))
    faces.append(tuple(reversed([2 * i + 1 for i in range(vertices)])))

    mesh = bpy.data.meshes.new(name + "Mesh")
    mesh.from_pydata(verts, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    if mat:
        obj.data.materials.append(mat)
    return obj


def add_cube(name, dimensions, loc, mat=None):
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=loc)
    obj = bpy.context.object
    obj.name = name
    obj.dimensions = dimensions
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    if mat:
        obj.data.materials.append(mat)
    return obj


def add_bevel(obj, amount, segments=3):
    bevel = obj.modifiers.new("print_edge_bevel", "BEVEL")
    bevel.width = amount
    bevel.segments = segments
    bevel.affect = "EDGES"
    bevel.harden_normals = True
    obj.modifiers.new("weighted_normals", "WEIGHTED_NORMAL")


def bool_difference(target, cutter, name):
    bpy.context.view_layer.objects.active = target
    mod = target.modifiers.new(name, "BOOLEAN")
    mod.operation = "DIFFERENCE"
    mod.object = cutter
    mod.solver = "EXACT"
    bpy.ops.object.modifier_apply(modifier=mod.name)


def make_rounded_box_cutter(name, dimensions, loc, bevel_radius):
    cutter = add_cube(name, dimensions, loc)
    bevel = cutter.modifiers.new("cutter_rounding", "BEVEL")
    bevel.width = bevel_radius
    bevel.segments = 8
    cutter.modifiers.new("cutter_normals", "WEIGHTED_NORMAL")
    bpy.context.view_layer.objects.active = cutter
    cutter.select_set(True)
    bpy.ops.object.modifier_apply(modifier=bevel.name)
    return cutter


def add_wire_ring(name, dia, z, mat):
    ring = add_cylinder(name, dia / 2.0, 0.08, (0, 0, z), vertices=192, mat=mat)
    ring.display_type = "WIRE"
    ring.hide_render = True
    return ring


def add_text(name, text, loc, size=1.45):
    bpy.ops.object.text_add(location=loc, rotation=(math.radians(90), 0, 0))
    obj = bpy.context.object
    obj.name = name
    obj.data.body = text
    obj.data.align_x = "CENTER"
    obj.data.align_y = "CENTER"
    obj.data.size = size
    return obj


def build_model(
    stl_path=STL_PATH,
    blend_path=BLEND_PATH,
    top_connector_top_inset_mm=0.0,
    save_blend=True,
):
    clean_scene()
    setup_units()

    plate_mat = material("mat_black_printed_bottom_board", (0.018, 0.017, 0.016, 1.0))
    cutter_mat = material("mat_hidden_cutters", (1.0, 0.05, 0.02, 0.18))
    ref_case_mat = transparent_material("mat_case_outer_reference", (0.0, 0.35, 0.8), 0.22)
    ref_display_mat = transparent_material("mat_display_reference", (0.0, 0.8, 0.35), 0.18)
    text_mat = material("mat_dimension_text", (0.1, 0.1, 0.1, 1.0))

    t = PARAMS["plate_thickness"]
    plate = add_cylinder(
        "print_bottom_board_plate_OD_51mm",
        PARAMS["bottom_board_dia"] / 2.0,
        t,
        (0, 0, t / 2.0),
        vertices=192,
        mat=plate_mat,
    )
    add_bevel(plate, PARAMS["bevel_radius"], segments=4)

    cutters = []
    countersink_depth = (
        PARAMS["screw_countersink_outer_dia"] - PARAMS["m2_through_dia"]
    ) / (2.0 * math.tan(math.radians(PARAMS["screw_countersink_angle_deg"] / 2.0)))

    for idx, (x, y) in enumerate(SCREW_CENTERS, start=1):
        through = add_cylinder(
            f"m2_through_hole_cutter_{idx}",
            PARAMS["m2_through_dia"] / 2.0,
            t + 1.0,
            (x, y, t / 2.0),
            vertices=72,
            mat=cutter_mat,
        )
        bool_difference(plate, through, "m2_through_hole")
        cutters.append(through)

        countersink = add_frustum(
            f"m2_90deg_countersink_cutter_{idx}",
            PARAMS["screw_countersink_outer_dia"] / 2.0,
            PARAMS["m2_through_dia"] / 2.0,
            t + 0.03,
            t - countersink_depth - 0.03,
            (x, y),
            vertices=128,
            mat=cutter_mat,
        )
        bool_difference(plate, countersink, "m2_90deg_countersink")
        cutters.append(countersink)

    # Bottom header opening: the STEP reference shows this as one continuous
    # rectangular opening, not eight separate pin apertures.
    header_opening = make_rounded_box_cutter(
        "rear_8pin_header_single_opening_cutter",
        (PARAMS["header_opening_width"], PARAMS["header_opening_len"], t + 1.0),
        (0.0, PARAMS["header_center_y"], t / 2.0),
        0.45,
    )
    bool_difference(plate, header_opening, "rear_8pin_header_single_opening")
    cutters.append(header_opening)

    # Two small top connector windows for the speaker/battery connectors visible
    # near the top of the bottom-plate image.
    top_connector_len = PARAMS["connector_cutout_len"] - top_connector_top_inset_mm
    if top_connector_len <= 0:
        raise ValueError("top_connector_top_inset_mm must be smaller than connector_cutout_len")
    top_connector_center_y = PARAMS["top_connector_center_y"] - top_connector_top_inset_mm / 2.0

    for idx, x in enumerate((-PARAMS["top_connector_spacing_x"] / 2.0, PARAMS["top_connector_spacing_x"] / 2.0), start=1):
        conn_cut = make_rounded_box_cutter(
            f"rear_connector_access_cutout_cutter_{idx}",
            (PARAMS["connector_cutout_width"], top_connector_len, t + 1.0),
            (x, top_connector_center_y, t / 2.0),
            0.45,
        )
        bool_difference(plate, conn_cut, "rear_connector_access_cutout")
        cutters.append(conn_cut)

    for cutter in cutters:
        cutter.hide_viewport = True
        cutter.hide_render = True

    # Non-printing reference rings so the plate can be checked against the
    # internal PCB/display dimensions without adding them to the STL.
    add_wire_ring("reference_pcb_OD_46mm", PARAMS["pcb_reference_dia"], t + 0.35, ref_case_mat)
    add_wire_ring(
        "reference_display_assembly_OD_48_96mm",
        PARAMS["display_assembly_reference_dia"],
        t + 0.55,
        ref_display_mat,
    )

    info = (
        "Flat bottom plate only, matched to protective-case image\n"
        "OD 51.00 mm | thickness 1.60 mm | M2 through 2.20 mm | 90 deg countersink 4.80 mm\n"
        "Header: single opening 21.80 x 3.20 mm; top connector windows 6.90 x 5.40 mm\n"
        "Screw centers: (0,+20.50), (+/-13.75,-14.70)\n"
        "Reference rings only: PCB OD 46.00 mm, display OD 48.96 mm"
    )
    text = add_text("dimension_notes", info, (0, 31, 0.05))
    text.data.materials.append(text_mat)

    root = bpy.data.objects.new("PARAMS_edit_dimensions_here", None)
    bpy.context.collection.objects.link(root)
    for key, value in PARAMS.items():
        root[key] = value
    root["screw_countersink_depth"] = countersink_depth
    root["screw_centers_xy_mm"] = str(SCREW_CENTERS)
    root["top_connector_top_inset_mm"] = top_connector_top_inset_mm

    camera_data = bpy.data.cameras.new("Camera")
    camera = bpy.data.objects.new("Camera", camera_data)
    bpy.context.collection.objects.link(camera)
    camera.location = (0, -75, 45)
    camera.rotation_euler = (math.radians(58), 0, 0)
    camera_data.lens = 55
    bpy.context.scene.camera = camera

    light_data = bpy.data.lights.new("Key_Area_Light", "AREA")
    light = bpy.data.objects.new("Key_Area_Light", light_data)
    bpy.context.collection.objects.link(light)
    light.location = (0, -30, 45)
    light_data.energy = 350
    light_data.size = 50

    bpy.context.scene.render.engine = "CYCLES"
    bpy.context.scene.cycles.samples = 64
    bpy.context.scene.view_settings.view_transform = "Filmic"
    bpy.context.scene.view_settings.look = "Medium High Contrast"

    if save_blend:
        bpy.ops.wm.save_as_mainfile(filepath=str(blend_path))

    bpy.ops.object.select_all(action="DESELECT")
    plate.select_set(True)
    bpy.context.view_layer.objects.active = plate
    bpy.ops.wm.stl_export(filepath=str(stl_path), export_selected_objects=True)


if __name__ == "__main__":
    build_model()
