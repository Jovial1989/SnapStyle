/**
 * Band occlusion for a single-mesh avatar — vanilla Three.js, no framework.
 *
 * A continuous body mesh cannot be hidden part-by-part, so the skin under a
 * garment is removed in the fragment shader instead. Cheap (one compare per
 * fragment), invisible to the rest of the PBR pipeline, and it fixes both
 * poke-through and hem gaps at the source — no inflating the cloth.
 *
 *   import { setupBodyOcclusion, updateOcclusionBounds } from './bandOcclusion.js';
 *   setupBodyOcclusion(bodyMesh);
 *   updateOcclusionBounds(0.80, 1.24);   // wearing a tee
 *   updateOcclusionBounds();             // nothing worn → nothing hidden
 */

/** Sentinel that disables the band without branching in JS. */
const OFF = -999;

/** Registry so updateOcclusionBounds() can reach every prepared body. */
const registry = new Set();

/**
 * Prepare a body mesh: patch its material so fragments inside [minY, maxY]
 * (WORLD space) are discarded.
 *
 * @param {THREE.Mesh} bodyMesh  mesh whose material is a MeshStandardMaterial
 *                               (or any material built from the standard chunks)
 * @returns {{ set(minY:number, maxY:number): void, clear(): void, dispose(): void }}
 */
export function setupBodyOcclusion(bodyMesh) {
  const material = bodyMesh.material;
  if (!material) throw new Error('setupBodyOcclusion: mesh has no material');

  // Uniform objects live OUTSIDE the compile callback: they are created now,
  // handed to the shader on compile, and mutated later. That is what makes
  // updateOcclusionBounds() safe to call before the first frame.
  const uniforms = {
    occlusionMinY: { value: OFF },
    occlusionMaxY: { value: OFF },
  };

  const patch = (shader) => {
    shader.uniforms.occlusionMinY = uniforms.occlusionMinY;
    shader.uniforms.occlusionMaxY = uniforms.occlusionMaxY;

    // NOTE on the varying name: `vWorldPosition` is also declared by
    // <transmission_pars_vertex>. If this body material ever enables
    // transmission, rename the varying here — a duplicate declaration is a
    // compile error that only appears on that one material configuration.
    shader.vertexShader = shader.vertexShader
      .replace(
        '#include <common>',
        '#include <common>\nvarying vec3 vWorldPosition;',
      )
      .replace(
        '#include <worldpos_vertex>',
        // `transformed` is final here (skinning/morphs already applied), so the
        // band follows the body even when it is posed.
        '#include <worldpos_vertex>\n\tvWorldPosition = ( modelMatrix * vec4( transformed, 1.0 ) ).xyz;',
      );

    shader.fragmentShader = shader.fragmentShader
      .replace(
        '#include <common>',
        `#include <common>
        varying vec3 vWorldPosition;
        uniform float occlusionMinY;
        uniform float occlusionMaxY;`,
      )
      .replace(
        // Discarding right after the clipping chunk means we bail out before
        // any lighting maths runs — the cheapest possible place.
        '#include <clipping_planes_fragment>',
        `#include <clipping_planes_fragment>
        if ( vWorldPosition.y > occlusionMinY && vWorldPosition.y < occlusionMaxY ) discard;`,
      );
  };

  material.onBeforeCompile = patch;
  // Three caches compiled programs per material signature. Without a distinct
  // key this patched material could be handed a program compiled for an
  // unpatched one that happens to match.
  material.customProgramCacheKey = () => 'bandOcclusion';
  material.needsUpdate = true;

  // The shadow pass renders with a DEPTH material, which never sees the patch
  // above — the invisible slice would still cast a shadow. Opt in with
  // setupShadowOcclusion(mesh, api, THREE) once you have your THREE import.

  const api = {
    /** Hide everything between these two world-space heights. */
    set(minY, maxY) {
      uniforms.occlusionMinY.value = Math.min(minY, maxY);
      uniforms.occlusionMaxY.value = Math.max(minY, maxY);
    },
    /** Show the whole body again. */
    clear() {
      uniforms.occlusionMinY.value = OFF;
      uniforms.occlusionMaxY.value = OFF;
    },
    /** Detach the patch (e.g. when tearing the scene down). */
    dispose() {
      material.onBeforeCompile = () => {};
      material.customProgramCacheKey = () => '';
      material.needsUpdate = true;
      registry.delete(api);
    },
    uniforms,
    material,
    mesh: bodyMesh,
  };

  registry.add(api);
  return api;
}

/**
 * Apply the same discard to the shadow pass. Call it with your THREE import:
 *
 *   setupShadowOcclusion(bodyMesh, occlusion, THREE);
 *
 * Kept separate from setupBodyOcclusion() so the core module stays free of a
 * three.js import and can be dropped into any bundling setup.
 */
export function setupShadowOcclusion(bodyMesh, occlusion, THREE) {
  const depth = new THREE.MeshDepthMaterial({
    depthPacking: THREE.RGBADepthPacking,
  });
  depth.onBeforeCompile = (shader) => {
    shader.uniforms.occlusionMinY = occlusion.uniforms.occlusionMinY;
    shader.uniforms.occlusionMaxY = occlusion.uniforms.occlusionMaxY;
    shader.vertexShader = shader.vertexShader
      .replace('#include <common>', '#include <common>\nvarying vec3 vWorldPosition;')
      .replace(
        '#include <worldpos_vertex>',
        '#include <worldpos_vertex>\n\tvWorldPosition = ( modelMatrix * vec4( transformed, 1.0 ) ).xyz;',
      );
    shader.fragmentShader = shader.fragmentShader
      .replace(
        '#include <common>',
        `#include <common>
        varying vec3 vWorldPosition;
        uniform float occlusionMinY;
        uniform float occlusionMaxY;`,
      )
      .replace(
        '#include <clipping_planes_fragment>',
        `#include <clipping_planes_fragment>
        if ( vWorldPosition.y > occlusionMinY && vWorldPosition.y < occlusionMaxY ) discard;`,
      );
  };
  depth.customProgramCacheKey = () => 'bandOcclusionDepth';
  bodyMesh.customDepthMaterial = depth;
  return depth;
}

/**
 * Module-level helper for the common single-avatar scene: updates every body
 * prepared with setupBodyOcclusion(). Call with no arguments to reveal the
 * whole body (nothing equipped).
 *
 * @param {number} [minY]
 * @param {number} [maxY]
 */
export function updateOcclusionBounds(minY, maxY) {
  const clearing = minY === undefined || maxY === undefined;
  registry.forEach((o) => (clearing ? o.clear() : o.set(minY, maxY)));
}

/**
 * Convenience: derive the band from the garment actually worn, so equipping a
 * piece needs no hand-tuned numbers.
 *
 *   updateOcclusionBounds(...bandFromGarment(teeObject, THREE));
 *
 * [inset] pulls the band in from the hem and collar, leaving a sliver of body
 * visible at the openings — otherwise you look into the neck hole and see an
 * empty shell.
 */
export function bandFromGarment(object3D, THREE, inset = 0.02) {
  const box = new THREE.Box3().setFromObject(object3D);
  if (box.isEmpty()) return [OFF, OFF];
  return [box.min.y + inset, box.max.y - inset];
}
