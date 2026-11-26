import Foundation

public enum DiacriticFolding {
    private static let specialLatinFolds: [Character: String] = [
        "ł": "l",
        "ø": "o",
        "đ": "d",
        "ß": "s",
        "æ": "ae",
        "œ": "oe",
        "\u{2019}": "'",
        "\u{2018}": "'",
        "\u{02BC}": "'"
    ]

    public static func normalizingApostrophes(_ text: String) -> String {
        String(text.map { specialLatinFolds[$0] == "'" ? "'" : $0 })
    }

    public static func fold(_ text: String) -> String {
        var result = String()
        result.reserveCapacity(text.count)

        for character in text.lowercased() {
            if character == "ё" {
                result.append("е")
                continue
            }
            if character == "й" {
                result.append("й")
                continue
            }
            if let special = specialLatinFolds[character] {
                result.append(special)
                continue
            }

            if let firstScalar = character.unicodeScalars.first,
               (0x0400...0x04FF).contains(firstScalar.value)
            {
                result.append(character)
                continue
            }

            let decomposed = String(character).decomposedStringWithCanonicalMapping
            for scalar in decomposed.unicodeScalars {
                if !scalar.properties.generalCategory.isCombiningMark {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }

    public static func foldedScalars(_ text: String) -> [UInt32] {
        fold(text).unicodeScalars.map(\.value)
    }

    public static func applyCasing(
        of typedWord: String,
        to suggestion: String,
        language: LanguageCode? = nil
    ) -> String {
        guard !typedWord.isEmpty, !suggestion.isEmpty else {
            return suggestion
        }

        let letters = typedWord.filter(\.isLetter)
        if letters.count >= 2 && letters.allSatisfy(\.isUppercase) {
            return suggestion.uppercased()
        }

        if language == .english {
            let lower = suggestion.lowercased()
            if lower == "i" {
                return "I"
            }
            if lower.hasPrefix("i'") {
                return "I" + lower.dropFirst()
            }
        }

        if let firstCharacter = typedWord.first, firstCharacter.isUppercase {
            return suggestion.prefix(1).uppercased() + suggestion.dropFirst()
        }

        return suggestion
    }
}

private extension Unicode.GeneralCategory {
    var isCombiningMark: Bool {
        self == .nonspacingMark || self == .spacingMark || self == .enclosingMark
    }
}
