//  GestureMappingSettingsView.swift
//
//  Remapping UI for the Controller Bridge's pinch gestures (hand × finger →
//  virtual controller input). Persists via GestureControllerMappingStore and
//  pushes changes into a live bridge immediately, so remaps take effect next
//  frame mid-session.
//
//  One hand at a time, chosen at the top. Both hands at once was eight picker
//  rows in two sections and a sheet you had to scroll to reach the reset button
//  — and it buried the fact that the two hands drive *different controllers*
//  inside a pair of section headers. A hand switch makes that the first thing you
//  touch, and halves the height on the way. Left thumb+index is the locomotion
//  joystick and shows as a locked row in its natural position, rather than as a
//  lone exception in a section of its own.
//
//  Which map is being edited is explicit. A title can carry its own map in its
//  `GameProfile`, and that map wins over the global one — which used to mean that
//  with such a title running, every edit here saved to the global map and silently
//  changed nothing in the game. Now, with a title running, a scope switch picks
//  "All games" or that title; the sheet opens on whichever the game is actually
//  using, and says so when the global map is not the one in force. A title's map
//  that ends up identical to the global one is stored as no override at all, so it
//  goes back to following global edits.
//
//  Gated behind FOVEATED_ENABLED.

#if FOVEATED_ENABLED
import RAVEInput
import SwiftUI

struct GestureMappingSettingsView: View {
    @Environment(FoveatedConnectionManager.self) private var manager
    @Environment(\.dismiss) private var dismiss

    @State private var globalMapping = GestureControllerMappingStore.load()
    @State private var hand: BridgeHand = .right
    @State private var scope: Scope = .allGames

    enum Scope: Hashable { case allGames, title }

    private var bridge: ControllerBridgeSender? { manager.controllerBridge }
    /// The running title, when there is one to scope to.
    private var game: String? { bridge?.activeGame }
    private var titleMapping: GestureControllerMapping? { bridge?.titleGestureMapping }
    private var editingTitle: Bool { scope == .title && game != nil }

    /// The map on screen: the title's own (or the global one it currently follows), or
    /// the global one.
    private var mapping: GestureControllerMapping {
        editingTitle ? (titleMapping ?? globalMapping) : globalMapping
    }

    private func setMapping(_ newValue: GestureControllerMapping) {
        if editingTitle {
            bridge?.setTitleGestureMapping(newValue)
        } else {
            globalMapping = newValue
            GestureControllerMappingStore.save(newValue)
            bridge?.updateGestureMapping(newValue)
        }
    }

