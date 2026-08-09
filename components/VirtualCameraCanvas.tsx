"use client";
// Renders the virtual 3D scene into a <canvas> and drives its rAF loop.
// Owns the THREE resources for the lifetime of the mount, and forwards the
// underlying canvas ref up so TrackingCanvas can pull frames off it.

import { useEffect, useRef, forwardRef, useImperativeHandle } from "react";
import { createVirtualScene, type VirtualScene } from "@/lib/virtualScene";
import type { VirtualPtzController } from "@/lib/virtualPtz";

interface Props {
  controller: VirtualPtzController | null;
  cameraId: string;
}

const VirtualCameraCanvas = forwardRef<HTMLCanvasElement, Props>(function VirtualCameraCanvas(
  { controller },
  ref,
) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  useImperativeHandle(ref, () => canvasRef.current!, []);

  const controllerRef = useRef(controller);
  controllerRef.current = controller;

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;

    // Size the drawing buffer to the on-screen size at mount.
    const initialRect = canvas.getBoundingClientRect();
    const scene: VirtualScene = createVirtualScene(canvas);
    scene.resize(Math.round(initialRect.width), Math.round(initialRect.height));

    // Keep the buffer in sync with the container.
    const resizeObserver = new ResizeObserver((entries) => {
      const entry = entries[0];
      if (!entry) return;
      const { width, height } = entry.contentRect;
      scene.resize(Math.round(width), Math.round(height));
    });
    resizeObserver.observe(canvas);

    let rafId = 0;
    let lastTime = performance.now();
    const startTime = lastTime;

    const loop = (now: number): void => {
      const dt = now - lastTime;
      lastTime = now;
      const elapsed = (now - startTime) / 1000;

      const ctrl = controllerRef.current;
      if (ctrl) {
        ctrl.tick(dt);
        ctrl.apply(scene.camera);
      }
      scene.update(elapsed);
      scene.render();

      rafId = requestAnimationFrame(loop);
    };
    rafId = requestAnimationFrame(loop);

    return () => {
      cancelAnimationFrame(rafId);
      resizeObserver.disconnect();
      controllerRef.current?.flush();
      scene.dispose();
    };
  }, []);

  return (
    <canvas
      ref={canvasRef}
      className="w-full h-full block"
      style={{ display: "block" }}
    />
  );
});

export default VirtualCameraCanvas;
