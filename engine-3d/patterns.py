"""Lofted garment patterns + simulated drape — the Marvelous-free path.

The shell method (cut a region off the body, inflate) hit its ceiling: hems
follow body quads so they read ragged, and the piece clings like compression
wear. Here a garment is built the way a pattern is: measure the body's
cross-section at each height, lay a clean ring of N points around it with ease,
loft the rings into a tube, then let Blender's cloth solver drape it against
the body so it hangs with real folds.

Run:
  blender -b -P patterns.py -- [--height_m 1.80 --shoulders 1.09 ...]
Outputs: assets/tee.glb, assets/chinos.glb, assets/shorts.glb (+ previews)
"""
import argparse
import math
import os
import sys

import bmesh
import bpy
import numpy as np
from mathutils import Vector

ROOT = os.path.dirname(os.path.abspath(__file__))
A = lambda *p: os.path.join(ROOT, "assets", *p)
CASES = os.path.join(ROOT, "..", "spike-qwen", "cases")
RING = 32          # points per ring — clean quads, cheap on mobile
SIM_FRAMES = 60    # enough for the cloth to settle into folds


def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    p = argparse.ArgumentParser()
    p.add_argument("--body", default=A("body.glb"))
    p.add_argument("--sim", type=int, default=1)   # 0 = skip cloth (fast iterate)
    return p.parse_args(argv)


def dominant_color(path):
    img = bpy.data.images.load(path)
    px = np.array(img.pixels[:]).reshape(-1, 4)[:, :3]
    mask = ~np.all(px > 0.92, axis=1)
    r, g, b = (px[mask] if mask.any() else px).mean(axis=0)
    bpy.data.images.remove(img)
    return float(r), float(g), float(b)


def cloth_material(name, rgb, rough=0.9):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*rgb, 1)
    b.inputs["Roughness"].default_value = rough
    return m


def section(verts, z, band, x_center=0.0, x_window=None):
    """Polar profile of the body part at height [z]: for each of RING
    directions, the farthest vertex inside the z-band AND inside an x-window
    around [x_center]. The window is what makes this a MEASUREMENT of one part:
    without it the chest section swallows both arms (→ a boxy tunic) and a
    thigh section swallows the pelvis (→ a flared cone)."""
    lo, hi = z - band, z + band
    radii = [0.0] * RING
    cx, cy, n = 0.0, 0.0, 0
    picked = []
    for v in verts:
        if not (lo <= v.z <= hi):
            continue
        if x_window is not None and abs(v.x - x_center) > x_window:
            continue
        picked.append(v)
        cx += v.x
        cy += v.y
        n += 1
    if n < 8:
        return None
    cx, cy = cx / n, cy / n
    for v in picked:
        ang = math.atan2(v.y - cy, v.x - cx) % (2 * math.pi)
        i = int(ang / (2 * math.pi) * RING) % RING
        r = math.hypot(v.x - cx, v.y - cy)
        if r > radii[i]:
            radii[i] = r
    # Fill gaps + smooth: a garment ring is continuous, the point cloud isn't.
    for _ in range(3):
        for i in range(RING):
            a, b = radii[(i - 1) % RING], radii[(i + 1) % RING]
            if radii[i] <= 0:
                radii[i] = (a + b) / 2 or max(radii)
            else:
                radii[i] = radii[i] * 0.6 + (a + b) * 0.2
    return (cx, cy), radii


def section_x(verts, x, band, z_center, z_window):
    """Same measurement, but slabs perpendicular to X — used for sleeves,
    where the limb runs outward rather than upward."""
    lo, hi = x - band, x + band
    radii = [0.0] * RING
    cy, cz, n = 0.0, 0.0, 0
    picked = []
    for v in verts:
        if not (lo <= v.x <= hi):
            continue
        if abs(v.z - z_center) > z_window:
            continue
        picked.append(v); cy += v.y; cz += v.z; n += 1
    if n < 8:
        return None
    cy, cz = cy / n, cz / n
    for v in picked:
        ang = math.atan2(v.z - cz, v.y - cy) % (2 * math.pi)
        i = int(ang / (2 * math.pi) * RING) % RING
        r = math.hypot(v.y - cy, v.z - cz)
        if r > radii[i]:
            radii[i] = r
    for _ in range(3):
        for i in range(RING):
            a, b = radii[(i - 1) % RING], radii[(i + 1) % RING]
            radii[i] = (a + b) / 2 if radii[i] <= 0 else radii[i] * 0.6 + (a + b) * 0.2
    return (cy, cz), radii


