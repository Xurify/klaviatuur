import XCTest
@testable import KeyboardCore

final class TypingSessionControllerTests: XCTestCase {
    func testAutocorrectAndUndoOnImmediateBackspace() throws {
        let slovak = try BinaryDictionary.buildInMemory(
            words: [("ďakujem", 60000), ("veľmi", 55000)]
        )
        let engine = MultilingualEngine(dictionaries: [.slovak: slovak])
        let session = TypingSessionController(engine: engine)
        let languages: [LanguageCode] = [.slovak]

        for character in "dakujem" {
            _ = session.handleCharacterInput(
                String(character),
                activeLanguages: languages,
                autocorrectEnabled: true
            )
        }

        let spaceActions = session.handleSpace(
            textBeforeCursor: "dakujem",
            activeLanguages: languages,
            autocorrectEnabled: true,
            doubleSpacePeriodEnabled: true
        )
        XCTAssertEqual(
            spaceActions,
            [.replaceBackward(deleteCount: 7, insertText: "ďakujem ")]
        )

        let undoActions = session.handleBackspace(
            textBeforeCursor: "ďakujem ",
            activeLanguages: languages,
            autocorrectEnabled: true
        )
        XCTAssertEqual(
            undoActions,
            [.replaceBackward(deleteCount: 8, insertText: "dakujem")]
        )
        XCTAssertEqual(session.currentWord, "dakujem")
    }

    func testUndoSurvivesTheHostReportingTheCorrectionBack() throws {
        let slovak = try BinaryDictionary.buildInMemory(words: [("ďakujem", 60000)])
        let languages: [LanguageCode] = [.slovak]

        func correctedSession(after prefix: String = "") -> TypingSessionController {
            let session = TypingSessionController(engine: MultilingualEngine(dictionaries: [.slovak: slovak]))
            session.syncWithDocumentContext(textBeforeCursor: prefix, activeLanguages: languages, autocorrectEnabled: true)
            for character in "dakujem" {
                _ = session.handleCharacterInput(String(character), activeLanguages: languages, autocorrectEnabled: true)
            }
            _ = session.handleSpace(
                textBeforeCursor: prefix + "dakujem", activeLanguages: languages,
                autocorrectEnabled: true, doubleSpacePeriodEnabled: true
            )
            return session
        }

        let echoed = correctedSession()
        echoed.syncWithDocumentContext(textBeforeCursor: "ďakujem ", activeLanguages: languages, autocorrectEnabled: true)
        XCTAssertEqual(
            echoed.handleBackspace(textBeforeCursor: "ďakujem ", activeLanguages: languages, autocorrectEnabled: true),
            [.replaceBackward(deleteCount: 8, insertText: "dakujem")]
        )

        let afterWords = correctedSession(after: "Ahoj, som tu a ")
        afterWords.syncWithDocumentContext(
            textBeforeCursor: "Ahoj, som tu a ďakujem ", activeLanguages: languages, autocorrectEnabled: true
        )
        XCTAssertNotNil(afterWords.lastAutocorrectRevert)

        let moved = correctedSession()
        moved.syncWithDocumentContext(textBeforeCursor: "elsewhere ", activeLanguages: languages, autocorrectEnabled: true)
        XCTAssertNil(moved.lastAutocorrectRevert)

        let sameWordEarlier = correctedSession()
        sameWordEarlier.syncWithDocumentContext(
            textBeforeCursor: "Povedal som ďakujem ", activeLanguages: languages, autocorrectEnabled: true
        )
        XCTAssertNil(sameWordEarlier.lastAutocorrectRevert)

        let longerWord = correctedSession()
        longerWord.syncWithDocumentContext(textBeforeCursor: "poďakujem ", activeLanguages: languages, autocorrectEnabled: true)
        XCTAssertNil(longerWord.lastAutocorrectRevert)

        let scrubbed = correctedSession()
        scrubbed.cursorDidMove()
        XCTAssertNil(scrubbed.lastAutocorrectRevert)
    }

    func testDoubleSpaceAddsNoPeriodAfterPunctuationOrInAnEmptyField() {
        let start = Date(timeIntervalSince1970: 1000)
        for before in ["hi? ", "hi, ", " "] {
            let session = TypingSessionController(engine: MultilingualEngine())
            _ = session.handleSpace(
                textBeforeCursor: String(before.dropLast()), activeLanguages: [.english],
                autocorrectEnabled: false, doubleSpacePeriodEnabled: true, now: start
            )
            let second = session.handleSpace(
                textBeforeCursor: before, activeLanguages: [.english], autocorrectEnabled: false,
                doubleSpacePeriodEnabled: true, now: start.addingTimeInterval(0.2)
            )
            XCTAssertEqual(second, [.insert(" ")], before)
        }
    }

    func testDoubleSpaceInsertsPeriod() throws {
        let engine = MultilingualEngine()
        let session = TypingSessionController(engine: engine)
        let firstTime = Date(timeIntervalSince1970: 1000)

        _ = session.handleCharacterInput("h", activeLanguages: [.english], autocorrectEnabled: false)
        _ = session.handleCharacterInput("i", activeLanguages: [.english], autocorrectEnabled: false)
        let firstSpace = session.handleSpace(
            textBeforeCursor: "hi",
            activeLanguages: [.english],
            autocorrectEnabled: false,
            doubleSpacePeriodEnabled: true,
            now: firstTime
        )
        XCTAssertEqual(firstSpace, [.insert(" ")])

        let secondSpace = session.handleSpace(
            textBeforeCursor: "hi ",
            activeLanguages: [.english],
            autocorrectEnabled: false,
            doubleSpacePeriodEnabled: true,
            now: firstTime.addingTimeInterval(0.2)
        )
        XCTAssertEqual(secondSpace, [.replaceBackward(deleteCount: 1, insertText: ". ")])
    }
}
