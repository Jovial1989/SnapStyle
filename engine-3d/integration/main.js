/**
 * LookTok 3D engine — vanilla Three.js scene driven from Flutter.
 *
 * Contract with the host:
 *   window.updateOutfit(topUrl, bottomUrl)   ← Flutter calls this on every change
 *   SceneBridge.postMessage('ready')         → sent once the body is on screen
 *
 * Both arguments are nullable: `null` means "take that slot off".
 */

import * as THREE from 'three';
import { GLTFLoader } from './vendor/jsm/loaders/GLTFLoader.js';
import { OrbitControls } from './vendor/jsm/controls/OrbitControls.js';
import { RoomEnvironment } from './vendor/jsm/environments/RoomEnvironment.js';

const BODY_URL = './models/body.glb';

/* ─────────────────────────── renderer ─────────────────────────── */

const stage = document.getElementById('stage');

// alpha:true allocates an alpha channel; premultipliedAlpha:false keeps edge
// pixels from darkening against the Flutter backdrop. Both are needed for a
// seamless composite — alpha alone leaves a grey fringe on antialiased edges.
const renderer = new THREE.WebGLRenderer({
  antialias: true,
  alpha: true,
  premultipliedAlpha: false,
});
renderer.setPixelRatio(Math.min(devicePixelRatio, 2)); // 3x on phones is wasted fill rate
renderer.setSize(innerWidth, innerHeight);
renderer.setClearColor(0x000000, 0);                   // fully transparent clear
renderer.shadowMap.enabled = true;
renderer.shadowMap.type = THREE.PCFSoftShadowMap;
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.toneMappingExposure = 1.05;
renderer.outputColorSpace = THREE.SRGBColorSpace;
stage.appendChild(renderer.domElement);

const scene = new THREE.Scene();
scene.background = null;                               // never paint a backdrop

// Image-based lighting without a skybox: real reflections on fabric and
// leather, nothing drawn behind the figure.
const pmrem = new THREE.PMREMGenerator(renderer);
scene.environment = pmrem.fromScene(new RoomEnvironment(), 0.04).texture;

const camera = new THREE.PerspectiveCamera(34, innerWidth / innerHeight, 0.1, 50);
camera.position.set(0, 1.35, 3.4);

const controls = new OrbitControls(camera, stage);
controls.target.set(0, 1.0, 0);
controls.enableDamping = true;
controls.enablePan = false;
controls.minDistance = 1.6;
controls.maxDistance = 6;
controls.maxPolarAngle = Math.PI * 0.62;               // never dip under the floor

scene.add(new THREE.HemisphereLight(0xffffff, 0xddd8d0, 0.9));
const key = new THREE.DirectionalLight(0xffffff, 1.6);
key.position.set(2.5, 4, 3);
key.castShadow = true;
key.shadow.mapSize.set(2048, 2048);
scene.add(key);
scene.add(new THREE.DirectionalLight(0xffffff, 0.6).translateX(-3).translateY(3).translateZ(-2));

// Shadow-only floor: catches the contact shadow, stays invisible itself, so
// the transparency survives.
const floor = new THREE.Mesh(
  new THREE.CircleGeometry(1.6, 48),
  new THREE.ShadowMaterial({ opacity: 0.16 }),
);
floor.rotation.x = -Math.PI / 2;
floor.receiveShadow = true;
scene.add(floor);

/* ───────────────────────── scene contents ───────────────────────── */

const loader = new GLTFLoader();
const slots = { body: null, top: null, bottom: null };
const cache = new Map();                               // url → THREE.Group

function post(message) {
  if (window.SceneBridge) window.SceneBridge.postMessage(message);
}

function load(url) {
  const hit = cache.get(url);
  if (hit) return Promise.resolve(hit);
  return new Promise((resolve, reject) => {
    loader.load(
      url,
      (gltf) => {
        const root = gltf.scene;
        root.traverse((o) => {
          if (o.isMesh) {
            o.castShadow = true;
            o.frustumCulled = false;                   // garments hug the body
          }
        });
        cache.set(url, root);                          // a re-tap is instant
        resolve(root);
      },
      undefined,
      reject,
    );
  });
}

/** Put `url` in `slot`, or clear the slot when url is null/undefined. */
async function equip(slot, url) {
  const current = slots[slot];
  if (current && current.userData.url === url) return; // already worn
  if (current) {
    scene.remove(current);
    slots[slot] = null;
  }
  if (!url) return;
  try {
    const model = await load(url);
    model.userData.url = url;
    slots[slot] = model;
    scene.add(model);
  } catch (err) {
    post(`error:${slot}:${err?.message ?? 'load failed'}`);
  }
}

/* ─────────────────────────── the bridge ─────────────────────────── */

/**
 * Called by Flutter on every outfit change. Kept deliberately dumb: the host
 * owns state, the scene just reflects it.
 */
window.updateOutfit = function updateOutfit(topUrl, bottomUrl) {
  console.log('[scene] updateOutfit', topUrl, bottomUrl);
  Promise.all([equip('top', topUrl), equip('bottom', bottomUrl)]).catch((e) =>
    post(`error:${e?.message ?? 'equip failed'}`),
  );
};

/* ──────────────────────────── boot ──────────────────────────── */

load(BODY_URL)
  .then((body) => {
    slots.body = body;
    scene.add(body);
    // One frame drawn before reporting, so Flutter's loader hides on a real
    // picture rather than on a still-empty canvas.
    renderer.render(scene, camera);
    requestAnimationFrame(() => post('ready'));
  })
  .catch((e) => post(`error:body:${e?.message ?? 'load failed'}`));

addEventListener('resize', () => {
  camera.aspect = innerWidth / innerHeight;
  camera.updateProjectionMatrix();
  renderer.setSize(innerWidth, innerHeight);
});

(function tick() {
  controls.update();
  renderer.render(scene, camera);
  requestAnimationFrame(tick);
})();
