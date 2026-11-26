import Foundation

public enum LayoutRegistry {
    private static let pixelLatinSymbolHints: [String: String] = [
        "q": "%", "w": "\\", "e": "|", "r": "=", "t": "[",
        "y": "]", "u": "<", "i": ">", "o": "{", "p": "}",
        "a": "@", "s": "#", "d": "$", "f": "_", "g": "&",
        "h": "-", "j": "+", "k": "(", "l": ")",
        "z": "*", "x": "\"", "c": "'", "v": ":", "b": ";",
        "n": "!", "m": "?"
    ]

    private static let pixelLatinNoNumberRowHints: [String: String] = [
        "q": "1", "w": "2", "e": "3", "r": "4", "t": "5",
        "y": "6", "u": "7", "i": "8", "o": "9", "p": "0",
        "a": "@", "s": "#", "d": "$", "f": "_", "g": "&",
        "h": "-", "j": "+", "k": "(", "l": ")",
        "z": "*", "x": "\"", "c": "'", "v": ":", "b": ";",
        "n": "!", "m": "?"
    ]

    private static let pixelCyrillicSymbolHints: [String: String] = [
        "й": "%", "ц": "\\", "у": "|", "к": "=", "е": "ё",
        "н": "[", "г": "]", "ш": "<", "щ": ">", "з": "{", "х": "}",
        "ф": "@", "ы": "#", "в": "$", "а": "_", "п": "&",
        "р": "-", "о": "+", "л": "(", "д": ")", "ж": "/", "э": "\"",
        "я": "*", "ч": "'", "с": ":", "м": ";", "и": "!",
        "т": "?", "ь": "ъ", "б": ",", "ю": "."
    ]

    public static func layout(
        for settings: KeyboardSettings,
        mode: KeyboardLayoutMode,
        returnKeyLabel: String = "return"
    ) -> KeyboardLayoutSpec {
        let activeLanguages = settings.activeLanguagesForCurrentLayout()
        let spacebarLabel = activeLanguages
            .map { $0.profile.shortTag }
            .joined(separator: " · ")

        switch mode {
        case .letters:
            switch settings.activeScript {
            case .latin:
                return buildLatinLettersLayout(
                    settings: settings,
                    activeLanguages: activeLanguages,
                    spacebarLabel: spacebarLabel,
                    returnKeyLabel: returnKeyLabel
                )
            case .cyrillic:
                return buildCyrillicLettersLayout(
                    settings: settings,
                    activeLanguages: activeLanguages,
                    spacebarLabel: spacebarLabel,
                    returnKeyLabel: returnKeyLabel
                )
            }
        case .symbolsPrimary:
            return buildSymbolsPrimaryLayout(
                script: settings.activeScript,
                spacebarLabel: spacebarLabel,
                returnKeyLabel: returnKeyLabel
            )
        case .symbolsSecondary:
            return buildSymbolsSecondaryLayout(
                script: settings.activeScript,
                spacebarLabel: spacebarLabel,
                returnKeyLabel: returnKeyLabel
            )
        }
    }

    private static func buildNumberRow() -> KeyRow {
        let numberVariants: [String: [String]] = [
            "1": ["¹", "½", "⅓", "¼"],
            "2": ["²", "⅔"],
            "3": ["³", "¾"],
            "4": ["⁴"],
            "5": ["⁵"],
            "6": ["⁶"],
            "7": ["⁷"],
            "8": ["⁸"],
            "9": ["⁹"],
            "0": ["⁰", "°", "∅"]
        ]
        let digits = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
        let keys = digits.map { digit in
            KeySpec(
                id: "num_\(digit)",
                kind: .number(digit),
                primaryLabel: digit,
                longPressVariants: numberVariants[digit] ?? [],
                widthWeight: 1.0
            )
        }
        return KeyRow(keys: keys)
    }

    private static func mergedDiacritics(
        for baseCharacter: String,
        activeLanguages: [LanguageCode]
    ) -> [String] {
        var ordered: [String] = []
        var seen: Set<String> = []
        for language in activeLanguages {
            let variants = language.profile.diacriticCharacters[baseCharacter] ?? []
            for variant in variants where seen.insert(variant).inserted {
                ordered.append(variant)
            }
        }
        return ordered
    }