def build_sleeve(name, specs, rgb, rough=0.9):
    """specs: [(x, band, ease, z_center, z_window)] — inner→outer."""
    body = bpy.data.objects["Body"]
    verts = [body.matrix_world @ v.co for v in body.data.vertices]
    me = bpy.data.meshes.new(name)
    obj = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(obj)
    bm = bmesh.new()
    grid = []
    for x, band, ease, zc, zw in specs:
        sec = section_x(verts, x, band, zc, zw)
        if sec is None:
            continue
        (cy, cz), radii = sec
        row = []
        for i in range(RING):
            ang = 2 * math.pi * i / RING
            r = radii[i] + ease
            row.append(bm.verts.new((x, cy + r * math.cos(ang), cz + r * math.sin(ang))))
        grid.append(row)
    if len(grid) < 2:
        bm.free()
        raise RuntimeError(f"{name}: no sleeve sections")
    bm.verts.ensure_lookup_table()
    for a, b in zip(grid, grid[1:]):
        for i in range(RING):
            j = (i + 1) % RING
            bm.faces.new((a[i], a[j], b[j], b[i]))
    bm.to_mesh(me); bm.free()
    obj.data.materials.append(cloth_material(f"{name}_cloth", rgb, rough))
    return obj


def loft(bm, rings, close_top=False, close_bottom=False):
    """Bridge consecutive rings into quads — clean, predictable topology."""
    grid = []
    for (cx, cy), z, radii, ease in rings:
        row = []
        for i in range(RING):
            ang = 2 * math.pi * i / RING
            r = radii[i] + ease
            row.append(bm.verts.new((cx + r * math.cos(ang), cy + r * math.sin(ang), z)))
        grid.append(row)
    bm.verts.ensure_lookup_table()
    for a, b in zip(grid, grid[1:]):
        for i in range(RING):
            j = (i + 1) % RING
            bm.faces.new((a[i], a[j], b[j], b[i]))
    if close_bottom:
        bm.faces.new(grid[0][::-1])
    if close_top:
        bm.faces.new(grid[-1])
    return grid


def build(name, ring_specs, rgb, rough=0.9, pin_rows=1):
    """ring_specs: [(z, band, ease, x_center, x_window)] bottom→top."""
    body = bpy.data.objects["Body"]
    verts = [body.matrix_world @ v.co for v in body.data.vertices]
    rings = []
    for z, band, ease, xc, xw in ring_specs:
        s = section(verts, z, band, x_center=xc, x_window=xw)
        if s is None:
            continue
        (cx, cy), radii = s
        rings.append(((cx, cy), z, radii, ease))
    if len(rings) < 2:
        raise RuntimeError(f"{name}: not enough sections")
    me = bpy.data.meshes.new(name)
    obj = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(obj)
    bm = bmesh.new()
    loft(bm, rings)
    bm.to_mesh(me)
    bm.free()
    # Pin group: the top rows hold the garment up (collar/waistband) while
    # gravity and body collision shape everything below into folds. Vertices
    # were created ring-by-ring, so the top rows are simply the last indices
    # (bmesh references die with bm.free(), so index arithmetic it is).
    vg = obj.vertex_groups.new(name="pin")
    first = (len(rings) - pin_rows) * RING
    vg.add(list(range(first, len(rings) * RING)), 1.0, "REPLACE")
    obj.data.materials.append(cloth_material(f"{name}_cloth", rgb, rough))
    return obj


