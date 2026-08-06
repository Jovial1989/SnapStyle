"""Realistic parametric body from the CC0 Blender Studio Human Base Meshes.

Replaces the metaball mannequin ("too cartoonish" — owner) with
GEO-body_male_realistic: professional anatomy, clay-matte material (realistic
FORM without uncanny skin textures). Parametric proportions via smooth z-band
region scaling. Shell garments are rebuilt over THIS body — same method,
fraction-of-height bands.

Run:
  blender -b -P body_real.py -- [--shoulders 1.0 --waist 1.0 --hips 1.0 --tone "#D9C6B0"]
Outputs: assets/body.glb, assets/tee.glb, assets/chinos.glb, assets/shorts.glb,
         assets/preview_real_{1,2}.png
"""
import argparse
import math
import os
import sys

import bmesh
import bpy
from mathutils import Vector
import numpy as np

ROOT = os.path.dirname(os.path.abspath(__file__))
A = lambda *p: os.path.join(ROOT, "assets", *p)
BUNDLE = ("/private/tmp/claude-501/-Users-jvpetrov/e7429e3b-3ded-4eda-a59b-27382a1aed93/"
          "scratchpad/hbm/human-base-meshes-bundle-v1.4.1/human_base_meshes_bundle.blend")
CASES = os.path.join(ROOT, "..", "spike-qwen", "cases")


def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    p = argparse.ArgumentParser()
    p.add_argument("--height_m", type=float, default=0.0)   # absolute target height, 0 = keep
    p.add_argument("--shoulders", type=float, default=1.0)
    p.add_argument("--waist", type=float, default=1.0)
    p.add_argument("--hips", type=float, default=1.0)
    p.add_argument("--tone", default="#D9C6B0")
    # Personal-avatar mode: export ONLY the morphed body to this path and stop.
    # Keeps per-user bakes from overwriting the shared demo assets, and skips
    # the garment shells + preview renders (seconds instead of a minute).
    p.add_argument("--out", default="")
    return p.parse_args(argv)


def band_scale(verts, z0, z1, factor):
    """Scale XY around the center axis inside [z0,z1] with cosine falloff."""
    if abs(factor - 1.0) < 1e-4:
        return
    mid, half = (z0 + z1) / 2, (z1 - z0) / 2
    for v in verts:
        t = abs(v.co.z - mid) / half
        if t < 1.0:
            k = 1 + (factor - 1) * (0.5 + 0.5 * math.cos(math.pi * t))
            v.co.x *= k
            v.co.y *= k


def dominant_color(path):
    img = bpy.data.images.load(path)
    px = np.array(img.pixels[:]).reshape(-1, 4)[:, :3]
    mask = ~np.all(px > 0.92, axis=1)
    r, g, b = (px[mask] if mask.any() else px).mean(axis=0)
    bpy.data.images.remove(img)
    return float(r), float(g), float(b)


TEX = os.path.join(ROOT, "textures")

