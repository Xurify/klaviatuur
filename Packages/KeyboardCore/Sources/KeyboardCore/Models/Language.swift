import Foundation

public enum ScriptKind: String, Codable, CaseIterable, Hashable, Sendable {
    case latin
    case cyrillic

    public var displayName: String {
        switch self {
        case .latin:
            return "Latin"
        case .cyrillic:
            return "Cyrillic"
        }
    }
}

public enum LatinLayoutVariant: String, Codable, CaseIterable, Hashable, Sendable {
    case qwerty
    case qwertz

    public var displayName: String {
        switch self {
        case .qwerty:
            return "QWERTY"
        case .qwertz:
            return "QWERTZ"
        }
    }
}

public enum KeyboardThemeStyle: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case tonal
    case borderless
    case vivid
    case glass

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .tonal: return "Tonal"
        case .borderless: return "Borderless"
        case .vivid: return "Vivid"
        case .glass: return "Glass"
        }
    }
}

public enum LanguageCode: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case english = "en"
    case slovak = "sk"
    case czech = "cs"
    case estonian = "et"
    case russian = "ru"

    public var id: String { rawValue }

    public var profile: LanguageProfile {
        switch self {
        case .english:
            return LanguageProfile(
                code: .english,
                displayName: "English",
                nativeName: "English",
                shortTag: "EN",
                script: .latin,
                diacriticCharacters: [:]
            )
        case .slovak:
            return LanguageProfile(
                code: .slovak,
                displayName: "Slovak",
                nativeName: "Slovenčina",
                shortTag: "SK",
                script: .latin,
                diacriticCharacters: [
                    "a": ["á", "ä"],
                    "c": ["č"],
                    "d": ["ď"],
                    "e": ["é"],
                    "i": ["í"],
                    "l": ["ľ", "ĺ"],
                    "n": ["ň"],
                    "o": ["ó", "ô"],
                    "r": ["ŕ"],
                    "s": ["š"],
                    "t": ["ť"],
                    "u": ["ú"],
                    "y": ["ý"],
                    "z": ["ž"]
                ]
            )
        case .czech:
            return LanguageProfile(
                code: .czech,
                displayName: "Czech",
                nativeName: "Čeština",
                shortTag: "CS",
                script: .latin,
                diacriticCharacters: [
                    "a": ["á"],
                    "c": ["č"],
                    "d": ["ď"],
                    "e": ["é", "ě"],
                    "i": ["í"],
                    "n": ["ň"],
                    "o": ["ó"],
                    "r": ["ř"],
                    "s": ["š"],
                    "t": ["ť"],
                    "u": ["ú", "ů"],
                    "y": ["ý"],
                    "z": ["ž"]
                ]
            )
        case .estonian:
            return LanguageProfile(
                code: .estonian,
                displayName: "Estonian",
                nativeName: "Eesti",
                shortTag: "ET",
                script: .latin,
                diacriticCharacters: [
                    "a": ["ä"],
                    "o": ["õ", "ö"],
                    "s": ["š"],
                    "u": ["ü"],
                    "z": ["ž"]
                ]
            )
        case .russian:
            return LanguageProfile(
                code: .russian,
                displayName: "Russian",
                nativeName: "Русский",
                shortTag: "RU",
                script: .cyrillic,
                diacriticCharacters: [
                    "е": ["ё"],
                    "ь": ["ъ"]
                ]
            )
        }
    }
}

public struct LanguageProfile: Equatable, Sendable {
    public let code: LanguageCode
    public let displayName: String
    public let nativeName: String
    public let shortTag: String
    public let script: ScriptKind
    public let diacriticCharacters: [String: [String]]

    public init(
        code: LanguageCode,
        displayName: String,
        nativeName: String,
        shortTag: String,
        script: ScriptKind,
        diacriticCharacters: [String: [String]]
    ) {
        self.code = code
        self.displayName = displayName
        self.nativeName = nativeName
        self.shortTag = shortTag
        self.script = script
        self.diacriticCharacters = diacriticCharacters
    }
}

public struct KeyboardSettings: Codable, Equatable, Sendable {
    public var enabledLanguages: [LanguageCode]
    public var activeScript: ScriptKind
    public var activeSingleLanguage: LanguageCode?
    public var latinVariant: LatinLayoutVariant
    public var simultaneousMultilingual: Bool
    public var showNumberRow: Bool
    public var showLongPressHints: Bool
    public var longPressDelayMilliseconds: Int
    public var enableHaptics: Bool
    public var enableKeyPopups: Bool
    public var enableAutocorrect: Bool
    public var enableProbabilisticHitboxes: Bool
    public var enableAutoCapitalization: Bool
    public var enableDoubleSpacePeriod: Bool
    public var enableClipboardHistory: Bool
    public var clipboardRetentionMinutes: Int
    public var keyboardHeightScale: Double
    // Optional so settings saved before themes existed still decode instead of resetting to defaults.
    private var storedThemeStyle: KeyboardThemeStyle?

