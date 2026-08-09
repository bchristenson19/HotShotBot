"use client";
import { useState } from "react";
import type { Camera, CameraModel } from "@/lib/ptz";
import { defaultStreamUrl, defaultCameraColor } from "@/lib/ptz";
import type { DiscoveredCamera } from "@/app/api/discover/route";

interface Props {
  cameras: Camera[];
  onChange: (cameras: Camera[]) => void;
  onClose: () => void;
}

const MODEL_LABELS: Record<CameraModel, string> = {
  "aw-ue70":   "AW-UE70",
  "aw-ue160":  "AW-UE160",
  "aw-he130":  "AW-HE130",
  "virtual":   "Virtual (3D)",
};

export default function CameraConfig({ cameras, onChange, onClose }: Props) {
  const [draft, setDraft] = useState<Camera[]>(cameras.length ? cameras : [newCam(1)]);
  const [discovering, setDiscovering] = useState(false);
  const [discovered, setDiscovered] = useState<DiscoveredCamera[]>([]);
  const [discoverError, setDiscoverError] = useState("");
  const [discoverSubnet, setDiscoverSubnet] = useState("");

  function newCam(n: number): Camera {
    return { id: crypto.randomUUID(), name: `Camera ${n}`, ip: "", port: 80, model: "aw-ue70", color: defaultCameraColor(n - 1) };
  }

  function update(index: number, field: keyof Camera, value: string | number) {
    setDraft((prev) => prev.map((c, i) => (i === index ? { ...c, [field]: value } : c)));
  }

  function addCamera() {
    if (draft.length >= 4) return;
    setDraft((prev) => [...prev, newCam(prev.length + 1)]);
  }

  function removeCamera(index: number) {
    setDraft((prev) => prev.filter((_, i) => i !== index));
  }

  function addDiscovered(cam: DiscoveredCamera) {
    if (draft.length >= 4) return;
    if (draft.some((c) => c.ip === cam.ip)) return; // already added
    const n = draft.length + 1;
    setDraft((prev) => [
      ...prev,
      { id: crypto.randomUUID(), name: cam.name, ip: cam.ip, port: 80, model: cam.model as CameraModel },
    ]);
    void n;
  }

  async function discover() {
    setDiscovering(true);
    setDiscoverError("");
    setDiscovered([]);
    try {
      const res = await fetch("/api/discover");
      const data = await res.json();
      setDiscovered(data.cameras ?? []);
      setDiscoverSubnet(data.subnet ?? "");
      if ((data.cameras ?? []).length === 0 && !data.error) {
        setDiscoverError(`No cameras found on ${data.subnet}`);
      }
      if (data.error) setDiscoverError(data.error);
    } catch {
      setDiscoverError("Discovery failed — check network connection");
    } finally {
      setDiscovering(false);
    }
  }

  function save() {
    const valid = draft.filter((c) => c.ip.trim() || c.model === "virtual");
    if (!valid.length) return;
    onChange(valid);
    onClose();
  }

  return (
    <div className="fixed inset-0 bg-black/70 flex items-center justify-center z-50 p-4">
      <div className="bg-zinc-900 border border-zinc-700 rounded-2xl w-full max-w-lg max-h-[90vh] flex flex-col">
        <div className="px-6 py-4 border-b border-zinc-800 flex items-center justify-between">
          <h2 className="text-white text-xl font-bold">Camera Setup</h2>
          <button
            onClick={discover}
            disabled={discovering}
            className="flex items-center gap-2 text-sm px-3 py-1.5 rounded-lg bg-zinc-800 hover:bg-zinc-700 text-zinc-300 hover:text-white disabled:opacity-50 transition-colors"
          >
            {discovering ? (
              <>
                <div className="w-3 h-3 border border-zinc-500 border-t-blue-400 rounded-full animate-spin" />
                Scanning…
              </>
            ) : (
              "Discover"
            )}
          </button>
        </div>

        <div className="flex-1 overflow-y-auto p-6 space-y-4">
          {/* Discovery results */}
          {(discovered.length > 0 || discoverError) && (
            <div className="bg-zinc-800 rounded-xl p-4 space-y-2">
              <p className="text-zinc-400 text-xs uppercase tracking-widest">
                {discoverError ? "Discovery" : `Found on ${discoverSubnet}`}
              </p>
              {discoverError && <p className="text-zinc-500 text-sm">{discoverError}</p>}
              {discovered.map((cam) => {
                const alreadyAdded = draft.some((c) => c.ip === cam.ip);
                return (
                  <div key={cam.ip} className="flex items-center justify-between gap-3">
                    <div>
                      <span className="text-white text-sm font-medium">{cam.name}</span>
                      <span className="text-zinc-500 text-xs ml-2">{cam.ip}</span>
                    </div>
                    <button
                      onClick={() => addDiscovered(cam)}
                      disabled={alreadyAdded || draft.length >= 4}
                      className="text-xs px-2.5 py-1 rounded-lg transition-colors disabled:opacity-40 disabled:cursor-not-allowed bg-blue-600/20 text-blue-400 hover:bg-blue-600 hover:text-white"
                    >
                      {alreadyAdded ? "Added" : "+ Add"}
                    </button>
                  </div>
                );
              })}
            </div>
          )}

          {/* Manual entries */}
          {draft.map((cam, i) => (
            <div key={cam.id} className="bg-zinc-800 rounded-xl p-4 space-y-2">
              <div className="flex items-center justify-between">
                <span className="text-zinc-400 text-sm font-medium">Camera {i + 1}</span>
                {draft.length > 1 && (
                  <button onClick={() => removeCamera(i)} className="text-red-400 hover:text-red-300 text-xs">
                    Remove
                  </button>
                )}
              </div>

              <div className="flex gap-2">
                <input
                  type="color"
                  value={cam.color ?? defaultCameraColor(i)}
                  onChange={(e) => update(i, "color", e.target.value)}
                  title="Light bar color"
                  className="w-10 h-10 rounded-lg cursor-pointer bg-zinc-700 border-0 p-0.5"
                />
                <input
                  type="text"
                  placeholder="Name (e.g. Stage Left)"
                  value={cam.name}
                  onChange={(e) => update(i, "name", e.target.value)}
                  className="flex-1 bg-zinc-700 text-white rounded-lg px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-blue-500"
                />
                <select
                  value={cam.model ?? "aw-ue70"}
                  onChange={(e) => update(i, "model", e.target.value)}
                  className="bg-zinc-700 text-white rounded-lg px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-blue-500"
                >
                  {(Object.keys(MODEL_LABELS) as CameraModel[]).map((m) => (
                    <option key={m} value={m}>{MODEL_LABELS[m]}</option>
                  ))}
                </select>
              </div>

              {cam.model !== "virtual" ? (
                <>
                  <div className="flex gap-2">
                    <input
                      type="text"
                      placeholder="IP Address (e.g. 192.168.1.100)"
                      value={cam.ip}
                      onChange={(e) => update(i, "ip", e.target.value)}
                      className="flex-1 bg-zinc-700 text-white rounded-lg px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-blue-500"
                    />
                    <input
                      type="number"
                      placeholder="Port"
                      value={cam.port}
                      onChange={(e) => update(i, "port", parseInt(e.target.value) || 80)}
                      className="w-20 bg-zinc-700 text-white rounded-lg px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-blue-500"
                    />
                  </div>

                  <input
                    type="text"
                    placeholder={cam.ip ? `Stream URL (default: ${defaultStreamUrl({ ...cam, model: cam.model ?? "aw-ue70" })})` : "Stream URL (optional)"}
                    value={cam.streamUrl ?? ""}
                    onChange={(e) => update(i, "streamUrl", e.target.value)}
                    className="w-full bg-zinc-700 text-white rounded-lg px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-blue-500 font-mono"
                  />
                </>
              ) : (
                <p className="text-zinc-500 text-xs italic px-1 py-2">
                  Renders a 3D scene inside the app — no network camera needed.
                </p>
              )}
            </div>
          ))}

          {draft.length < 4 && (
            <button
              onClick={addCamera}
              className="w-full border border-dashed border-zinc-600 text-zinc-400 hover:text-white hover:border-zinc-400 rounded-xl py-2 text-sm transition-colors"
            >
              + Add Camera Manually
            </button>
          )}
        </div>

        <div className="flex gap-3 px-6 py-4 border-t border-zinc-800">
          <button onClick={onClose} className="flex-1 bg-zinc-700 hover:bg-zinc-600 text-white rounded-xl py-2 text-sm transition-colors">
            Cancel
          </button>
          <button onClick={save} className="flex-1 bg-blue-600 hover:bg-blue-500 text-white rounded-xl py-2 text-sm font-semibold transition-colors">
            Save
          </button>
        </div>
      </div>
    </div>
  );
}
