import Foundation

public enum HistoryToken: Equatable, Sendable {
    case sentenceStart
    case word(String)
}

/// The last two tokens before the word being typed. Clause punctuation clears it and sentence
/// punctuation resets it to `.sentenceStart`, so predictions never condition on a previous clause.
public struct WordHistory: Equatable, Sendable {
    public private(set) var tokens: [HistoryToken]

    public init(_ tokens: [HistoryToken] = []) {
        self.tokens = Array(tokens.suffix(2))
    }

    public static let empty = WordHistory()
    public static let sentenceStart = WordHistory([.sentenceStart])

    public var isEmpty: Bool { tokens.isEmpty }
    public var isSentenceStart: Bool { tokens.last == .sentenceStart }

    public var previousWord: String? {
        if case .word(let word)? = tokens.last { return word }
        return nil
    }

    public mutating func append(word: String) {
        tokens = Array((tokens + [.word(word)]).suffix(2))
    }
}
