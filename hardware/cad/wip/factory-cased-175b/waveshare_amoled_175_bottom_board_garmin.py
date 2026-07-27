import math
from pathlib import Path

import bpy
from mathutils import Vector


OUT_DIR = Path(__file__).resolve().parent
BOTTOM_PLATE_STL = OUT_DIR / "waveshare_amoled_175_bottom_board.stl"
GARMIN_STL = OUT_DIR / "garmin-mount.stl"
COMBINED_STL_PATH = OUT_DIR / "waveshare_amoled_175_bottom_board_garmin.stl"
GARMIN_UPPER_SOURCE_CUT_ABOVE_PLATE = 3.00


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


def import_stl(path, name):
    bpy.ops.wm.stl_import(filepath=str(path))
    obj = bpy.context.object
    obj.name = name
    return obj


def set_origin_to_bounds_center(obj):
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    bpy.ops.object.origin_set(type="ORIGIN_GEOMETRY", center="BOUNDS")
    obj.select_set(False)


def bounds_world(obj):
    corners = [obj.matrix_world @ Vector(corner) for corner in obj.bound_box]
    mins = Vector((min(v.x for v in corners), min(v.y for v in corners), min(v.z for v in corners)))
    maxs = Vector((max(v.x for v in corners), max(v.y for v in corners), max(v.z for v in corners)))
    return mins, maxs


def format_bounds(bounds):
    mins, maxs = bounds
    size = maxs - mins
    return f"{size.x:.3f} x {size.y:.3f} x {size.z:.3f}"


def center_xy(obj):
    mins, maxs = bounds_world(obj)
    obj.location.x -= (mins.x + maxs.x) / 2.0
    obj.location.y -= (mins.y + maxs.y) / 2.0


def place_bottom_on_z(obj, z):
    mins, _ = bounds_world(obj)
    obj.location.z += z - mins.z


def add_text(name, text, loc, size=2.0):
    bpy.ops.object.text_add(location=loc, rotation=(math.radians(90), 0, 0))
    obj = bpy.context.object
    obj.name = name
    obj.data.body = text
    obj.data.align_x = "CENTER"
    obj.data.align_y = "CENTER"
    obj.data.size = size
    return obj


