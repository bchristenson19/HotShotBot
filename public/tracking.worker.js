// Tracking Web Worker — runs TF.js + COCO-SSD fully off the main thread.
// One instance per camera. Receives ImageData frames, sends back detections + PTZ commands.

let model = null;
let lockedBox = null;
let inferring = false;

// Smoothed position — exponential moving average to reduce jitter
let smoothX = 0.5;
let smoothY = 0.5;
let smoothH = 0;
const SMOOTH = 0.35; // 0=no smoothing, 1=instant. Lower = smoother but more lag

const DEFAULT_DEAD_ZONE = 0.04;
const DEFAULT_ZOOM_DEAD_ZONE = 0.06;
// targetH = desired bounding box height as fraction of frame height.
// full: whole person visible, box fills ~80% of frame height
// mid:  waist-up only — zoom in until box is ~1.8× frame height (top 50% of body fills frame)
const SHOT_PRESETS = { full: 0.80, mid: 1.80, none: null };

// Tilt target Y per preset — where to aim the vertical anchor point in the frame
// full: center the whole body → anchor = box center → target = 0.5
// mid:  show head to waist → anchor = head → target = 0.22 (upper quarter)
// All presets anchor on the head — ensures head is always in frame.
// targetY = where the head should sit vertically (0 = top, 1 = bottom).
// full: head near top so feet have room below (~15% from top)
// mid:  head higher in frame for waist-up framing (~20% from top)
// none: head at comfortable upper-third (~28% from top)
const TILT_TARGETS = {
  full: { targetY: 0.15 },
  mid:  { targetY: 0.20 },
  none: { targetY: 0.28 },
};

const HEAD_OFFSET = 0.04; // fraction of box height from top where head sits

async function loadModel() {
  // Derive the base URL from the worker's own location (e.g. http://localhost:3000)
  const base = self.location.origin;

  importScripts(
    `${base}/tfjs/tf.min.js`,
    `${base}/tfjs/tf-backend-webgl.min.js`,
    `${base}/tfjs/coco-ssd.min.js`
  );

  const backend = await tf.setBackend("webgpu").then(() => "webgpu").catch(async () => {
    await tf.setBackend("webgl");
    return "webgl";
  });
  await tf.ready();
  console.log(`[HotShotBot worker] backend: ${backend}`);

  model = await cocoSsd.load({
    base: "mobilenet_v2",
    modelUrl: `${base}/tfjs/models/coco-ssd/model.json`,
  });
  postMessage({ type: "ready" });
}

function trackAxis(offset, speed, deadZone) {
  const abs = Math.abs(offset);
  if (abs < deadZone) return 0;
  const dir = offset > 0 ? 1 : -1;
  // Proportional zone is wider (6x dead zone) so camera ramps up gently
  const fastZone = deadZone * 6;
  if (abs > fastZone) return dir * speed;
  return dir * ((abs - deadZone) / (fastZone - deadZone)) * speed;
}

async function processFrame(imageData, width, height, speed, shotPreset, deadZone) {
  deadZone = deadZone ?? DEFAULT_DEAD_ZONE;
  const zoomDeadZone = deadZone * 1.5;
  if (!model || inferring) return;
  inferring = true;

  try {
    console.log(`[HotShotBot worker] frame ${width}x${height}`);
    const bmp = await createImageBitmap(imageData);
    const preds = await model.detect(bmp);
    bmp.close();
    console.log(`[HotShotBot worker] detections:`, preds.map(p => `${p.class} ${Math.round(p.score*100)}%`).join(', ') || 'none');

    const people = preds.filter(p => p.class === "person");
    const dets = people.map((p, i) => ({
      x: p.bbox[0] / width,
      y: p.bbox[1] / height,
      w: p.bbox[2] / width,
      h: p.bbox[3] / height,
      score: p.score,
      id: i,
    }));

    if (!lockedBox) {
      postMessage({ type: "result", detections: dets, trackingState: dets.length > 0 ? "detecting" : "idle", lockedBox: null, pan: 0, tilt: 0, zoom: 0 });
      return;
    }

    // Find best match by position AND size, gated tightly enough that a
    // different person walking near the locked one can't hijack the lock —
    // center-distance alone (old behavior) allowed matches nearly half the
    // frame away, so tracking would jump to whoever was nearest, not
    // necessarily the person originally clicked.
    const lx = lockedBox.x + lockedBox.w / 2;
    const ly = lockedBox.y + lockedBox.h / 2;
    const lh = lockedBox.h;
    // Positional tolerance scales with the locked box's own height — a
    // person close to camera (tall box) can shift further between frames in
    // normalized units than one far away (short box).
    const posTolerance = Math.max(0.08, lh * 0.6);
    let best = null, bestCost = Infinity;
    for (const d of dets) {
      const dist = Math.hypot((d.x + d.w / 2) - lx, (d.y + d.h / 2) - ly);
      if (dist > posTolerance) continue;
      const sizeRatio = d.h / lh;
      if (sizeRatio < 0.5 || sizeRatio > 2.0) continue; // different-sized person, not the same one closer/further
      const cost = dist / posTolerance + Math.abs(Math.log(sizeRatio));
      if (cost < bestCost) { bestCost = cost; best = d; }
    }

    if (!best) {
      postMessage({ type: "result", detections: dets, trackingState: "lost", lockedBox, pan: 0, tilt: 0, zoom: 0 });
      return;
    }

    lockedBox = best;

    // Smooth detected position with EMA to absorb frame-to-frame jitter
    const rawCx = best.x + best.w / 2;
    const rawHeadY = best.y + best.h * HEAD_OFFSET;
    smoothX = smoothX + (rawCx - smoothX) * SMOOTH;
    smoothY = smoothY + (rawHeadY - smoothY) * SMOOTH;
    smoothH = smoothH + (best.h - smoothH) * SMOOTH;

    // Pan on smoothed center X
    const pan = trackAxis(smoothX - 0.5, speed, deadZone);

    // Tilt on smoothed head Y
    const tiltTarget = TILT_TARGETS[shotPreset] ?? TILT_TARGETS.none;
    const tilt = trackAxis(smoothY - tiltTarget.targetY, speed, deadZone);

    // Zoom on smoothed box height
    let zoom = 0;
    const targetH = SHOT_PRESETS[shotPreset] ?? null;
    if (targetH !== null) {
      const err = smoothH - targetH;
      if (Math.abs(err) > zoomDeadZone) {
        zoom = Math.max(-1, Math.min(1, -err * speed * 1.5));
      }
    }

    postMessage({ type: "result", detections: dets, trackingState: "tracking", lockedBox: best, pan, tilt, zoom });
  } catch (e) {
    postMessage({ type: "error", message: e.message });
  } finally {
    inferring = false;
  }
}

self.onmessage = async (e) => {
  const { type } = e.data;
  if (type === "init") {
    await loadModel();
  } else if (type === "frame") {
    const { imageData, width, height, speed, shotPreset, deadZone } = e.data;
    await processFrame(imageData, width, height, speed, shotPreset, deadZone);
  } else if (type === "lock") {
    lockedBox = e.data.box;
    // Seed smoothed position from the locked box so there's no initial lurch
    smoothX = lockedBox.x + lockedBox.w / 2;
    smoothY = lockedBox.y + lockedBox.h * HEAD_OFFSET;
    smoothH = lockedBox.h;
  } else if (type === "unlock") {
    lockedBox = null;
  }
};
