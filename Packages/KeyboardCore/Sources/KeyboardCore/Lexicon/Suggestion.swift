import Foundation

public struct SuggestionCandidate: Equatable, Sendable {
    public let text: String
    public let language: LanguageCode
    public let score: Double
    public let isAutocorrectPrimary: Bool

    public init(text: String, language: LanguageCode, score: Double, isAutocorrectPrimary: Bool = false) {
        self.text = text
        self.language = language
        self.score = score
        self.isAutocorrectPrimary = isAutocorrectPrimary
    }
}

public struct SuggestionResult: Equatable, Sendable {
    public let suggestions: [SuggestionCandidate]
    public let autocorrectReplacement: String?
    public let detectedLanguage: LanguageCode?
    /// Next-word predictions rather than completions of a typed word.
    public let isPrediction: Bool

    public static let empty = SuggestionResult(suggestions: [], autocorrectReplacement: nil, detectedLanguage: nil)

    public init(
        suggestions: [SuggestionCandidate],
        autocorrectReplacement: String?,
        detectedLanguage: LanguageCode?,
        isPrediction: Bool = false
    ) {
        self.suggestions = suggestions
        self.autocorrectReplacement = autocorrectReplacement
        self.detectedLanguage = detectedLanguage
        self.isPrediction = isPrediction
    }

    public func uppercased() -> SuggestionResult {
        SuggestionResult(
            suggestions: suggestions.map {
                SuggestionCandidate(
                    text: $0.text.uppercased(),
                    language: $0.language,
                    score: $0.score,
                    isAutocorrectPrimary: $0.isAutocorrectPrimary
                )
            },
            autocorrectReplacement: autocorrectReplacement?.uppercased(),
            detectedLanguage: detectedLanguage,
            isPrediction: isPrediction
        )
    }
}
