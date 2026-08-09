// Procedural articulated human figure for the virtual camera scene.
// Roughly human proportions (~7 head-heights) so COCO-SSD's "person" class
// can detect it. Walking cycle is driven by sine waves at ~2 Hz; the pelvis
// follows a rectangular loop with a lookAt heading.
//
// Public API: createActor() → { group, update(elapsedSec) }

import * as THREE from "three";

export interface Actor {
  group: THREE.Group;
  update: (t: number) => void;
}

// Rough human proportions in metres.
const HEAD_R      = 0.11;
const TORSO_H     = 0.65;
const TORSO_W     = 0.34;
const TORSO_D     = 0.20;
const UPPER_ARM_L = 0.30;
const LOWER_ARM_L = 0.28;
const ARM_R       = 0.05;
const UPPER_LEG_L = 0.45;
const LOWER_LEG_L = 0.42;
const LEG_R       = 0.07;
const FOOT_L      = 0.24;

// Walking path — rectangle in world space, corners at these XZ points.
// The actor traces this loop at PATH_SPEED metres/sec.
const PATH: Array<[number, number]> = [
  [-2.5, -1.2],
  [ 2.5, -1.2],
  [ 2.5,  1.2],
  [-2.5,  1.2],
];
const PATH_SPEED = 0.8;

const STEP_HZ = 1.6;

// Materials shared between limbs — the flat solid tone helps the person
// classifier fire on the silhouette instead of getting distracted by texture.
const skinMat = new THREE.MeshStandardMaterial({ color: 0xd9a273, roughness: 0.85 });
const shirtMat = new THREE.MeshStandardMaterial({ color: 0x2563eb, roughness: 0.7 });
const pantsMat = new THREE.MeshStandardMaterial({ color: 0x1e293b, roughness: 0.9 });
const shoeMat  = new THREE.MeshStandardMaterial({ color: 0x0f172a, roughness: 0.6 });

function limbSegment(length: number, radius: number, mat: THREE.Material): THREE.Group {
  // A tapered cylinder pivoted at its top so a parent can rotate the joint.
  const geom = new THREE.CylinderGeometry(radius, radius * 0.9, length, 8);
  geom.translate(0, -length / 2, 0);
  const mesh = new THREE.Mesh(geom, mat);
  mesh.castShadow = true;
  const g = new THREE.Group();
  g.add(mesh);
  return g;
}

// Segments the walker exposes so update() can drive them.
interface Rig {
  root: THREE.Group;    // holds pelvis + everything above
  leftHip: THREE.Group;
  rightHip: THREE.Group;
  leftKnee: THREE.Group;
  rightKnee: THREE.Group;
  leftShoulder: THREE.Group;
  rightShoulder: THREE.Group;
  leftElbow: THREE.Group;
  rightElbow: THREE.Group;
  torso: THREE.Group;
}

function buildRig(): Rig {
  const root = new THREE.Group();

  // Pelvis at y ≈ UPPER_LEG_L + LOWER_LEG_L above feet
  const pelvisY = UPPER_LEG_L + LOWER_LEG_L;
  const pelvis = new THREE.Group();
  pelvis.position.y = pelvisY;
  root.add(pelvis);

  // Torso — pivot at its base (top of pelvis).
  const torso = new THREE.Group();
  const torsoBox = new THREE.Mesh(
    new THREE.BoxGeometry(TORSO_W, TORSO_H, TORSO_D),
    shirtMat,
  );
  torsoBox.position.y = TORSO_H / 2;
  torsoBox.castShadow = true;
  torso.add(torsoBox);
  pelvis.add(torso);

  // Head + neck
  const head = new THREE.Mesh(new THREE.SphereGeometry(HEAD_R, 20, 16), skinMat);
  head.position.y = TORSO_H + HEAD_R + 0.04;
  head.castShadow = true;
  torso.add(head);

  // Shoulders — sit at top of torso, offset outward.
  const shoulderY = TORSO_H - 0.03;
  const shoulderX = TORSO_W / 2 + ARM_R * 0.8;

  function buildArm(side: -1 | 1): { shoulder: THREE.Group; elbow: THREE.Group } {
    const shoulder = new THREE.Group();
    shoulder.position.set(side * shoulderX, shoulderY, 0);
    const upper = limbSegment(UPPER_ARM_L, ARM_R, skinMat);
    shoulder.add(upper);
    const elbow = new THREE.Group();
    elbow.position.y = -UPPER_ARM_L;
    upper.add(elbow);
    const lower = limbSegment(LOWER_ARM_L, ARM_R * 0.9, skinMat);
    elbow.add(lower);
    return { shoulder, elbow };
  }
  const larm = buildArm(-1);
  const rarm = buildArm(1);
  torso.add(larm.shoulder, rarm.shoulder);

  // Hips — sit at the pelvis, offset outward.
  const hipX = TORSO_W / 4 + LEG_R * 0.5;

  function buildLeg(side: -1 | 1): { hip: THREE.Group; knee: THREE.Group } {
    const hip = new THREE.Group();
    hip.position.set(side * hipX, 0, 0);
    const upper = limbSegment(UPPER_LEG_L, LEG_R, pantsMat);
    hip.add(upper);
    const knee = new THREE.Group();
    knee.position.y = -UPPER_LEG_L;
    upper.add(knee);
    const lower = limbSegment(LOWER_LEG_L, LEG_R * 0.85, pantsMat);
    knee.add(lower);
    // Foot at bottom of lower leg
    const foot = new THREE.Mesh(
      new THREE.BoxGeometry(LEG_R * 1.8, LEG_R * 0.9, FOOT_L),
      shoeMat,
    );
    foot.position.set(0, -LOWER_LEG_L - LEG_R * 0.45, FOOT_L / 2 - LEG_R * 0.6);
    foot.castShadow = true;
    lower.add(foot);
    return { hip, knee };
  }
  const lleg = buildLeg(-1);
  const rleg = buildLeg(1);
  pelvis.add(lleg.hip, rleg.hip);

  return {
    root,
    torso,
    leftShoulder: larm.shoulder,
    rightShoulder: rarm.shoulder,
    leftElbow: larm.elbow,
    rightElbow: rarm.elbow,
    leftHip: lleg.hip,
    rightHip: rleg.hip,
    leftKnee: lleg.knee,
    rightKnee: rleg.knee,
  };
}

