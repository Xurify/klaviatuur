import XCTest
@testable import KeyboardCore

final class MultilingualEngineTests: XCTestCase {
    private func makeEngine() throws -> MultilingualEngine {
        let english = try BinaryDictionary.buildInMemory(
            words: [
                ("the", 65000),
                ("thank", 55000),
                ("you", 62000),
                ("hello", 50000),
                ("i", 60000),
                ("to", 61000)
            ]
        )
        let slovak = try BinaryDictionary.buildInMemory(
            words: [
                ("ďakujem", 58000),
                ("veľmi", 52000),
                ("pekne", 50000),
                ("dobrý", 54000),
                ("deň", 53000)
            ]
        )
        let czech = try BinaryDictionary.buildInMemory(
            words: [
                ("příliš", 49000),
                ("děkuji", 56000),
                ("dobře", 51000)
            ]
        )
        let estonian = try BinaryDictionary.buildInMemory(
            words: [
                ("tänan", 54000),
                ("kõik", 57000),
                ("hästi", 52000)
            ]
        )
        let russian = try BinaryDictionary.buildInMemory(
            words: [
                ("ещё", 60000),
                ("привет", 58000),
                ("хорошо", 55000)
            ]
        )

        return MultilingualEngine(dictionaries: [
            .english: english,
            .slovak: slovak,
            .czech: czech,
            .estonian: estonian,
            .russian: russian
        ])
    }

    func testSimultaneousFourLanguageLatinDiacriticRestoration() throws {
        let engine = try makeEngine()
        let activeLatin: [LanguageCode] = [.english, .slovak, .czech, .estonian]

        let slovakResult = engine.suggestions(for: "dakujem", activeLanguages: activeLatin)
        XCTAssertEqual(slovakResult.autocorrectReplacement, "ďakujem")

        let czechResult = engine.suggestions(for: "prilis", activeLanguages: activeLatin)
        XCTAssertEqual(czechResult.autocorrectReplacement, "příliš")

        let estonianResult = engine.suggestions(for: "tanan", activeLanguages: activeLatin)
        XCTAssertEqual(estonianResult.autocorrectReplacement, "tänan")

        let englishTypo = engine.suggestions(for: "teh", activeLanguages: activeLatin)
        XCTAssertEqual(englishTypo.autocorrectReplacement, "the")
    }

    func testRussianYoRestoration() throws {
        let engine = try makeEngine()
        let result = engine.suggestions(for: "еще", activeLanguages: [.russian])
        XCTAssertEqual(result.autocorrectReplacement, "ещё")
    }

    func testCapitalizationPreservedInDiacriticRestoration() throws {
        let engine = try makeEngine()
        let titleCase = engine.suggestions(for: "Dakujem", activeLanguages: [.english, .slovak])
        XCTAssertEqual(titleCase.autocorrectReplacement, "Ďakujem")

        let uppercase = engine.suggestions(for: "DAKUJEM", activeLanguages: [.english, .slovak])
        XCTAssertEqual(uppercase.autocorrectReplacement, "ĎAKUJEM")
    }

    func testCapsLockUppercasesEverySuggestion() {
        let result = SuggestionResult(
            suggestions: [SuggestionCandidate(text: "Ďakujem", language: .slovak, score: 1, isAutocorrectPrimary: true)],
            autocorrectReplacement: "ďakujem",
            detectedLanguage: .slovak,
            isPrediction: true
        ).uppercased()
        XCTAssertEqual(result.suggestions.map(\.text), ["ĎAKUJEM"])
        XCTAssertEqual(result.suggestions.first?.isAutocorrectPrimary, true)
        XCTAssertEqual(result.autocorrectReplacement, "ĎAKUJEM")
        XCTAssertTrue(result.isPrediction)
    }
}
