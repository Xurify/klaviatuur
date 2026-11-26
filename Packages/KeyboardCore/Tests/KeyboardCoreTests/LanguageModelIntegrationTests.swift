import XCTest
@testable import KeyboardCore

final class LanguageModelIntegrationTests: XCTestCase {
    /// Builds a test model numbered like `dictionary`. A nil context word means the start of a sentence.
    private func makeModel(
        for dictionary: BinaryDictionary,
        unigrams: [String: Double] = [:],
        backoffs: [String?: Double] = [:],
        bigrams: [(String?, String, Double, Double?)] = [],
        trigrams: [(String?, String, String, Double)] = [],
        fingerprint: UInt64? = nil
    ) throws -> BinaryLanguageModel {
        let vocabCount = dictionary.wordCount
        func id(_ word: String) throws -> UInt32 {
            try XCTUnwrap(dictionary.exactWordId(for: word), "\(word) missing from dictionary")
        }
        func token(_ word: String?) throws -> LMContextToken {
            guard let word else { return .bos }
            return .word(try id(word))
        }
        var unigramRows: [(logProb: Double, logBow: Double?)] = []
        for index in 0..<vocabCount {
            let word = try XCTUnwrap(dictionary.word(at: UInt32(index))).word
            unigramRows.append((unigrams[word] ?? -4.0, backoffs[word]))
        }
        unigramRows.append((0.0, backoffs[nil]))
        return try BinaryLanguageModel.buildInMemory(
            vocabCount: vocabCount,
            vocabFingerprint: fingerprint ?? dictionary.vocabFingerprint(),
            unigrams: unigramRows,
            bigrams: try bigrams.map { (try token($0.0), try id($0.1), $0.2, $0.3) },
            trigrams: try trigrams.map { (try token($0.0), try id($0.1), try id($0.2), $0.3) }
        )
    }

    private func makeRussianEngine() throws -> MultilingualEngine {
        let russian = try BinaryDictionary.buildInMemory(words: [
            ("все", 60000), ("всё", 50000), ("это", 62000), ("почти", 40000), ("привет", 45000)
        ])
        let model = try makeModel(
            for: russian,
            unigrams: ["все": -1.5, "всё": -2.0, "это": -1.3, "почти": -2.5, "привет": -2.2],
            backoffs: ["это": -0.5, "почти": -0.5, nil: -0.4],
            bigrams: [
                ("это", "всё", -0.3, nil),
                ("почти", "все", -0.2, nil),
                (nil, "привет", -0.4, nil),
                (nil, "это", -0.6, nil)
            ]
        )
        let engine = MultilingualEngine(dictionaries: [.russian: russian])
        XCTAssertTrue(engine.registerLanguageModel(model, for: .russian))
        return engine
    }

    func testContextRestoresYoAfterEto() throws {
        let engine = try makeRussianEngine()
        let afterEto = engine.suggestions(
            for: "все",
            history: WordHistory([.sentenceStart, .word("это")]),
            activeLanguages: [.russian]
        )
        XCTAssertEqual(afterEto.autocorrectReplacement, "всё")
    }

    func testContextKeepsVseAfterPochti() throws {
        let engine = try makeRussianEngine()
        let afterPochti = engine.suggestions(
            for: "все",
            history: WordHistory([.word("почти")]),
            activeLanguages: [.russian]
        )
        XCTAssertNil(afterPochti.autocorrectReplacement)
    }

    func testWithoutContextLiteralWins() throws {
        let engine = try makeRussianEngine()
        let result = engine.suggestions(for: "все", history: .empty, activeLanguages: [.russian])
        XCTAssertNil(result.autocorrectReplacement)
    }

    func testSentenceStartPredictionsAreCapitalized() throws {
        let engine = try makeRussianEngine()
        let result = engine.nextWordSuggestions(history: .sentenceStart, activeLanguages: [.russian])
        XCTAssertTrue(result.isPrediction)
        XCTAssertEqual(result.suggestions.first?.text, "Привет")
    }

