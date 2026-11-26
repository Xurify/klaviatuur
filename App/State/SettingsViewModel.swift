import Foundation
import Combine
import UIKit
import KeyboardCore

@MainActor
final class SettingsViewModel: ObservableObject {
    private let storage = AppGroupStorage()
    private lazy var clipboardStore = ClipboardStore(fileURL: storage.clipboardFileURL)

    @Published var settings: KeyboardSettings {
        didSet {
            storage.saveSettings(settings)
        }
    }

    @Published var clipboardEntries: [ClipboardEntry] = []
    @Published var isKeyboardEnabledInSystem: Bool = false

    init() {
        self.settings = storage.loadSettings()
        refreshAll()
    }

    func refreshAll() {
        settings = storage.loadSettings()
        clipboardStore.reload()
        clipboardEntries = clipboardStore.allEntries(retentionMinutes: settings.clipboardRetentionMinutes)
        checkKeyboardRegistration()
    }

    func checkKeyboardRegistration() {
        let keyboards = UserDefaults.standard.object(forKey: "AppleKeyboards") as? [String] ?? []
        isKeyboardEnabledInSystem = keyboards.contains { identifier in
            identifier.contains("com.klaviatuur.app.keyboard")
        }
    }

    func toggleLanguage(_ language: LanguageCode) {
        if let existingIndex = settings.enabledLanguages.firstIndex(of: language) {
            guard settings.enabledLanguages.count > 1 else { return }
            settings.enabledLanguages.remove(at: existingIndex)
        } else {
            settings.enabledLanguages.append(language)
        }
        if !settings.availableScripts().contains(settings.activeScript) {
            settings.activeScript = settings.availableScripts().first ?? .latin
        }
    }

    func moveLanguages(from offsets: IndexSet, to destination: Int) {
        var updated = settings.enabledLanguages
        var moving: [LanguageCode] = []
        for index in offsets.sorted(by: >) {
            moving.insert(updated.remove(at: index), at: 0)
        }
        let clampedDestination = min(destination, updated.count)
        updated.insert(contentsOf: moving, at: clampedDestination)
        settings.enabledLanguages = updated
    }

    func addPinnedSnippet(_ text: String) {
        _ = clipboardStore.addPinnedSnippet(text)
        clipboardEntries = clipboardStore.allEntries(retentionMinutes: settings.clipboardRetentionMinutes)
    }

    func togglePin(_ entryID: UUID) {
        clipboardStore.togglePin(entryID: entryID)
        clipboardEntries = clipboardStore.allEntries(retentionMinutes: settings.clipboardRetentionMinutes)
    }

    func deleteClipboardEntry(_ entryID: UUID) {
        clipboardStore.delete(entryID: entryID)
        clipboardEntries = clipboardStore.allEntries(retentionMinutes: settings.clipboardRetentionMinutes)
    }

    func clearRecentClipboard() {
        clipboardStore.clearUnpinned()
        clipboardEntries = clipboardStore.allEntries(retentionMinutes: settings.clipboardRetentionMinutes)
    }
}