    private static func buildLatinLettersLayout(
        settings: KeyboardSettings,
        activeLanguages: [LanguageCode],
        spacebarLabel: String,
        returnKeyLabel: String
    ) -> KeyboardLayoutSpec {
        let hintsTable = settings.showNumberRow ? pixelLatinSymbolHints : pixelLatinNoNumberRowHints

        let topRowLetters = settings.latinVariant == .qwertz
            ? ["q", "w", "e", "r", "t", "z", "u", "i", "o", "p"]
            : ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"]
        let middleRowLetters = ["a", "s", "d", "f", "g", "h", "j", "k", "l"]
        let bottomRowLetters = settings.latinVariant == .qwertz
            ? ["y", "x", "c", "v", "b", "n", "m"]
            : ["z", "x", "c", "v", "b", "n", "m"]

        func makeLetterKey(_ letter: String) -> KeySpec {
            let hint = settings.showLongPressHints ? hintsTable[letter] : nil
            var variants = mergedDiacritics(for: letter, activeLanguages: activeLanguages)
            if let symbolHint = hintsTable[letter], !variants.contains(symbolHint) {
                variants.append(symbolHint)
            }
            return KeySpec(
                id: "latin_\(letter)",
                kind: .character(letter),
                primaryLabel: letter,
                shiftedLabel: letter.uppercased(),
                secondaryHint: hint,
                longPressVariants: variants,
                widthWeight: 1.0
            )
        }

        var rows: [KeyRow] = []
        if settings.showNumberRow {
            rows.append(buildNumberRow())
        }
        rows.append(KeyRow(keys: topRowLetters.map(makeLetterKey)))
        rows.append(KeyRow(keys: middleRowLetters.map(makeLetterKey), horizontalInsetWeight: 0.5))

        var thirdRowKeys: [KeySpec] = [
            KeySpec(id: "shift", kind: .shift, primaryLabel: "⇧", widthWeight: 1.45)
        ]
        thirdRowKeys.append(contentsOf: bottomRowLetters.map(makeLetterKey))
        thirdRowKeys.append(
            KeySpec(id: "backspace", kind: .backspace, primaryLabel: "⌫", widthWeight: 1.45)
        )
        rows.append(KeyRow(keys: thirdRowKeys))

        rows.append(buildBottomActionRow(
            modeSwitchTarget: .symbolsPrimary,
            modeSwitchLabel: "?123",
            spacebarLabel: spacebarLabel,
            returnKeyLabel: returnKeyLabel
        ))

        return KeyboardLayoutSpec(
            script: .latin,
            mode: .letters,
            rows: rows,
            spacebarLabel: spacebarLabel
        )
    }

    private static func buildCyrillicLettersLayout(
        settings: KeyboardSettings,
        activeLanguages: [LanguageCode],
        spacebarLabel: String,
        returnKeyLabel: String
    ) -> KeyboardLayoutSpec {
        let topRow = ["й", "ц", "у", "к", "е", "н", "г", "ш", "щ", "з", "х"]
        let middleRow = ["ф", "ы", "в", "а", "п", "р", "о", "л", "д", "ж", "э"]
        let bottomRow = ["я", "ч", "с", "м", "и", "т", "ь", "б", "ю"]

        func makeCyrillicKey(_ letter: String) -> KeySpec {
            let hint = settings.showLongPressHints ? pixelCyrillicSymbolHints[letter] : nil
            var variants = mergedDiacritics(for: letter, activeLanguages: activeLanguages)
            if let symbolHint = pixelCyrillicSymbolHints[letter], !variants.contains(symbolHint) {
                variants.append(symbolHint)
            }
            return KeySpec(
                id: "cyr_\(letter)",
                kind: .character(letter),
                primaryLabel: letter,
                shiftedLabel: letter.uppercased(),
                secondaryHint: hint,
                longPressVariants: variants,
                widthWeight: 1.0
            )
        }

        var rows: [KeyRow] = []
        if settings.showNumberRow {
            rows.append(buildNumberRow())
        }
        rows.append(KeyRow(keys: topRow.map(makeCyrillicKey)))
        rows.append(KeyRow(keys: middleRow.map(makeCyrillicKey)))

        var thirdRowKeys: [KeySpec] = [
            KeySpec(id: "shift", kind: .shift, primaryLabel: "⇧", widthWeight: 1.25)
        ]
        thirdRowKeys.append(contentsOf: bottomRow.map(makeCyrillicKey))
        thirdRowKeys.append(
            KeySpec(id: "backspace", kind: .backspace, primaryLabel: "⌫", widthWeight: 1.25)
        )
        rows.append(KeyRow(keys: thirdRowKeys))

        rows.append(buildBottomActionRow(
            modeSwitchTarget: .symbolsPrimary,
            modeSwitchLabel: "?123",
            spacebarLabel: spacebarLabel,
            returnKeyLabel: returnKeyLabel
        ))

        return KeyboardLayoutSpec(
            script: .cyrillic,
            mode: .letters,
            rows: rows,
            spacebarLabel: spacebarLabel
        )
    }

