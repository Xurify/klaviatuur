import Foundation
import os

public struct AutocorrectRevertState: Equatable, Sendable {
    public let originalTypedWord: String
    public let insertedReplacement: String
    public let trailingSeparator: String
    /// The two tokens before the correction, so an identical word elsewhere is not mistaken for it.
    public let precedingHistory: WordHistory
}

public enum TextEditAction: Equatable, Sendable {
    case insert(String)
    case deleteBackward(count: Int)
    case replaceBackward(deleteCount: Int, insertText: String)
}

public final class TypingSessionController {
    private let engine: MultilingualEngine
    private(set) public var currentWord: String = ""
    private(set) public var history: WordHistory = .sentenceStart
    public var previousCommittedWord: String? { history.previousWord }
    private(set) public var currentSuggestions: SuggestionResult = .empty
    private(set) public var lastAutocorrectRevert: AutocorrectRevertState?
    private var lastSpaceTimestamp: Date?
    private var pendingSentenceStart = false
    private var rejectedAutocorrectWords: Set<String> = []

    private struct LookupKey: Equatable {
        let word: String
        let history: WordHistory
        let languages: [LanguageCode]
        let autocorrect: Bool
    }

    // Space commits the word whose suggestions were just computed for the toolbar; reusing them
    // avoids a second full multi-language fuzzy search on the same keystroke.
    private var lastLookup: (key: LookupKey, result: SuggestionResult)?

    private func lookup(
        _ word: String,
        activeLanguages: [LanguageCode],
        autocorrect: Bool
    ) -> SuggestionResult {
        let key = LookupKey(
            word: word,
            history: history,
            languages: activeLanguages,
            autocorrect: autocorrect
        )
        if let lastLookup, lastLookup.key == key {
            return lastLookup.result
        }
        let result = engine.suggestions(
            for: word,
            history: history,
            activeLanguages: activeLanguages,
            autocorrectEnabled: autocorrect,
            limit: 3
        )
        lastLookup = word.isEmpty ? nil : (key, result)
        return result
    }

    public init(engine: MultilingualEngine) {
        self.engine = engine
    }

    public func syncWithDocumentContext(
        textBeforeCursor: String?,
        activeLanguages: [LanguageCode],
        autocorrectEnabled: Bool
    ) {
        let context = textBeforeCursor ?? ""
        let extracted = Self.extractTrailingContext(from: context)
        currentWord = extracted.currentWord
        history = extracted.history
        pendingSentenceStart = false
        // Some hosts report the keyboard's own insertion back through textDidChange; the
        // correction stays undoable while the cursor is still right after it.
        if let revert = lastAutocorrectRevert {
            let kept = Self.isRightAfter(revert, in: context)
            KeyboardLog.input.debug("Host reported a text change; autocorrect undo \(kept ? "kept" : "dropped", privacy: .public)")
            if !kept {
                lastAutocorrectRevert = nil
            }
        }
        refreshSuggestions(activeLanguages: activeLanguages, autocorrectEnabled: autocorrectEnabled)
    }

    public func cursorDidMove() {
        lastAutocorrectRevert = nil
        lastSpaceTimestamp = nil
    }

    public func handleCharacterInput(
        _ text: String,
        activeLanguages: [LanguageCode],
        autocorrectEnabled: Bool
    ) -> [TextEditAction] {
        if text.count == 1, let mark = text.first,
           !Self.isWordCharacter(mark) || (currentWord.isEmpty && Self.edgeMarks.contains(mark))
        {
            return handlePunctuation(text, activeLanguages: activeLanguages, autocorrectEnabled: autocorrectEnabled)
        }
        lastAutocorrectRevert = nil
        lastSpaceTimestamp = nil
        pendingSentenceStart = false
        currentWord.append(text)
        refreshSuggestions(activeLanguages: activeLanguages, autocorrectEnabled: autocorrectEnabled)
        return [.insert(text)]
    }

