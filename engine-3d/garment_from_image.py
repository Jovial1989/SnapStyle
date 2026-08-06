"""Flat-lay → 3D garment. Upload a photo of a piece, get it on the avatar.

Two things are read from the image and nothing is hand-modelled:

  SILHOUETTE  → the pattern. Where the sleeves end, how long the hem is, how
                wide the shoulders sit, how deep the neckline cuts. These drive
                the ring heights/ease of the drafter (patterns.py), so the 3D
                piece has the same PROPORTIONS as the real garment.
  PIXELS      → the surface. The photo is planar-projected onto the front of
                the mesh (and mirrored to the back), so prints, plaids, seams
                and shading come along for free. This is where the realism
                actually lives — the RenderPeople scans look real because of
                their texture, not their topology.

Run:
  blender -b -P garment_from_image.py -- --image path/to/flatlay.jpg \
      --slot top --out assets/item.glb
"""
import argparse
import json
import math
import os
import sys

import bmesh
import bpy
import numpy as np

ROOT = os.path.dirname(os.path.abspath(__file__))
A = lambda *p: os.path.join(ROOT, "assets", *p)
RING = 32


def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    p = argparse.ArgumentParser()
    p.add_argument("--image", required=True)
    p.add_argument("--slot", default="top", choices=["top", "bottom"])
    p.add_argument("--out", default=A("item.glb"))
    p.add_argument("--body", default=A("body.glb"))
    p.add_argument("--sim", type=int, default=1)
    p.add_argument("--preview", default=A("preview_item.png"))
    return p.parse_args(argv)