def copy_mesh_faces_above_world_z(source, name, min_z, mat=None, floor_tolerance=0.05):
    world_verts = [source.matrix_world @ vertex.co for vertex in source.data.vertices]
    vert_map = {}
    verts = []
    faces = []

    for polygon in source.data.polygons:
        if all(world_verts[index].z >= min_z for index in polygon.vertices):
            # Drop coplanar cut-floor faces. The bottom plate owns that contact
            # plane; keeping the cut face causes z-fighting artifacts in Blender.
            if all(world_verts[index].z <= min_z + floor_tolerance for index in polygon.vertices):
                continue
            face = []
            for index in polygon.vertices:
                if index not in vert_map:
                    vert_map[index] = len(verts)
                    verts.append(tuple(world_verts[index]))
                face.append(vert_map[index])
            faces.append(tuple(face))

    mesh = bpy.data.meshes.new(name + "Mesh")
    mesh.from_pydata(verts, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    if mat:
        obj.data.materials.append(mat)
    return obj


def move_bottom_to_z(obj, z):
    bpy.context.view_layer.update()
    mins, _ = bounds_world(obj)
    obj.location.z += z - mins.z
    bpy.context.view_layer.update()


def create_joined_duplicate(name, parts, hidden=True):
    bpy.ops.object.select_all(action="DESELECT")
    hide_states = [(obj, obj.hide_viewport) for obj in parts]
    for obj in parts:
        obj.hide_viewport = False
    for obj in parts:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = parts[0]
    bpy.ops.object.duplicate()
    for obj, was_hidden in hide_states:
        obj.hide_viewport = was_hidden
    duplicate_parts = list(bpy.context.selected_objects)
    bpy.context.view_layer.objects.active = duplicate_parts[0]
    bpy.ops.object.join()
    combined = bpy.context.object
    combined.name = name
    combined.data.name = name + "_mesh"
    combined.hide_viewport = hidden
    combined.hide_render = hidden
    return combined


def build_scene():
    clean_scene()
    setup_units()

    plate_mat = material("bottom_plate_black", (0.018, 0.017, 0.016, 1.0))
    garmin_mat = material("garmin_male_mount_blue_reference", (0.05, 0.19, 0.55, 1.0))
    note_mat = material("scene_note_gray", (0.22, 0.22, 0.22, 1.0))

    plate = import_stl(BOTTOM_PLATE_STL, "waveshare_bottom_plate_usb_front")
    plate.data.materials.append(plate_mat)
    set_origin_to_bounds_center(plate)
    center_xy(plate)
    place_bottom_on_z(plate, 0.0)

    _, plate_max = bounds_world(plate)

    garmin = import_stl(GARMIN_STL, "garmin_male_original_hidden")
    garmin.data.materials.append(garmin_mat)
    set_origin_to_bounds_center(garmin)
    native_garmin_bounds = format_bounds(bounds_world(garmin))

    # Native Garmin mount bounds are about X=32, Y=6, Z=32 mm. Rotate it so the
    # 6 mm thickness protrudes outward from the bottom plate, then rotate 90
    # degrees in-plane so a mounted device's USB/front side points to -Y.
    garmin.rotation_euler = (math.radians(-90), 0, math.radians(90))
    bpy.context.view_layer.update()
    bpy.context.view_layer.objects.active = garmin
    garmin.select_set(True)
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
    garmin.select_set(False)
    center_xy(garmin)
    place_bottom_on_z(garmin, plate_max.z)
    bpy.context.view_layer.update()
    rotated_garmin_bounds = format_bounds(bounds_world(garmin))

    upper_source_cut_z = plate_max.z + GARMIN_UPPER_SOURCE_CUT_ABOVE_PLATE
    garmin_upper = copy_mesh_faces_above_world_z(
        garmin,
        "garmin_male_locking_features",
        upper_source_cut_z,
        garmin_mat,
    )
    move_bottom_to_z(garmin_upper, plate_max.z)
    garmin.hide_viewport = True
    garmin.hide_render = True

    combined = create_joined_duplicate(
        "printable_combined_bottom_plate_garmin",
        [plate, garmin_upper],
    )

    root = bpy.data.objects.new("assembly_dimensions", None)
    bpy.context.collection.objects.link(root)
    root["bottom_plate_dia_mm"] = 51.0
    root["bottom_plate_thickness_mm"] = round(plate_max.z, 3)
    root["garmin_source_stl"] = str(GARMIN_STL)
    root["garmin_native_bounds_mm"] = native_garmin_bounds
    root["garmin_upper_source_cut_z_mm"] = round(upper_source_cut_z, 3)
    root["garmin_rotated_original_bounds_mm"] = rotated_garmin_bounds
    root["garmin_rotation_euler_deg"] = "-90, 0, 90"
    root["usb_front_direction"] = "-Y"
    root["printable_combined_stl"] = str(COMBINED_STL_PATH)

    note = add_text(
        "orientation_note",
        "USB/front side faces camera (-Y)\nGarmin male plug faces outward, rotated 90 deg in-plane\nCombined printable STL exported",
        (0, -34, 0.05),
        size=1.8,
    )
    note.data.materials.append(note_mat)

    camera_data = bpy.data.cameras.new("Camera")
    camera = bpy.data.objects.new("Camera", camera_data)
    bpy.context.collection.objects.link(camera)
    camera.location = (0, -82, 42)
    camera.rotation_euler = (math.radians(62), 0, 0)
    camera_data.lens = 55
    bpy.context.scene.camera = camera

    light_data = bpy.data.lights.new("Key_Area_Light", "AREA")
    light = bpy.data.objects.new("Key_Area_Light", light_data)
    bpy.context.collection.objects.link(light)
    light.location = (0, -35, 65)
    light_data.energy = 450
    light_data.size = 55

    bpy.context.scene.render.engine = "CYCLES"
    bpy.context.scene.cycles.samples = 64
    bpy.context.scene.view_settings.view_transform = "Filmic"
    bpy.context.scene.view_settings.look = "Medium High Contrast"

    bpy.ops.object.select_all(action="DESELECT")
    combined.hide_viewport = False
    combined.select_set(True)
    bpy.context.view_layer.objects.active = combined
    bpy.ops.wm.stl_export(filepath=str(COMBINED_STL_PATH), export_selected_objects=True)
    combined.hide_viewport = True
    combined.select_set(False)


if __name__ == "__main__":
    build_scene()
