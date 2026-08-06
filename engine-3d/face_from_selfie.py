"""Selfie → the avatar's face. Same lesson as the garments: realism lives in
the texture, not the geometry.

The head region of the body mesh gets a second UV set that is a FRONT planar
projection, mapped onto the face found in the user's photo. Skin elsewhere
keeps the flat tone, and the two are blended with a soft oval mask so there is
no hard seam at the jaw or hairline.

Auto-detection without ML: the photo is a full-body cutout, so the head is the
silhouette's topmost cluster — its width collapses at the neck, which is the
narrowest row in the upper fifth. That is enough to crop the face reliably.

Run:
  blender -b -P face_from_selfie.py -- --photo person.jpg --out assets/body_face.glb
"""
import argparse
import math
import os
import sys

import bpy
import numpy as np

ROOT = os.path.dirname(os.path.abspath(__file__))
A = lambda *p: os.path.join(ROOT, "assets", *p)


def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    p = argparse.ArgumentParser()
    p.add_argument("--photo", required=True)
    p.add_argument("--body", default=A("body.glb"))
    p.add_argument("--out", default=A("body_face.glb"))
    p.add_argument("--preview", default=A("preview_face.png"))
    p.add_argument("--tone", default="")   # empty = sample it from the photo
    return p.parse_args(argv)


