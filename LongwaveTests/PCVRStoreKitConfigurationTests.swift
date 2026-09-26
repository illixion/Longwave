import XCTest
import StoreKit
import StoreKitTest
@testable import Longwave

/// Configuration/Longwave.storekit is the local stand-in for App Store Connect.
/// If its product identifiers drift from `PCVRStore.ProductID`, a StoreKit-backed
/// run of the paywall shows no products and the mismatch looks like a network
/// problem, so pin them together here.
#if FOVEATED_ENABLED
final class PCVRStoreKitConfigurationTests: XCTestCase {

    private var session: SKTestSession!

    private static let configurationURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Configuration/Longwave.storekit")

    override func setUpWithError() throws {
        session = try SKTestSession(contentsOf: Self.configurationURL)
        session.disableDialogs = true
        session.clearTransactions()
    }

    override func tearDown() {
        session?.clearTransactions()
        session = nil
    }

    func testConfigurationOffersExactlyTheStoreProducts() async throws {
        let products = try await Product.products(for: PCVRStore.ProductID.all)
        XCTAssertEqual(Set(products.map(\.id)), Set(PCVRStore.ProductID.all))

        let lifetime = try XCTUnwrap(products.first { $0.id == PCVRStore.ProductID.lifetime })
        XCTAssertEqual(lifetime.type, .nonConsumable)

        let monthly = try XCTUnwrap(products.first { $0.id == PCVRStore.ProductID.monthly })
        XCTAssertEqual(monthly.type, .autoRenewable)
        let period = try XCTUnwrap(monthly.subscription?.subscriptionPeriod)
        XCTAssertEqual(period.unit, .month)
        XCTAssertEqual(period.value, 1)
    }

    /// The prices the paywall and the docs quote. Read from the file rather than
    /// from `Product.price`: the test session parses the file's prices with the
    /// simulator's locale, and a comma-decimal region truncates 24.99 to 24.
    func testConfigurationPricesMatchTheAdvertisedOnes() throws {
        struct Item: Decodable { let productID: String; let displayPrice: String }
        struct Group: Decodable { let subscriptions: [Item] }
        struct File: Decodable { let products: [Item]; let subscriptionGroups: [Group] }

        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: Self.configurationURL))
        let items = file.products + file.subscriptionGroups.flatMap(\.subscriptions)
        let prices = Dictionary(uniqueKeysWithValues: items.map { ($0.productID, $0.displayPrice) })
        XCTAssertEqual(prices, [PCVRStore.ProductID.lifetime: "24.99",
                                PCVRStore.ProductID.monthly: "1.99"])
    }
}
#endif
