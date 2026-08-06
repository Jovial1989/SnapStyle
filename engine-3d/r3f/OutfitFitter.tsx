/**
 * <OutfitFitter/> — dynamic garment swapping on a rigged body.
 *
 * Design rules this implements:
 *   • Garments are real MESHES, never textures painted on the body.
 *   • Every garment rebinds to the BODY's skeleton, so one pose/animation
 *     drives body and clothes together (no per-garment animation state).
 *   • The body is occluded under each garment, so nothing z-fights through.
 *   • Textures are user-supplied (a flat-lay, a scan, a generated map) and are
 *     applied with glTF-correct sampling (flipY off, sRGB for colour maps).
 *
 * Requirements on the assets (see the notes at the bottom of this file):
 *   body.glb    — one SkinnedMesh + Skeleton, bones named consistently.
 *   *_garment.glb — SkinnedMesh weighted to a skeleton with the SAME bone
 *                   names/order as the body. Bone COUNT may differ; we remap
 *                   by name and fall back to the body's bind pose.
 */

import * as React from 'react'
import * as THREE from 'three'
import { useGLTF, useTexture } from '@react-three/drei'
import { clone as cloneSkinned } from 'three/examples/jsm/utils/SkeletonUtils.js'

/* ────────────────────────────── types ────────────────────────────── */

export type GarmentSlot = 'top' | 'bottom'

export interface GarmentMaterialMaps {
  /** Base colour / albedo. Usually the user's own flat-lay. */
  map?: string
  normalMap?: string
  roughnessMap?: string
  aoMap?: string
  /** Multiplied over `map`; use alone for plain-colour pieces. */
  color?: THREE.ColorRepresentation
  roughness?: number
  metalness?: number
  /** Tiling for repeating fabric maps (weave/denim). Omit for flat-lays. */
  repeat?: [number, number]
}

export interface GarmentSource {
  url: string
  maps?: GarmentMaterialMaps
  /**
   * Body mesh names this piece fully covers. Those meshes are hidden while it
   * is worn. Falls back to `occludeBands` when the body is a single mesh.
   */
  occludeMeshes?: string[]
  /**
   * Vertical bands of the body to discard in the shader, in LOCAL body units
   * (metres): [[yMin, yMax], …]. Needed for single-mesh bodies, which cannot
   * be occluded by hiding sub-objects.
   */
  occludeBands?: Array<[number, number]>
}

export interface OutfitFitterProps {
  bodyUrl: string
  top?: GarmentSource | null
  bottom?: GarmentSource | null
  /** Extra slots (shoes, outerwear) — same contract as top/bottom. */
  extras?: GarmentSource[]
  /** Applied to the whole outfit group. */
  position?: [number, number, number]
  scale?: number
  onReady?: () => void
}

/* ─────────────────────────── shared helpers ─────────────────────────── */

/** First SkinnedMesh in a subtree (garments and bodies each have exactly one
 *  in a well-authored asset; we take the first and warn on extras). */
function findSkinnedMesh(root: THREE.Object3D): THREE.SkinnedMesh | null {
  let found: THREE.SkinnedMesh | null = null
  let count = 0
  root.traverse((o) => {
    if ((o as THREE.SkinnedMesh).isSkinnedMesh) {
      count += 1
      if (!found) found = o as THREE.SkinnedMesh
    }
  })
  if (count > 1) {
    console.warn(`[OutfitFitter] ${count} SkinnedMeshes found; using the first.`)
  }
  return found
}

/**
 * Rebind a garment's skin to the body's skeleton.
 *
 * Bone ORDER is what skinIndex attributes reference, and exporters do not
 * guarantee it matches between two files — so we rebuild a Skeleton whose
 * bone array follows the GARMENT's original order but points at the BODY's
 * bone objects, matched by name. That keeps skinIndex valid while making the
 * body the single source of animation truth.
 */
function bindToSkeleton(garment: THREE.SkinnedMesh, bodySkinned: THREE.SkinnedMesh): boolean {
  const bodyBones = new Map<string, THREE.Bone>()
  bodySkinned.skeleton.bones.forEach((b) => bodyBones.set(b.name, b))

  const remapped: THREE.Bone[] = []
  const inverses: THREE.Matrix4[] = []
  let missing = 0

  garment.skeleton.bones.forEach((gb, i) => {
    const target = bodyBones.get(gb.name)
    if (target) {
      remapped.push(target)
      // Reuse the body's inverse for shared bones so the bind pose matches.
      const idx = bodySkinned.skeleton.bones.indexOf(target)
      inverses.push(bodySkinned.skeleton.boneInverses[idx].clone())
    } else {
      missing += 1
      remapped.push(gb)
      inverses.push(garment.skeleton.boneInverses[i].clone())
    }
  })

  if (missing) {
    console.warn(
      `[OutfitFitter] ${missing}/${garment.skeleton.bones.length} garment bones ` +
        `have no match on the body — those keep their own transform.`,
    )
  }

  const skeleton = new THREE.Skeleton(remapped, inverses)
  garment.bind(skeleton, bodySkinned.bindMatrix.clone())
  garment.bindMatrixInverse.copy(bodySkinned.bindMatrixInverse)
  // The garment must not carry its own transform once bound to the body rig.
  garment.matrixAutoUpdate = false
  garment.matrix.identity()
  garment.updateMatrixWorld(true)
  // Skinned bounds are computed from the bind pose; recompute so frustum
  // culling doesn't pop the garment out of view when the body moves.
  garment.frustumCulled = false
  return missing === 0
}