    public var themeStyle: KeyboardThemeStyle {
        get { storedThemeStyle ?? .tonal }
        set { storedThemeStyle = newValue }
    }

    public static let `default` = KeyboardSettings(
        enabledLanguages: [.english, .slovak, .czech, .estonian, .russian],
        activeScript: .latin,
        activeSingleLanguage: nil,
        latinVariant: .qwerty,
        simultaneousMultilingual: true,
        showNumberRow: true,
        showLongPressHints: true,
        longPressDelayMilliseconds: 260,
        enableHaptics: true,
        enableKeyPopups: true,
        enableAutocorrect: true,
        enableProbabilisticHitboxes: true,
        enableAutoCapitalization: true,
        enableDoubleSpacePeriod: true,
        enableClipboardHistory: true,
        clipboardRetentionMinutes: 60,
        keyboardHeightScale: 1.0
    )

    public init(
        enabledLanguages: [LanguageCode],
        activeScript: ScriptKind,
        activeSingleLanguage: LanguageCode?,
        latinVariant: LatinLayoutVariant,
        simultaneousMultilingual: Bool,
        showNumberRow: Bool,
        showLongPressHints: Bool,
        longPressDelayMilliseconds: Int,
        enableHaptics: Bool,
        enableKeyPopups: Bool,
        enableAutocorrect: Bool,
        enableProbabilisticHitboxes: Bool,
        enableAutoCapitalization: Bool,
        enableDoubleSpacePeriod: Bool,
        enableClipboardHistory: Bool,
        clipboardRetentionMinutes: Int,
        keyboardHeightScale: Double,
        themeStyle: KeyboardThemeStyle = .tonal
    ) {
        self.storedThemeStyle = themeStyle
        self.enabledLanguages = enabledLanguages
        self.activeScript = activeScript
        self.activeSingleLanguage = activeSingleLanguage
        self.latinVariant = latinVariant
        self.simultaneousMultilingual = simultaneousMultilingual
        self.showNumberRow = showNumberRow
        self.showLongPressHints = showLongPressHints
        self.longPressDelayMilliseconds = longPressDelayMilliseconds
        self.enableHaptics = enableHaptics
        self.enableKeyPopups = enableKeyPopups
        self.enableAutocorrect = enableAutocorrect
        self.enableProbabilisticHitboxes = enableProbabilisticHitboxes
        self.enableAutoCapitalization = enableAutoCapitalization
        self.enableDoubleSpacePeriod = enableDoubleSpacePeriod
        self.enableClipboardHistory = enableClipboardHistory
        self.clipboardRetentionMinutes = clipboardRetentionMinutes
        self.keyboardHeightScale = keyboardHeightScale
    }

    public func activeLanguagesForCurrentLayout() -> [LanguageCode] {
        let enabled = enabledLanguages.isEmpty ? [.english] : enabledLanguages
        if simultaneousMultilingual {
            let scriptMatches = enabled.filter { $0.profile.script == activeScript }
            if !scriptMatches.isEmpty {
                return scriptMatches
            }
            return [enabled[0]]
        }
        if let single = activeSingleLanguage, enabled.contains(single) {
            return [single]
        }
        return [enabled[0]]
    }

    public func availableScripts() -> [ScriptKind] {
        var seen: Set<ScriptKind> = []
        var ordered: [ScriptKind] = []
        for language in enabledLanguages {
            let script = language.profile.script
            if seen.insert(script).inserted {
                ordered.append(script)
            }
        }
        return ordered.isEmpty ? [.latin] : ordered
    }

    public mutating func cycleActiveLayout() {
        let enabled = enabledLanguages.isEmpty ? [.english] : enabledLanguages
        if simultaneousMultilingual {
            let scripts = availableScripts()
            guard scripts.count > 1 else { return }
            if let currentIndex = scripts.firstIndex(of: activeScript) {
                let nextIndex = (currentIndex + 1) % scripts.count
                activeScript = scripts[nextIndex]
            } else {
                activeScript = scripts[0]
            }
        } else {
            let current = activeSingleLanguage ?? enabled[0]
            if let currentIndex = enabled.firstIndex(of: current) {
                let nextLanguage = enabled[(currentIndex + 1) % enabled.count]
                activeSingleLanguage = nextLanguage
                activeScript = nextLanguage.profile.script
            } else {
                activeSingleLanguage = enabled[0]
                activeScript = enabled[0].profile.script
            }
        }
    }
}
