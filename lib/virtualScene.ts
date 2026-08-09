// Three.js scene factory for the virtual camera feature.
// Owns the renderer/scene/camera and one actor; exposes update() for the
// per-frame animation tick and dispose() to release GPU resources.

import * as THREE from "three";
import { createActor, type Actor } from "./virtualActor";

export interface VirtualScene {
  renderer: THREE.WebGLRenderer;
  scene: THREE.Scene;
  camera: THREE.PerspectiveCamera;
  update: (elapsedSec: number) => void;
  render: () => void;
  resize: (w: number, h: number) => void;
  dispose: () => void;
}

// Camera sits at roughly human eye height at one end of the walker's path so
// the actor is visible under the default (yaw=0, pitch=0) pose.
const CAMERA_POS  = new THREE.Vector3(0, 1.55, 3.5);
const DEFAULT_FOV = 60;

export function createVirtualScene(canvas: HTMLCanvasElement): VirtualScene {
  const renderer = new THREE.WebGLRenderer({
    canvas,
    antialias: true,
    alpha: false,
  });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  renderer.setClearColor(0x1a2530);

  const scene = new THREE.Scene();
  scene.fog = new THREE.Fog(0x1a2530, 8, 25);

  // Camera. Aspect is fixed up by resize() on first mount.
  const camera = new THREE.PerspectiveCamera(DEFAULT_FOV, 16 / 9, 0.1, 100);
  camera.position.copy(CAMERA_POS);
  camera.rotation.order = "YXZ";

  // ── Lights ──────────────────────────────────────────────────────────
  const hemi = new THREE.HemisphereLight(0xd6e6ff, 0x2a2a2a, 0.75);
  scene.add(hemi);

  const dir = new THREE.DirectionalLight(0xffffff, 1.1);
  dir.position.set(5, 8, 4);
  scene.add(dir);

  // ── Floor ───────────────────────────────────────────────────────────
  const floor = new THREE.Mesh(
    new THREE.PlaneGeometry(30, 30),
    new THREE.MeshStandardMaterial({ color: 0x3f5060, roughness: 0.95 }),
  );
  floor.rotation.x = -Math.PI / 2;
  floor.position.y = 0;
  scene.add(floor);

  // Grid — subtle, gives the camera something to reveal scale/motion.
  const grid = new THREE.GridHelper(30, 30, 0x5a6b7a, 0x2a3540);
  (grid.material as THREE.Material).transparent = true;
  (grid.material as THREE.Material).opacity = 0.35;
  scene.add(grid);

  // ── Reference props ────────────────────────────────────────────────
  const boxMat = new THREE.MeshStandardMaterial({ color: 0xa26f3d, roughness: 0.85 });
  const box1 = new THREE.Mesh(new THREE.BoxGeometry(0.9, 0.9, 0.9), boxMat);
  box1.position.set(-2.2, 0.45, 0.4);
  scene.add(box1);
  const box2 = new THREE.Mesh(new THREE.BoxGeometry(0.6, 1.3, 0.6), boxMat);
  box2.position.set(2.2, 0.65, 0.2);
  scene.add(box2);

  // Back-wall marker so pan/tilt reveal movement even when the actor is offscreen.
  const wallMat = new THREE.MeshStandardMaterial({ color: 0x8a5a3c, roughness: 0.9 });
  const wall = new THREE.Mesh(new THREE.BoxGeometry(14, 4, 0.2), wallMat);
  wall.position.set(0, 2, -4);
  scene.add(wall);

  // ── Actor ──────────────────────────────────────────────────────────
  const actor: Actor = createActor();
  scene.add(actor.group);

  const update = (elapsedSec: number): void => {
    actor.update(elapsedSec);
  };

  const render = (): void => {
    renderer.render(scene, camera);
  };

  const resize = (w: number, h: number): void => {
    if (w <= 0 || h <= 0) return;
    renderer.setSize(w, h, false);
    camera.aspect = w / h;
    camera.updateProjectionMatrix();
  };

  const dispose = (): void => {
    scene.traverse((obj) => {
      const m = obj as THREE.Mesh;
      if (m.geometry) m.geometry.dispose();
      const mat = m.material as THREE.Material | THREE.Material[] | undefined;
      if (Array.isArray(mat)) mat.forEach((mm) => mm.dispose());
      else if (mat) mat.dispose();
    });
    renderer.dispose();
  };

  return { renderer, scene, camera, update, render, resize, dispose };
}
