"use client";
import { useState } from "react";
import type { ControlMapping, ButtonId, ActionId } from "@/lib/mapping";
import { BUTTON_IDS, BUTTON_LABELS, BUTTON_ACTIONS, ACTION_LABELS, DEFAULT_MAPPING } from "@/lib/mapping";

interface Props {
  mapping: ControlMapping;
  onChange: (m: ControlMapping) => void;
  onClose: () => void;
}

function Toggle({ checked, onChange }: { checked: boolean; onChange: () => void }) {
  return (
    <button
      onClick={onChange}
      className={`shrink-0 w-11 h-6 rounded-full transition-colors relative ${checked ? "bg-blue-600" : "bg-zinc-600"}`}
    >
      <span className={`absolute top-1 left-1 w-4 h-4 rounded-full bg-white transition-transform ${checked ? "translate-x-5" : "translate-x-0"}`} />
    </button>
  );
}

function SegmentedButtons<T extends string>({ value, options, onChange }: {
  value: T; options: T[]; onChange: (v: T) => void;
}) {
  return (
    <div className="flex rounded-lg overflow-hidden border border-zinc-600 text-xs shrink-0">
      {options.map((opt) => (
        <button
          key={opt}
          onClick={() => onChange(opt)}
          className={`px-3 py-1.5 capitalize transition-colors ${
            value === opt ? "bg-blue-600 text-white" : "bg-zinc-700 text-zinc-400 hover:text-white"
          }`}
        >
          {opt}
        </button>
      ))}
    </div>
  );
}

function Row({ label, description, children }: { label: string; description?: string; children: React.ReactNode }) {
  return (
    <div className="flex items-center justify-between gap-3">
      <div className="min-w-0">
        <span className="text-sm font-medium text-zinc-300 block">{label}</span>
        {description && <span className="text-xs text-zinc-500">{description}</span>}
      </div>
      {children}
    </div>
  );
}

function Slider({ label, value, unit, min, max, step, onChange, minLabel, maxLabel }: {
  label: string; value: number; unit?: string; min: number; max: number; step: number;
  onChange: (v: number) => void; minLabel?: string; maxLabel?: string;
}) {
  return (
    <div className="space-y-1 pt-1">
      <div className="flex justify-between">
        <span className="text-sm text-zinc-400">{label}</span>
        <span className="text-sm text-blue-400 font-mono">{value}{unit}</span>
      </div>
      <input type="range" min={min} max={max} step={step} value={value}
        onChange={(e) => onChange(parseInt(e.target.value))}
        className="w-full accent-blue-500" />
      {(minLabel || maxLabel) && (
        <div className="flex justify-between text-xs text-zinc-600">
          <span>{minLabel}</span><span>{maxLabel}</span>
        </div>
      )}
    </div>
  );
}

function GroupLabel({ children }: { children: React.ReactNode }) {
  return <p className="text-zinc-300 text-sm font-semibold pt-2 pb-1 border-b border-zinc-700">{children}</p>;
}

