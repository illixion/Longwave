//  PCVRPanels.swift
//
//  The building blocks the PCVR tab is assembled from: a titled glass panel, a
//  selectable option tile, and the little drawings that go inside the tiles.
//
//  The tab used to be a `Form`, which is the right shape for a list of settings
//  and the wrong one for a page that has to *explain* things — three immersion
//  styles and two ways of finding a PC are choices nobody can make from a
//  three-word segmented control. Panels give each choice room for a picture and
//  a sentence, and cost nothing on the settings that really are just toggles.
//
//  Gated behind FOVEATED_ENABLED.

#if FOVEATED_ENABLED
import RAVEInput
import SwiftUI

// MARK: - Container

/// A titled card. Sized by its content, full width, with the section's name and
/// icon at the top so a panel is still scannable when the page is scrolled past
/// its heading.
struct PCVRPanel<Content: View>: View {
    let title: String
    let systemImage: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.headline)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            content
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

// MARK: - Option tile

/// One choice in a row of choices: a drawing, a name, a sentence. Selection is
/// carried by a tinted fill and a rim rather than a checkmark — at tile size the
/// checkmark is the smallest part of the control and the first thing missed.
struct PCVROptionTile<Graphic: View>: View {
    let title: String
    let detail: String
    let isSelected: Bool
    var badge: String?
    let action: () -> Void
    @ViewBuilder var graphic: Graphic

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                graphic
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(title)
                    .font(.subheadline).fontWeight(.semibold)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            // `maxHeight` as well as `maxWidth`: tiles sit in an HStack and their
            // sentences are not the same length, so without it a row of choices
            // comes out as a row of different-sized boxes — which reads as a
            // hierarchy that is not there.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // Overlaid, not stacked: beside the title it wraps to two hyphenated
            // syllables at tile width, and above the title it reads as a heading
            // for the tile rather than a note about it. The corner beside the
            // drawing is empty space in every tile.
            .overlay(alignment: .topTrailing) {
                if let badge {
                    Text(badge)
                        .font(.caption2).fontWeight(.medium)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.35), in: Capsule())
                        .padding(10)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(.tint.opacity(0.22)) : AnyShapeStyle(.fill.quaternary))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .hoverEffect(.highlight)
        .animation(.easeOut(duration: 0.18), value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// An option tile that reports rather than offers. Same shape as `PCVROptionTile`
/// so a row of them reads the same, but not a button: the state it shows is set
/// somewhere else — on the PC — and a tile that looked pressable would be
/// promising something it cannot deliver.
struct PCVRStatusTile<Graphic: View>: View {
    let title: String
    let detail: String
    let isActive: Bool
    @ViewBuilder var graphic: Graphic

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            graphic
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(isActive ? 1 : 0.45)
            HStack(spacing: 8) {
                Text(title)
                    .font(.subheadline).fontWeight(.semibold)
                if isActive {
                    Text("Active")
                        .font(.caption2).fontWeight(.medium)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.35), in: Capsule())
                }
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(isActive ? AnyShapeStyle(.tint.opacity(0.22)) : AnyShapeStyle(.fill.quaternary))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .animation(.easeOut(duration: 0.18), value: isActive)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isActive ? "Active" : "Inactive")
    }
}

// MARK: - Drawings

/// What each immersion style looks like from inside the headset, drawn rather
/// than symbolised: the difference between "portal", "composited" and "sealed"
/// is a picture, and there is no SF Symbol that tells those three apart.
struct ImmersionGlyph: View {
    let style: FoveatedImmersionStyle

    /// Small enough to leave the tile's top-right corner free for the badge.
    private static let size = CGSize(width: 100, height: 58)
    private static let radius: CGFloat = 11

