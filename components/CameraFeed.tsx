"use client";
import { useState, useEffect, useRef, useCallback } from "react";
import type { Camera } from "@/lib/ptz";
import { defaultStreamUrl, isVirtual } from "@/lib/ptz";
import type { CameraStatus } from "@/hooks/useCameraStatus";
import ControlsOverlay from "@/components/ControlsOverlay";
import TrackingCanvas from "@/components/TrackingCanvas";
import VirtualCameraCanvas from "@/components/VirtualCameraCanvas";
import type { VirtualPtzController } from "@/lib/virtualPtz";
import type { GamepadState } from "@/hooks/useGamepad";
import type { ControlMapping } from "@/lib/mapping";
import type { TrackingState, Detection } from "@/hooks/useMultiCameraTracking";

interface Props {
  camera: Camera;
  autoFocus: boolean;
  gain: string;
  status: CameraStatus | null;
  statusError: boolean;
  showControls: boolean;
  padState: GamepadState;
  mapping: ControlMapping;
  profileName: string | null;
  // Tracking
  trackingEnabled: boolean;
  workerReady: boolean;
  detections: Detection[];
  trackingState: TrackingState;
  lockedBox: Detection | null;
  onSendFrame: (imageData: ImageData, w: number, h: number) => void;
  onLockTarget: (box: Detection) => void;
  onClearLock: () => void;
  // Virtual camera — non-null when camera.model === "virtual"
  virtualController?: VirtualPtzController | null;
}