    public func handleSpace(
        textBeforeCursor: String?,
        activeLanguages: [LanguageCode],
        autocorrectEnabled: Bool,
        doubleSpacePeriodEnabled: Bool,
        now: Date = Date()
    ) -> [TextEditAction] {
        if doubleSpacePeriodEnabled,
           currentWord.isEmpty,
           let lastSpace = lastSpaceTimestamp,
           now.timeIntervalSince(lastSpace) <= 0.45,
           let before = textBeforeCursor,
           before.hasSuffix(" "),
           let prior = before.dropLast().last,
           prior.isLetter || prior.isNumber || Self.closingMarks.contains(prior)
        {
            lastSpaceTimestamp = nil
            lastAutocorrectRevert = nil
            engine.resetSentenceMomentum()
            history = .sentenceStart
            currentSuggestions = predictions(activeLanguages)
            return [.replaceBackward(deleteCount: 1, insertText: ". ")]
        }

        lastSpaceTimestamp = now
        if currentWord.isEmpty, let last = textBeforeCursor?.last, Self.endsSentence(String(last)) {
            pendingSentenceStart = true
        }
        return commitCurrentWord(
            separator: " ",
            activeLanguages: activeLanguages,
            autocorrectEnabled: autocorrectEnabled
        )
    }

    public func handlePunctuation(
        _ punctuation: String,
        activeLanguages: [LanguageCode],
        autocorrectEnabled: Bool
    ) -> [TextEditAction] {
        if !currentWord.isEmpty, punctuation.count == 1, let mark = punctuation.first, Self.isWordCharacter(mark) {
            return handleCharacterInput(punctuation, activeLanguages: activeLanguages, autocorrectEnabled: autocorrectEnabled)
        }
        lastSpaceTimestamp = nil
        let actions = commitCurrentWord(
            separator: punctuation,
            activeLanguages: activeLanguages,
            autocorrectEnabled: autocorrectEnabled
        )
        if punctuation == "\n" {
            engine.resetSentenceMomentum()
            history = .sentenceStart
            currentSuggestions = predictions(activeLanguages)
        } else if Self.endsSentence(punctuation) {
            // "example.com" is not a new sentence; only a space after the period makes one.
            engine.resetSentenceMomentum()
            history = .empty
            pendingSentenceStart = true
            currentSuggestions = .empty
        } else {
            history = .empty
            currentSuggestions = .empty
        }
        return actions
    }

    public func handleBackspace(
        textBeforeCursor: String?,
        activeLanguages: [LanguageCode],
        autocorrectEnabled: Bool
    ) -> [TextEditAction] {
        lastSpaceTimestamp = nil
        pendingSentenceStart = false

        if let revert = lastAutocorrectRevert {
            let expectedSuffix = revert.insertedReplacement + revert.trailingSeparator
            if let before = textBeforeCursor, Self.isRightAfter(revert, in: before) {
                lastAutocorrectRevert = nil
                rejectedAutocorrectWords.insert(Self.splitTrailingMarks(revert.originalTypedWord).core.lowercased())
                currentWord = revert.originalTypedWord
                history = Self.extractTrailingContext(
                    from: String(before.dropLast(expectedSuffix.count))
                ).history
                refreshSuggestions(activeLanguages: activeLanguages, autocorrectEnabled: false)
                return [
                    .replaceBackward(
                        deleteCount: expectedSuffix.count,
                        insertText: revert.originalTypedWord
                    )
                ]
            }
            lastAutocorrectRevert = nil
        }

        if !currentWord.isEmpty {
            currentWord.removeLast()
            refreshSuggestions(activeLanguages: activeLanguages, autocorrectEnabled: autocorrectEnabled)
            return [.deleteBackward(count: 1)]
        }

        if let before = textBeforeCursor, !before.isEmpty {
            let remaining = String(before.dropLast())
            let extracted = Self.extractTrailingContext(from: remaining)
            currentWord = extracted.currentWord
            history = extracted.history
            refreshSuggestions(activeLanguages: activeLanguages, autocorrectEnabled: autocorrectEnabled)
        }
        return [.deleteBackward(count: 1)]
    }

