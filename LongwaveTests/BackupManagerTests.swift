import XCTest
import SwiftData
@testable import Longwave

final class BackupManagerTests: XCTestCase {
    private func makeInMemoryContext() throws -> ModelContext {
        let schema = Schema([SavedConnection.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    func testConnectionBackupExcludesSecretsButKeepsEverythingElse() {
        let connection = SavedConnection(hostname: "mac.local", port: 5900, label: "Office Mac")
        connection.savedUsername = "vlad"
        connection.savedPassword = "super-secret-password"
        connection.companionToken = "super-secret-token"
        connection.autoLogin = true

        let backup = ConnectionBackup(from: connection)
        let encoder = JSONEncoder()
        let data = try! encoder.encode(backup)
        let json = String(data: data, encoding: .utf8)!

        XCTAssertFalse(json.contains("super-secret-password"))
        XCTAssertFalse(json.contains("super-secret-token"))
        XCTAssertTrue(json.contains("mac.local"))
        XCTAssertTrue(json.contains("vlad"))
        XCTAssertEqual(backup.id, connection.id)
        XCTAssertTrue(backup.autoLogin)
    }

    func testRestoreReplacesConnectionListAndPreservesUntouchedSecrets() throws {
        let context = try makeInMemoryContext()

        let kept = SavedConnection(hostname: "kept.local", label: "Kept")
        kept.savedPassword = "kept-password"
        let removed = SavedConnection(hostname: "removed.local", label: "Removed")
        context.insert(kept)
        context.insert(removed)
        try context.save()

        // Backup: `kept` with an edited label, plus a brand-new connection.
        // `removed` is absent, so a restore should delete it.
        var keptBackup = ConnectionBackup(from: kept)
        keptBackup.label = "Kept (renamed)"
        let newID = UUID()
        var newConnectionBackup = ConnectionBackup(from: SavedConnection(hostname: "new.local", label: "New"))
        newConnectionBackup.id = newID

        let backup = LongwaveBackup(
            version: LongwaveBackup.currentVersion,
            exportDate: Date(),
            appVersion: "test",
            connections: [keptBackup, newConnectionBackup],
            preferences: nil
        )

        try BackupManager.restore(backup, context: context)

        let all = try context.fetch(FetchDescriptor<SavedConnection>())
        XCTAssertEqual(all.count, 2)

        let restoredKept = all.first { $0.id == kept.id }
        XCTAssertEqual(restoredKept?.label, "Kept (renamed)")
        // The secret wasn't in the backup, so restore must leave it alone.
        XCTAssertEqual(restoredKept?.savedPassword, "kept-password")

        let restoredNew = all.first { $0.id == newID }
        XCTAssertEqual(restoredNew?.hostname, "new.local")

        XCTAssertNil(all.first { $0.id == removed.id })
    }

    func testRestorePreferencesOnlyOverwritesFieldsPresentInBackup() throws {
        let context = try makeInMemoryContext()
        UserDefaults.standard.set(9999, forKey: "default_vnc_port")
        UserDefaults.standard.removeObject(forKey: "default_terminal_font_size")

        var prefs = PreferencesBackup()
        prefs.vncPort = 6900
        // terminalFontSize deliberately left nil.

        let backup = LongwaveBackup(
            version: LongwaveBackup.currentVersion,
            exportDate: Date(),
            appVersion: "test",
            connections: nil,
            preferences: prefs
        )

        try BackupManager.restore(backup, context: context)

        XCTAssertEqual(UserDefaults.standard.integer(forKey: "default_vnc_port"), 6900)
        XCTAssertNil(UserDefaults.standard.object(forKey: "default_terminal_font_size"))
    }

    func testBackupRoundTripsThroughJSON() throws {
        let context = try makeInMemoryContext()
        let connection = SavedConnection(hostname: "round.trip", label: "Round Trip")
        context.insert(connection)
        try context.save()

        let exported = BackupManager.exportBackup(context: context)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(exported)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(LongwaveBackup.self, from: data)

        XCTAssertEqual(decoded.version, LongwaveBackup.currentVersion)
        XCTAssertEqual(decoded.connections?.first?.hostname, "round.trip")
    }
}
