"use client";
import { useRef, useEffect, useCallback } from "react";
import type { TrackingState, Detection } from "@/hooks/useMultiCameraTracking";

type FrameSource = HTMLImageElement | HTMLCanvasElement;

interface Props {
  sourceRef: React.RefObject<FrameSource | null>;
  streamLive: boolean;
  // Worker results passed in from parent
  detections: Detection[];
  trackingState: TrackingState;
  lockedBox: Detection | null;
  workerReady: boolean;
  // Frame sender — parent calls this each interval
  onSendFrame: (imageData: ImageData, w: number, h: number) => void;
  onLock: (box: Detection) => void;
  onUnlock: () => void;
}

const CAPTURE_W = 640;
const CAPTURE_H = 360;
const FRAME_INTERVAL_MS = 150; // ~6-7fps inference — less hectic than 10fps

// Return the source's intrinsic pixel size. Images expose naturalWidth/Height,
// canvases expose width/height directly.
function dims(el: FrameSource | null): { w: number; h: number } {
  if (!el) return { w: 0, h: 0 };
  if (el instanceof HTMLCanvasElement) return { w: el.width, h: el.height };
  return { w: el.naturalWidth, h: el.naturalHeight };
}

export default function TrackingCanvas({
  sourceRef, streamLive,
  detections, trackingState, lockedBox, workerReady,
  onSendFrame, onLock, onUnlock,
}: Props) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const captureCanvas = useRef<HTMLCanvasElement | null>(null);
  const rafRef = useRef<number | null>(null);
  const frameTimerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const onSendFrameRef = useRef(onSendFrame);
  onSendFrameRef.current = onSendFrame;

  // Frame capture loop — extracts ImageData and sends to worker
  useEffect(() => {
    if (!streamLive || !workerReady) return;

    if (!captureCanvas.current) {
      captureCanvas.current = document.createElement("canvas");
      captureCanvas.current.width = CAPTURE_W;
      captureCanvas.current.height = CAPTURE_H;
    }

    frameTimerRef.current = setInterval(() => {
      const src = sourceRef.current;
      const cc = captureCanvas.current;
      if (!src || !cc) return;
      const { w, h } = dims(src);
      if (w === 0 || h === 0) return;
      if (src instanceof HTMLImageElement && !src.complete) return;
      const ctx = cc.getContext("2d", { willReadFrequently: true });
      if (!ctx) return;
      ctx.drawImage(src, 0, 0, CAPTURE_W, CAPTURE_H);
      const imageData = ctx.getImageData(0, 0, CAPTURE_W, CAPTURE_H);
      onSendFrameRef.current(imageData, CAPTURE_W, CAPTURE_H);
    }, FRAME_INTERVAL_MS);

    return () => {
      if (frameTimerRef.current) clearInterval(frameTimerRef.current);
    };
  }, [streamLive, workerReady, sourceRef]);

  // Draw loop — renders detection boxes onto the overlay canvas
  useEffect(() => {
    if (!streamLive) return;

    function draw() {
      const canvas = canvasRef.current;
      if (!canvas) { rafRef.current = requestAnimationFrame(draw); return; }
      const ctx = canvas.getContext("2d");
      if (!ctx) { rafRef.current = requestAnimationFrame(draw); return; }

      const { width, height } = canvas.getBoundingClientRect();
      if (canvas.width !== Math.round(width) || canvas.height !== Math.round(height)) {
        canvas.width = Math.round(width);
        canvas.height = Math.round(height);
      }

      ctx.clearRect(0, 0, canvas.width, canvas.height);
      const W = canvas.width;
      const H = canvas.height;

      // Compute object-contain image rect
      const src = sourceRef.current;
      const { w: srcW, h: srcH } = dims(src);
      const imgAspect = srcW ? srcW / srcH : 16 / 9;
      const canvasAspect = W / H;
      let imgW: number, imgH: number, imgX: number, imgY: number;
      if (imgAspect > canvasAspect) {
        imgW = W; imgH = W / imgAspect; imgX = 0; imgY = (H - imgH) / 2;
      } else {
        imgH = H; imgW = H * imgAspect; imgX = (W - imgW) / 2; imgY = 0;
      }

      function mapX(nx: number) { return imgX + nx * imgW; }
      function mapY(ny: number) { return imgY + ny * imgH; }

      for (const d of detections) {
        const isLocked = lockedBox &&
          Math.abs((d.x + d.w / 2) - (lockedBox.x + lockedBox.w / 2)) < 0.15 &&
          Math.abs((d.y + d.h / 2) - (lockedBox.y + lockedBox.h / 2)) < 0.15;

        const bx = mapX(d.x), by = mapY(d.y);
        const bw = d.w * imgW, bh = d.h * imgH;

        if (isLocked) {
          ctx.strokeStyle = trackingState === "lost" ? "#ef4444" : "#22c55e";
          ctx.lineWidth = 3;
          ctx.strokeRect(bx, by, bw, bh);

          const c = Math.min(18, bw * 0.25, bh * 0.25);
          ctx.lineWidth = 4;
          const corners: [number, number, number, number, number, number][] = [
            [bx, by, c, 0, 0, c], [bx + bw, by, -c, 0, 0, c],
            [bx, by + bh, c, 0, 0, -c], [bx + bw, by + bh, -c, 0, 0, -c],
          ];
          for (const [x, y, dx1, dy1, dx2, dy2] of corners) {
            ctx.beginPath();
            ctx.moveTo(x + dx1, y + dy1); ctx.lineTo(x, y); ctx.lineTo(x + dx2, y + dy2);
            ctx.stroke();
          }
          ctx.fillStyle = trackingState === "lost" ? "#ef4444" : "#22c55e";
          ctx.beginPath();
          ctx.arc(bx + bw / 2, by + bh / 2, 4, 0, Math.PI * 2);
          ctx.fill();
        } else {
          ctx.strokeStyle = "rgba(96,165,250,0.7)";
          ctx.lineWidth = 1.5;
          ctx.strokeRect(bx, by, bw, bh);
          ctx.fillStyle = "rgba(96,165,250,0.85)";
          ctx.font = "11px system-ui";
          ctx.fillText(`${Math.round(d.score * 100)}%`, bx + 3, by + 13);
        }
      }

      if (lockedBox) {
        const cx = imgX + imgW / 2, cy = imgY + imgH / 2;
        ctx.strokeStyle = "rgba(255,255,255,0.2)";
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.moveTo(cx - 14, cy); ctx.lineTo(cx + 14, cy);
        ctx.moveTo(cx, cy - 14); ctx.lineTo(cx, cy + 14);
        ctx.stroke();
      }

      rafRef.current = requestAnimationFrame(draw);
    }

    rafRef.current = requestAnimationFrame(draw);
    return () => { if (rafRef.current) cancelAnimationFrame(rafRef.current); };
  }, [streamLive, detections, lockedBox, trackingState, sourceRef]);

  const handleClick = useCallback((e: React.MouseEvent<HTMLCanvasElement>) => {
    if (lockedBox) { onUnlock(); return; }

    const canvas = canvasRef.current;
    const src = sourceRef.current;
    if (!canvas) return;

    const rect = canvas.getBoundingClientRect();
    const cx = (e.clientX - rect.left) / rect.width * canvas.width;
    const cy = (e.clientY - rect.top) / rect.height * canvas.height;
    const W = canvas.width, H = canvas.height;
    const { w: srcW, h: srcH } = dims(src);
    const imgAspect = srcW ? srcW / srcH : 16 / 9;
    const ca = W / H;
    let imgW: number, imgH: number, imgX: number, imgY: number;
    if (imgAspect > ca) { imgW = W; imgH = W / imgAspect; imgX = 0; imgY = (H - imgH) / 2; }
    else { imgH = H; imgW = H * imgAspect; imgX = (W - imgW) / 2; imgY = 0; }
    const nx = (cx - imgX) / imgW, ny = (cy - imgY) / imgH;

    for (const d of detections) {
      if (nx >= d.x && nx <= d.x + d.w && ny >= d.y && ny <= d.y + d.h) {
        onLock(d); return;
      }
    }
  }, [lockedBox, detections, onLock, onUnlock, sourceRef]);

  return (
    <canvas
      ref={canvasRef}
      onClick={handleClick}
      className="absolute inset-0 w-full h-full"
      style={{
        cursor: lockedBox ? "default" : detections.length > 0 ? "pointer" : "crosshair",
        outline: "none",
      }}
    />
  );
}