/** Configure a texture for glTF UVs. */
function prepareTexture(
  tex: THREE.Texture,
  { srgb, repeat }: { srgb: boolean; repeat?: [number, number] },
): THREE.Texture {
  // glTF UVs have their origin at the top-left; three flips by default for
  // non-glTF loaders only. Getting this wrong mirrors prints vertically.
  tex.flipY = false
  tex.colorSpace = srgb ? THREE.SRGBColorSpace : THREE.NoColorSpace
  tex.anisotropy = 8
  if (repeat) {
    tex.wrapS = tex.wrapT = THREE.RepeatWrapping
    tex.repeat.set(repeat[0], repeat[1])
  } else {
    // A flat-lay is a one-off atlas: clamp so edge pixels never tile in.
    tex.wrapS = tex.wrapT = THREE.ClampToEdgeWrapping
  }
  tex.needsUpdate = true
  return tex
}

/**
 * Discard body fragments inside Y bands — the only way to occlude a body
 * authored as a SINGLE skinned mesh (hiding sub-objects needs a split body).
 * Injected via onBeforeCompile so the standard PBR shading is untouched.
 */
function useBandOcclusion(material: THREE.Material | null, bands: Array<[number, number]>) {
  const uniforms = React.useRef({
    uBandCount: { value: 0 },
    uBands: { value: Array.from({ length: 8 }, () => new THREE.Vector2()) },
  })

  React.useEffect(() => {
    const u = uniforms.current
    u.uBandCount.value = Math.min(bands.length, 8)
    bands.slice(0, 8).forEach(([a, b], i) => u.uBands.value[i].set(a, b))
  }, [bands])

  React.useEffect(() => {
    if (!material) return
    material.onBeforeCompile = (shader) => {
      shader.uniforms.uBandCount = uniforms.current.uBandCount
      shader.uniforms.uBands = uniforms.current.uBands
      shader.vertexShader = shader.vertexShader
        .replace('#include <common>', '#include <common>\nvarying float vBodyY;')
        .replace(
          '#include <skinning_vertex>',
          '#include <skinning_vertex>\nvBodyY = (modelMatrix * vec4(transformed, 1.0)).y;',
        )
      shader.fragmentShader = shader.fragmentShader
        .replace(
          '#include <common>',
          `#include <common>
           varying float vBodyY;
           uniform int uBandCount;
           uniform vec2 uBands[8];`,
        )
        .replace(
          '#include <clipping_planes_fragment>',
          `#include <clipping_planes_fragment>
           for (int i = 0; i < 8; i++) {
             if (i >= uBandCount) break;
             if (vBodyY > uBands[i].x && vBodyY < uBands[i].y) discard;
           }`,
        )
    }
    material.needsUpdate = true
    return () => {
      material.onBeforeCompile = () => {}
      material.needsUpdate = true
    }
  }, [material])
}

/* ───────────────────────────── the body ───────────────────────────── */

interface BodyProps {
  url: string
  hiddenMeshes: Set<string>
  bands: Array<[number, number]>
  onSkeleton: (mesh: THREE.SkinnedMesh) => void
}

const Body: React.FC<BodyProps> = ({ url, hiddenMeshes, bands, onSkeleton }) => {
  const { scene } = useGLTF(url)
  // Clone so the cached glTF is never mutated (drei caches per URL, and two
  // OutfitFitters on one page would otherwise fight over visibility flags).
  const root = React.useMemo(() => cloneSkinned(scene) as THREE.Group, [scene])
  const skinned = React.useMemo(() => findSkinnedMesh(root), [root])

  React.useEffect(() => {
    if (skinned) onSkeleton(skinned)
    else console.error('[OutfitFitter] body has no SkinnedMesh — garments cannot bind.')
  }, [skinned, onSkeleton])

  // Sub-mesh occlusion (bodies authored in parts).
  React.useEffect(() => {
    root.traverse((o) => {
      if ((o as THREE.Mesh).isMesh) o.visible = !hiddenMeshes.has(o.name)
    })
  }, [root, hiddenMeshes])

  // Band occlusion (single-mesh bodies).
  const material = React.useMemo(
    () => (skinned ? (skinned.material as THREE.Material) : null),
    [skinned],
  )
  useBandOcclusion(material, bands)

  return <primitive object={root} />
}

/* ─────────────────────────── one garment ─────────────────────────── */

interface GarmentProps {
  source: GarmentSource
  bodySkinned: THREE.SkinnedMesh
}