    var body: some View {
        ZStack {
            room
            switch style {
            case .mixed: mixedContent
            case .progressive: progressiveContent
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        }
    }

    /// The passthrough behind everything: a horizon and a suggestion of a window,
    /// enough for "this is your room" to read at 128 points wide.
    private var room: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(.quaternary)
            Rectangle()
                .fill(.white.opacity(0.06))
                .frame(height: 17)
            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(width: 20, height: 24)
                .offset(x: 11, y: -24)
        }
    }

    private var streamFill: LinearGradient {
        LinearGradient(colors: [Color.accentColor.opacity(0.95), Color.accentColor.opacity(0.45)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Mixed: the game as a shape standing in the room, passthrough all around it.
    private var mixedContent: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(streamFill)
            .frame(width: 58, height: 33)
            .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
    }

    /// Progressive: a portal, opaque inside, with the Digital Crown implied at the
    /// edge — the control that makes it wider.
    private var progressiveContent: some View {
        ZStack {
            Circle()
                .fill(streamFill)
                .frame(width: 40, height: 40)
                .overlay { Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1) }
            Capsule()
                .fill(.white.opacity(0.5))
                .frame(width: 4, height: 18)
                .offset(x: 42)
        }
    }

}

/// A hand with one finger pinched to the thumb. Four of these side by side are
/// the fastest way to say which gesture a row is about — "Thumb + Ring" is a
/// phrase you have to decode, a picture is not.
struct PinchGlyph: View {
    let hand: BridgeHand
    /// The finger touching the thumb. `nil` draws the open hand.
    let finger: BridgeFinger?
    var isActive = true

    private static let size = CGSize(width: 62, height: 58)

    /// Centre line and length of each finger, index → little. Splayed enough that
    /// the gaps survive at this size: at 3 pt they close up and the hand renders
    /// as one solid mitten.
    private static let columns: [BridgeFinger: (x: CGFloat, length: CGFloat)] = [
        .index:  (26, 23),
        .middle: (36, 27),
        .ring:   (46, 23),
        .little: (55, 18),
    ]
    private static let order: [BridgeFinger] = [.index, .middle, .ring, .little]
    /// Where the fingers meet the palm, and where the thumb's tip sits.
    private static let knuckleY: CGFloat = 34
    private static let thumbTip = CGPoint(x: 12, y: 27)

    var body: some View {
        ZStack {
            palm
            thumb
            ForEach(Self.order, id: \.self) { item in
                fingerBar(item)
            }
            contactArc
        }
        .frame(width: Self.size.width, height: Self.size.height)
        // One drawing, mirrored: a left hand is a right hand seen from the other
        // side, and mirroring is honest about that where a second set of
        // hand-tuned coordinates would only be a chance to get one of them wrong.
        .scaleEffect(x: hand == .left ? -1 : 1, y: 1, anchor: .center)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: finger)
        .accessibilityHidden(true)
    }

    private var tint: AnyShapeStyle {
        isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary.opacity(0.55))
    }

    private var rest: AnyShapeStyle { AnyShapeStyle(.secondary.opacity(0.3)) }

    /// With no finger named there is no pinch to point at, so the whole hand
    /// carries the state instead — that is the open hand beside the hand switch.
    private var idleFill: AnyShapeStyle { finger == nil ? tint : rest }

    private var palm: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(idleFill)
            .frame(width: 37, height: 23)
            .position(x: 40, y: 45)
    }

    private func fingerBar(_ item: BridgeFinger) -> some View {
        let column = Self.columns[item] ?? (36, 24)
        let pinched = item == finger
        // A pinched finger curls: shorter, and its tip is where the arc lands.
        let length = pinched ? column.length * 0.62 : column.length
        return Capsule()
            .fill(pinched ? tint : idleFill)
            .frame(width: 7, height: length)
            .position(x: column.x, y: Self.knuckleY - length / 2)
    }

    private var thumb: some View {
        Capsule()
            .fill(finger == nil ? idleFill : tint)
            .frame(width: 7, height: 21)
            .rotationEffect(.degrees(-34))
            .position(x: 17, y: 36)
    }

    /// The pinch itself. Rotating the finger down to physically meet the thumb was
    /// tried first and reads as a stray diagonal across the palm at this size; a
    /// dashed arc between the two tips says "these touch" without pretending to
    /// be anatomy.
    @ViewBuilder
    private var contactArc: some View {
        if let finger, let column = Self.columns[finger] {
            let tipY = Self.knuckleY - column.length * 0.62
            Path { path in
                path.move(to: Self.thumbTip)
                path.addQuadCurve(
                    to: CGPoint(x: column.x, y: tipY),
                    control: CGPoint(x: (Self.thumbTip.x + column.x) / 2, y: tipY - 9)
                )
            }
            .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 3.5]))
        }
    }
}
#endif
