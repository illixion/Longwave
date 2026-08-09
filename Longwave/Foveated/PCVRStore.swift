//  PCVRStore.swift
//
//  What the user has bought, and the only thing that lifts the PCVR session
//  limit. Everything else in Longwave is free; this covers PCVR alone.
//
//  Two ways to buy the same thing, because they suit different people: a
//  monthly subscription for someone who plays in bursts, and a one-off unlock
//  for someone who would rather never think about it again. Owning either is
//  identical at runtime — `isUnlocked` is the whole interface the rest of the
//  app sees.
//
//  Gated behind FOVEATED_ENABLED, which means the open-source editions contain
//  no purchase code at all rather than code that is switched off.

#if FOVEATED_ENABLED
import Foundation
import StoreKit
import SwiftUI
import os

@Observable
final class PCVRStore {

    /// Must match App Store Connect exactly. `lifetime` is a non-consumable,
    /// `monthly` an auto-renewable subscription.
    enum ProductID {
        static let lifetime = "com.illixion.LongwavePro.pcvr.lifetime"
        static let monthly = "com.illixion.LongwavePro.pcvr.monthly"
        /// Lifetime first: it is the order the paywall lists them in, and the
        /// order `resolveEntitlements` prefers when someone holds both.
        static let all = [lifetime, monthly]
    }

    enum Unlock: Equatable {
        case lifetime
        case subscription

        var label: String {
            switch self {
            case .lifetime: "Purchased"
            case .subscription: "Subscribed"
            }
        }
    }

    /// Nil until `resolveEntitlements` has run once. The distinction matters:
    /// "not unlocked" and "not known yet" must not look the same to the session
    /// limiter, or a slow StoreKit query would start a trial clock on a paying
    /// customer.
    private(set) var unlock: Unlock??
    private(set) var products: [Product] = []
    private(set) var loadFailure: String?
    private(set) var purchaseInFlight: String?
    private(set) var isRestoring = false

    /// True only once StoreKit has answered and the answer was "nothing owned".
    var isTrial: Bool { unlock == .some(nil) }
    var isUnlocked: Bool {
        if case .some(.some) = unlock { return true }
        return false
    }
    /// Whether entitlements have been resolved at all yet.
    var isResolved: Bool { unlock != nil }

    private var updatesTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.illixion.Longwave", category: "PCVRStore")

    init() {
        // Transactions can arrive without the app asking: a renewal, a purchase
        // made on another device, an Ask-to-Buy approval, a refund. Listening for
        // the app's whole lifetime is StoreKit's documented requirement, not a
        // nicety — a transaction that is never finished is redelivered forever.
        updatesTask = Task { [weak self] in
            for await update in StoreKit.Transaction.updates {
                guard let self else { return }
                if let transaction = Self.verified(update) {
                    await transaction.finish()
                }
                await self.resolveEntitlements()
            }
        }
    }

    deinit { updatesTask?.cancel() }

    // MARK: Entitlements

    /// Recomputes `unlock` from what StoreKit currently considers owned.
    /// `currentEntitlements` already excludes expired subscriptions, refunded
    /// purchases and upgraded-away transactions, so no expiry arithmetic here.
    func resolveEntitlements() async {
        var found: Unlock?
        for await entitlement in StoreKit.Transaction.currentEntitlements {
            guard let transaction = Self.verified(entitlement) else { continue }
            switch transaction.productID {
            case ProductID.lifetime:
                // Outranks a subscription: someone holding both should not lose
                // access if the subscription lapses.
                found = .lifetime
            case ProductID.monthly:
                if found != .lifetime { found = .subscription }
            default:
                continue
            }
        }
        unlock = .some(found)
    }

    /// A transaction whose signature the App Store did not vouch for is not a
    /// purchase. There is no salvage path worth writing — treat it as absent.
    private static func verified(_ result: VerificationResult<StoreKit.Transaction>) -> StoreKit.Transaction? {
        switch result {
        case .verified(let transaction): transaction
        case .unverified: nil
        }
    }

    // MARK: Catalogue

    func loadProducts() async {
        guard products.isEmpty else { return }
        do {
            let loaded = try await Product.products(for: ProductID.all)
            // Preserve the order in ProductID.all; StoreKit does not promise one.
            products = ProductID.all.compactMap { id in loaded.first { $0.id == id } }
            loadFailure = products.isEmpty ? "No purchase options are available right now." : nil
        } catch {
            log.error("Product load failed: \(error.localizedDescription, privacy: .public)")
            loadFailure = "Could not reach the App Store. Check your connection and try again."
        }
    }

    // MARK: Purchase

    enum PurchaseOutcome { case unlocked, pending, cancelled, failed(String) }

    /// Takes SwiftUI's `PurchaseAction` rather than calling `product.purchase()`
    /// directly: on visionOS the bare call is unavailable, because the App Store
    /// sheet has to be confirmed in a specific scene, and the environment action
    /// is what knows which one that is.
    @discardableResult
    func purchase(_ product: Product, using action: PurchaseAction) async -> PurchaseOutcome {
        purchaseInFlight = product.id
        defer { purchaseInFlight = nil }
        do {
            switch try await action(product) {
            case .success(let verification):
                guard let transaction = Self.verified(verification) else {
                    return .failed("That purchase could not be verified.")
                }
                await transaction.finish()
                await resolveEntitlements()
                return isUnlocked ? .unlocked : .failed("The purchase went through but did not unlock PCVR.")
            case .pending:
                // Ask to Buy, or a payment method needing approval. The unlock
                // arrives later through StoreKit.Transaction.updates.
                return .pending
            case .userCancelled:
                return .cancelled
            @unknown default:
                return .failed("The App Store returned an unexpected result.")
            }
        } catch {
            log.error("Purchase failed: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
    }

    /// For a new device or a reinstall. `AppStore.sync()` prompts for the App
    /// Store password, so it belongs behind a button the user pressed — the
    /// automatic path is `resolveEntitlements`, which needs no prompt.
    func restore() async {
        isRestoring = true
        defer { isRestoring = false }
        try? await AppStore.sync()
        await resolveEntitlements()
    }
}
#endif
