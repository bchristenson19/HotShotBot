"use client";
// Lightweight registry of VirtualPtzController instances keyed by camera id.
// Mirrors the map-per-camera pattern in useMultiCameraTracking.
//
// Controllers are created lazily on first access so a virtual camera that is
// never selected doesn't allocate one.

import { useRef, useCallback, useEffect } from "react";
import { VirtualPtzController } from "@/lib/virtualPtz";

export function useVirtualPtz() {
  const controllers = useRef<Map<string, VirtualPtzController>>(new Map());

  const getController = useCallback((cameraId: string): VirtualPtzController => {
    let c = controllers.current.get(cameraId);
    if (!c) {
      c = new VirtualPtzController(cameraId);
      controllers.current.set(cameraId, c);
    }
    return c;
  }, []);

  const execCommand = useCallback((
    cameraId: string,
    cmd: string,
    endpoint: "aw_ptz" | "aw_cam" = "aw_ptz",
  ): void => {
    getController(cameraId).execCommand(cmd, endpoint);
  }, [getController]);

  // Persist any pending preset saves on unmount / page nav.
  useEffect(() => {
    const map = controllers.current;
    return () => {
      map.forEach((c) => c.flush());
    };
  }, []);

  return { getController, execCommand };
}
