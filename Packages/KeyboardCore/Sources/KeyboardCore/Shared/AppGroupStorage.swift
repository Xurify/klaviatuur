import Foundation

public final class AppGroupStorage {
    public static let appGroupIdentifier = "group.com.klaviatuur.shared"
    private static let settingsStorageKey = "klaviatuur.keyboard.settings.v1"
    private static let settingsStampKey = "klaviatuur.keyboard.settings.stamp"

    public let userDefaults: UserDefaults
    public let containerURL: URL
    /// Process-local defaults. Without Full Access the keyboard can only read the App Group,
    /// so its own changes (like the language picked with the globe key) are kept here too.
    private let localDefaults: UserDefaults

    public init(
        appGroupIdentifier: String = AppGroupStorage.appGroupIdentifier,
        localDefaults: UserDefaults = .standard
    ) {
        self.localDefaults = localDefaults
        if let sharedDefaults = UserDefaults(suiteName: appGroupIdentifier) {
            self.userDefaults = sharedDefaults
        } else {
            self.userDefaults = .standard
        }

        if let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) {
            self.containerURL = groupURL
        } else {
            self.containerURL = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
        }
    }

    public var clipboardFileURL: URL {
        containerURL.appendingPathComponent("clipboard_history.json")
    }

    public var userDictionaryFileURL: URL {
        containerURL.appendingPathComponent("user_words.json")
    }

    /// Returns whichever copy was written most recently: the shared one (normally written by the
    /// app) or the local one (written by the keyboard when the shared write may not stick).
    public func loadSettings() -> KeyboardSettings {
        let shared = Self.readSettings(from: userDefaults)
        let local = userDefaults === localDefaults ? nil : Self.readSettings(from: localDefaults)
        switch (shared, local) {
        case let (shared?, local?):
            return local.stamp > shared.stamp ? local.settings : shared.settings
        case let (shared?, nil):
            return shared.settings
        case let (nil, local?):
            return local.settings
        case (nil, nil):
            return .default
        }
    }

    public func saveSettings(_ settings: KeyboardSettings, now: Date = Date()) {
        guard let encoded = try? JSONEncoder().encode(settings) else { return }
        let stamp = now.timeIntervalSince1970
        for defaults in [userDefaults, localDefaults] {
            defaults.set(encoded, forKey: Self.settingsStorageKey)
            defaults.set(stamp, forKey: Self.settingsStampKey)
        }
    }

    private static func readSettings(from defaults: UserDefaults) -> (settings: KeyboardSettings, stamp: Double)? {
        guard let data = defaults.data(forKey: settingsStorageKey),
              let decoded = try? JSONDecoder().decode(KeyboardSettings.self, from: data)
        else {
            return nil
        }
        return (decoded, defaults.double(forKey: settingsStampKey))
    }
}
