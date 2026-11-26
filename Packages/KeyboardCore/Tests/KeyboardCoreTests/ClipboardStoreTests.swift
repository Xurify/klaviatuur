import XCTest
@testable import KeyboardCore

final class ClipboardStoreTests: XCTestCase {
    func testRecordPinExpiryAndPersistence() {
        let temporaryFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("klaviatuur_clipboard_test_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporaryFile) }

        let baseTime = Date(timeIntervalSince1970: 10_000)
        let store = ClipboardStore(fileURL: temporaryFile, maxUnpinnedItems: 5)

        let pinned = store.addPinnedSnippet("my.email@example.com", now: baseTime)
        XCTAssertNotNil(pinned)
        _ = store.recordCopiedText("temporary code 1234", retentionMinutes: 60, now: baseTime)

        // Two hours later, unpinned item expires while pinned snippet remains
        let twoHoursLater = baseTime.addingTimeInterval(7200)
        let entriesAfterExpiry = store.allEntries(retentionMinutes: 60, now: twoHoursLater)
        XCTAssertEqual(entriesAfterExpiry.count, 1)
        XCTAssertEqual(entriesAfterExpiry.first?.text, "my.email@example.com")
        XCTAssertTrue(entriesAfterExpiry.first?.isPinned == true)

        // Reload from disk verifies persistence
        let reloadedStore = ClipboardStore(fileURL: temporaryFile)
        XCTAssertEqual(reloadedStore.pinnedEntries().first?.text, "my.email@example.com")
    }

    func testOversizedCopyIsNotStored() {
        let temporaryFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("klaviatuur_clipboard_test_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporaryFile) }

        let store = ClipboardStore(fileURL: temporaryFile)
        let huge = String(repeating: "a", count: ClipboardStore.maxStoredTextBytes + 1)
        XCTAssertNil(store.recordCopiedText(huge))
        XCTAssertNil(store.addPinnedSnippet(huge))
        XCTAssertTrue(store.allEntries(retentionMinutes: 60).isEmpty)
    }

    func testPinnedItemsAreCapped() {
        let temporaryFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("klaviatuur_clipboard_test_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporaryFile) }

        let store = ClipboardStore(fileURL: temporaryFile)
        for index in 0..<ClipboardStore.maxPinnedItems {
            XCTAssertNotNil(store.addPinnedSnippet("snippet \(index)"))
        }
        XCTAssertNil(store.addPinnedSnippet("one too many"))
        XCTAssertEqual(store.pinnedEntries().count, ClipboardStore.maxPinnedItems)
    }
}

final class AppGroupStorageTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let name = "klaviatuur.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    func testKeyboardLocalChangeSurvivesWhenSharedWriteIsLost() {
        let (local, localName) = makeDefaults()
        let sharedName = "klaviatuur.tests.shared.\(UUID().uuidString)"
        defer {
            local.removePersistentDomain(forName: localName)
            UserDefaults().removePersistentDomain(forName: sharedName)
        }

        let appStorage = AppGroupStorage(appGroupIdentifier: sharedName, localDefaults: local)
        var fromApp = KeyboardSettings.default
        fromApp.activeScript = .latin
        appStorage.saveSettings(fromApp, now: Date(timeIntervalSince1970: 100))

        // Simulate a keyboard without Full Access: only its local copy takes the newer value.
        var fromKeyboard = fromApp
        fromKeyboard.activeScript = .cyrillic
        let encoded = try! JSONEncoder().encode(fromKeyboard)
        local.set(encoded, forKey: "klaviatuur.keyboard.settings.v1")
        local.set(200.0, forKey: "klaviatuur.keyboard.settings.stamp")

        XCTAssertEqual(appStorage.loadSettings().activeScript, .cyrillic)

        // A later change from the app wins again.
        var laterFromApp = fromApp
        laterFromApp.showNumberRow = false
        appStorage.saveSettings(laterFromApp, now: Date(timeIntervalSince1970: 300))
        XCTAssertEqual(appStorage.loadSettings().activeScript, .latin)
        XCTAssertFalse(appStorage.loadSettings().showNumberRow)
    }
}

final class KeyboardSettingsThemeTests: XCTestCase {
    func testSettingsSavedBeforeThemesStillDecode() throws {
        var legacy = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(KeyboardSettings.default)
        ) as! [String: Any]
        legacy.removeValue(forKey: "storedThemeStyle")
        legacy["showNumberRow"] = false

        let decoded = try JSONDecoder().decode(
            KeyboardSettings.self,
            from: JSONSerialization.data(withJSONObject: legacy)
        )
        XCTAssertEqual(decoded.themeStyle, .tonal)
        XCTAssertFalse(decoded.showNumberRow)
    }

    func testThemeStyleRoundTrips() throws {
        var settings = KeyboardSettings.default
        settings.themeStyle = .glass
        let decoded = try JSONDecoder().decode(
            KeyboardSettings.self,
            from: JSONEncoder().encode(settings)
        )
        XCTAssertEqual(decoded.themeStyle, .glass)
    }
}
