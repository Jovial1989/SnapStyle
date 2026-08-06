/**
 * Minimal host scene for <OutfitFitter/> — Suspense boundaries, studio IBL,
 * contact shadow, orbit. Mirrors the lighting of the current vanilla viewer
 * (ACES + RoomEnvironment) so assets look identical across both.
 */
import * as React from 'react'
import { Canvas } from '@react-three/fiber'
import { Environment, OrbitControls, ContactShadows, Html, useProgress } from '@react-three/drei'
import * as THREE from 'three'

import OutfitFitter, { GarmentSource, preloadOutfit } from './OutfitFitter'

const BODY = '/models/body.glb'

/** Catalogue entry → garment source. `map` is the user's own flat-lay. */
const CATALOGUE: Record<string, GarmentSource> = {
  tee: {
    url: '/models/regular_tshirt.glb',
    maps: { map: '/textures/user/tee_flatlay.jpg', roughness: 0.95 },
    // The tee covers the torso: hide it on a split body, or discard the band
    // on a single-mesh body (metres, world Y).
    occludeMeshes: ['Body_Torso'],
    occludeBands: [[0.95, 1.46]],
  },
  hoodie: {
    url: '/models/oversized_hoodie.glb',
    maps: { map: '/textures/user/hoodie_flatlay.jpg', roughness: 0.98 },
    occludeMeshes: ['Body_Torso', 'Body_ArmsUpper'],
    occludeBands: [[0.92, 1.52]],
  },
  chinos: {
    url: '/models/chinos.glb',
    maps: {
      map: '/textures/user/chinos_flatlay.jpg',
      normalMap: '/textures/fabric/denim_nor.jpg',
      repeat: [9, 9],
      roughness: 0.88,
    },
    occludeMeshes: ['Body_Legs'],
    occludeBands: [[0.05, 1.0]],
  },
}

const Loader: React.FC = () => {
  const { progress } = useProgress()
  return (
    <Html center>
      <div style={{ font: '600 13px -apple-system', color: '#8C8C88' }}>
        {progress.toFixed(0)}%
      </div>
    </Html>
  )
}

export const FittingRoom: React.FC = () => {
  const [topKey, setTopKey] = React.useState<string | null>('tee')
  const [bottomKey, setBottomKey] = React.useState<string | null>('chinos')

  // Warm every mesh once: swapping then costs a material rebind, not a fetch.
  React.useEffect(() => {
    preloadOutfit([BODY, ...Object.values(CATALOGUE).map((g) => g.url)])
  }, [])

  return (
    <div style={{ position: 'fixed', inset: 0, background: '#F6F5F2' }}>
      <Canvas
        shadows
        camera={{ position: [0, 1.35, 3.4], fov: 34 }}
        gl={{ antialias: true, toneMapping: THREE.ACESFilmicToneMapping }}
        onCreated={({ gl }) => {
          gl.toneMappingExposure = 1.05
          gl.outputColorSpace = THREE.SRGBColorSpace
        }}
      >
        <hemisphereLight args={[0xffffff, 0xddd8d0, 0.9]} />
        <directionalLight position={[2.5, 4, 3]} intensity={1.6} castShadow shadow-mapSize={[2048, 2048]} />
        <directionalLight position={[-3, 3, -2]} intensity={0.6} />

        <React.Suspense fallback={<Loader />}>
          <Environment preset="studio" />
          <OutfitFitter
            bodyUrl={BODY}
            top={topKey ? CATALOGUE[topKey] : null}
            bottom={bottomKey ? CATALOGUE[bottomKey] : null}
          />
        </React.Suspense>

        <ContactShadows position={[0, 0, 0]} opacity={0.35} scale={4} blur={2.4} far={1.2} />
        <OrbitControls target={[0, 1, 0]} enableDamping minDistance={1.6} maxDistance={6}
                       maxPolarAngle={Math.PI * 0.62} />
      </Canvas>

      <div style={{ position: 'fixed', left: 0, right: 0, bottom: 0, display: 'flex',
                    gap: 8, justifyContent: 'center', padding: '14px 16px' }}>
        {(['tee', 'hoodie'] as const).map((k) => (
          <Chip key={k} label={k} on={topKey === k} onTap={() => setTopKey(topKey === k ? null : k)} />
        ))}
        <Chip label="chinos" on={bottomKey === 'chinos'}
              onTap={() => setBottomKey(bottomKey ? null : 'chinos')} />
      </div>
    </div>
  )
}

const Chip: React.FC<{ label: string; on: boolean; onTap: () => void }> = ({ label, on, onTap }) => (
  <button
    onClick={onTap}
    style={{
      padding: '10px 16px', borderRadius: 999, cursor: 'pointer',
      border: `1px solid ${on ? '#0A0A0A' : '#E4E4E1'}`,
      background: on ? '#0A0A0A' : '#fff', color: on ? '#fff' : '#0A0A0A',
      fontWeight: 700, fontSize: 13, textTransform: 'capitalize',
    }}
  >
    {label}
  </button>
)

export default FittingRoom
