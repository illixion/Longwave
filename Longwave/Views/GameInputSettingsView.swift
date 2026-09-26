//  GameInputSettingsView.swift
//
//  Per-title hand input for PCVR: how you walk, how (and whether) you turn, and how
//  eagerly the pinch joystick engages. Stored in the running title's `GameProfile`, so
//  a game that needs arm swinging keeps it and the next one does not inherit it.
//
//  Per title rather than global because the right answer is a property of the game:
//  Half-Life: Alyx needs a thumbstick to walk and to turn and has no controllerless
//  mode, while a seated title wants no gesture locomotion at all. The wrist HUD carries
//  the two mode switches for flipping mid-game; this sheet is the full set.
//
//  Gated behind FOVEATED_ENABLED.

#if FOVEATED_ENABLED
import RAVEInput
import SwiftUI

struct GameInputSettingsView: View {
    @Environment(FoveatedConnectionManager.self) private var manager
    @Environment(\.dismiss) private var dismiss

    private var bridge: ControllerBridgeSender? { manager.controllerBridge }
    private var input: GameInput { bridge?.gameProfile.input ?? GameInput() }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let bridge, let game = bridge.activeGame {
                        Text("Settings for \(game)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        locomotionSection
                        turnSection
                        Button("Reset \(game) to Defaults", role: .destructive) {
                            bridge.updateGameInput {
                                $0.locomotion = nil
                                $0.joystickSensitivity = nil
                                $0.turn = nil
                                $0.turnHand = nil
                            }
                        }
                        .disabled(input.locomotion == nil && input.joystickSensitivity == nil
                                  && input.turn == nil && input.turnHand == nil)
                    } else {
                        ContentUnavailableView(
                            "No game running",
                            systemImage: "figure.walk",
                            description: Text("Input is set per game. Start one from Games, then come back here to change how you walk and turn in it."))
                    }
                }
                .padding(28)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Game Input")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: Walking

    private var locomotionSection: some View {
        card {
            Label("Walking", systemImage: "figure.walk")
                .font(.headline)
            Picker("Walking", selection: binding(\.resolvedLocomotion) { $0.locomotion = $1 }) {
                ForEach(GameLocomotionMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text(locomotionCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if input.resolvedLocomotion != .off {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Joystick sensitivity")
                        .font(.subheadline)
                    HStack {
                        Text("Steadier").font(.caption2).foregroundStyle(.secondary)
                        Slider(value: binding(\.resolvedJoystickSensitivity) { $0.joystickSensitivity = $1 },
                               in: GameInput.joystickSensitivityRange, step: 0.1)
                        Text("Quicker").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("Steadier needs a longer pinch before the stick engages, a wider still zone and more travel to full speed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var locomotionCaption: String {
        switch input.resolvedLocomotion {
        case .pinchJoystick:
            "Pinch left thumb and index, hold a moment, then move your hand the way you want to go."
        case .armSwing:
            "Close both fists and jog your arms to walk; the faster you swing, the faster you go. While you swing, those hands press no buttons. The pinch joystick still works and takes over while held."
        case .off:
            "No gesture walking. Left thumb and index press nothing."
        }
    }

    // MARK: Turning

    private var turnSection: some View {
        card {
            Label("Turning", systemImage: "arrow.triangle.2.circlepath")
                .font(.headline)
            Picker("Turning", selection: binding(\.resolvedTurn) { $0.turn = $1 }) {
                ForEach(GameTurnMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            if input.resolvedTurn != .off {
                Picker("Turn hand", selection: binding(\.resolvedTurnHand) { $0.turnHand = $1 }) {
                    Text("Right hand").tag(BridgeHand.right)
                    Text("Left hand").tag(BridgeHand.left)
                }
                .pickerStyle(.segmented)
            }
            Text(turnCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var turnCaption: String {
        let hand = input.resolvedTurnHand == .right ? "right" : "left"
        switch input.resolvedTurn {
        case .off:
            return "Off by default so nothing turns you by accident. Turn it on for a game that has no other way to turn."
        case .snap:
            return "Hold \(hand) thumb and middle until it registers, then move that hand sideways. Each move is one snap — set the angle in the game's own snap-turn option. That pinch stops pressing its mapped button while turning is on."
        case .smooth:
            return "Hold \(hand) thumb and middle until it registers, then move that hand sideways — the farther, the faster. That pinch stops pressing its mapped button while turning is on."
        }
    }

    // MARK: Plumbing

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// Read the resolved value, write through the bridge (which persists only what
    /// differs from the defaults).
    private func binding<Value>(_ read: KeyPath<GameInput, Value>,
                                write: @escaping (inout GameInput, Value) -> Void) -> Binding<Value> {
        Binding(
            get: { input[keyPath: read] },
            set: { value in bridge?.updateGameInput { write(&$0, value) } }
        )
    }
}
#endif