    public func acceptSuggestion(
        _ candidate: SuggestionCandidate,
        activeLanguages: [LanguageCode],
        autocorrectEnabled: Bool
    ) -> [TextEditAction] {
        lastSpaceTimestamp = nil
        lastAutocorrectRevert = nil
        lastLookup = nil
        let deleteCount = currentWord.count
        let typedWithMarks = currentWord
        let (typed, tail) = Self.splitTrailingMarks(currentWord)
        let committedWord = candidate.text
        engine.recordCommittedWord(committedWord, history: history, activeLanguages: activeLanguages)
        if committedWord == typed {
            engine.learnWord(committedWord)
        }

        history.append(word: committedWord)
        currentWord = ""
        currentSuggestions = predictions(activeLanguages)

        // "don'" + "don't" must not become "don't'"; a closing quote after a whole word stays.
        let completesTail = DiacriticFolding.fold(committedWord).hasPrefix(DiacriticFolding.fold(typedWithMarks))
        let insertText = committedWord + (completesTail ? "" : tail) + " "
        return deleteCount > 0 ? [.replaceBackward(deleteCount: deleteCount, insertText: insertText)] : [.insert(insertText)]
    }

    public func shouldAutoCapitalize(textBeforeCursor: String?) -> Bool {
        guard let before = textBeforeCursor, !before.isEmpty else {
            return true
        }
        let trimmed = before.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return true
        }
        if before.hasSuffix("\n") {
            return true
        }
        if let last = trimmed.last, Self.endsSentence(String(last)) && before.hasSuffix(" ") {
            return true
        }
        return false
    }

    private func commitCurrentWord(
        separator: String,
        activeLanguages: [LanguageCode],
        autocorrectEnabled: Bool
    ) -> [TextEditAction] {
        let (typed, tail) = Self.splitTrailingMarks(currentWord)
        let deleteCount = currentWord.count
        let startsSentence = pendingSentenceStart && separator == " "
        currentWord = ""
        pendingSentenceStart = false
        guard !typed.isEmpty else {
            lastAutocorrectRevert = nil
            if startsSentence {
                history = .sentenceStart
            }
            currentSuggestions = separator == " "
                ? predictions(activeLanguages)
                : .empty
            return [.insert(separator)]
        }

        let allowAutocorrect = canAutocorrect(typed, enabled: autocorrectEnabled)
        let result = lookup(typed, activeLanguages: activeLanguages, autocorrect: allowAutocorrect)
        lastLookup = nil

        if let replacement = result.autocorrectReplacement, replacement != typed {
            engine.recordCommittedWord(replacement, history: history, activeLanguages: activeLanguages)
            lastAutocorrectRevert = AutocorrectRevertState(
                originalTypedWord: typed + tail,
                insertedReplacement: replacement,
                trailingSeparator: tail + separator,
                precedingHistory: history
            )
            history.append(word: replacement)
            currentSuggestions = separator == " "
                ? predictions(activeLanguages)
                : .empty
            return [
                .replaceBackward(
                    deleteCount: deleteCount,
                    insertText: replacement + tail + separator
                )
            ]
        }

        lastAutocorrectRevert = nil
        engine.recordCommittedWord(typed, history: history, activeLanguages: activeLanguages)
        history.append(word: typed)
        currentSuggestions = separator == " "
            ? predictions(activeLanguages)
            : .empty
        return [.insert(separator)]
    }

    private func canAutocorrect(_ word: String, enabled: Bool) -> Bool {
        enabled && !word.contains(where: \.isNumber) && !rejectedAutocorrectWords.contains(word.lowercased())
    }

    private func predictions(_ activeLanguages: [LanguageCode]) -> SuggestionResult {
        engine.nextWordSuggestions(history: history, activeLanguages: activeLanguages, limit: 3)
    }

    private func refreshSuggestions(
        activeLanguages: [LanguageCode],
        autocorrectEnabled: Bool
    ) {
        let word = Self.splitTrailingMarks(currentWord).core
        let allowAutocorrect = canAutocorrect(word, enabled: autocorrectEnabled)
        currentSuggestions = lookup(word, activeLanguages: activeLanguages, autocorrect: allowAutocorrect)
    }

    /// "bathe " ends with "the " too; the correction must start a word and follow the same two tokens.
    private static func isRightAfter(_ revert: AutocorrectRevertState, in context: String) -> Bool {
        let corrected = revert.insertedReplacement + revert.trailingSeparator
        guard context.hasSuffix(corrected) else { return false }
        let preceding = extractTrailingContext(from: String(context.dropLast(corrected.count)))
        return preceding.currentWord.isEmpty && preceding.history == revert.precedingHistory
    }

    static func endsSentence(_ text: String) -> Bool {
        text == "." || text == "!" || text == "?" || text == "\u{2026}" || text == "\n"
    }

    private static let closingMarks = "\"'\u{2019}\u{201D})]"
    private static let edgeMarks = "-'\u{2018}\u{2019}\u{02BC}"
    private static let wordEdgeMarks = CharacterSet(charactersIn: edgeMarks)

    /// A quote or hyphen at the end of a word ("hello'", "go-") is punctuation, not part of the word.
    static func splitTrailingMarks(_ word: String) -> (core: String, tail: String) {
        let core = String(word.reversed().drop { edgeMarks.contains($0) }.reversed())
        return (core, String(word.dropFirst(core.count)))
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || edgeMarks.contains(character)
    }

    /// Splits the text before the cursor into the word being typed and up to two context
    /// tokens before it. iOS only hands the keyboard a window of recent text, so reaching the
    /// start of that window counts as a sentence start; that is right far more often than not.
    static func extractTrailingContext(from context: String) -> (currentWord: String, history: WordHistory) {
        var start = context.endIndex
        while start > context.startIndex, isWordCharacter(context[context.index(before: start)]) {
            start = context.index(before: start)
        }
        var currentStart = start
        while currentStart < context.endIndex, edgeMarks.contains(context[currentStart]) {
            currentStart = context.index(after: currentStart)
        }
        let current = String(context[currentStart...])
        // An opening quote or dash is a clause break, as it is in the training corpus.
        guard currentStart == start else { return (current, .empty) }

        var reversedTokens: [HistoryToken] = []
        var cursor = start
        while reversedTokens.count < 2 {
            let beforeSpaces = cursor
            while cursor > context.startIndex {
                let character = context[context.index(before: cursor)]
                guard character.isWhitespace, !character.isNewline else { break }
                cursor = context.index(before: cursor)
            }
            guard cursor > context.startIndex else {
                reversedTokens.append(.sentenceStart)
                break
            }
            let character = context[context.index(before: cursor)]
            if character.isNewline || (endsSentence(String(character)) && cursor != beforeSpaces) {
                reversedTokens.append(.sentenceStart)
                break
            }
            guard isWordCharacter(character) else { break }
            var wordStart = cursor
            while wordStart > context.startIndex, isWordCharacter(context[context.index(before: wordStart)]) {
                wordStart = context.index(before: wordStart)
            }
            let raw = context[wordStart..<cursor]
            let word = raw.trimmingCharacters(in: wordEdgeMarks)
            guard !word.isEmpty else { break }
            reversedTokens.append(.word(word))
            if let first = raw.first, edgeMarks.contains(first) { break }
            cursor = wordStart
        }
        return (current, WordHistory(reversedTokens.reversed()))
    }
}