    private static func buildSymbolsPrimaryLayout(
        script: ScriptKind,
        spacebarLabel: String,
        returnKeyLabel: String
    ) -> KeyboardLayoutSpec {
        let row1 = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"].map {
            KeySpec(id: "sym1_\($0)", kind: .number($0), primaryLabel: $0)
        }
        let row2 = ["@", "#", "$", "_", "&", "-", "+", "(", ")", "/"].map {
            KeySpec(id: "sym1_\($0)", kind: .punctuation($0), primaryLabel: $0)
        }
        var row3: [KeySpec] = [
            KeySpec(id: "to_sym2", kind: .modeSwitch(.symbolsSecondary), primaryLabel: "=\\<", widthWeight: 1.45)
        ]
        row3.append(contentsOf: ["*", "\"", "'", ":", ";", "!", "?"].map {
            KeySpec(id: "sym1_\($0)", kind: .punctuation($0), primaryLabel: $0)
        })
        row3.append(KeySpec(id: "backspace", kind: .backspace, primaryLabel: "⌫", widthWeight: 1.45))

        let row4 = buildBottomActionRow(
            modeSwitchTarget: .letters,
            modeSwitchLabel: script == .cyrillic ? "АБВ" : "ABC",
            spacebarLabel: spacebarLabel,
            returnKeyLabel: returnKeyLabel
        )

        return KeyboardLayoutSpec(
            script: script,
            mode: .symbolsPrimary,
            rows: [KeyRow(keys: row1), KeyRow(keys: row2), KeyRow(keys: row3), row4],
            spacebarLabel: spacebarLabel
        )
    }

    private static func buildSymbolsSecondaryLayout(
        script: ScriptKind,
        spacebarLabel: String,
        returnKeyLabel: String
    ) -> KeyboardLayoutSpec {
        let row1 = ["~", "`", "|", "•", "√", "π", "÷", "×", "§", "Δ"].map {
            KeySpec(id: "sym2_\($0)", kind: .punctuation($0), primaryLabel: $0)
        }
        let row2 = ["€", "£", "¥", "¢", "^", "°", "=", "{", "}", "\\"].map {
            KeySpec(id: "sym2_\($0)", kind: .punctuation($0), primaryLabel: $0)
        }
        var row3: [KeySpec] = [
            KeySpec(id: "to_sym1", kind: .modeSwitch(.symbolsPrimary), primaryLabel: "?123", widthWeight: 1.45)
        ]
        row3.append(contentsOf: ["%", "©", "®", "™", "✓", "[", "]"].map {
            KeySpec(id: "sym2_\($0)", kind: .punctuation($0), primaryLabel: $0)
        })
        row3.append(KeySpec(id: "backspace", kind: .backspace, primaryLabel: "⌫", widthWeight: 1.45))

        let row4 = buildBottomActionRow(
            modeSwitchTarget: .letters,
            modeSwitchLabel: script == .cyrillic ? "АБВ" : "ABC",
            spacebarLabel: spacebarLabel,
            returnKeyLabel: returnKeyLabel
        )

        return KeyboardLayoutSpec(
            script: script,
            mode: .symbolsSecondary,
            rows: [KeyRow(keys: row1), KeyRow(keys: row2), KeyRow(keys: row3), row4],
            spacebarLabel: spacebarLabel
        )
    }

    private static func buildBottomActionRow(
        modeSwitchTarget: KeyboardLayoutMode,
        modeSwitchLabel: String,
        spacebarLabel: String,
        returnKeyLabel: String
    ) -> KeyRow {
        KeyRow(keys: [
            KeySpec(
                id: "mode_switch",
                kind: .modeSwitch(modeSwitchTarget),
                primaryLabel: modeSwitchLabel,
                widthWeight: 1.45
            ),
            KeySpec(
                id: "comma",
                kind: .punctuation(","),
                primaryLabel: ",",
                longPressVariants: [",", ";", ":", "\"", "'"],
                widthWeight: 0.95
            ),
            KeySpec(
                id: "globe",
                kind: .globe,
                primaryLabel: "🌐",
                widthWeight: 1.05
            ),
            KeySpec(
                id: "space",
                kind: .space,
                primaryLabel: spacebarLabel,
                widthWeight: 4.15
            ),
            KeySpec(
                id: "period",
                kind: .punctuation("."),
                primaryLabel: ".",
                secondaryHint: "?",
                longPressVariants: [".", "?", "!", ",", "…", "-", "'", "@"],
                widthWeight: 0.95
            ),
            KeySpec(
                id: "return",
                kind: .returnKey,
                primaryLabel: returnKeyLabel,
                widthWeight: 1.55
            )
        ])
    }
}
