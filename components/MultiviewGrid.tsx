"use client";
// Broadcast-style multiview: shows every configured camera's live feed at once
// in a grid. Click a tile to make that camera active (and return to the normal
// single-camera control view). Purely a monitoring surface — it doesn't feed
// the tracking worker; background tracking still runs via FrameCapture in page.tsx.
import { useState } from "react";
import type { Camera } from "@/lib/ptz";
import { defaultStreamUrl, isVirtual } from "@/lib/ptz";
import type { VirtualPtzController } from "@/lib/virtualPtz";
import type { TrackingState } from "@/hooks/useMultiCameraTracking";
import VirtualCameraCanvas from "@/components/VirtualCameraCanvas";

interface TrackingInfo {
  enabled: boolean;
  state: TrackingState;
}

interface Props {
  cameras: Camera[];
  activeCamIndex: number;
  onSelect: (index: number) => void;
  getVirtualController: (cameraId: string) => VirtualPtzController;
  getTrackingInfo: (cameraId: string) => TrackingInfo;
}

export default function MultiviewGrid({ cameras, activeCamIndex, onSelect, getVirtualController, getTrackingInfo }: Props) {
  const gridCols = cameras.length <= 1 ? "grid-cols-1" : "grid-cols-2";
  return (
    <div className={`grid ${gridCols} auto-rows-fr gap-3 flex-1 min-h-0`}>
      {cameras.map((cam, i) => (
        <MultiviewTile
          key={cam.id}
          camera={cam}
          isActive={i === activeCamIndex}
          onClick={() => onSelect(i)}
          virtualController={isVirtual(cam) ? getVirtualController(cam.id) : null}
          tracking={getTrackingInfo(cam.id)}
        />
      ))}
    </div>
  );
}

function MultiviewTile({
  camera, isActive, onClick, virtualController, tracking,
}: {
  camera: Camera;
  isActive: boolean;
  onClick: () => void;
  virtualController: VirtualPtzController | null;
  tracking: TrackingInfo;
}) {
  const virtual = isVirtual(camera);
  const url = camera.streamUrl || defaultStreamUrl(camera);
  const [status, setStatus] = useState<"loading" | "live" | "error">(virtual ? "live" : "loading");
  // Reset to loading whenever the URL changes, without an effect — mirrors the
  // "adjust state during render" pattern React recommends over useEffect+setState.
  const [prevUrl, setPrevUrl] = useState(url);
  if (!virtual && url !== prevUrl) {
    setPrevUrl(url);
    setStatus("loading");
  }

  return (
    <button
      onClick={onClick}
      className={`relative bg-black rounded-xl overflow-hidden border-2 text-left transition-colors focus:outline-none ${
        isActive ? "border-blue-500" : "border-zinc-800 hover:border-zinc-600"
      }`}
      style={{ aspectRatio: "16 / 9" }}
    >
      {virtual ? (
        <VirtualCameraCanvas controller={virtualController} cameraId={camera.id} />
      ) : url ? (
        // eslint-disable-next-line @next/next/no-img-element
        <img
          src={url}
          alt={camera.name}
          className={`w-full h-full object-contain transition-opacity duration-300 ${status === "live" ? "opacity-100" : "opacity-0"}`}
          onLoad={() => setStatus("live")}
          onError={() => setStatus("error")}
        />
      ) : null}

      {!virtual && status !== "live" && (
        <div className="absolute inset-0 flex items-center justify-center">
          {!url ? (
            <span className="text-zinc-600 text-xs">No IP configured</span>
          ) : status === "error" ? (
            <span className="text-zinc-600 text-xs">Unavailable</span>
          ) : (
            <div className="w-5 h-5 border-2 border-zinc-600 border-t-blue-500 rounded-full animate-spin" />
          )}
        </div>
      )}

      <div className="absolute top-2 left-2 flex items-center gap-1.5">
        <div className="w-1.5 h-1.5 rounded-full shrink-0" style={{ background: camera.color ?? "#1d4ed8" }} />
        <span className="text-white text-xs font-semibold bg-black/60 backdrop-blur-sm px-1.5 py-0.5 rounded-full">
          {camera.name}
        </span>
      </div>

      {tracking.enabled && (
        <div
          className={`absolute top-2 right-2 text-[10px] font-semibold px-1.5 py-0.5 rounded-full backdrop-blur-sm ${
            tracking.state === "tracking"
              ? "bg-green-500/80 text-white"
              : tracking.state === "lost"
              ? "bg-red-500/80 text-white"
              : "bg-black/50 text-zinc-300"
          }`}
        >
          {tracking.state === "tracking" ? "TRACKING" : tracking.state === "lost" ? "LOST" : "SCAN"}
        </div>
      )}

      {isActive && (
        <div className="absolute bottom-2 left-2 text-[10px] font-semibold text-blue-300 bg-blue-600/20 px-1.5 py-0.5 rounded-full">
          ACTIVE
        </div>
      )}
    </button>
  );
}
