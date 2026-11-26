import XCTest
@testable import KeyboardCore

final class BinaryDictionaryTests: XCTestCase {
    func testDiacriticFoldingPreservesRussianShortIAndFoldsYo() {
        XCTAssertEqual(DiacriticFolding.fold("Ďakujem"), "dakujem")
        XCTAssertEqual(DiacriticFolding.fold("Příliš"), "prilis")
        XCTAssertEqual(DiacriticFolding.fold("Tänan"), "tanan")
        XCTAssertEqual(DiacriticFolding.fold("Kõik"), "koik")
        XCTAssertEqual(DiacriticFolding.fold("Ещё"), "еще")
        XCTAssertEqual(DiacriticFolding.fold("Мой"), "мой")
        XCTAssertNotEqual(DiacriticFolding.fold("мой"), DiacriticFolding.fold("мои"))
    }

    func testInMemoryBuildAndQueries() throws {
        let dictionary = try BinaryDictionary.buildInMemory(
            words: [
                ("the", 65000),
                ("there", 50000),
                ("their", 48000),
                ("thank", 45000),
                ("you", 60000),
                ("ďakujem", 55000)
            ]
        )

        XCTAssertEqual(dictionary.wordCount, 6)
        XCTAssertEqual(dictionary.exactMatches(for: "dakujem").first?.word, "ďakujem")

        let nextScores = dictionary.nextCharacterScores(forPrefix: "th")
        let scalarE = UInt32(UnicodeScalar("e").value)
        let scalarA = UInt32(UnicodeScalar("a").value)
        XCTAssertEqual(nextScores[scalarE], 65000)
        XCTAssertEqual(nextScores[scalarA], 45000)

        let completions = dictionary.prefixCompletions(forPrefix: "the", limit: 3)
        XCTAssertEqual(completions.map(\.word), ["the", "there", "their"])
    }

    func testEmptyDataIsRejected() {
        XCTAssertThrowsError(try BinaryDictionary(data: Data()))
    }

    func testFuzzyTranspositionMatching() throws {
        let dictionary = try BinaryDictionary.buildInMemory(
            words: [
                ("the", 65000),
                ("hello", 50000)
            ]
        )

        let matches = dictionary.fuzzyMatches(
            for: "teh",
            maxEditCost: 1.0,
            substitutionCost: { _, _ in 1.0 },
            limit: 3
        )
        XCTAssertEqual(matches.first?.word, "the")
    }

    func testFuzzyMatchingStillFindsEditsAcrossDepths() throws {
        let dictionary = try BinaryDictionary.buildInMemory(
            words: [
                ("keyboard", 60000),
                ("keyboards", 40000),
                ("key", 50000)
            ]
        )

        let matches = dictionary.fuzzyMatches(
            for: "keybaord",
            maxEditCost: 1.0,
            substitutionCost: { _, _ in 1.0 },
            limit: 3
        )
        XCTAssertEqual(matches.first?.word, "keyboard")
    }

    func testShippedDictionaryLoadsFromMemoryMappedFile() throws {
        let english = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../../KeyboardExtension/Resources/Dictionaries/en.kdict")
            .standardizedFileURL
        try XCTSkipUnless(FileManager.default.fileExists(atPath: english.path), "en.kdict not found")

        let dictionary = try BinaryDictionary(contentsOf: english)
        XCTAssertGreaterThan(dictionary.wordCount, 0)
        XCTAssertFalse(dictionary.prefixCompletions(forPrefix: "th", limit: 3).isEmpty)
    }
}