# ── 1. Read the garment's shape out of the photo ──────────────────────────────
def analyze(path: str) -> dict:
    """Silhouette measurements, all as fractions of the garment's own bbox."""
    img = bpy.data.images.load(path)
    w, h = img.size
    px = np.array(img.pixels[:], dtype=np.float32).reshape(h, w, 4)[..., :3]
    px = px[::-1]                                    # Blender rows are bottom-up
    mx, mn = px.max(axis=2), px.min(axis=2)
    solid = ~((mn > 0.90) & ((mx - mn) < 0.10))      # not the near-white backdrop
    bpy.data.images.remove(img)
    ys, xs = np.nonzero(solid)
    if len(ys) < 50:
        raise RuntimeError("no garment found in the image")
    y0, y1, x0, x1 = ys.min(), ys.max(), xs.min(), xs.max()
    box = solid[y0:y1 + 1, x0:x1 + 1]
    bh, bw = box.shape
    rows = box.sum(axis=1) / bw                      # filled fraction per row
    widest = float(rows.max())

    def row_span(fr):
        r = box[min(int(fr * (bh - 1)), bh - 1)]
        nz = np.nonzero(r)[0]
        return (0.0, 0.0) if not len(nz) else (nz.min() / bw, nz.max() / bw)

    # Sleeves: the shoulder band is much wider than the waist band on a top.
    top_w = float(rows[: max(1, bh // 4)].max())
    mid_w = float(np.median(rows[bh // 2: 3 * bh // 4]))
    sleeve_ratio = top_w / max(mid_w, 1e-3)
    # Where the wide part ends = the cuff line (fraction from the top).
    wide = np.nonzero(rows > (mid_w + (top_w - mid_w) * 0.55))[0]
    sleeve_end = float(wide.max() / bh) if len(wide) else 0.0
    # Neckline depth: how far the empty notch reaches down the top edge.
    notch = 0.0
    for i in range(bh // 3):
        r = box[i]
        nz = np.nonzero(r)[0]
        if len(nz) > 2:
            gaps = np.diff(nz)
            if gaps.max() > bw * 0.12:               # a hole in the middle = collar
                notch = (i + 1) / bh
    # Per-row span of the piece (64 samples, fractions of the bbox width): the
    # UV lookup uses these so a tube NEVER samples the white backdrop beside a
    # narrow part (that was the white shoulder/leg panels).
    spans = []
    for k in range(64):
        r = box[min(int(k / 63 * (bh - 1)), bh - 1)]
        nz = np.nonzero(r)[0]
        spans.append((float(nz.min() / bw), float(nz.max() / bw)) if len(nz) else (0.45, 0.55))
    # First/last rows with real content: sampling is clamped inside them so a
    # sparse top row (hanger gap, shadow) can never paint backdrop onto the
    # waistband or hem.
    filled = np.nonzero(rows > 0.25)[0]
    row_lo = float(filled.min() / max(bh - 1, 1)) if len(filled) else 0.0
    row_hi = float(filled.max() / max(bh - 1, 1)) if len(filled) else 1.0
    a = {
        "spans": spans,
        "row_solid": (row_lo, row_hi),
        "aspect": bh / bw,
        "widest": widest,
        "sleeve_ratio": round(sleeve_ratio, 3),
        "sleeve_end": round(sleeve_end, 3),
        "neck_depth": round(notch, 3),
        "hem_w": round(row_span(0.97)[1] - row_span(0.97)[0], 3),
        "chest_w": round(row_span(0.45)[1] - row_span(0.45)[0], 3),
        "bbox": [int(x0), int(y0), int(x1), int(y1), int(w), int(h)],
    }
    a["has_sleeves"] = a["sleeve_ratio"] > 1.25
    # Long sleeve reaches far down the garment; short sleeve stops high.
    a["sleeve_len"] = ("long" if a["sleeve_end"] > 0.55 else
                       "short" if a["has_sleeves"] else "none")
    return a


# ── 2. Draft the pattern from those measurements ──────────────────────────────
def section(verts, z, band, x_center=0.0, x_window=None):
    lo, hi = z - band, z + band
    radii = [0.0] * RING
    cx = cy = 0.0
    picked = []
    for v in verts:
        if not (lo <= v.z <= hi):
            continue
        if x_window is not None and abs(v.x - x_center) > x_window:
            continue
        picked.append(v); cx += v.x; cy += v.y
    if len(picked) < 8:
        return None
    cx /= len(picked); cy /= len(picked)
    for v in picked:
        ang = math.atan2(v.y - cy, v.x - cx) % (2 * math.pi)
        i = int(ang / (2 * math.pi) * RING) % RING
        radii[i] = max(radii[i], math.hypot(v.x - cx, v.y - cy))
    for _ in range(3):
        for i in range(RING):
            p, n = radii[(i - 1) % RING], radii[(i + 1) % RING]
            radii[i] = (p + n) / 2 if radii[i] <= 0 else radii[i] * 0.6 + (p + n) * 0.2
    return (cx, cy), radii


def tube(name, rings, pin_rows=1):
    me = bpy.data.meshes.new(name)
    obj = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(obj)
    bm = bmesh.new()
    grid = []
    for (cx, cy), z, radii, ease in rings:
        row = [bm.verts.new((cx + (radii[i] + ease) * math.cos(2 * math.pi * i / RING),
                             cy + (radii[i] + ease) * math.sin(2 * math.pi * i / RING), z))
               for i in range(RING)]
        grid.append(row)
    bm.verts.ensure_lookup_table()
    for a, b in zip(grid, grid[1:]):
        for i in range(RING):
            j = (i + 1) % RING
            bm.faces.new((a[i], a[j], b[j], b[i]))
    bm.to_mesh(me); bm.free()
    vg = obj.vertex_groups.new(name="pin")
    first = (len(rings) - pin_rows) * RING
    vg.add(list(range(first, len(rings) * RING)), 1.0, "REPLACE")
    return obj


def draft(body, a, slot):
    """Ring plan driven by the photo's measurements."""
    verts = [body.matrix_world @ v.co for v in body.data.vertices]
    H = max(v.z for v in verts)
    f = lambda k: k * H
    TORSO_W, EASE = 0.155 * H, 0.026
    rings = []
    if slot == "top":
        # A longer garment in the photo (tall bbox) hangs lower on the body.
        hem = 0.545 - min(0.09, max(0.0, (a["aspect"] - 1.15) * 0.10))
        collar = min(0.828, 0.836 - a["neck_depth"] * 0.06)
        plan = [(hem, EASE + 0.018), (hem + 0.055, EASE + 0.014),
                (0.62, EASE + 0.010), (0.67, EASE + 0.007), (0.72, EASE + 0.005),
                (0.775, EASE + 0.002), (0.815, EASE - 0.004)]
        for zf, ease in plan:
            s = section(verts, f(zf), f(0.02), 0.0, TORSO_W)
            if s:
                rings.append((s[0], f(zf), s[1], ease))
        s = section(verts, f(collar), f(0.012), 0.0, 0.062 * H)
        if s:
            rings.append((s[0], f(collar), s[1], EASE - 0.006))
    else:
        LEG_X, LEG_W = 0.052 * H, 0.075 * H
        # Photo aspect decides shorts vs full length.
        ankle = 0.075 if a["aspect"] > 1.05 else 0.36
        # Legs reach high INTO the hip tube (0.54) — the old 0.50 top left a
        # sliver of bare body at the seam, visible in profile.
        plan = [(ankle, EASE + 0.014), (ankle + 0.13, EASE + 0.008),
                (0.40, EASE + 0.005), (0.50, EASE + 0.002), (0.54, EASE)]
        for sign in (-1, 1):
            r = []
            for zf, ease in plan:
                if zf > 0.56:
                    continue
                s = section(verts, f(zf), f(0.02), sign * LEG_X, LEG_W)
                if s:
                    r.append((s[0], f(zf), s[1], ease))
            if len(r) >= 2:
                rings.append(("LEG", r))
        hipr = []
        for zf, ease in [(0.36, EASE + 0.010), (0.42, EASE + 0.007),
                         (0.475, EASE + 0.004), (0.555, EASE - 0.002)]:
            s = section(verts, f(zf), f(0.02), 0.0, TORSO_W)
            if s:
                hipr.append((s[0], f(zf), s[1], ease))
        rings.append(("HIP", hipr))
    return rings, H


# ── 3. Wear the photo: planar-project the flat-lay onto the mesh ──────────────
def project_texture(obj, image_path, a, bounds, u_sub=(0.0, 1.0)):
    """Folded cylindrical wrap, clamped to the garment's real width per row.

    A flat-lay's left/right edges at a given height ARE that part's side seams,
    so the fold maps: tube front → row centre, tube sides → row edges, back →
    mirrored front. Sampling is clamped to the row's span, so a narrow part
    (collar, a single trouser leg) can never pick up the white backdrop —
    which is exactly what produced the white panels in profile.
    [u_sub] narrows the lookup to a slice of the row (each trouser leg takes
    its own half of the photo).
    """
    me = obj.data
    verts = me.vertices
    x0, x1, z0, z1, cx, cy = bounds
    dz = max(z1 - z0, 1e-6)
    bx0, by0, bx1, by1, iw, ih = a["bbox"]
    bw_px = max(bx1 - bx0, 1)
    spans = a["spans"]
    front = -math.pi / 2                        # the avatar faces -Y

    uvs = me.uv_layers.new(name="flatlay") if not me.uv_layers else me.uv_layers.active
    for loop in me.loops:
        co = verts[loop.vertex_index].co
        fz = min(max((co.z - z0) / dz, 0.0), 1.0)
        # Remap so garment top/bottom hit the first/last SOLID photo rows.
        r_lo, r_hi = a.get("row_solid", (0.0, 1.0))
        frow = r_lo + (1.0 - fz) * (r_hi - r_lo)
        lo, hi = spans[min(63, int(frow * 63))]  # photo rows run top-down
        lo, hi = lo + (hi - lo) * u_sub[0], lo + (hi - lo) * u_sub[1]
        phi = ((math.atan2(co.y - cy, co.x - cx) - front) / (2 * math.pi)) % 1.0
        if phi <= 0.25:
            t = 0.5 + 2 * phi                    # front → one seam
        elif phi <= 0.75:
            t = 1.5 - 2 * phi                    # back, mirrored
        else:
            t = 2 * phi - 1.5                    # other seam → front
        u_frac = lo + t * (hi - lo)              # inside the garment, always
        u = (bx0 + u_frac * bw_px) / iw
        v = 1.0 - (by0 + frow * (by1 - by0)) / ih
        uvs.data[loop.index].uv = (u, v)

    mat = bpy.data.materials.new(f"{obj.name}_mat")
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    bsdf.inputs["Roughness"].default_value = 0.9
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = bpy.data.images.load(image_path, check_existing=True)
    tex.extension = "EXTEND"
    nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    me.materials.clear()
    me.materials.append(mat)


def simulate(obj, body, frames=50):
    if "collide" not in body.modifiers:
        body.modifiers.new("collide", "COLLISION")
        body.collision.thickness_outer = 0.008
    cl = obj.modifiers.new("cloth", "CLOTH")
    cs = cl.settings
    cs.quality = 6; cs.mass = 0.25
    cs.tension_stiffness = 7; cs.compression_stiffness = 7
    cs.shear_stiffness = 8; cs.bending_stiffness = 0.18
    cs.vertex_group_mass = "pin"
    cl.collision_settings.distance_min = 0.008
    scene = bpy.context.scene
    scene.frame_start, scene.frame_end = 1, frames
    for fr in range(1, frames + 1):
        scene.frame_set(fr)
    dg = bpy.context.evaluated_depsgraph_get()
    baked = bpy.data.meshes.new_from_object(obj.evaluated_get(dg))
    obj.modifiers.clear()
    obj.data = baked
    scene.frame_set(1)


def solidify(obj, thickness=0.009):
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True); bpy.context.view_layer.objects.active = obj
    sol = obj.modifiers.new("solid", "SOLIDIFY"); sol.thickness = thickness
    sm = obj.modifiers.new("smooth", "SMOOTH"); sm.iterations = 2
    bpy.ops.object.modifier_apply(modifier=sol.name)
    bpy.ops.object.modifier_apply(modifier=sm.name)
    bpy.ops.object.shade_smooth()


def main():
    args = parse_args()
    bpy.ops.object.select_all(action="SELECT"); bpy.ops.object.delete(use_global=False)
    bpy.ops.import_scene.gltf(filepath=args.body)
    body = next(o for o in bpy.context.scene.objects if o.type == "MESH")
    body.name = "Body"

    a = analyze(args.image)
    print("[analyze]", json.dumps(a))

    rings, H = draft(body, a, args.slot)
    parts = []
    if args.slot == "top":
        parts.append(tube("garment", rings))
    else:
        for tag, r in rings:
            parts.append(tube(f"garment_{tag.lower()}{len(parts)}", r))

    for o in parts:
        if args.sim:
            try:
                simulate(o, body)
            except Exception as e:
                print("[sim] skipped", o.name, e)
        solidify(o)
    # One shared projection frame across every part of the piece.
    allx = [v.co.x for o in parts for v in o.data.vertices]
    ally = [v.co.y for o in parts for v in o.data.vertices]
    allz = [v.co.z for o in parts for v in o.data.vertices]
    # Each part wraps around ITS OWN vertical axis (a trouser leg is its own
    # tube), but shares the photo's vertical range so the waistband lands once.
    zb = (min(allz), max(allz))
    for o in parts:
        pxs = [v.co.x for v in o.data.vertices]
        pys = [v.co.y for v in o.data.vertices]
        mid = sum(pxs) / len(pxs)
        # A leg tube reads its own half of the flat-lay (left piece ← left half).
        sub = (0.0, 1.0)
        if len(parts) > 1 and abs(mid) > 0.02:
            sub = (0.0, 0.5) if mid < 0 else (0.5, 1.0)
        project_texture(o, args.image, a,
                        (min(pxs), max(pxs), zb[0], zb[1], mid, sum(pys) / len(pys)), sub)

    if len(parts) > 1:
        bpy.ops.object.select_all(action="DESELECT")
        for o in parts:
            o.select_set(True)
        bpy.context.view_layer.objects.active = parts[0]
        bpy.ops.object.join()
    item = parts[0]
    bpy.ops.object.select_all(action="DESELECT"); item.select_set(True)
    bpy.ops.export_scene.gltf(filepath=args.out, export_format="GLB",
                              use_selection=True, export_yup=True)
    print("[export]", args.out)

    scene = bpy.context.scene
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    scene.collection.objects.link(cam); scene.camera = cam
    cam.data.lens = 55
    cam.location = (0, -3.6, H * 0.55); cam.rotation_euler = (math.radians(90), 0, 0)
    sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
    sun.data.energy = 3.0; sun.rotation_euler = (math.radians(52), 0, math.radians(28))
    scene.collection.objects.link(sun)
    w = bpy.data.worlds.new("w"); scene.world = w; w.use_nodes = True
    w.node_tree.nodes["Background"].inputs[0].default_value = (0.96, 0.95, 0.93, 1)
    scene.render.engine = "BLENDER_EEVEE"
    scene.view_settings.view_transform = "Filmic"
    scene.render.resolution_x, scene.render.resolution_y = 700, 1000
    scene.render.filepath = args.preview
    bpy.ops.render.render(write_still=True)
    print("done")


main()