def simulate(obj, frames=SIM_FRAMES):
    """Drape the tube on the body: cloth + collision, then bake to mesh."""
    body = bpy.data.objects["Body"]
    if "collide" not in body.modifiers:
        col = body.modifiers.new("collide", "COLLISION")
        body.collision.thickness_outer = 0.008
    cl = obj.modifiers.new("cloth", "CLOTH")
    cs = cl.settings
    cs.quality = 12
    cs.mass = 0.3
    cs.tension_stiffness = 18
    cs.compression_stiffness = 18
    cs.shear_stiffness = 18
    # The single most important dial: 0.18 crumpled every panel into wet
    # gauze. Woven cotton at avatar scale needs real bending resistance.
    cs.bending_stiffness = 4.0
    cs.air_damping = 2.0
    cs.vertex_group_mass = "pin"
    cl.collision_settings.distance_min = 0.010
    cl.collision_settings.use_self_collision = False
    scene = bpy.context.scene
    scene.frame_start, scene.frame_end = 1, frames
    for f in range(1, frames + 1):
        scene.frame_set(f)
    # Bake the deformed state.
    dg = bpy.context.evaluated_depsgraph_get()
    baked = bpy.data.meshes.new_from_object(obj.evaluated_get(dg))
    obj.modifiers.clear()
    obj.data = baked
    scene.frame_set(1)


def finish(obj, thickness=0.009):
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.mesh.remove_doubles(threshold=0.010)   # heal sim-torn seams + weld sleeve↔torso junctions
    bpy.ops.object.mode_set(mode="OBJECT")
    sol = obj.modifiers.new("solid", "SOLIDIFY")
    sol.thickness = thickness
    sol.offset = 1.0            # grow OUTWARD only — inward growth z-fights the skin
    sm = obj.modifiers.new("smooth", "SMOOTH")
    sm.factor = 0.35
    sm.iterations = 6
    bpy.ops.object.modifier_apply(modifier=sol.name)
    bpy.ops.object.modifier_apply(modifier=sm.name)
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.smart_project(angle_limit=1.15, island_margin=0.02)
    bpy.ops.object.mode_set(mode="OBJECT")
    bpy.ops.object.shade_smooth()


def export_glb(obj, path):
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLB",
                              use_selection=True, export_yup=True)
    print("[export]", os.path.basename(path))