    private func makeEnglishEngine() throws -> (MultilingualEngine, BinaryDictionary) {
        let english = try BinaryDictionary.buildInMemory(words: [
            ("i", 64000), ("want", 50000), ("to", 63000), ("you", 62000), ("thank", 45000),
            ("yes", 47000), ("year", 46000), ("go", 48000)
        ])
        let model = try makeModel(
            for: english,
            unigrams: ["i": -1.4, "want": -2.6, "to": -1.3, "you": -1.5, "thank": -3.0,
                       "yes": -2.8, "year": -2.9, "go": -2.4],
            backoffs: ["i": -0.4, "want": -0.4, "thank": -0.8, nil: -0.3],
            bigrams: [
                ("i", "want", -0.5, -0.2),
                ("want", "you", -0.3, nil),
                ("want", "to", -0.6, nil),
                ("thank", "you", -0.05, nil),
                (nil, "i", -0.5, nil)
            ],
            trigrams: [("i", "want", "to", -0.1)]
        )
        let engine = MultilingualEngine(dictionaries: [.english: english])
        XCTAssertTrue(engine.registerLanguageModel(model, for: .english))
        return (engine, english)
    }

    func testTrigramContextOutranksBigram() throws {
        let (engine, _) = try makeEnglishEngine()
        let bigramOnly = engine.nextWordSuggestions(
            history: WordHistory([.word("want")]),
            activeLanguages: [.english]
        )
        XCTAssertEqual(bigramOnly.suggestions.first?.text, "you")

        let withTrigram = engine.nextWordSuggestions(
            history: WordHistory([.word("I"), .word("want")]),
            activeLanguages: [.english]
        )
        XCTAssertEqual(withTrigram.suggestions.first?.text, "to")
    }

    func testEnglishIIsCapitalizedMidSentence() throws {
        let english = try BinaryDictionary.buildInMemory(words: [("so", 50000), ("i", 45000), ("i'm", 40000)])
        let model = try makeModel(
            for: english,
            backoffs: ["so": -0.3],
            bigrams: [("so", "i", -0.3, nil), ("so", "i'm", -0.5, nil)]
        )
        let engine = MultilingualEngine(dictionaries: [.english: english])
        XCTAssertTrue(engine.registerLanguageModel(model, for: .english))
        let result = engine.nextWordSuggestions(history: WordHistory([.word("so")]), activeLanguages: [.english])
        XCTAssertEqual(result.suggestions.map(\.text), ["I", "I'm"])
    }

    func testOneLetterUsesContext() throws {
        let (engine, _) = try makeEnglishEngine()
        let result = engine.suggestions(
            for: "y",
            history: WordHistory([.word("thank")]),
            activeLanguages: [.english]
        )
        XCTAssertTrue(result.suggestions.contains { $0.text == "you" })
    }

    func testUnknownPreviousWordGivesNoPredictions() throws {
        let (engine, _) = try makeEnglishEngine()
        let result = engine.nextWordSuggestions(
            history: WordHistory([.word("zzyzx")]),
            activeLanguages: [.english]
        )
        XCTAssertTrue(result.suggestions.isEmpty)
    }

    func testMismatchedModelIsRejected() throws {
        let english = try BinaryDictionary.buildInMemory(words: [("hello", 50000), ("world", 40000)])
        let model = try makeModel(for: english, fingerprint: english.vocabFingerprint() ^ 1)
        let engine = MultilingualEngine(dictionaries: [.english: english])
        XCTAssertFalse(engine.registerLanguageModel(model, for: .english))
        XCTAssertFalse(engine.hasLanguageModel(for: .english))
    }

    func testFingerprintIsStableAcrossRebuilds() throws {
        let words: [(word: String, score: UInt16)] = [("a", 3), ("b", 2), ("c", 1)]
        let first = try BinaryDictionary.buildInMemory(words: words)
        let second = try BinaryDictionary.buildInMemory(words: words)
        XCTAssertEqual(first.vocabFingerprint(), second.vocabFingerprint())
        let reordered = try BinaryDictionary.buildInMemory(words: [("a", 3), ("b", 1), ("c", 2)])
        XCTAssertNotEqual(first.vocabFingerprint(), reordered.vocabFingerprint())
    }

    func testFingerprintCatchesAnySwap() throws {
        let words = (0..<500).map { (word: "w\($0)", score: UInt16(60000 - $0 * 2)) }
        var swapped = words
        swapped[201].score = words[202].score
        swapped[202].score = words[201].score
        XCTAssertNotEqual(
            try BinaryDictionary.buildInMemory(words: words).vocabFingerprint(),
            try BinaryDictionary.buildInMemory(words: swapped).vocabFingerprint()
        )
    }

    func testCurlyApostropheResolvesToModelWord() throws {
        let english = try BinaryDictionary.buildInMemory(words: [("don't", 50000), ("know", 40000)])
        let model = try makeModel(for: english, backoffs: ["don't": -0.5], bigrams: [("don't", "know", -0.2, nil)])
        let engine = MultilingualEngine(dictionaries: [.english: english])
        XCTAssertTrue(engine.registerLanguageModel(model, for: .english))
        let result = engine.nextWordSuggestions(history: WordHistory([.word("don\u{2019}t")]), activeLanguages: [.english])
        XCTAssertEqual(result.suggestions.first?.text, "know")
    }