export default function CameraFeed({ camera, autoFocus, gain, status, statusError, showControls, padState, mapping, profileName, trackingEnabled, workerReady, detections, trackingState: trackingDisplayState, lockedBox, onSendFrame, onLockTarget, onClearLock, virtualController }: Props) {
  const virtual = isVirtual(camera);
  const rawUrl = camera.streamUrl || defaultStreamUrl(camera);
  // In Electron (webSecurity:false) canvas reads cross-origin directly — no proxy needed.
  // typeof check keeps SSR happy; the value is stable after first client render.
  const isElectron = typeof window !== "undefined" && !!window.electronAPI;
  // Never use the proxy in Electron — always stream directly from the camera IP.
  const url = trackingEnabled && rawUrl && !isElectron
    ? `/api/stream?url=${encodeURIComponent(rawUrl)}`
    : rawUrl;
  // Only tracks the MJPEG <img> load lifecycle. For virtual cams we derive
  // streamStatus below without touching this state.
  const [rawStreamStatus, setStreamStatus] = useState<"loading" | "live" | "error">("loading");
  const streamStatus: "loading" | "live" | "error" = virtual ? "live" : rawStreamStatus;
  const [isFullscreen, setIsFullscreen] = useState(false);
  const detectionCount = detections.length;
  const imgRef = useRef<HTMLImageElement>(null);
  const virtualCanvasRef = useRef<HTMLCanvasElement>(null);
  // Source ref handed to TrackingCanvas — either the MJPEG <img> or the 3D <canvas>
  const sourceRef = useRef<HTMLImageElement | HTMLCanvasElement | null>(null);
  const containerRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    // Virtual cams stay "live"; only reset when the URL changes, not on tracking toggle.
    if (!virtual) setStreamStatus("loading");
  }, [url, virtual]);

  useEffect(() => {
    function onFsChange() {
      setIsFullscreen(!!document.fullscreenElement);
    }
    document.addEventListener("fullscreenchange", onFsChange);
    return () => document.removeEventListener("fullscreenchange", onFsChange);
  }, []);

  const toggleFullscreen = useCallback(() => {
    if (!containerRef.current) return;
    if (!document.fullscreenElement) {
      containerRef.current.requestFullscreen();
    } else {
      document.exitFullscreen();
    }
  }, []);

  if (!url && !virtual) {
    return (
      <div className="w-full aspect-video bg-zinc-900 border border-zinc-800 rounded-2xl flex items-center justify-center">
        <p className="text-zinc-600 text-sm">No IP configured — add camera IP in Settings</p>
      </div>
    );
  }

  return (
    <div ref={containerRef} className="relative w-full aspect-video bg-black rounded-2xl overflow-hidden border border-zinc-800 group">
      {virtual ? (
        /* 3D scene — replaces MJPEG stream */
        <VirtualCameraCanvas
          ref={(el) => { virtualCanvasRef.current = el; sourceRef.current = el; }}
          controller={virtualController ?? null}
          cameraId={camera.id}
        />
      ) : (
        <>
          {/* MJPEG stream */}
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img
            ref={(el) => { imgRef.current = el; sourceRef.current = el; }}
            src={url}
            alt="Camera feed"
            crossOrigin={trackingEnabled && !isElectron ? "anonymous" : undefined}
            className={`w-full h-full object-contain transition-opacity duration-300 ${streamStatus === "live" ? "opacity-100" : "opacity-0"}`}
            onLoad={() => setStreamStatus("live")}
            onError={() => setStreamStatus("error")}
          />
        </>
      )}

      {/* Loading */}
      {streamStatus === "loading" && (
        <div className="absolute inset-0 flex flex-col items-center justify-center gap-3">
          <div className="w-8 h-8 border-2 border-zinc-600 border-t-blue-500 rounded-full animate-spin" />
          <p className="text-zinc-500 text-xs">Connecting to stream…</p>
          <p className="text-zinc-700 text-[10px] font-mono truncate max-w-xs">{url}</p>
        </div>
      )}

      {/* Error */}
      {streamStatus === "error" && (
        <div className="absolute inset-0 flex flex-col items-center justify-center gap-3">
          <div className="text-3xl">📷</div>
          <p className="text-zinc-400 text-sm">Stream unavailable</p>
          <p className="text-zinc-600 text-xs max-w-xs text-center">
            Check the camera is on the network and the stream URL is correct
          </p>
          <button
            onClick={() => {
              setStreamStatus("loading");
              if (imgRef.current) {
                imgRef.current.src = url + (url.includes("?") ? "&" : "?") + "_r=" + Date.now();
              }
            }}
            className="mt-1 text-xs text-blue-400 hover:text-blue-300 transition-colors"
          >
            Retry
          </button>
          <p className="text-zinc-700 text-[10px] font-mono truncate max-w-xs">{url}</p>
        </div>
      )}

      {/* ── Overlay (only when stream is live) ── */}
      {streamStatus === "live" && (
        <>
          {/* Tracking canvas — sits on top of stream, captures clicks */}
          {trackingEnabled && (
            <TrackingCanvas
              sourceRef={sourceRef}
              streamLive={streamStatus === "live"}
              detections={detections}
              trackingState={trackingDisplayState}
              lockedBox={lockedBox}
              workerReady={workerReady}
              onSendFrame={onSendFrame}
              onLock={onLockTarget}
              onUnlock={onClearLock}
            />
          )}

          {/* Top-left: LIVE badge + profile name + tracking state */}
          <div className="absolute top-3 left-3 flex items-center gap-2 pointer-events-none">
            <div className="flex items-center gap-1.5 bg-black/60 backdrop-blur-sm px-2 py-1 rounded-full">
              <div className="w-1.5 h-1.5 rounded-full bg-red-500 animate-pulse" />
              <span className="text-white text-[10px] font-semibold tracking-wider">LIVE</span>
            </div>
            {profileName && (
              <div className="bg-blue-600/60 backdrop-blur-sm px-2 py-1 rounded-full">
                <span className="text-white text-[10px] font-medium">{profileName}</span>
              </div>
            )}
            {trackingEnabled && trackingDisplayState === "tracking" && (
              <div className="bg-green-500/80 backdrop-blur-sm px-2 py-1 rounded-full text-[10px] font-semibold text-white">TRACKING</div>
            )}
            {trackingEnabled && trackingDisplayState === "lost" && (
              <div className="bg-red-500/80 backdrop-blur-sm px-2 py-1 rounded-full text-[10px] font-semibold text-white">LOST</div>
            )}
            {trackingEnabled && (trackingDisplayState === "detecting" || trackingDisplayState === "idle") && detectionCount > 0 && (
              <div className="bg-blue-500/70 backdrop-blur-sm px-2 py-1 rounded-full text-[10px] font-semibold text-white">
                {detectionCount} person{detectionCount > 1 ? "s" : ""} — click to track
              </div>
            )}
            {trackingEnabled && detectionCount === 0 && (trackingDisplayState === "idle" || trackingDisplayState === "detecting") && (
              <div className="bg-black/50 backdrop-blur-sm px-2 py-1 rounded-full text-[10px] text-zinc-400">
                Scanning…
              </div>
            )}
          </div>

          {/* Top-right: AF indicator + fullscreen */}
          <div className="absolute top-3 right-3 flex items-center gap-2">
            <div className={`px-2 py-1 rounded-full text-[10px] font-semibold backdrop-blur-sm ${
              autoFocus ? "bg-green-500/70 text-white" : "bg-black/60 text-zinc-400"
            }`}>
              {autoFocus ? "AF" : "MF"}
            </div>
            <button
              onClick={toggleFullscreen}
              className="bg-black/60 backdrop-blur-sm hover:bg-black/80 p-1.5 rounded-full transition-colors"
              title={isFullscreen ? "Exit fullscreen" : "Fullscreen"}
            >
              {isFullscreen ? (
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="white" strokeWidth="2.5" strokeLinecap="round">
                  <path d="M8 3v3a2 2 0 0 1-2 2H3"/><path d="M21 8h-3a2 2 0 0 1-2-2V3"/>
                  <path d="M3 16h3a2 2 0 0 1 2 2v3"/><path d="M16 21v-3a2 2 0 0 1 2-2h3"/>
                </svg>
              ) : (
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="white" strokeWidth="2.5" strokeLinecap="round">
                  <path d="M3 7V3h4"/><path d="M21 7V3h-4"/>
                  <path d="M3 17v4h4"/><path d="M21 17v4h-4"/>
                </svg>
              )}
            </button>
          </div>

          {/* Controls overlay — dpad far left, face buttons far right */}
          {showControls && (
            <>
              <div className="absolute bottom-16 left-3">
                <ControlsOverlay state={padState} mapping={mapping} side="dpad" />
              </div>
              <div className="absolute bottom-16 right-3">
                <ControlsOverlay state={padState} mapping={mapping} side="face" />
              </div>
            </>
          )}

          {/* Bottom bar: camera parameters */}
          <div className="absolute bottom-0 left-0 right-0 bg-gradient-to-t from-black/80 to-transparent px-4 py-3">
            {status ? (
              <div className="flex items-end justify-between gap-4">
                {/* Left: camera name + exposure */}
                <div className="flex items-end gap-5">
                  <div className="flex flex-col items-start">
                    <span className="text-zinc-500 text-[9px] font-medium tracking-widest leading-none mb-0.5">CAM</span>
                    <span className="text-white text-sm font-semibold leading-none">{camera.name}</span>
                  </div>
                  <StatItem label="IRIS" value={status.iris} />
                  <StatItem label="GAIN" value={gain} />
                  <StatItem label="FOCUS" value={status.autoFocus ? "AF" : "MF"} />
                </div>

                {/* Right: zoom + focus bars */}
                <div className="flex gap-4 items-end">
                  <BarStat label="ZOOM" value={status.zoom} />
                  <BarStat label="FOCUS" value={status.focus} highlight={!autoFocus} />
                </div>
              </div>
            ) : (
              <div className="flex items-end justify-between gap-4">
                <span className="text-white text-sm font-semibold">{camera.name}</span>
                <div className="flex items-center gap-2">
                  {statusError ? (
                    <span className="text-zinc-600 text-[10px]">Camera params unavailable</span>
                  ) : (
                    <>
                      <div className="w-3 h-3 border border-zinc-600 border-t-zinc-400 rounded-full animate-spin" />
                      <span className="text-zinc-600 text-[10px]">Reading camera…</span>
                    </>
                  )}
                </div>
              </div>
            )}
          </div>
        </>
      )}
    </div>
  );
}

function StatItem({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex flex-col items-start">
      <span className="text-zinc-500 text-[9px] font-medium tracking-widest leading-none mb-0.5">{label}</span>
      <span className="text-white text-sm font-mono font-semibold leading-none">{value}</span>
    </div>
  );
}

function BarStat({ label, value, highlight }: { label: string; value: number; highlight?: boolean }) {
  return (
    <div className="flex flex-col items-end gap-1">
      <span className="text-zinc-500 text-[9px] font-medium tracking-widest">{label}</span>
      <div className="flex items-center gap-1.5">
        <span className="text-white text-xs font-mono w-7 text-right">{value}%</span>
        <div className="w-16 h-1.5 bg-zinc-700 rounded-full overflow-hidden">
          <div
            className={`h-full rounded-full transition-none ${highlight ? "bg-blue-400" : "bg-zinc-400"}`}
            style={{ width: `${value}%` }}
          />
        </div>
      </div>
    </div>
  );
}
