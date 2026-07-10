import math
from pathlib import Path

import bpy
import bmesh
from mathutils import Vector


OUT_DIR = Path(__file__).resolve().parent
CASE_STL = OUT_DIR / "waveshare_206_case.stl"
GARMIN_STL = OUT_DIR / "garmin-mount.stl"
OUTPUT_STL = OUT_DIR / "waveshare_206_case_garmin.stl"

GARMIN_BACKING_THICKNESS_MM = 3.0
GARMIN_CASE_OVERLAP_MM = 0.25


def clean_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete()


def setup_units():
    scene = bpy.context.scene
    scene.unit_settings.system = "METRIC"
    scene.unit_settings.scale_length = 0.001
    scene.unit_settings.length_unit = "MILLIMETERS"


def import_stl(path, name):
    bpy.ops.wm.stl_import(filepath=str(path))
    obj = bpy.context.object
    obj.name = name
    return obj


def bounds_world(obj):
    points = [obj.matrix_world @ Vector(corner) for corner in obj.bound_box]
    minimum = Vector(tuple(min(point[i] for point in points) for i in range(3)))
    maximum = Vector(tuple(max(point[i] for point in points) for i in range(3)))
    return minimum, maximum


def center_xy_on(obj, x, y):
    minimum, maximum = bounds_world(obj)
    obj.location.x += x - (minimum.x + maximum.x) / 2.0
    obj.location.y += y - (minimum.y + maximum.y) / 2.0
    bpy.context.view_layer.update()


def place_bottom_on_z(obj, z):
    minimum, _ = bounds_world(obj)
    obj.location.z += z - minimum.z
    bpy.context.view_layer.update()


def remove_garmin_backing_plate(mount):
    place_bottom_on_z(mount, 0.0)
    bpy.context.view_layer.objects.active = mount
    mount.select_set(True)
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.mesh.bisect(
        plane_co=(0, 0, GARMIN_BACKING_THICKNESS_MM),
        plane_no=(0, 0, 1),
        clear_inner=True,
        clear_outer=False,
        use_fill=True,
    )
    bpy.ops.object.mode_set(mode="OBJECT")
    mount.select_set(False)
    bpy.context.view_layer.update()


def union_objects(target, addition):
    modifier = target.modifiers.new(name="GarminMountUnion", type="BOOLEAN")
    modifier.operation = "UNION"
    modifier.solver = "EXACT"
    modifier.object = addition
    bpy.context.view_layer.objects.active = target
    target.select_set(True)
    bpy.ops.object.modifier_apply(modifier=modifier.name)
    target.select_set(False)
    bpy.data.objects.remove(addition, do_unlink=True)


def clean_mesh(obj):
    mesh = obj.data
    bm = bmesh.new()
    bm.from_mesh(mesh)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=0.00001)
    boundary_edges = [edge for edge in bm.edges if edge.is_boundary]
    if boundary_edges:
        bmesh.ops.holes_fill(bm, edges=boundary_edges)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(mesh)
    bm.free()
    mesh.update()
    print(f"Repaired boundary edges: {len(boundary_edges)}")


def export_stl(obj):
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.wm.stl_export(filepath=str(OUTPUT_STL), export_selected_objects=True)


def build():
    clean_scene()
    setup_units()

    case = import_stl(CASE_STL, "waveshare_206_case")
    case_minimum, case_maximum = bounds_world(case)
    case_center_x = (case_minimum.x + case_maximum.x) / 2.0
    case_center_y = (case_minimum.y + case_maximum.y) / 2.0

    mount = import_stl(GARMIN_STL, "garmin_locking_mount")
    bpy.context.view_layer.objects.active = mount
    mount.select_set(True)
    bpy.ops.object.origin_set(type="ORIGIN_GEOMETRY", center="BOUNDS")

    # Rotate the source thickness onto Z. No in-plane rotation is applied: the
    # opposing locking features remain on +/-X, toward the SD and USB sides.
    mount.rotation_euler = (math.radians(-90), 0, 0)
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
    mount.select_set(False)

    remove_garmin_backing_plate(mount)
    center_xy_on(mount, case_center_x, case_center_y)
    place_bottom_on_z(mount, case_maximum.z - GARMIN_CASE_OVERLAP_MM)

    mount_minimum, mount_maximum = bounds_world(mount)
    union_objects(case, mount)
    clean_mesh(case)
    export_stl(case)

    output_minimum, output_maximum = bounds_world(case)
    print(f"Case bounds: {case_maximum - case_minimum}")
    print(f"Trimmed mount bounds: {mount_maximum - mount_minimum}")
    print(f"Output bounds: {output_maximum - output_minimum}")
    print("Garmin locking features face -X (SD) and +X (USB).")
    print(f"Exported: {OUTPUT_STL}")


if __name__ == "__main__":
    build()
