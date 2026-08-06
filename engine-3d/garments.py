"""Garment templates for the Looktok mannequin — shell-from-body method.

A garment = a region of the mannequin surface, duplicated, inflated along the
normals and solidified. Because it's derived FROM the body, it fits any
proportion set automatically — this is the whole trick that makes dressing
free at runtime.

Colors come from REAL library flat-lays (dominant non-white pixel average).

Run:
  blender -b -P garments.py
Outputs: assets/tee.glb, assets/chinos.glb, assets/shorts.glb,
         assets/preview_dressed_{1,2}.png
"""
import math
import os

import bmesh
import bpy
import numpy as np

ROOT = os.path.dirname(os.path.abspath(__file__))
A = lambda *p: os.path.join(ROOT, "assets", *p)
CASES = os.path.join(ROOT, "..", "spike-qwen", "cases")

# slot → (source flat-lay, region predicate over (x, y, z), normal offset)
def tee_region(x, y, z):      # torso + upper arms (short set-in sleeves)
    return 1.06 <= z <= 1.50 and (abs(x) < 0.16 or z > 1.22)

def chinos_region(x, y, z):   # hips → ankles, legs only (arms excluded by |x|)
    return 0.09 <= z <= 1.14 and abs(x) <= 0.18

def shorts_region(x, y, z):   # hips → above the knee
    return 0.60 <= z <= 1.14 and abs(x) <= 0.18

GARMENTS = [
    ("tee",    os.path.join(CASES, "01", "garment.jpg"), tee_region,    0.024),
    ("chinos", os.path.join(CASES, "19", "garment.jpg"), chinos_region, 0.016),
    ("shorts", os.path.join(CASES, "08", "garment.jpg"), shorts_region, 0.018),
]


def dominant_color(path: str) -> tuple:
    """Average of non-background pixels — the garment's read color."""
    img = bpy.data.images.load(path)
    px = np.array(img.pixels[:]).reshape(-1, 4)
    rgb = px[:, :3]
    mask = ~np.all(rgb > 0.92, axis=1)  # drop near-white backdrop
    use = rgb[mask] if mask.any() else rgb
    r, g, b = use.mean(axis=0)
    bpy.data.images.remove(img)
    return float(r), float(g), float(b)


def cloth_material(name: str, rgb: tuple):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*rgb, 1)
    bsdf.inputs["Roughness"].default_value = 0.92
    return mat


def shell(body, name, region, offset, rgb):
    dup = body.copy()
    dup.data = body.data.copy()
    dup.name = name
    bpy.context.collection.objects.link(dup)
    bm = bmesh.new()
    bm.from_mesh(dup.data)
    doomed = [v for v in bm.verts if not region(v.co.x, v.co.y, v.co.z)]
    bmesh.ops.delete(bm, geom=doomed, context="VERTS")
    bm.normal_update()
    for v in bm.verts:
        v.co += v.normal * offset
    bm.to_mesh(dup.data)
    bm.free()
    dup.data.materials.clear()
    dup.data.materials.append(cloth_material(f"{name}_cloth", rgb))
    sol = dup.modifiers.new("solid", "SOLIDIFY")
    sol.thickness = 0.008
    sm = dup.modifiers.new("smooth", "SMOOTH")
    sm.iterations = 4
    bpy.ops.object.select_all(action="DESELECT")
    dup.select_set(True)
    bpy.context.view_layer.objects.active = dup
    bpy.ops.object.modifier_apply(modifier=sol.name)
    bpy.ops.object.modifier_apply(modifier=sm.name)
    bpy.ops.object.shade_smooth()
    return dup


def export_glb(obj, path):
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLB",
                              use_selection=True, export_yup=True)


def studio(scene):
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    scene.collection.objects.link(cam)
    scene.camera = cam
    cam.location = (2.4, -2.4, 1.35)
    cam.rotation_euler = (math.radians(78), 0, math.radians(45))
    sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
    sun.data.energy = 3.2
    sun.rotation_euler = (math.radians(50), 0, math.radians(30))
    scene.collection.objects.link(sun)
    world = bpy.data.worlds.new("w")
    scene.world = world
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs[0].default_value = (0.965, 0.955, 0.94, 1)
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x, scene.render.resolution_y = 700, 1000


def main():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    bpy.ops.import_scene.gltf(filepath=A("mannequin.glb"))
    body = next(o for o in bpy.context.scene.objects if o.type == "MESH")
    body.name = "Body"

    made = {}
    for name, src, region, offset in GARMENTS:
        rgb = dominant_color(src)
        made[name] = shell(body, name, region, offset, rgb)
        print(f"[garment] {name}: color={tuple(round(c, 3) for c in rgb)}")

    for name, obj in made.items():
        export_glb(obj, A(f"{name}.glb"))
        print(f"[garment] exported {name}.glb")

    # Dressed previews: (1) tee + chinos, (2) tee + shorts.
    studio(bpy.context.scene)
    made["shorts"].hide_render = True
    bpy.context.scene.render.filepath = A("preview_dressed_1.png")
    bpy.ops.render.render(write_still=True)
    made["shorts"].hide_render = False
    made["chinos"].hide_render = True
    bpy.context.scene.render.filepath = A("preview_dressed_2.png")
    bpy.ops.render.render(write_still=True)
    print("previews done")


main()
