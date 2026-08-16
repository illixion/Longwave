//  PCVRPaywallView.swift
//
//  The one place Longwave asks for money. Reached from the seal in the PCVR
//  tab's toolbar, and shown automatically after a trial session ends.
//
//  It states the limit plainly rather than dressing it up: the reason someone is
//  reading this is that a game just closed, and the useful thing to tell them is
//  what they get and what it costs. Prices come from StoreKit, never from a
//  literal here — the customer's currency and store are not ours to guess.
//
//  Gated behind FOVEATED_ENABLED.

#if FOVEATED_ENABLED
import SwiftUI
import StoreKit

struct PCVRPaywallView: View {
    @Environment(PCVRStore.self) private var store
    @Environment(\.purchase) private var purchase
    @Environment(\.dismiss) private var dismiss

    /// Set when the sheet was opened by a session ending rather than by the
    /// user going looking for it, so the copy can lead with what just happened.
    var afterSessionEnd = false

    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                if store.isUnlocked {
                    unlockedState
                } else {
                    benefits
                    options
                    restoreRow
                }
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                soloDeveloper
                finePrint
            }
            .padding(32)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Unlock PCVR")
        .task {
            await store.loadProducts()
            await store.resolveEntitlements()
        }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: afterSessionEnd ? "hourglass" : "visionpro")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text(afterSessionEnd ? "That session reached 20 minutes" : "Play without the 20-minute limit")
                .font(.title2).fontWeight(.semibold)
            Text("""
            PCVR is free to try for as long as you like — there is no trial period and \
            no session count. Each session simply ends after twenty minutes. Unlocking \
            removes the limit; nothing else about the app changes, and everything outside \
            PCVR is free either way.
            """)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// What actually changes when you pay. Short, and all of it true: the trial is
    /// the full feature on a clock, so the honest list is one item long plus the
    /// reasons it is worth having.
    private var benefits: some View {
        VStack(alignment: .leading, spacing: 14) {
            benefit("infinity", "Sessions of any length",
                    "No clock, no warning banners, no title closing under you mid-raid.")
            benefit("eye", "Gaze-driven foveation, kept",
                    "The same host-side foveated rendering the trial runs — full detail where you look, on every session.")
            benefit("person.2", "Everywhere you sign in",
                    "One purchase covers every Vision Pro on your Apple Account.")
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func benefit(_ icon: String, _ title: String, _ detail: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline).fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .frame(width: 26)
        }
    }

    @ViewBuilder
    private var options: some View {
        if let failure = store.loadFailure {
            VStack(alignment: .leading, spacing: 12) {
                Text(failure).foregroundStyle(.secondary)
                Button("Try again") {
                    Task { await store.loadProducts() }
                }
            }
        } else if store.products.isEmpty {
            ProgressView().frame(maxWidth: .infinity)
        } else {
            HStack(alignment: .top, spacing: 16) {
                ForEach(store.products, id: \.id) { product in
                    productCard(product)
                }
            }
        }
    }

    /// A card apiece rather than two rows in a list: they are alternatives, and
    /// side by side is how a pair of alternatives is read. The one-off is the
    /// prominent one — it is the better deal past a year and the one with nothing
    /// to cancel, and pretending otherwise to push the subscription would be a
    /// small lie told for money.
    private func productCard(_ product: Product) -> some View {
        let isLifetime = product.id == PCVRStore.ProductID.lifetime
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(isLifetime ? "Buy once" : "Subscribe")
                    .font(.headline)
                if isLifetime {
                    Text("Best value")
                        .font(.caption2).fontWeight(.medium)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.35), in: Capsule())
                }
            }

            Text(priceLabel(product))
                .font(.system(size: 30, weight: .semibold))
                .monospacedDigit()

            Text(isLifetime
                 ? "A single payment. Yours permanently, with nothing to cancel."
                 : "Cancel whenever you like, in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                Task { await buy(product) }
            } label: {
                Group {
                    if store.purchaseInFlight == product.id {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(isLifetime ? "Unlock PCVR" : "Start subscription")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(isLifetime ? AnyButtonStyle(.borderedProminent) : AnyButtonStyle(.bordered))
            .disabled(store.purchaseInFlight != nil)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(isLifetime ? AnyShapeStyle(.tint.opacity(0.6)) : AnyShapeStyle(.clear),
                              lineWidth: 2)
        }
    }

    /// "$1.99/month" for the subscription, the bare price for the one-off. The
    /// period comes from the product so a future annual plan reads correctly
    /// without another branch here.
    private func priceLabel(_ product: Product) -> String {
        guard let period = product.subscription?.subscriptionPeriod else { return product.displayPrice }
        let unit: String
        switch period.unit {
        case .day: unit = period.value == 7 ? "week" : "day"
        case .week: unit = "week"
        case .month: unit = "month"
        case .year: unit = "year"
        @unknown default: return product.displayPrice
        }
        return "\(product.displayPrice)/\(unit)"
    }

    private var unlockedState: some View {
        Label("PCVR is unlocked on this Apple Account. Sessions run as long as you want.",
              systemImage: "checkmark.seal.fill")
            .font(.callout)
            .foregroundStyle(.green)
    }

    /// Who the money goes to. Worth one paragraph and no more: it is a reason, not
    /// an argument, and a paywall that pleads is worse than one that just says the
    /// price.
    private var soloDeveloper: some View {
        Label {
            Text("Longwave is written by one person. There are no ads, no accounts and no analytics in it, and PCVR is the only paid part — buying it is what pays for the RTX card, the Apple Developer account, and the time the rest of the app is given away in.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "heart.circle")
                .foregroundStyle(.tint)
                .frame(width: 26)
        }
    }

    private var restoreRow: some View {
        HStack {
            Button {
                Task {
                    await store.restore()
                    message = store.isUnlocked
                        ? nil
                        : "No previous purchase was found on this Apple Account."
                }
            } label: {
                if store.isRestoring {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Restore purchases")
                }
            }
            .disabled(store.isRestoring)
            Spacer()
            Button("Not now") { dismiss() }
        }
    }

    private var finePrint: some View {
        Text("""
        A subscription renews automatically until cancelled, and can be managed or \
        cancelled in Settings › Apple Account › Subscriptions. Buying once is a single \
        payment with nothing to cancel. Either one unlocks PCVR everywhere you are signed \
        in with the same Apple Account.
        """)
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    // MARK: Actions

    private func buy(_ product: Product) async {
        switch await store.purchase(product, using: purchase) {
        case .unlocked:
            dismiss()
        case .pending:
            message = "That purchase needs approval. PCVR unlocks as soon as it is approved."
        case .cancelled:
            message = nil
        case .failed(let reason):
            message = reason
        }
    }
}

/// Two button styles in one expression need a common type; `AnyButtonStyle`
/// keeps the branch at the call site instead of duplicating the whole card.
private struct AnyButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: PrimitiveButtonStyle>(_ style: S) {
        make = { configuration in AnyView(Button(configuration).buttonStyle(style)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
#endif