    private static let fingers: [BridgeFinger] = [.index, .middle, .ring, .little]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    scopeSection
                    handPicker
                    rows
                    resetRow
                }
                .padding(28)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Gesture Controls")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                // Open on the map the running game actually uses.
                scope = titleMapping != nil ? .title : .allGames
            }
        }
    }

    // MARK: Scope

    @ViewBuilder
    private var scopeSection: some View {
        if let game {
            VStack(spacing: 10) {
                Picker("Editing", selection: $scope) {
                    Text("All games").tag(Scope.allGames)
                    Text(game).tag(Scope.title)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)
                Text(scopeCaption(game: game))
                    .font(.caption)
                    .foregroundStyle(titleMapping != nil && !editingTitle ? .orange : .secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func scopeCaption(game: String) -> String {
        switch (editingTitle, titleMapping != nil) {
        case (false, true):
            "\(game) has its own mapping, so changes here do not reach it. Switch to \(game) to edit that one, or reset it there to follow this one."
        case (false, false):
            "Changes apply to every game without its own mapping, \(game) included."
        case (true, true):
            "\(game) uses its own mapping. Other games are unaffected."
        case (true, false):
            "\(game) follows the all-games mapping. A change here gives it its own."
        }
    }

    // MARK: Pieces

    /// The switch, and the sentence that makes the whole sheet make sense. Which
    /// hand you are editing is also *which controller* you are editing, so the
    /// subtitle says so under the control that changes it.
    private var handPicker: some View {
        VStack(spacing: 14) {
            HStack(spacing: 20) {
                PinchGlyph(hand: .left, finger: nil, isActive: hand == .left)
                    .opacity(hand == .left ? 1 : 0.4)
                Picker("Hand", selection: $hand) {
                    Text("Left").tag(BridgeHand.left)
                    Text("Right").tag(BridgeHand.right)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
                PinchGlyph(hand: .right, finger: nil, isActive: hand == .right)
                    .opacity(hand == .right ? 1 : 0.4)
            }

            Text(hand == .right
                 ? "Your right hand drives the right controller. Pinch your thumb to a fingertip to press the mapped input — one pinch per hand at a time, and a fist suppresses detection."
                 : "Your left hand drives the left controller. Pinch your thumb to a fingertip to press the mapped input — one pinch per hand at a time, and a fist suppresses detection.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .animation(.easeOut(duration: 0.2), value: hand)
    }

    private var rows: some View {
        VStack(spacing: 10) {
            ForEach(Self.fingers, id: \.self) { finger in
                if hand == .left, finger == .index {
                    locomotionRow
                } else {
                    mappingRow(finger)
                }
            }
        }
    }

    private func mappingRow(_ finger: BridgeFinger) -> some View {
        let target = mapping.target(for: hand, finger: finger)
        return HStack(spacing: 16) {
            PinchGlyph(hand: hand, finger: finger)
            Text(fingerName(finger))
                .font(.subheadline)
            Spacer(minLength: 12)
            GestureTargetChip(target: target, hand: hand)
            Picker("", selection: binding(finger: finger)) {
                ForEach(BridgeGestureTarget.allCases, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .labelsHidden()
            .frame(minWidth: 150)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// Reserved, not unassigned: pinching left thumb + index and moving the hand
    /// is how you walk, so there is nothing here to choose. Shown in the row it
    /// would otherwise occupy so the four fingers stay in order.
    private var locomotionRow: some View {
        HStack(spacing: 16) {
            PinchGlyph(hand: .left, finger: .index)
            VStack(alignment: .leading, spacing: 2) {
                Text(fingerName(.index))
                    .font(.subheadline)
                Text("Pinch and move your hand to walk")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Label("Locomotion", systemImage: "figure.walk")
                .font(.callout)
                .foregroundStyle(.secondary)
            Image(systemName: "lock.fill")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder
    private var resetRow: some View {
        if editingTitle {
            Button("Use All-Games Mapping", role: .destructive) {
                bridge?.setTitleGestureMapping(nil)
            }
            .disabled(titleMapping == nil)
        } else {
            Button("Reset to Defaults", role: .destructive) {
                setMapping(.defaults)
            }
            .disabled(globalMapping == .defaults)
        }
    }

    // MARK: Plumbing

    private func binding(finger: BridgeFinger) -> Binding<BridgeGestureTarget> {
        Binding(
            get: { mapping.target(for: hand, finger: finger) },
            set: {
                var edited = mapping
                edited.set($0, for: hand, finger: finger)
                setMapping(edited)
            }
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

/// The controller input a pinch presses, drawn as the button it is. The
/// side-dependent ones (trigger, grip, stick) take the hand, because "L2" and
/// "R2" are the names a player already knows them by and the picker's neutral
/// "Trigger" is not.
private struct GestureTargetChip: View {
    let target: BridgeGestureTarget
    let hand: BridgeHand

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 24))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(target == .none ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
            .frame(width: 40, height: 34)
            // A key-cap behind the glyph. The gamepad symbols are outlines with a
            // lot of air in them, and against a glass row they read as smudges
            // until something sits behind them.
            .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityHidden(true)
    }

    private var isRight: Bool { hand == .right }

    private var symbol: String {
        switch target {
        case .none:       "circle.dashed"
        case .trigger:    isRight ? "r2.button.roundedtop.horizontal.fill" : "l2.button.roundedtop.horizontal.fill"
        case .grip:       isRight ? "r1.button.roundedbottom.horizontal.fill" : "l1.button.roundedbottom.horizontal.fill"
        case .stickClick: isRight ? "r.joystick.press.down.fill" : "l.joystick.press.down.fill"
        case .aButton:    "a.circle.fill"
        case .bButton:    "b.circle.fill"
        case .xButton:    "x.circle.fill"
        case .yButton:    "y.circle.fill"
        case .menu:       "plus.circle.fill"
        case .system:     "house.circle.fill"
        }
    }
}
#endif
