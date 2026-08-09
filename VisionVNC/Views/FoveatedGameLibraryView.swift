//  FoveatedGameLibraryView.swift
//
//  Gallery of the PC's curated games, shown from the PCVR controls window during
//  a foveated session. Tall 2:3 box art (Steam's library_600x900) laid out in a
//  grid, tapped to launch on the host.
//
//  Curation is deliberately absent here: what appears is whatever the user
//  selected in the Windows companion app. The headset cannot browse the PC, add
//  a title, or remove one — so this view has no editing affordances at all, and
//  says so when the list is empty rather than offering a way to fix it.
//
//  Gated behind FOVEATED_ENABLED.

#if FOVEATED_ENABLED
import SwiftUI

struct FoveatedGameLibraryView: View {
    @Environment(FoveatedConnectionManager.self) private var manager
    @Environment(\.dismiss) private var dismiss

    private var library: FoveatedGameLibrary { manager.gameLibrary }

    /// 2:3 box art. 148pt reads at arm's length without the grid turning into a
    /// wall of thumbnails on a 29-title library.
    private static let tileWidth: CGFloat = 148
    private static let columns = [GridItem(.adaptive(minimum: tileWidth), spacing: 26)]

    var body: some View {
        Group {
            // Deliberately three distinct outcomes, not two. "Nothing came back
            // from the PC" and "the PC has nothing shared" look identical to a
            // user and have completely different fixes; showing the first one
            // under a "No Games" heading sent a real debugging session down the
            // wrong path.
            if library.titles.isEmpty, case .failed(let message) = library.state {
                unreachable(message)
            } else if library.titles.isEmpty, library.state != .loaded {
                ProgressView("Reading the PC's library…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if library.titles.isEmpty {
                noneShared
            } else {
                grid
            }
        }
        .navigationTitle("Games")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { library.refresh() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(library.state == .loading)
            }
        }
        .overlay(alignment: .bottom) {
            if let error = library.lastLaunchError {
                Text(error)
                    .font(.callout)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .glassBackgroundEffect()
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring, value: library.lastLaunchError)
        .onChange(of: library.lastSuccessfulLaunchID) { _, titleID in
            if titleID != nil { dismiss() }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: Self.columns, spacing: 30) {
                ForEach(library.titles) { title in
                    GameCover(title: title,
                              art: library.art[title.id],
                              isLaunching: library.launching == title.id)
                        .onTapGesture { library.launch(title) }
                        // Art is fetched as tiles come into view, not up front: a
                        // full library is about a megabyte of jpeg sharing the
                        // channel with hand tracking.
                        .onAppear { library.loadArt(for: title) }
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
        }
    }

    /// The PC could not be asked, or did not answer. A host problem, not a
    /// curation one — so it never claims the library is empty.
    private func unreachable(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Can't Reach the PC", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") { library.refresh() }
        }
    }

    /// The PC answered, with nothing. Only fixable on the PC, so this offers no
    /// action beyond re-asking.
    private var noneShared: some View {
        ContentUnavailableView {
            Label("No Games Shared", systemImage: "gamecontroller")
        } description: {
            Text("Choose which games to offer in the VisionVNC Windows Companion, on the PC. "
                 + "Only the games you tick there appear here.")
        } actions: {
            Button("Check Again") { library.refresh() }
        }
    }
}

/// One box-art tile. Depth is the point of it: the cover stands off the window's
/// glass on its own plane with a cast shadow, so the grid reads as a shelf of
/// boxes rather than a flat contact sheet, and the system lift effect pulls the
/// looked-at one further forward.
private struct GameCover: View {
    let title: GameLibraryTitle
    let art: Image?
    let isLaunching: Bool

    private static let cornerRadius: CGFloat = 12
    /// Static separation from the window plane. Constant rather than hover-driven:
    /// on visionOS `onHover` does not follow gaze (deliberately — where you look
    /// is not reported to the app), so any depth the app animates itself would
    /// only ever respond to a trackpad. Gaze response comes from `hoverEffect`,
    /// which the system renders out of process.
    private static let plateDepth: CGFloat = 14

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                if let art {
                    art.resizable().aspectRatio(2 / 3, contentMode: .fill)
                } else {
                    placeholder
                }
                if isLaunching {
                    Color.black.opacity(0.45)
                    ProgressView().controlSize(.large).tint(.white)
                }
            }
            .aspectRatio(2 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            // A thin specular rim rather than a border: on glass a border reads as
            // a frame around the art, a rim reads as the edge of the box itself.
            .overlay {
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.32), radius: 12, y: 7)
            .offset(z: Self.plateDepth)
            // Scale on gaze in addition to the lift: the lift alone is subtle on
            // art that already has its own bright edges.
            .hoverEffect { effect, isActive, _ in
                effect.animation(.spring(response: 0.28, dampingFraction: 0.72)) {
                    $0.scaleEffect(isActive ? 1.04 : 1.0)
                }
            }
            .hoverEffect(.lift)

            Text(title.name)
                .font(.caption)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title.name)
        .accessibilityHint("Starts this game on the PC")
        .accessibilityAddTraits(.isButton)
    }

    /// Shown for the handful of titles Steam has never cached art for, and for
    /// custom executables (which have none by definition).
    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.18), Color(white: 0.09)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(initial)
                .font(.system(size: 54, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.22))
        }
    }

    private var initial: String {
        String(title.name.first.map(String.init)?.uppercased() ?? "?")
    }
}
#endif