    func testApostropheKeyContinuesTheWord() {
        let session = TypingSessionController(engine: MultilingualEngine())
        for character in "don" {
            _ = session.handleCharacterInput(String(character), activeLanguages: [.english], autocorrectEnabled: false)
        }
        _ = session.handlePunctuation("'", activeLanguages: [.english], autocorrectEnabled: false)
        _ = session.handleCharacterInput("t", activeLanguages: [.english], autocorrectEnabled: false)
        XCTAssertEqual(session.currentWord, "don't")
        _ = session.handleSpace(
            textBeforeCursor: "don't", activeLanguages: [.english], autocorrectEnabled: false,
            doubleSpacePeriodEnabled: false
        )
        XCTAssertEqual(session.history.tokens, [.sentenceStart, .word("don't")])
    }

    func testExtractTrailingContext() {
        func check(
            _ text: String,
            _ current: String,
            _ tokens: [HistoryToken],
            line: UInt = #line
        ) {
            let result = TypingSessionController.extractTrailingContext(from: text)
            XCTAssertEqual(result.currentWord, current, line: line)
            XCTAssertEqual(result.history.tokens, tokens, line: line)
        }
        check("", "", [.sentenceStart])
        check("Thank ", "", [.sentenceStart, .word("Thank")])
        check("I want to", "to", [.word("I"), .word("want")])
        check("well I want ", "", [.word("I"), .word("want")])
        check("Hello, wor", "wor", [])
        check("Done. Ne", "Ne", [.sentenceStart])
        check("Hello.", "", [])
        check("see example.co", "co", [])
        check("he said 'hel", "hel", [])
        check("he said 'hello wor", "wor", [.word("hello")])
        check("line\nfoo", "foo", [.sentenceStart])
        check("Ok, apples", "apples", [])
        check("Ok 42 app", "app", [.word("Ok"), .word("42")])
        check("the 2nd", "2nd", [.sentenceStart, .word("the")])
        check("что-то и", "и", [.sentenceStart, .word("что-то")])
        check("don’t know ", "", [.word("don’t"), .word("know")])
    }

    func testPunctuationResetsHistory() {
        let session = TypingSessionController(engine: MultilingualEngine())
        for character in "hi" {
            _ = session.handleCharacterInput(String(character), activeLanguages: [.english], autocorrectEnabled: false)
        }
        _ = session.handlePunctuation(",", activeLanguages: [.english], autocorrectEnabled: false)
        XCTAssertEqual(session.history, .empty)

        for character in "ok" {
            _ = session.handleCharacterInput(String(character), activeLanguages: [.english], autocorrectEnabled: false)
        }
        _ = session.handlePunctuation(".", activeLanguages: [.english], autocorrectEnabled: false)
        XCTAssertEqual(session.history, .empty)
        _ = session.handleSpace(
            textBeforeCursor: "hi, ok.", activeLanguages: [.english], autocorrectEnabled: false,
            doubleSpacePeriodEnabled: false
        )
        XCTAssertEqual(session.history, .sentenceStart)
    }

    func testLongPressedOpeningQuoteStaysOutsideTheWord() throws {
        let english = try BinaryDictionary.buildInMemory(words: [("hello", 60000)])
        let session = TypingSessionController(engine: MultilingualEngine(dictionaries: [.english: english]))
        XCTAssertEqual(
            session.handleCharacterInput("'", activeLanguages: [.english], autocorrectEnabled: true),
            [.insert("'")]
        )
        for character in "helo" {
            _ = session.handleCharacterInput(String(character), activeLanguages: [.english], autocorrectEnabled: true)
        }
        _ = session.handleCharacterInput("'", activeLanguages: [.english], autocorrectEnabled: true)
        let actions = session.handleSpace(
            textBeforeCursor: "'helo'", activeLanguages: [.english], autocorrectEnabled: true,
            doubleSpacePeriodEnabled: false
        )
        XCTAssertEqual(actions, [.replaceBackward(deleteCount: 5, insertText: "hello' ")])
    }

