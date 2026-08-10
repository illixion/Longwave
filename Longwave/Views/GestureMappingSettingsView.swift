//  GestureMappingSettingsView.swift
//
//  Remapping UI for the Controller Bridge's pinch gestures (hand × finger →
//  virtual controller input). Persists via GestureControllerMappingStore and
//  pushes changes into a live bridge immediately, so remaps take effect next
//  frame mid-session. Left thumb+index is the locomotion joystick and is shown
//  locked. Gated behind FOVEATED_ENABLED.

#if FOVEATED_ENABLED
import RAVEInput
import SwiftUI

struct GestureMappingSettingsView: View {
    @Environment(FoveatedConnectionManager.self) private var manager
    @Environment(\.dismiss) private var dismiss

    @State private var mapping = GestureControllerMappingStore.load()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Pinch your thumb to a fingertip to press the mapped input. One pinch per hand at a time; a fist suppresses detection.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Right hand — right controller") {
                    row(hand: .right, finger: .index)
                    row(hand: .right, finger: .middle)
                    row(hand: .right, finger: .ring)
                    row(hand: .right, finger: .little)
                }

                Section("Left hand — left controller") {
                    LabeledContent(fingerName(.index)) {
                        Label("Locomotion joystick", systemImage: "lock.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    row(hand: .left, finger: .middle)
                    row(hand: .left, finger: .ring)
                    row(hand: .left, finger: .little)
                }

                Section {
                    Button("Reset to Defaults", role: .destructive) {
                        mapping = .defaults
                    }
                    .disabled(mapping == .defaults)
                }
            }
            .navigationTitle("Gesture Controls")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: mapping) { _, newValue in
                GestureControllerMappingStore.save(newValue)
                manager.controllerBridge?.updateGestureMapping(newValue)
            }
        }
    }

    private func row(hand: BridgeHand, finger: BridgeFinger) -> some View {
        Picker(fingerName(finger), selection: binding(hand: hand, finger: finger)) {
            ForEach(BridgeGestureTarget.allCases, id: \.self) { target in
                Text(target.displayName).tag(target)
            }
        }
    }

    private func binding(hand: BridgeHand, finger: BridgeFinger) -> Binding<BridgeGestureTarget> {
        Binding(
            get: { mapping.target(for: hand, finger: finger) },
            set: { mapping.set($0, for: hand, finger: finger) }
        )
    }

    private func fingerName(_ finger: BridgeFinger) -> String {
        switch finger {
        case .index:  "Thumb + Index"
        case .middle: "Thumb + Middle"
        case .ring:   "Thumb + Ring"
        case .little: "Thumb + Little"
        }
    }
}
#endif