// Interpolate the actor's position around the closed path at speed s.
function pointOnPath(distance: number): { x: number; z: number; heading: number } {
  const segs: Array<{ ax: number; az: number; bx: number; bz: number; len: number }> = [];
  let total = 0;
  for (let i = 0; i < PATH.length; i++) {
    const [ax, az] = PATH[i];
    const [bx, bz] = PATH[(i + 1) % PATH.length];
    const dx = bx - ax;
    const dz = bz - az;
    const len = Math.hypot(dx, dz);
    segs.push({ ax, az, bx, bz, len });
    total += len;
  }
  let d = ((distance % total) + total) % total;
  for (const s of segs) {
    if (d <= s.len) {
      const t = d / s.len;
      const x = s.ax + (s.bx - s.ax) * t;
      const z = s.az + (s.bz - s.az) * t;
      const heading = Math.atan2(s.bx - s.ax, s.bz - s.az);
      return { x, z, heading };
    }
    d -= s.len;
  }
  return { x: 0, z: 0, heading: 0 };
}

export function createActor(): Actor {
  const rig = buildRig();

  const update = (t: number): void => {
    // Position along the path.
    const p = pointOnPath(t * PATH_SPEED);
    rig.root.position.x = p.x;
    rig.root.position.z = p.z;
    rig.root.rotation.y = p.heading;

    // Walking cycle — hips swing opposite, knees bend on the up-swing, arms
    // counter-swing to the legs. Amplitude picked to look clearly like walking.
    const phase = t * STEP_HZ * Math.PI * 2;
    const hipSwing = Math.sin(phase) * 0.55;
    // Knee bend spikes when the foot is coming forward (positive hipSwing).
    const kneeBendL = Math.max(0, Math.sin(phase))       * 1.05;
    const kneeBendR = Math.max(0, Math.sin(phase + Math.PI)) * 1.05;

    rig.leftHip.rotation.x  =  hipSwing;
    rig.rightHip.rotation.x = -hipSwing;
    // Knees flex the lower leg backward (foot kicks up behind) — positive
    // rotation.x, since the lower leg points down and toes point +Z.
    rig.leftKnee.rotation.x  = kneeBendL;
    rig.rightKnee.rotation.x = kneeBendR;

    // Arms swing counter to legs; small elbow bend.
    rig.leftShoulder.rotation.x  = -hipSwing * 0.9;
    rig.rightShoulder.rotation.x =  hipSwing * 0.9;
    rig.leftElbow.rotation.x  = -0.25 - kneeBendR * 0.15;
    rig.rightElbow.rotation.x = -0.25 - kneeBendL * 0.15;

    // Slight torso bob and lean into the step.
    const bob = Math.abs(Math.sin(phase * 2)) * 0.03;
    rig.root.position.y = bob;
    rig.torso.rotation.z = Math.sin(phase) * 0.05;
  };

  return { group: rig.root, update };
}