    func testAcceptingAContractionDoesNotRepeatTheApostrophe() throws {
        let english = try BinaryDictionary.buildInMemory(words: [("don't", 60000), ("hello", 50000)])
        let session = TypingSessionController(engine: MultilingualEngine(dictionaries: [.english: english]))
        for character in "don" {
            _ = session.handleCharacterInput(String(character), activeLanguages: [.english], autocorrectEnabled: true)
        }
        _ = session.handleCharacterInput("'", activeLanguages: [.english], autocorrectEnabled: true)
        let contraction = SuggestionCandidate(text: "don't", language: .english, score: 1)
        XCTAssertEqual(
            session.acceptSuggestion(contraction, activeLanguages: [.english], autocorrectEnabled: true),
            [.replaceBackward(deleteCount: 4, insertText: "don't ")]
        )

        for character in "helo" {
            _ = session.handleCharacterInput(String(character), activeLanguages: [.english], autocorrectEnabled: true)
        }
        _ = session.handleCharacterInput("'", activeLanguages: [.english], autocorrectEnabled: true)
        let correction = SuggestionCandidate(text: "hello", language: .english, score: 1)
        XCTAssertEqual(
            session.acceptSuggestion(correction, activeLanguages: [.english], autocorrectEnabled: true),
            [.replaceBackward(deleteCount: 5, insertText: "hello' ")]
        )
    }

    func testInternalCapitalsAreLeftAlone() throws {
        let english = try BinaryDictionary.buildInMemory(words: [("iphone", 50000), ("youtube", 40000)])
        let engine = MultilingualEngine(dictionaries: [.english: english])
        XCTAssertNil(engine.suggestions(for: "iPhone", activeLanguages: [.english]).autocorrectReplacement)
        XCTAssertNil(engine.suggestions(for: "YouTube", activeLanguages: [.english]).autocorrectReplacement)
    }

    func testCzechIIsNotCapitalized() throws {
        let english = try BinaryDictionary.buildInMemory(words: [("i", 30000)])
        let czech = try BinaryDictionary.buildInMemory(words: [("i", 65000)])
        let engine = MultilingualEngine(dictionaries: [.english: english, .czech: czech])
        engine.recordCommittedWord("i", activeLanguages: [.czech])
        let result = engine.suggestions(for: "i", activeLanguages: [.english, .czech])
        XCTAssertNil(result.autocorrectReplacement)
        let englishOnly = engine.suggestions(for: "i", activeLanguages: [.english])
        XCTAssertEqual(englishOnly.autocorrectReplacement, "I")
    }

    func testWordsWithDigitsAreNotAutocorrected() throws {
        let english = try BinaryDictionary.buildInMemory(words: [("and", 60000)])
        let session = TypingSessionController(engine: MultilingualEngine(dictionaries: [.english: english]))
        for character in "2nd" {
            _ = session.handleCharacterInput(String(character), activeLanguages: [.english], autocorrectEnabled: true)
        }
        let actions = session.handleSpace(
            textBeforeCursor: "2nd", activeLanguages: [.english], autocorrectEnabled: true,
            doubleSpacePeriodEnabled: false
        )
        XCTAssertEqual(actions, [.insert(" ")])
    }

    func testCommaAfterPeriodCancelsSentenceStart() {
        let session = TypingSessionController(engine: MultilingualEngine())
        for character in "hi" {
            _ = session.handleCharacterInput(String(character), activeLanguages: [.english], autocorrectEnabled: false)
        }
        _ = session.handlePunctuation(".", activeLanguages: [.english], autocorrectEnabled: false)
        _ = session.handlePunctuation(",", activeLanguages: [.english], autocorrectEnabled: false)
        _ = session.handleSpace(
            textBeforeCursor: "hi.,", activeLanguages: [.english], autocorrectEnabled: false,
            doubleSpacePeriodEnabled: false
        )
        XCTAssertEqual(session.history, .empty)
    }

    func testOnlyTheReplacementIsHighlighted() throws {
        let english = try BinaryDictionary.buildInMemory(words: [("hello", 60000), ("help", 50000)])
        let engine = MultilingualEngine(dictionaries: [.english: english])
        let off = engine.suggestions(for: "helo", activeLanguages: [.english], autocorrectEnabled: false)
        XCTAssertFalse(off.suggestions.contains { $0.isAutocorrectPrimary })
        let on = engine.suggestions(for: "helo", activeLanguages: [.english], autocorrectEnabled: true)
        XCTAssertEqual(on.autocorrectReplacement, "hello")
        XCTAssertEqual(on.suggestions.filter(\.isAutocorrectPrimary).map(\.text), ["hello"])
    }