const Garment: React.FC<GarmentProps> = ({ source, bodySkinned }) => {
  const { scene } = useGLTF(source.url)
  const root = React.useMemo(() => cloneSkinned(scene) as THREE.Group, [scene])

  // drei's useTexture wants a stable record; undefined entries are skipped.
  const maps = source.maps ?? {}
  const textureUrls = React.useMemo(
    () =>
      Object.fromEntries(
        (['map', 'normalMap', 'roughnessMap', 'aoMap'] as const)
          .filter((k) => Boolean(maps[k]))
          .map((k) => [k, maps[k] as string]),
      ),
    [maps.map, maps.normalMap, maps.roughnessMap, maps.aoMap],
  )
  const textures = useTexture(textureUrls) as Record<string, THREE.Texture>

  // Bind to the body rig once per (garment, body) pair.
  React.useEffect(() => {
    const skinned = findSkinnedMesh(root)
    if (!skinned) {
      console.warn(`[OutfitFitter] ${source.url} has no SkinnedMesh; rendering unrigged.`)
      return
    }
    bindToSkeleton(skinned, bodySkinned)
  }, [root, bodySkinned, source.url])

  // PBR material from the supplied maps.
  React.useEffect(() => {
    const material = new THREE.MeshStandardMaterial({
      color: maps.color ?? 0xffffff,
      roughness: maps.roughness ?? 0.9,
      metalness: maps.metalness ?? 0.0,
      side: THREE.DoubleSide, // cloth shells are thin; both faces must shade
    })
    if (textures.map) {
      material.map = prepareTexture(textures.map, { srgb: true, repeat: maps.repeat })
    }
    if (textures.normalMap) {
      material.normalMap = prepareTexture(textures.normalMap, { srgb: false, repeat: maps.repeat })
      material.normalScale = new THREE.Vector2(1, 1)
    }
    if (textures.roughnessMap) {
      material.roughnessMap = prepareTexture(textures.roughnessMap, {
        srgb: false,
        repeat: maps.repeat,
      })
    }
    if (textures.aoMap) {
      material.aoMap = prepareTexture(textures.aoMap, { srgb: false, repeat: maps.repeat })
    }

    const previous: THREE.Material[] = []
    root.traverse((o) => {
      const mesh = o as THREE.Mesh
      if (!mesh.isMesh) return
      previous.push(mesh.material as THREE.Material)
      mesh.material = material
      mesh.castShadow = true
      mesh.receiveShadow = true
      // aoMap needs a second UV set; reuse uv when the asset lacks uv2.
      const geo = mesh.geometry as THREE.BufferGeometry
      if (material.aoMap && !geo.getAttribute('uv2') && geo.getAttribute('uv')) {
        geo.setAttribute('uv2', geo.getAttribute('uv'))
      }
    })

    return () => {
      material.dispose()
      // Textures come from drei's cache — do NOT dispose them here.
      let i = 0
      root.traverse((o) => {
        const mesh = o as THREE.Mesh
        if (mesh.isMesh) mesh.material = previous[i++]
      })
    }
  }, [root, textures, maps.color, maps.roughness, maps.metalness, maps.repeat])

  return <primitive object={root} />
}

/* ──────────────────────────── the fitter ──────────────────────────── */

export const OutfitFitter: React.FC<OutfitFitterProps> = ({
  bodyUrl,
  top = null,
  bottom = null,
  extras = [],
  position = [0, 0, 0],
  scale = 1,
  onReady,
}) => {
  const [bodySkinned, setBodySkinned] = React.useState<THREE.SkinnedMesh | null>(null)

  const worn = React.useMemo(
    () => [top, bottom, ...extras].filter(Boolean) as GarmentSource[],
    [top, bottom, extras],
  )

  // Occlusion is the union of what every worn piece covers.
  const hiddenMeshes = React.useMemo(
    () => new Set(worn.flatMap((g) => g.occludeMeshes ?? [])),
    [worn],
  )
  const bands = React.useMemo(() => worn.flatMap((g) => g.occludeBands ?? []), [worn])

  const handleSkeleton = React.useCallback((mesh: THREE.SkinnedMesh) => {
    setBodySkinned(mesh)
  }, [])

  React.useEffect(() => {
    if (bodySkinned) onReady?.()
  }, [bodySkinned, onReady])

  return (
    <group position={position} scale={scale}>
      <Body url={bodyUrl} hiddenMeshes={hiddenMeshes} bands={bands} onSkeleton={handleSkeleton} />
      {bodySkinned &&
        worn.map((g) => (
          // Keying by URL remounts (and rebinds) only when the piece changes.
          <Garment key={g.url} source={g} bodySkinned={bodySkinned} />
        ))}
    </group>
  )
}

/** Warm the cache so a tap swaps instantly instead of suspending. */
export function preloadOutfit(urls: string[]): void {
  urls.forEach((u) => useGLTF.preload(u))
}

export default OutfitFitter
