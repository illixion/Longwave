//  PCVRPaywallView.swift
//
//  The one place Longwave asks for money. Reached from the PCVR tab, and shown
//  after a trial session ends.
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
            VStack(alignment: .leading, spacing: 28) {
                header
                if store.isUnlocked {
                    unlockedState
                } else {
                    options
                    restoreRow
                }
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                finePrint
            }
            .padding(32)
            .frame(maxWidth: 620, alignment: .leading)
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
        VStack(alignment: .leading, spacing: 10) {
            Label(afterSessionEnd ? "That session reached 20 minutes" : "Play without the 20-minute limit",
                  systemImage: "visionpro")
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
            VStack(spacing: 14) {
                ForEach(store.products, id: \.id) { product in
                    productRow(product)
                }
            }
        }
    }

    private func productRow(_ product: Product) -> some View {
        let isLifetime = product.id == PCVRStore.ProductID.lifetime
        return Button {
            Task { await buy(product) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isLifetime ? "Buy once" : "Subscribe")
                        .font(.headline)
                    Text(isLifetime
                         ? "Yours permanently, on every device signed in to this Apple Account."
                         : "Cancel whenever you like, in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 12)
                if store.purchaseInFlight == product.id {
                    ProgressView().controlSize(.small)
                } else {
                    Text(priceLabel(product))
                        .font(.headline)
                        .monospacedDigit()
                }
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(isLifetime ? AnyButtonStyle(.borderedProminent) : AnyButtonStyle(.bordered))
        .disabled(store.purchaseInFlight != nil)
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
              systemImage: "checkmark.circle.fill")
            .font(.callout)
            .foregroundStyle(.green)
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
/// keeps the branch at the call site instead of duplicating the whole row.
private struct AnyButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: PrimitiveButtonStyle>(_ style: S) {
        make = { configuration in AnyView(Button(configuration).buttonStyle(style)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
#endif