def find_head(path: str) -> dict:
    """Head box + average skin tone, straight from the cutout's silhouette."""
    img = bpy.data.images.load(path)
    w, h = img.size
    px = np.array(img.pixels[:], dtype=np.float32).reshape(h, w, 4)
    rgb, alpha = px[..., :3][::-1], px[..., 3][::-1]     # Blender rows are bottom-up
    mx, mn = rgb.max(axis=2), rgb.min(axis=2)
    solid = (alpha > 0.2) & ~((mn > 0.90) & ((mx - mn) < 0.10))
    ys, xs = np.nonzero(solid)
    if len(ys) < 50:
        bpy.data.images.remove(img)
        raise RuntimeError("no subject found in the photo")
    top, bottom = int(ys.min()), int(ys.max())
    height = bottom - top

    # Head box WITHOUT a neck detector. On a full-body shot the widest row in
    # any fixed scan window is the SHOULDERS, which swallowed head+chest into
    # the "face" box. Instead: measure head width in the crown zone only
    # (rows that cannot reach the shoulders), then use anatomy — a head is
    # ~1.35× taller than its width, chin included.
    crown_zone = widths_zone = max(6, int(height * 0.12))
    row_w = [len(np.nonzero(solid[y])[0]) for y in range(top, top + crown_zone)]
    head_w = max(row_w) if row_w else max(4, height // 8)
    neck_y = top + int(1.35 * head_w)
    band = solid[top:neck_y + 1]
    cols = np.nonzero(band.any(axis=0))[0]
    x0, x1 = int(cols.min()), int(cols.max())
    # Anatomy guard: a head is ~1.3–1.5× taller than wide. A beard or a shirt
    # collar defeats the pinch detector and the "head" swallows the neck —
    # then every feature lands too low on the mesh. Clamp and re-measure.
    max_h = int(1.45 * max(x1 - x0, 1))
    if neck_y - top > max_h:
        neck_y = top + max_h
        band = solid[top:neck_y + 1]
        cols = np.nonzero(band.any(axis=0))[0]
        x0, x1 = int(cols.min()), int(cols.max())

    # Skin tone: the median of the face box beats the mean, which any stray
    # dark pixel (hair, shadow, glasses) drags down.
    face = rgb[top:neck_y + 1, x0:x1 + 1].reshape(-1, 3)
    tone = tuple(float(v) for v in np.median(face, axis=0))
    bpy.data.images.remove(img)
    return {
        "box": [x0, top, x1, neck_y, w, h],
        "tone": tone,
        "height_frac": (neck_y - top) / max(height, 1),
    }


def project_face(body, info, photo_path):
    """Second UV layer over the head + a material that blends the photo in."""
    me = body.data
    verts = me.vertices
    zs = [v.co.z for v in verts]
    H = max(zs)

    # The head starts where the mesh's own silhouette narrows into the neck.
    head_bottom = H * 0.855
    head_top = H
    xs = [v.co.x for v in verts if v.co.z > head_bottom]
    ys_ = [v.co.y for v in verts if v.co.z > head_bottom]
    if not xs:
        raise RuntimeError("body has no head region above 0.855H")
    hx0, hx1 = min(xs), max(xs)
    hy_front = min(ys_)                                  # the avatar faces -Y

    uv = me.uv_layers[0] if me.uv_layers else me.uv_layers.new(name="face")
    bx0, by0, bx1, by1, iw, ih = info["box"]
    u0, u1 = bx0 / iw, bx1 / iw

    # Three-anchor vertical map. Photo: eyes sit ~42% down the head box,
    # chin ~96%. Mesh: eyes ~55% up the head band. Piecewise-linear between
    # the anchors keeps every feature at its anatomical height.
    MESH_EYE, PHOTO_EYE, PHOTO_CHIN = 0.55, 0.42, 0.96
    def photo_row(fz):          # fz: 0=head bottom, 1=crown → row from top
        if fz >= MESH_EYE:      # eyes … crown
            t = (fz - MESH_EYE) / (1 - MESH_EYE)
            return PHOTO_EYE * (1 - t)
        t = fz / MESH_EYE       # chin … eyes
        return PHOTO_CHIN - t * (PHOTO_CHIN - PHOTO_EYE)

    for loop in me.loops:
        co = verts[loop.vertex_index].co
        fx = (co.x - hx0) / max(hx1 - hx0, 1e-6)
        fz = (co.z - head_bottom) / max(head_top - head_bottom, 1e-6)
        row = photo_row(min(max(fz, 0.0), 1.0))
        v = 1.0 - (by0 + row * (by1 - by0)) / ih
        uv.data[loop.index].uv = (u0 + fx * (u1 - u0), v)

    # TWO EXPLICIT MATERIAL SLOTS — no shader gates. The old soft mask lived
    # in MapRange/Mix nodes, which the glTF exporter CANNOT bake: in Blender
    # previews it looked right, in the browser the face texture smeared down
    # the torso (the "black stripe"). Slots survive export losslessly:
    #   0 mat_body — plain skin tone
    #   1 mat_head — the photo, face-UV, front of the head only
    mat_body = bpy.data.materials.new("mat_body")
    mat_body.use_nodes = True
    bb = mat_body.node_tree.nodes["Principled BSDF"]
    tone = info["tone"]
    bb.inputs["Base Color"].default_value = (*tone, 1)
    bb.inputs["Roughness"].default_value = 0.62

    mat_head = bpy.data.materials.new("mat_head")
    mat_head.use_nodes = True
    nt = mat_head.node_tree
    bh = nt.nodes["Principled BSDF"]
    bh.inputs["Roughness"].default_value = 0.62
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = bpy.data.images.load(photo_path, check_existing=True)
    tex.extension = "EXTEND"
    nt.links.new(tex.outputs["Color"], bh.inputs["Base Color"])  # TEXCOORD_0

    me.materials.clear()
    me.materials.append(mat_body)   # index 0
    me.materials.append(mat_head)   # index 1

    # Polygon assignment by geometry (no ops, no selection state — headless
    # friendly): the FRONT of the head band wears the photo, everything else
    # (body, back of the skull) stays plain skin. y threshold = 45% of head
    # depth from the front, so ears/back never catch smeared EXTEND pixels.
    y_front_limit = hy_front + (max(ys_) - hy_front) * 0.45
    for poly in me.polygons:
        cz = min(verts[v].co.z for v in poly.vertices)
        cy = sum(verts[v].co.y for v in poly.vertices) / len(poly.vertices)
        poly.material_index = 1 if (cz >= head_bottom and cy <= y_front_limit) else 0




def main():
    args = parse_args()
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    bpy.ops.import_scene.gltf(filepath=args.body)
    body = next(o for o in bpy.context.scene.objects if o.type == "MESH")
    body.name = "Body"

    info = find_head(args.photo)
    print("[face]", {k: v for k, v in info.items() if k != "tone"},
          "tone", tuple(round(c, 3) for c in info["tone"]))
    project_face(body, info, args.photo)

    bpy.ops.object.select_all(action="DESELECT")
    body.select_set(True)
    bpy.ops.export_scene.gltf(filepath=args.out, export_format="GLB",
                              use_selection=True, export_yup=True)
    print("[export]", args.out)

    # Head-and-shoulders preview: the face is the whole point of this pass.
    scene = bpy.context.scene
    H = max(v.co.z for v in body.data.vertices)
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    scene.collection.objects.link(cam); scene.camera = cam
    cam.data.lens = 80
    cam.location = (0, -1.15, H * 0.93)
    cam.rotation_euler = (math.radians(90), 0, 0)
    sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
    sun.data.energy = 2.6
    sun.rotation_euler = (math.radians(58), 0, math.radians(24))
    scene.collection.objects.link(sun)
    w = bpy.data.worlds.new("w"); scene.world = w; w.use_nodes = True
    w.node_tree.nodes["Background"].inputs[0].default_value = (0.96, 0.95, 0.93, 1)
    scene.render.engine = "BLENDER_EEVEE"
    scene.view_settings.view_transform = "Filmic"
    scene.render.resolution_x, scene.render.resolution_y = 700, 800
    scene.render.filepath = args.preview
    bpy.ops.render.render(write_still=True)
    print("done")


main()
