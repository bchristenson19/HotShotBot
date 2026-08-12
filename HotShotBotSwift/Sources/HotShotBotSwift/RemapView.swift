import SwiftUI

/// Controller remap sheet — SwiftUI port of `RemapModal.tsx`'s "Buttons" + the pan/tilt/zoom
/// portions of its "Advanced" tab, scoped to the fields `ControlMapping`/`PTZControlLoop`
/// actually implement (no focus/iris/gain/white-balance/presets/macros yet).
struct RemapView: View {
    @State private var draft: ControlMapping
    @Binding var isPresented: Bool
    let onSave: (ControlMapping) -> Void

    private enum Tab: String, CaseIterable { case buttons = "Buttons", panTilt = "Pan / Tilt", zoom = "Zoom" }
    @State private var activeTab: Tab = .buttons

    init(mapping: ControlMapping, isPresented: Binding<Bool>, onSave: @escaping (ControlMapping) -> Void) {
        _draft = State(initialValue: mapping)
        _isPresented = isPresented
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Remap Controller").font(.title2).bold()
                Spacer()
                Button("Reset to Electron defaults") { draft = ControlMapping() }
                    .font(.caption)
            }
            .padding()

            Picker("", selection: $activeTab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch activeTab {
                    case .buttons: buttonsTab
                    case .panTilt: panTiltTab
                    case .zoom: zoomTab
                    }
                }
                .padding()
            }

            Divider()
            HStack {
                Button("Cancel") { isPresented = false }
                Spacer()
                Button("Save") {
                    onSave(draft)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520, height: 620)
    }

    // MARK: - Buttons tab

    private var buttonsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Assign an action to each button.").font(.caption).foregroundStyle(.secondary)
            ForEach(ButtonId.allCases, id: \.self) { button in
                HStack {
                    Text(button.label).frame(width: 90, alignment: .leading).font(.system(.body, design: .monospaced))
                    Picker("", selection: Binding(
                        get: { draft.buttons[button] ?? ButtonActionId.none },
                        set: { draft.buttons[button] = $0 == ButtonActionId.none ? nil : $0 }
                    )) {
                        ForEach(ButtonActionId.allCases, id: \.self) { action in
                            Text(action.label).tag(action)
                        }
                    }
                    .labelsHidden()
                }
            }

            groupBox("Speed Modifier Trigger") {
                Text("Hold this trigger to slow (or speed up) pan/tilt — held threshold >50%, not a discrete button, since triggers report 0...1.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $draft.speedModifierButton) {
                    ForEach(TriggerId.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            groupBox("One-Touch Focus Mode") {
                Text(draft.oneTouchFocusMode == .pulse
                    ? "Press: focuses once then returns to manual after 2s."
                    : "Hold: auto focus while held, manual on release.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $draft.oneTouchFocusMode) {
                    ForEach(OneTouchFocusMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    // MARK: - Pan/Tilt tab

    private var panTiltTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            groupBox("Sticks") {
                Toggle("Swap sticks", isOn: $draft.sticksSwapped)
                Text("Left stick takes over the right stick's job and vice versa.").font(.caption).foregroundStyle(.secondary)
            }

            groupBox("D-Pad Fine Pan/Tilt") {
                percentSlider("Step size", value: $draft.dpadFineSpeed, range: 0.05...0.50)
                Text("Speed while a D-pad direction bound to Fine Pan/Tilt is held.").font(.caption).foregroundStyle(.secondary)
            }

            groupBox("Sensitivity") {
                percentSlider("Sensitivity", value: $draft.ptSensitivity, range: 0.10...1.0)
                Toggle("Invert tilt", isOn: $draft.tiltInverted)
            }

            groupBox("Momentum") {
                Toggle("Momentum (glide to a stop)", isOn: $draft.momentumEnabled)
                if draft.momentumEnabled {
                    msSlider("Glide time", value: $draft.momentumGlideMs, range: 50...1200)
                    percentSlider("Acceleration", value: $draft.momentumAccel, range: 0.05...1.0)
                }
            }

            groupBox("Speed Modifier") {
                percentSlider("Slow multiplier", value: $draft.speedModifierValue, range: 0.05...0.90)
                Toggle("Also affects zoom", isOn: $draft.speedModifierAffectsZoom)
                percentSlider("Transition ease", value: $draft.modifierEaseRate, range: 0.05...1.0)
                Text("Lower = smoother ramp between slow and full speed; 100% = instant.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            groupBox("Gyro Fine-Adjust") {
                Toggle("Enabled", isOn: $draft.fineAdjustEnabled)
                Text("Hold both buttons together to steer pan/tilt from the controller's gyro instead of the stick, for very fine framing nudges.")
                    .font(.caption).foregroundStyle(.secondary)
                if draft.fineAdjustEnabled {
                    HStack {
                        Text("Buttons").frame(width: 90, alignment: .leading)
                        Picker("", selection: $draft.fineAdjustButtonA) {
                            ForEach(ButtonId.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        Text("+")
                        Picker("", selection: $draft.fineAdjustButtonB) {
                            ForEach(ButtonId.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                    }
                    percentSlider("Sensitivity", value: $draft.fineAdjustSensitivity, range: 0.02...0.50)
                    percentSlider("Max output", value: $draft.fineAdjustMaxOutput, range: 0.05...1.0)
                    Toggle("Invert tilt", isOn: $draft.fineAdjustTiltInverted)
                    Text("Separate from the stick's tilt invert above — the gyro is its own input path.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            groupBox("Brake") {
                Text("Scales pan/tilt and zoom speed down proportionally while held — for precision framing.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Brake trigger", selection: Binding(
                    get: { draft.brakeTrigger },
                    set: { draft.brakeTrigger = $0 }
                )) {
                    Text("Disabled").tag(TriggerId?.none)
                    ForEach(TriggerId.allCases, id: \.self) { Text($0.label).tag(TriggerId?.some($0)) }
                }
                .pickerStyle(.segmented)
                if draft.brakeTrigger != nil {
                    percentSlider("Min speed at full brake", value: $draft.brakeMinSpeed, range: 0.01...0.40)
                }
            }
        }
    }

    // MARK: - Zoom tab

    private var zoomTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            groupBox("Input") {
                Text("Right stick Y (left when sticks are swapped).").font(.caption).foregroundStyle(.secondary)
            }
            groupBox("Sensitivity") {
                percentSlider("Sensitivity", value: $draft.zoomSensitivity, range: 0.10...1.0)
                Toggle("Invert (push in = zoom in)", isOn: $draft.zoomInverted)
            }
            groupBox("Momentum") {
                Toggle("Momentum (glide to a stop)", isOn: $draft.zoomMomentumEnabled)
                if draft.zoomMomentumEnabled {
                    msSlider("Glide time", value: $draft.zoomMomentumGlideMs, range: 50...1200)
                }
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func groupBox(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).bold()
            content()
        }
        .padding(12)
        .background(Color.gray.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func percentSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text("\(Int(value.wrappedValue * 100))%").foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: value, in: range)
        }
    }

    private func msSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text("\(Int(value.wrappedValue))ms").foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: value, in: range)
        }
    }
}