    func testPeriodInsideAWordIsNotASentenceStart() {
        let session = TypingSessionController(engine: MultilingualEngine())
        for character in "example" {
            _ = session.handleCharacterInput(String(character), activeLanguages: [.english], autocorrectEnabled: false)
        }
        _ = session.handlePunctuation(".", activeLanguages: [.english], autocorrectEnabled: false)
        for character in "com" {
            _ = session.handleCharacterInput(String(character), activeLanguages: [.english], autocorrectEnabled: false)
        }
        _ = session.handleSpace(
            textBeforeCursor: "example.com", activeLanguages: [.english], autocorrectEnabled: false,
            doubleSpacePeriodEnabled: false
        )
        XCTAssertEqual(session.history.tokens, [.word("com")])
    }

    func testClosingQuoteSurvivesAutocorrect() throws {
        let english = try BinaryDictionary.buildInMemory(words: [("hello", 60000)])
        let session = TypingSessionController(engine: MultilingualEngine(dictionaries: [.english: english]))
        func type(_ word: String) {
            for character in word {
                _ = session.handleCharacterInput(String(character), activeLanguages: [.english], autocorrectEnabled: true)
            }
            _ = session.handlePunctuation("'", activeLanguages: [.english], autocorrectEnabled: true)
        }

        type("hello")
        let kept = session.handleSpace(
            textBeforeCursor: "hello'", activeLanguages: [.english], autocorrectEnabled: true,
            doubleSpacePeriodEnabled: false
        )
        XCTAssertEqual(kept, [.insert(" ")])
        XCTAssertEqual(session.history.tokens, [.sentenceStart, .word("hello")])

        type("helo")
        let corrected = session.handleSpace(
            textBeforeCursor: "hello' helo'", activeLanguages: [.english], autocorrectEnabled: true,
            doubleSpacePeriodEnabled: false
        )
        XCTAssertEqual(corrected, [.replaceBackward(deleteCount: 5, insertText: "hello' ")])
    }

    func testDoubleSpaceStartsSentence() {
        let session = TypingSessionController(engine: MultilingualEngine())
        let start = Date(timeIntervalSince1970: 1000)
        for character in "hi" {
            _ = session.handleCharacterInput(String(character), activeLanguages: [.english], autocorrectEnabled: false)
        }
        _ = session.handleSpace(
            textBeforeCursor: "hi", activeLanguages: [.english], autocorrectEnabled: false,
            doubleSpacePeriodEnabled: true, now: start
        )
        XCTAssertEqual(session.history.tokens, [.sentenceStart, .word("hi")])
        _ = session.handleSpace(
            textBeforeCursor: "hi ", activeLanguages: [.english], autocorrectEnabled: false,
            doubleSpacePeriodEnabled: true, now: start.addingTimeInterval(0.2)
        )
        XCTAssertEqual(session.history, .sentenceStart)
    }

    func testTwoWordHistoryFeedsTrigramPredictions() throws {
        let (engine, _) = try makeEnglishEngine()
        let session = TypingSessionController(engine: engine)
        var text = ""
        for word in ["i", "want"] {
            for character in word {
                _ = session.handleCharacterInput(String(character), activeLanguages: [.english], autocorrectEnabled: false)
                text.append(character)
            }
            _ = session.handleSpace(
                textBeforeCursor: text, activeLanguages: [.english], autocorrectEnabled: false,
                doubleSpacePeriodEnabled: false
            )
            text.append(" ")
        }
        XCTAssertEqual(session.history.tokens, [.word("i"), .word("want")])
        XCTAssertEqual(session.currentSuggestions.suggestions.first?.text, "to")
    }

    func testAutocorrectUndoRestoresHistory() throws {
        let slovak = try BinaryDictionary.buildInMemory(words: [("ďakujem", 60000), ("veľmi", 55000)])
        let session = TypingSessionController(engine: MultilingualEngine(dictionaries: [.slovak: slovak]))
        for character in "dakujem" {
            _ = session.handleCharacterInput(String(character), activeLanguages: [.slovak], autocorrectEnabled: true)
        }
        _ = session.handleSpace(
            textBeforeCursor: "dakujem", activeLanguages: [.slovak], autocorrectEnabled: true,
            doubleSpacePeriodEnabled: false
        )
        XCTAssertEqual(session.history.tokens, [.sentenceStart, .word("ďakujem")])
        _ = session.handleBackspace(
            textBeforeCursor: "ďakujem ", activeLanguages: [.slovak], autocorrectEnabled: true
        )
        XCTAssertEqual(session.currentWord, "dakujem")
        XCTAssertEqual(session.history, .sentenceStart)
    }
}