export default function RemapModal({ mapping, onChange, onClose }: Props) {
  const [draft, setDraft] = useState<ControlMapping>(JSON.parse(JSON.stringify(mapping)));
  const [activeTab, setActiveTab] = useState<"buttons" | "macros" | "advanced">("buttons");

  function setButtonAction(btn: ButtonId, action: ActionId) {
    setDraft((d) => ({ ...d, buttons: { ...d.buttons, [btn]: action } }));
  }

  function setMacro(i: number, field: string, value: string | boolean) {
    setDraft((d) => {
      const macros = [...d.macros] as ControlMapping["macros"];
      macros[i] = { ...macros[i], [field]: value };
      return { ...d, macros };
    });
  }

  function reset() {
    setDraft(JSON.parse(JSON.stringify(DEFAULT_MAPPING)));
  }

  function save() {
    onChange(draft);
    onClose();
  }

  return (
    <div className="fixed inset-0 bg-black/70 flex items-center justify-center z-50 p-4">
      <div className="bg-zinc-900 border border-zinc-700 rounded-2xl w-full max-w-2xl max-h-[90vh] flex flex-col">
        {/* Header */}
        <div className="flex items-center justify-between px-6 py-4 border-b border-zinc-800">
          <h2 className="text-white text-xl font-bold">Remap Controller</h2>
          <div className="flex gap-2">
            <button
              onClick={reset}
              className="text-xs text-zinc-400 hover:text-white px-3 py-1.5 rounded-lg bg-zinc-800 hover:bg-zinc-700 transition-colors"
            >
              Reset defaults
            </button>
          </div>
        </div>

        {/* Tabs */}
        <div className="flex border-b border-zinc-800">
          {(["buttons", "advanced", "macros"] as const).map((tab) => (
            <button
              key={tab}
              onClick={() => setActiveTab(tab)}
              className={`px-6 py-3 text-sm font-medium capitalize transition-colors ${
                activeTab === tab
                  ? "text-white border-b-2 border-blue-500"
                  : "text-zinc-400 hover:text-white"
              }`}
            >
              {tab}
            </button>
          ))}
        </div>

        {/* Content */}
        <div className="flex-1 overflow-y-auto p-6 space-y-3">
          {activeTab === "buttons" && (
            <>
              <p className="text-zinc-500 text-xs mb-4">Assign an action to each button.</p>

              {BUTTON_IDS.map((btn) => (
                <div key={btn} className="flex items-center justify-between gap-4">
                  <span className="w-20 text-sm font-medium text-zinc-300 shrink-0">
                    {BUTTON_LABELS[btn]}
                  </span>
                  <select
                    value={draft.buttons[btn]}
                    onChange={(e) => setButtonAction(btn, e.target.value as ActionId)}
                    className="flex-1 bg-zinc-800 text-white rounded-lg px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-blue-500"
                  >
                    {BUTTON_ACTIONS.map((a) => (
                      <option key={a} value={a}>
                        {ACTION_LABELS[a]}
                      </option>
                    ))}
                  </select>
                </div>
              ))}
            </>
          )}

          {activeTab === "advanced" && (
            <>
              {/* ── Pan / Tilt ─────────────────────────────── */}
              <GroupLabel>Pan / Tilt</GroupLabel>

              <div className="bg-zinc-800 rounded-xl p-4 space-y-3">
                <Row label="Mode" description={draft.ptMode === "single" ? "Left stick only" : "Left stick = base · Right stick adds/subtracts"}>
                  <SegmentedButtons value={draft.ptMode} options={["single", "dual"] as const}
                    onChange={(v) => setDraft((d) => ({ ...d, ptMode: v }))} />
                </Row>
                {draft.ptMode === "dual" && (
                  <Slider label="Right stick influence" value={Math.round(draft.ptFineScale * 100)} unit="%"
                    min={5} max={100} step={5} minLabel="5% (nudge)" maxLabel="100% (equal)"
                    onChange={(v) => setDraft((d) => ({ ...d, ptFineScale: v / 100 }))} />
                )}
              </div>

              <div className="bg-zinc-800 rounded-xl p-4 space-y-3">
                <Row label="Sensitivity" description="Scales left stick output">
                  <span className="text-sm text-blue-400 font-mono shrink-0">{Math.round(draft.ptSensitivity * 100)}%</span>
                </Row>
                <Slider label="" value={Math.round(draft.ptSensitivity * 100)} unit=""
                  min={10} max={100} step={5} minLabel="10% (slow)" maxLabel="100% (full)"
                  onChange={(v) => setDraft((d) => ({ ...d, ptSensitivity: v / 100 }))} />
                <Row label="Invert tilt" description="Flips up / down direction">
                  <Toggle checked={draft.tiltInverted}
                    onChange={() => setDraft((d) => ({ ...d, tiltInverted: !d.tiltInverted }))} />
                </Row>
              </div>

              <div className="bg-zinc-800 rounded-xl p-4 space-y-3">
                <Row label="Momentum" description="Pan/tilt glides to a stop instead of cutting hard">
                  <Toggle checked={draft.momentumEnabled}
                    onChange={() => setDraft((d) => ({ ...d, momentumEnabled: !d.momentumEnabled }))} />
                </Row>
                {draft.momentumEnabled && <>
                  <Slider label="Glide time" value={draft.momentumGlideMs} unit="ms"
                    min={50} max={1200} step={50} minLabel="50ms (snappy)" maxLabel="1200ms (floaty)"
                    onChange={(v) => setDraft((d) => ({ ...d, momentumGlideMs: v }))} />
                  <Slider label="Acceleration" value={Math.round(draft.momentumAccel * 100)} unit="%"
                    min={5} max={100} step={1} minLabel="5% (heavy)" maxLabel="100% (instant)"
                    onChange={(v) => setDraft((d) => ({ ...d, momentumAccel: v / 100 }))} />
                </>}
              </div>

              <div className="bg-zinc-800 rounded-xl p-4 space-y-3">
                <Row label="Speed Modifier" description={`Hold mapped button to ${draft.ptSpeedModifierMode === "slow" ? "slow down" : "speed up"} PT & optionally zoom`}>
                  <SegmentedButtons value={draft.ptSpeedModifierMode} options={["slow", "fast"] as const}
                    onChange={(v) => setDraft((d) => ({ ...d, ptSpeedModifierMode: v, ptSpeedModifierValue: v === "slow" ? 0.3 : 2.0 }))} />
                </Row>
                <Row label="Also affects zoom">
                  <Toggle checked={draft.ptSpeedModifierAffectsZoom}
                    onChange={() => setDraft((d) => ({ ...d, ptSpeedModifierAffectsZoom: !d.ptSpeedModifierAffectsZoom }))} />
                </Row>
                <Slider
                  label={draft.ptSpeedModifierMode === "slow" ? "Slow multiplier" : "Fast multiplier"}
                  value={Math.round(draft.ptSpeedModifierValue * 100)}
                  unit={draft.ptSpeedModifierMode === "slow" ? "%" : "×"}
                  min={draft.ptSpeedModifierMode === "slow" ? 5 : 110}
                  max={draft.ptSpeedModifierMode === "slow" ? 90 : 300}
                  step={10}
                  minLabel={draft.ptSpeedModifierMode === "slow" ? "5% (near stop)" : "1.1×"}
                  maxLabel={draft.ptSpeedModifierMode === "slow" ? "90% (almost normal)" : "3.0×"}
                  onChange={(v) => setDraft((d) => ({ ...d, ptSpeedModifierValue: v / 100 }))} />
              </div>

              <div className="bg-zinc-800 rounded-xl p-4 space-y-3">
                <Row
                  label="Brake"
                  description={draft.zoomMode === "triggers"
                    ? "Unavailable — triggers are used for zoom"
                    : "Trigger that limits PT speed for precision shots"}
                >
                  <select
                    value={draft.ptBrakeAxis ?? "none"}
                    disabled={draft.zoomMode === "triggers"}
                    onChange={(e) => setDraft((d) => ({ ...d, ptBrakeAxis: e.target.value === "none" ? null : e.target.value as typeof d.ptBrakeAxis }))}
                    className="bg-zinc-700 text-white rounded-lg px-3 py-1.5 text-sm outline-none focus:ring-2 focus:ring-blue-500 shrink-0 disabled:opacity-40 disabled:cursor-not-allowed"
                  >
                    <option value="none">Disabled</option>
                    <option value="l2">L2</option>
                    <option value="r2">R2</option>
                  </select>
                </Row>
                {draft.ptBrakeAxis && (
                  <Slider label="Min speed at full brake" value={Math.round(draft.ptBrakeMinSpeed * 100)} unit="%"
                    min={1} max={40} step={1} minLabel="1% (near stop)" maxLabel="40% (gentle slow)"
                    onChange={(v) => setDraft((d) => ({ ...d, ptBrakeMinSpeed: v / 100 }))} />
                )}
              </div>

              <div className="bg-zinc-800 rounded-xl p-4">
                <Row
                  label="Swap Tilt / Zoom"
                  description={draft.panTiltAxis.y === "leftY" ? "Left Y = Tilt · Right Y = Zoom" : "Left Y = Zoom · Right Y = Tilt"}
                >
                  <Toggle
                    checked={draft.panTiltAxis.y !== "leftY"}
                    onChange={() => setDraft((d) => {
                      const swapped = d.panTiltAxis.y === "leftY";
                      return { ...d, panTiltAxis: { ...d.panTiltAxis, y: swapped ? "rightY" : "leftY" }, zoomAxis: swapped ? "leftY" : "rightY" };
                    })} />
                </Row>
              </div>

              {/* ── Zoom ───────────────────────────────────── */}
              <GroupLabel>Zoom</GroupLabel>

              <div className="bg-zinc-800 rounded-xl p-4 space-y-3">
                <Row label="Input" description={draft.zoomMode === "stick" ? "Right stick Y" : "L2 = out · R2 = in"}>
                  <SegmentedButtons value={draft.zoomMode} options={["stick", "triggers"] as const}
                    onChange={(v) => setDraft((d) => ({ ...d, zoomMode: v }))} />
                </Row>
              </div>

              <div className="bg-zinc-800 rounded-xl p-4 space-y-3">
                <Row label="Sensitivity">
                  <span className="text-sm text-blue-400 font-mono shrink-0">{Math.round(draft.zoomSensitivity * 100)}%</span>
                </Row>
                <Slider label="" value={Math.round(draft.zoomSensitivity * 100)} unit=""
                  min={10} max={100} step={5} minLabel="10% (slow)" maxLabel="100% (full)"
                  onChange={(v) => setDraft((d) => ({ ...d, zoomSensitivity: v / 100 }))} />
              </div>

              <div className="bg-zinc-800 rounded-xl p-4 space-y-3">
                <Row label="Momentum" description="Zoom glides to a stop after release">
                  <Toggle checked={draft.zoomMomentumEnabled}
                    onChange={() => setDraft((d) => ({ ...d, zoomMomentumEnabled: !d.zoomMomentumEnabled }))} />
                </Row>
                {draft.zoomMomentumEnabled && (
                  <Slider label="Glide time" value={draft.zoomMomentumGlideMs} unit="ms"
                    min={50} max={1200} step={50} minLabel="50ms (snappy)" maxLabel="1200ms (floaty)"
                    onChange={(v) => setDraft((d) => ({ ...d, zoomMomentumGlideMs: v }))} />
                )}
              </div>

              <div className="bg-zinc-800 rounded-xl p-4">
                <Row label="Invert" description="Flips push-in / pull-out direction">
                  <Toggle checked={draft.zoomInverted}
                    onChange={() => setDraft((d) => ({ ...d, zoomInverted: !d.zoomInverted }))} />
                </Row>
              </div>

              {/* ── Focus ──────────────────────────────────── */}
              <GroupLabel>Focus</GroupLabel>

              <div className="bg-zinc-800 rounded-xl p-4">
                <Row
                  label="One-Touch Focus mode"
                  description={draft.oneTouchFocusMode === "pulse"
                    ? "Press: focuses once then returns to manual after 2s"
                    : "Hold: AF on while held, manual on release"}
                >
                  <SegmentedButtons value={draft.oneTouchFocusMode} options={["pulse", "hold"] as const}
                    onChange={(v) => setDraft((d) => ({ ...d, oneTouchFocusMode: v }))} />
                </Row>
              </div>
            </>
          )}

          {activeTab === "macros" && (
            <>
              <p className="text-zinc-500 text-xs mb-4">
                Macros send a raw AW-UE70 CGI command when their assigned button is pressed.
                Assign a button to macro1–4 in the Buttons tab.
              </p>
              {draft.macros.map((macro, i) => (
                <div key={i} className="bg-zinc-800 rounded-xl p-4 space-y-3">
                  <div className="flex items-center justify-between">
                    <span className="text-sm font-semibold text-zinc-300">Macro {i + 1}</span>
                    <label className="flex items-center gap-2 text-xs text-zinc-400 cursor-pointer">
                      <input
                        type="checkbox"
                        checked={macro.toggle}
                        onChange={(e) => setMacro(i, "toggle", e.target.checked)}
                        className="accent-blue-500"
                      />
                      Toggle mode
                    </label>
                  </div>
                  <input
                    type="text"
                    placeholder='Label (e.g. "Record")'
                    value={macro.label}
                    onChange={(e) => setMacro(i, "label", e.target.value)}
                    className="w-full bg-zinc-700 text-white rounded-lg px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-blue-500"
                  />
                  <input
                    type="text"
                    placeholder={macro.toggle ? "ON command (e.g. #REC1)" : "Command (e.g. #R05)"}
                    value={macro.cmd}
                    onChange={(e) => setMacro(i, "cmd", e.target.value)}
                    className="w-full bg-zinc-700 text-white rounded-lg px-3 py-2 text-sm font-mono outline-none focus:ring-2 focus:ring-blue-500"
                  />
                  {macro.toggle && (
                    <input
                      type="text"
                      placeholder="OFF command (e.g. #REC0)"
                      value={macro.offCmd}
                      onChange={(e) => setMacro(i, "offCmd", e.target.value)}
                      className="w-full bg-zinc-700 text-white rounded-lg px-3 py-2 text-sm font-mono outline-none focus:ring-2 focus:ring-blue-500"
                    />
                  )}
                </div>
              ))}
            </>
          )}
        </div>

        {/* Footer */}
        <div className="flex gap-3 px-6 py-4 border-t border-zinc-800">
          <button
            onClick={onClose}
            className="flex-1 bg-zinc-700 hover:bg-zinc-600 text-white rounded-xl py-2 text-sm transition-colors"
          >
            Cancel
          </button>
          <button
            onClick={save}
            className="flex-1 bg-blue-600 hover:bg-blue-500 text-white rounded-xl py-2 text-sm font-semibold transition-colors"
          >
            Save
          </button>
        </div>
      </div>
    </div>
  );
}