def cloth_pbr(name, rgb, weave="fabric_pattern_07", scale=14.0, rough=0.9):
    """Real fabric response: the flat-lay colour drives albedo, CC0 weave maps
    (Poly Haven, 2K) drive normal + roughness. Flat colour was what made the
    garments read as plastic — a woven micro-normal is the single biggest
    realism jump on a dressed avatar."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*rgb, 1)
    bsdf.inputs["Roughness"].default_value = rough
    coord = nt.nodes.new("ShaderNodeTexCoord")
    mapping = nt.nodes.new("ShaderNodeMapping")
    mapping.inputs["Scale"].default_value = (scale, scale, scale)
    nt.links.new(coord.outputs["UV"], mapping.inputs["Vector"])
    def tex(suffix, non_color=True):
        path = os.path.join(TEX, f"{weave}_{suffix}_2k.jpg")
        if not os.path.exists(path):
            return None
        n = nt.nodes.new("ShaderNodeTexImage")
        n.image = bpy.data.images.load(path, check_existing=True)
        if non_color:
            n.image.colorspace_settings.name = "Non-Color"
        nt.links.new(mapping.outputs["Vector"], n.inputs["Vector"])
        return n
    nor = tex("nor_gl")
    if nor:
        nm = nt.nodes.new("ShaderNodeNormalMap")
        nm.inputs["Strength"].default_value = 1.6
        nt.links.new(nor.outputs["Color"], nm.inputs["Color"])
        nt.links.new(nm.outputs["Normal"], bsdf.inputs["Normal"])
    rgh = tex("rough")
    if rgh:
        mix = nt.nodes.new("ShaderNodeMixRGB")
        mix.blend_type = "MULTIPLY"
        mix.inputs["Fac"].default_value = 0.85
        mix.inputs["Color2"].default_value = (rough, rough, rough, 1)
        nt.links.new(rgh.outputs["Color"], mix.inputs["Color1"])
        nt.links.new(mix.outputs["Color"], bsdf.inputs["Roughness"])
    return m


def matte(name, rgb, rough=0.9):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*rgb, 1)
    b.inputs["Roughness"].default_value = rough
    return m


def relax_boundary(bm, rounds=6):
    """Smooth the hem: a shell cut from body topology has a saw-tooth border
    (it follows quads, not a garment line). Averaging each boundary vertex with
    its boundary neighbours turns the saw-tooth into a clean sewn edge."""
    border = [v for v in bm.verts if v.is_boundary]
    if not border:
        return
    ring = set(border)
    for _ in range(rounds):
        moves = {}
        for v in border:
            nb = [e.other_vert(v) for e in v.link_edges if e.other_vert(v) in ring]
            if len(nb) >= 2:
                avg = sum((n.co for n in nb), Vector()) / len(nb)
                moves[v] = v.co.lerp(avg, 0.5)
        for v, co in moves.items():
            v.co = co


def taper_offsets(bm, offset, rings=3):
    """Inflate the shell along normals, but FADE the offset to ~0 at the hem so
    the garment tucks into the body instead of floating with a visible rim."""
    border = {v for v in bm.verts if v.is_boundary}
    depth = {v: 0 for v in border}
    frontier = set(border)
    for d in range(1, rings + 1):
        nxt = set()
        for v in frontier:
            for e in v.link_edges:
                o = e.other_vert(v)
                if o not in depth:
                    depth[o] = d
                    nxt.add(o)
        frontier = nxt
    for v in bm.verts:
        d = depth.get(v, rings + 1)
        k = min(1.0, d / (rings + 1)) ** 0.7      # 0 at the hem → 1 inside
        v.co += v.normal * (offset * k)


def shell(body, name, region, offset, rgb, drape=0.0, rough=0.92):
    """Garment = a region of the body surface, inflated and solidified.
    [drape] adds extra offset toward the lower edge so the piece hangs instead
    of clinging (a tee flares at the hem, trousers widen down the leg)."""
    dup = body.copy(); dup.data = body.data.copy(); dup.name = name
    bpy.context.collection.objects.link(dup)
    bm = bmesh.new(); bm.from_mesh(dup.data)
    doomed = [v for v in bm.verts if not region(v.co.x, v.co.y, v.co.z)]
    bmesh.ops.delete(bm, geom=doomed, context="VERTS")
    if not bm.verts:
        bm.free()
        raise RuntimeError(f"{name}: empty region")
    bm.normal_update()
    relax_boundary(bm)
    bm.normal_update()
    if drape:
        zs = [v.co.z for v in bm.verts]
        z0, z1 = min(zs), max(zs)
        span = max(z1 - z0, 1e-6)
        for v in bm.verts:
            t = 1 - (v.co.z - z0) / span         # 1 at the hem, 0 at the top
            v.co += v.normal * (drape * t * t)
    taper_offsets(bm, offset)
    bm.to_mesh(dup.data); bm.free()
    dup.data.materials.clear()
    # Plain material for the GLB: embedding 2K weave maps per garment blew the
    # files up to ~9MB each. The viewer applies ONE shared fabric normal to all
    # garments instead; cloth_pbr below is used only for offline renders.
    dup.data.materials.append(matte(f"{name}_cloth", rgb, rough))
    dup["weave"] = "denim" if name in ("chinos", "shorts") else "knit"
    sol = dup.modifiers.new("solid", "SOLIDIFY"); sol.thickness = 0.008
    sol.offset = 1.0
    sm = dup.modifiers.new("smooth", "SMOOTH"); sm.iterations = 6; sm.factor = 0.6
    bpy.ops.object.select_all(action="DESELECT")
    dup.select_set(True); bpy.context.view_layer.objects.active = dup
    bpy.ops.object.modifier_apply(modifier=sol.name)
    bpy.ops.object.modifier_apply(modifier=sm.name)
    # Own UV layout so the fabric weave tiles across the garment instead of
    # inheriting the body's atlas (which stretched the pattern).
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.smart_project(angle_limit=1.15, island_margin=0.02)
    bpy.ops.object.mode_set(mode="OBJECT")
    bpy.ops.object.shade_smooth()
    return dup


def export_glb(obj, path):
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLB",
                              use_selection=True, export_yup=True)


def main():
    args = parse_args()
    bpy.ops.wm.open_mainfile(filepath=BUNDLE)
    body = bpy.data.objects["GEO-body_male_realistic"]
    # Isolate: unlink everything else.
    for o in list(bpy.data.objects):
        if o is not body:
            bpy.data.objects.remove(o, do_unlink=True)
    scene = bpy.context.scene
    if body.name not in scene.collection.objects:
        scene.collection.objects.link(body)
    body.modifiers.clear()
    bpy.ops.object.select_all(action="DESELECT")
    body.select_set(True); bpy.context.view_layer.objects.active = body
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)

    # Center on origin (the bundle lays bodies out in a row along X) and put
    # feet at z=0.
    xs = [v.co.x for v in body.data.vertices]
    ys = [v.co.y for v in body.data.vertices]
    zs = [v.co.z for v in body.data.vertices]
    cx, cy, zmin = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2, min(zs)
    for v in body.data.vertices:
        v.co.x -= cx
        v.co.y -= cy
        v.co.z -= zmin
    H = max(v.co.z for v in body.data.vertices)
    print(f"[body] height={H:.2f}")

    # Parametric proportions (smooth bands, fractions of height).
    band_scale(body.data.vertices, 0.74 * H, 0.92 * H, args.shoulders)
    band_scale(body.data.vertices, 0.56 * H, 0.70 * H, args.waist)
    band_scale(body.data.vertices, 0.42 * H, 0.58 * H, args.hips)

    # Absolute height: uniform scale to the user's real stature.
    if args.height_m > 0:
        k = args.height_m / H
        for v in body.data.vertices:
            v.co *= k
        H = args.height_m
        print(f"[body] scaled to {H:.2f}m")

    tone = args.tone.lstrip("#")
    rgb = tuple(int(tone[i:i + 2], 16) / 255 for i in (0, 2, 4))
    body.data.materials.clear()
    body.data.materials.append(matte("Skin", rgb, 0.8))
    bpy.ops.object.shade_smooth()

    # ── Garment patterns, as fractions of height (scale-invariant) ─────────
    # A-pose: arms are excluded by |x|; legs spread, so the legwear limit
    # widens toward the ankle. The tee carves a real crew neckline instead of
    # climbing the throat.
    NECK_R = 0.075          # of H — neck hole radius around the body axis
    def tee(x, y, z):
        zf, xf = z / H, abs(x) / H
        if not (0.545 <= zf <= 0.855):
            return False
        if zf > 0.795 and (x * x + y * y) ** 0.5 / H < NECK_R:
            return False    # crew neck opening
        return xf < 0.135 or (zf > 0.72 and xf < 0.185)   # torso + short sleeve
    def leg_limit(zf):
        return 0.13 + max(0.0, (0.30 - zf)) * 0.28
    def chinos(x, y, z):
        zf, xf = z / H, abs(x) / H
        return 0.055 <= zf <= 0.575 and xf <= leg_limit(zf)
    def shorts(x, y, z):
        zf, xf = z / H, abs(x) / H
        return 0.35 <= zf <= 0.575 and xf <= 0.135
    def shoe(x, y, z):
        return z / H <= 0.058          # foot shell → a plain low sneaker
    def sole(x, y, z):
        return z / H <= 0.016          # bottom slab of the same shell

    tee_rgb = dominant_color(os.path.join(CASES, "01", "garment.jpg"))
    chi_rgb = dominant_color(os.path.join(CASES, "19", "garment.jpg"))
    sho_rgb = dominant_color(os.path.join(CASES, "08", "garment.jpg"))
    g_tee = shell(body, "tee", tee, 0.013, tee_rgb, drape=0.010, rough=0.95)
    g_chi = shell(body, "chinos", chinos, 0.010, chi_rgb, drape=0.012, rough=0.88)
    g_sho = shell(body, "shorts", shorts, 0.011, sho_rgb, drape=0.010, rough=0.88)
    # Upper: warm light grey, clearly not skin. Sole: near-white, thicker —
    # the two-tone break is what makes the eye read "sneaker".
    g_shoe = shell(body, "shoes", shoe, 0.014, (0.09, 0.09, 0.10), rough=0.62)
    g_sole = shell(body, "shoe_sole", sole, 0.020, (0.94, 0.93, 0.90), rough=0.35)
    g_sole.parent = g_shoe
    bpy.ops.object.select_all(action="DESELECT")
    g_shoe.select_set(True); g_sole.select_set(True)
    bpy.context.view_layer.objects.active = g_shoe
    bpy.ops.object.join()                     # one mesh, two materials
    export_glb(g_shoe, A("shoes.glb"))

    if args.out:
        export_glb(body, args.out)
        print("[export]", args.out)
        return

    export_glb(body, A("body.glb"))
    for o, n in [(g_tee, "tee"), (g_chi, "chinos"), (g_sho, "shorts")]:
        export_glb(o, A(f"{n}.glb"))
        print("[export]", n)
    # Swap in the full PBR fabric ONLY AFTER every export: embedding 2K weave
    # maps per garment blew the GLBs from ~200KB to ~9MB. Shipped meshes stay
    # light (the viewer applies one shared weave); offline previews get the
    # full material.
    for o in (g_tee, g_chi, g_sho, g_shoe):
        weave = "denim_fabric_04" if o.name in ("chinos", "shorts") else "fabric_pattern_07"
        base = tuple(o.data.materials[0].node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value)[:3]
        o.data.materials.clear()
        o.data.materials.append(cloth_pbr(f"{o.name}_pbr", base, weave))

    # Previews.
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    scene.collection.objects.link(cam); scene.camera = cam
    cam.location = (2.3, -2.3, 1.3)
    cam.rotation_euler = (math.radians(78), 0, math.radians(45))
    sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
    sun.data.energy = 3.2
    sun.rotation_euler = (math.radians(50), 0, math.radians(30))
    scene.collection.objects.link(sun)
    world = bpy.data.worlds.new("w"); scene.world = world
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs[0].default_value = (0.965, 0.955, 0.94, 1)
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x, scene.render.resolution_y = 700, 1000
    g_sho.hide_render = True
    scene.render.filepath = A("preview_real_1.png")
    bpy.ops.render.render(write_still=True)
    g_sho.hide_render = False; g_chi.hide_render = True
    scene.render.filepath = A("preview_real_2.png")
    bpy.ops.render.render(write_still=True)
    print("done")


main()
