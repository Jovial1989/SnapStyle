/**
 * Body occlusion for a SINGLE-mesh avatar.
 *
 * Hiding sub-objects is impossible when the body is one skinned/static mesh,
 * so we discard its fragments wherever a garment covers them. That removes
 * poke-through and hem gaps at the source — no inflating the cloth with
 * "ease" until nothing shows, which is what we were doing before and what
 * made the garments look like paper bags.
 *
 * Why BOXES and not a plain Y band: in an A-pose the arms live at the same
 * heights as the torso, so a band from hem to shoulder erases the arms too.
 * A box (centre + half-extent) keeps the discard inside the torso volume and
 * lets the sleeves handle the arms on their own.
 *
 * Cost: one branch over N regions per fragment, no extra draw calls, no
 * geometry work. The program is compiled ONCE — the region count is a uniform,
 * not a #define, so swapping garments never triggers a shader recompile.
 */

export const MAX_REGIONS = 4;

/**
 * Install the discard logic on a material and return a setter.
 * @param {THREE.Material} material  the body's material
 * @param {typeof import('three')} THREE
 * @returns {(regions: Array<{center: [number,number,number], half: [number,number,number]}>) => void}
 */
export function installOcclusion(material, THREE) {
  const uniforms = {
    uOccCount: { value: 0 },
    uOccCenter: { value: Array.from({ length: MAX_REGIONS }, () => new THREE.Vector3()) },
    uOccHalf: { value: Array.from({ length: MAX_REGIONS }, () => new THREE.Vector3(0, 0, 0)) },
  };

  material.onBeforeCompile = (shader) => {
    Object.assign(shader.uniforms, uniforms);

    // A uniquely named varying: `vWorldPosition` is already declared by some
    // built-in chunks (envmap/fog paths), and declaring it twice is a compile
    // error that only shows up on certain material configurations.
    shader.vertexShader = shader.vertexShader
      .replace(
        '#include <common>',
        '#include <common>\nvarying vec3 vOccWorld;',
      )
      .replace(
        '#include <worldpos_vertex>',
        '#include <worldpos_vertex>\n\tvOccWorld = (modelMatrix * vec4(transformed, 1.0)).xyz;',
      );

    shader.fragmentShader = shader.fragmentShader
      .replace(
        '#include <common>',
        `#include <common>
        varying vec3 vOccWorld;
        uniform int uOccCount;
        uniform vec3 uOccCenter[${MAX_REGIONS}];
        uniform vec3 uOccHalf[${MAX_REGIONS}];`,
      )
      .replace(
        '#include <clipping_planes_fragment>',
        `#include <clipping_planes_fragment>
        for (int i = 0; i < ${MAX_REGIONS}; i++) {
          if (i >= uOccCount) break;
          vec3 d = abs(vOccWorld - uOccCenter[i]);
          if (all(lessThan(d, uOccHalf[i]))) discard;
        }`,
      );

    material.userData.occlusionShader = shader;
  };

  // `transformed` only exists after the position chunks; `worldpos_vertex` is
  // present in every standard material, so the injection above is safe. Force
  // a rebuild in case the material was already compiled.
  material.needsUpdate = true;

  return function setRegions(regions) {
    const n = Math.min(regions.length, MAX_REGIONS);
    uniforms.uOccCount.value = n;
    for (let i = 0; i < n; i++) {
      uniforms.uOccCenter.value[i].set(...regions[i].center);
      uniforms.uOccHalf.value[i].set(...regions[i].half);
    }
    // Zero out the rest so a stale region can never re-appear.
    for (let i = n; i < MAX_REGIONS; i++) uniforms.uOccHalf.value[i].set(0, 0, 0);
  };
}

/**
 * Derive an occlusion box from a worn garment — no metadata, no pipeline
 * changes: the piece's own world bounds say what it covers.
 *
 * [inset] pulls the box in from the garment's edges so the body still shows
 * *at* the hem, cuff and collar. Without it you see straight through the
 * openings into an empty shell.
 */
/** Per-slot insets: a collar needs a deep top inset (you look INTO the neck
 *  hole), but a waistband hides under the top, and a shoe opening is tiny —
 *  one shared inset either shows skin at the waist or eats the underarm. */
export const SLOT_INSETS = {
  // x and z insets are SEPARATE: x protects side openings (sleeves), but a
  // torso has no front/back opening — any z inset leaves a strip of chest
  // and back alive inside the garment, which pokes through at 3/4 views.
  top:    { x: 0.008, z: 0.000, top: 0.020, bottom: 0.020 },
  bottom: { x: 0.000, z: 0.000, top: 0.006, bottom: 0.020 },
  shoes:  { x: 0.002, z: 0.000, top: 0.004, bottom: 0.000 },
};

export function regionFromGarment(object3D, THREE, inset = { x: 0.008, z: 0.0, top: 0.02, bottom: 0.02 }) {
  const box = new THREE.Box3().setFromObject(object3D);
  if (box.isEmpty()) return null;
  const min = box.min.clone();
  const max = box.max.clone();
  const ix = inset.x ?? inset.xz ?? 0, iz = inset.z ?? inset.xz ?? 0;
  min.x += ix; max.x -= ix;
  min.z += iz; max.z -= iz;
  min.y += inset.bottom; max.y -= inset.top;
  if (max.x <= min.x || max.y <= min.y || max.z <= min.z) return null;
  const center = min.clone().add(max).multiplyScalar(0.5);
  const half = max.clone().sub(min).multiplyScalar(0.5);
  return { center: [center.x, center.y, center.z], half: [half.x, half.y, half.z] };
}
