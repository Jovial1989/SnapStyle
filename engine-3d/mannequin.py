"""Parametric atelier mannequin — the Looktok 3D avatar body.

Design register: a tailor's dress form, not a human (no face, no uncanny
valley — the fashion-native language the brand already speaks: hanger,
atelier, STYLING). Proportions morph from user parameters; skin is a single
matte tone.

Run headless:
  blender -b -P mannequin.py -- --out assets/mannequin.glb \
      --height 1.0 --shoulders 1.0 --waist 1.0 --hips 1.0

The body is built from metaball-fused primitives → remesh → smooth, so any
proportion set produces one watertight, clean mesh. Units: meters-ish; the
figure is normalized to ~1.75 tall at height=1.0.
"""
import argparse
import math
import sys

import bpy


def parse_args() -> argparse.Namespace:
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    p = argparse.ArgumentParser()
    p.add_argument("--out", default="assets/mannequin.glb")
    p.add_argument("--height", type=float, default=1.0)     # overall scale
    p.add_argument("--shoulders", type=float, default=1.0)  # shoulder width ×
    p.add_argument("--waist", type=float, default=1.0)      # waist girth ×
    p.add_argument("--hips", type=float, default=1.0)       # hip girth ×
    p.add_argument("--tone", default="#D9C6B0")             # skin tone hex
    return p.parse_args(argv)


def clear_scene() -> None:
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for mb in list(bpy.data.metaballs):
        bpy.data.metaballs.remove(mb)


def add_ball(mb, co, radius, scale=(1, 1, 1)) -> None:
    el = mb.elements.new(type="ELLIPSOID")
    el.co = co
    el.radius = radius
    el.size_x, el.size_y, el.size_z = scale


def chain(mb, p0, p1, n, r0, r1, scale=(1, 1, 1)) -> None:
    """Dense overlapping ball chain p0→p1 — guarantees fusion (step ≤ radius)."""
    for i in range(n):
        t = i / max(n - 1, 1)
        co = tuple(a + (b - a) * t for a, b in zip(p0, p1))
        add_ball(mb, co, r0 + (r1 - r0) * t, scale)


def build(args: argparse.Namespace) -> None:
    clear_scene()
    mb = bpy.data.metaballs.new("mannequin")
    mb.resolution = 0.03
    mb.threshold = 0.28  # lower threshold → fatter surface → solid fusion
    obj = bpy.data.objects.new("Mannequin", mb)
    bpy.context.collection.objects.link(obj)

    sh, wa, hi = args.shoulders, args.waist, args.hips
    # Z-up: feet 0 → head top ~1.75. Slim depth (Y) — mannequin, not anatomy.
    for side in (-1, 1):
        x = 0.095 * hi * side
        # Leg: ankle → hip, dense.
        chain(mb, (x * 0.85, 0, 0.05), (x, 0, 0.96), 20, 0.052, 0.098, (1, 0.85, 1))
    # Pelvis bridge.
    chain(mb, (-0.08 * hi, 0, 0.98), (0.08 * hi, 0, 0.98), 5, 0.105, 0.105, (1.15, 0.8, 0.9))
    # Torso column: hips → chest with a waist pinch.
    chain(mb, (0, 0, 1.02), (0, 0, 1.16), 5, 0.115 * hi, 0.098 * wa, (1.2, 0.78, 1))
    chain(mb, (0, 0, 1.16), (0, 0, 1.42), 7, 0.098 * wa, 0.125, (1.28, 0.8, 1))
    # Shoulder bar.
    chain(mb, (-0.16 * sh, 0, 1.44), (0.16 * sh, 0, 1.44), 7, 0.075, 0.075, (1, 0.85, 0.9))
    # Arms: shoulder → wrist, relaxed slightly outward.
    for side in (-1, 1):
        chain(mb, (0.19 * sh * side, 0, 1.42), (0.25 * side, 0, 0.92), 18, 0.055, 0.042, (1, 0.9, 1))
    # Neck + abstract head (no face — dress-form register).
    chain(mb, (0, 0, 1.47), (0, 0, 1.56), 4, 0.05, 0.05, (1, 0.85, 1))
    chain(mb, (0, 0, 1.60), (0, 0, 1.68), 4, 0.085, 0.075, (0.9, 1, 1.05))

    # Metaball → mesh (convert operates on the SELECTED objects).
    bpy.context.view_layer.update()
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.convert(target="MESH")
    body = bpy.context.active_object
    body.name = "MannequinBody"

    # Clean + smooth: remesh for even topology, then relax.
    rm = body.modifiers.new("remesh", "REMESH")
    rm.mode = "VOXEL"
    rm.voxel_size = 0.018
    sm = body.modifiers.new("smooth", "CORRECTIVE_SMOOTH")
    sm.iterations = 40
    sm.factor = 0.8
    bpy.ops.object.modifier_apply(modifier=rm.name)
    bpy.ops.object.modifier_apply(modifier=sm.name)
    bpy.ops.object.shade_smooth()

    # Overall height scale.
    body.scale = (args.height, args.height, args.height)
    bpy.ops.object.transform_apply(scale=True)

    # Matte "linen form" material in the user's skin tone.
    tone = args.tone.lstrip("#")
    r, g, b = (int(tone[i:i + 2], 16) / 255 for i in (0, 2, 4))
    mat = bpy.data.materials.new("FormTone")
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (r, g, b, 1)
    bsdf.inputs["Roughness"].default_value = 0.85
    body.data.materials.append(mat)

    bpy.ops.export_scene.gltf(filepath=args.out, export_format="GLB",
                              use_selection=False, export_yup=True)
    print("exported", args.out)


if __name__ == "__main__":
    build(parse_args())