def main():
    args = parse_args()
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    bpy.ops.import_scene.gltf(filepath=args.body)
    body = next(o for o in bpy.context.scene.objects if o.type == "MESH")
    body.name = "Body"
    H = max((body.matrix_world @ v.co).z for v in body.data.vertices)
    print(f"[patterns] body height {H:.2f}")

    f = lambda k: k * H          # height fractions → metres
    EASE_T, EASE_B = 0.021, 0.017
    TORSO_W = 0.155 * H          # x-window that isolates the torso from arms
    LEG_X, LEG_W = 0.052 * H, 0.075 * H   # per-leg centre + window

    # TEE: hem → chest → shoulder seam, measured on the torso only.
    tee = build("tee", [
        # Hem sits BELOW the trouser waistband (0.555H) — the previous 0.545H
        # left a bare midriff once the cloth settled.
        (f(0.505), f(0.02), EASE_T + 0.018, 0.0, TORSO_W),   # hem hangs loose
        (f(0.56),  f(0.02), EASE_T + 0.014, 0.0, TORSO_W),
        (f(0.62),  f(0.02), EASE_T + 0.010, 0.0, TORSO_W),
        (f(0.67),  f(0.02), EASE_T + 0.007, 0.0, TORSO_W),
        (f(0.72),  f(0.02), EASE_T + 0.005, 0.0, TORSO_W),
        (f(0.775), f(0.02), EASE_T + 0.002, 0.0, TORSO_W),
        (f(0.815), f(0.015), EASE_T - 0.004, 0.0, TORSO_W),  # shoulder yoke
        (f(0.855), f(0.012), EASE_T - 0.006, 0.0, 0.062 * H),  # crew collar, pinned
    ], dominant_color(os.path.join(CASES, "01", "garment.jpg")), rough=0.95, pin_rows=1)

    # SHORT SLEEVES: two stubs measured across the upper arm, from the armhole
    # outward. In A-pose the arm runs down-and-out, so the slab centre drops as
    # it goes wider.
    tee_rgb = dominant_color(os.path.join(CASES, "01", "garment.jpg"))
    sleeves = []
    for sign, tag in ((-1, "sleeve_l"), (1, "sleeve_r")):
        try:
            sleeves.append(build_sleeve(tag, [
                (sign * 0.075 * H, 0.012 * H, EASE_T + 0.002, 0.800 * H, 0.080 * H),  # inside the torso tube
                (sign * 0.110 * H, 0.012 * H, EASE_T + 0.004, 0.790 * H, 0.075 * H),  # armhole
                (sign * 0.145 * H, 0.012 * H, EASE_T + 0.006, 0.772 * H, 0.070 * H),
                (sign * 0.178 * H, 0.012 * H, EASE_T + 0.009, 0.752 * H, 0.065 * H),  # cuff
            ], tee_rgb, rough=0.95))
        except Exception as e:
            print("[sleeve] skipped", tag, e)

    # CHINOS: each leg drafted around its own axis, then a hip tube on top.
    legs = []
    for sign, tag in ((-1, "chinos_l"), (1, "chinos_r")):
        legs.append(build(tag, [
            (f(0.075), f(0.02), EASE_B + 0.012, sign * LEG_X, LEG_W),  # break
            (f(0.20),  f(0.02), EASE_B + 0.006, sign * LEG_X, LEG_W),
            (f(0.34),  f(0.02), EASE_B + 0.003, sign * LEG_X, LEG_W),
            (f(0.45),  f(0.02), EASE_B - 0.005, sign * LEG_X * 1.1, LEG_W * 1.1),
            (f(0.465), f(0.02), EASE_B - 0.005, sign * LEG_X * 1.12, LEG_W * 1.12),  # tucked INSIDE the hip tube
        ], dominant_color(os.path.join(CASES, "19", "garment.jpg")), rough=0.88, pin_rows=1))
    hip = build("chinos_hip", [
        (f(0.36),  f(0.02), EASE_B + 0.012, 0.0, TORSO_W),   # flare over the leg tops
        (f(0.42),  f(0.02), EASE_B + 0.009, 0.0, TORSO_W),
        (f(0.47),  f(0.02), EASE_B + 0.006, 0.0, TORSO_W),
        (f(0.51),  f(0.02), EASE_B + 0.002, 0.0, TORSO_W),
        (f(0.555), f(0.015), EASE_B - 0.004, 0.0, TORSO_W),   # waistband, pinned
    ], dominant_color(os.path.join(CASES, "19", "garment.jpg")), rough=0.88, pin_rows=1)

    if args.sim:
        for o in (tee, *legs):
            try:
                simulate(o)
                print("[sim]", o.name)
            except Exception as e:      # a failed solve must not kill the build
                print("[sim] skipped", o.name, e)

    for o in (tee, *sleeves, *legs, hip):
        finish(o)

    # Tee ships as body + both sleeves in one object.
    bpy.ops.object.select_all(action="DESELECT")
    for o in (tee, *sleeves):
        o.select_set(True)
    bpy.context.view_layer.objects.active = tee
    if sleeves:
        bpy.ops.object.join()
    export_glb(tee, A("tee.glb"))
    # Join the trouser parts into one shippable object.
    bpy.ops.object.select_all(action="DESELECT")
    for o in (hip, *legs):
        o.select_set(True)
    bpy.context.view_layer.objects.active = hip
    bpy.ops.object.join()
    hip.name = "chinos"
    export_glb(hip, A("chinos.glb"))

    # Preview.
    scene = bpy.context.scene
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    scene.collection.objects.link(cam); scene.camera = cam
    cam.data.lens = 55
    cam.location = (0, -3.6, H * 0.55)
    cam.rotation_euler = (math.radians(90), 0, 0)
    sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
    sun.data.energy = 3.0
    sun.rotation_euler = (math.radians(52), 0, math.radians(28))
    scene.collection.objects.link(sun)
    w = bpy.data.worlds.new("w"); scene.world = w; w.use_nodes = True
    w.node_tree.nodes["Background"].inputs[0].default_value = (0.96, 0.95, 0.93, 1)
    scene.render.engine = "BLENDER_EEVEE"
    scene.view_settings.view_transform = "Filmic"
    scene.render.resolution_x, scene.render.resolution_y = 700, 1000
    scene.render.filepath = A("preview_patterns.png")
    bpy.ops.render.render(write_still=True)
    print("done")


main()
