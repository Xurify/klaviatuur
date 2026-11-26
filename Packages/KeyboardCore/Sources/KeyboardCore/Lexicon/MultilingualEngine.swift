import Foundation
import os

public final class MultilingualEngine {
    private var lexicons: [LanguageCode: Lexicon]
    private var languageMomentum: [LanguageCode: Double] = [:]
    private var keyCentersByScalar: [UInt32: KeyPoint] = [:]
    private var averageKeyWidth: Double = 36.0
    private var userLearnedWords: Set<String> = []

    public init(dictionaries: [LanguageCode: BinaryDictionary] = [:]) {
        lexicons = dictionaries.mapValues(Lexicon.init(dictionary:))
    }

    public func loadDictionaries(from bundle: Bundle, languages: [LanguageCode]) {
        func url(_ language: LanguageCode, _ fileExtension: String) -> URL? {
            bundle.url(forResource: language.rawValue, withExtension: fileExtension)
                ?? bundle.url(forResource: language.rawValue, withExtension: fileExtension, subdirectory: "Dictionaries")
        }
        for language in languages where lexicons[language] == nil {
            let code = language.rawValue
            guard let dictionaryURL = url(language, "kdict") else {
                KeyboardLog.lexicon.error("\(code, privacy: .public).kdict is missing from the bundle")
                continue
            }
            do {
                registerDictionary(try BinaryDictionary(contentsOf: dictionaryURL), for: language)
            } catch {
                KeyboardLog.lexicon.error("\(code, privacy: .public).kdict failed to load: \(String(describing: error), privacy: .public)")
                continue
            }
            guard let modelURL = url(language, "klm") else {
                KeyboardLog.lexicon.notice("\(code, privacy: .public).klm is missing, so \(code, privacy: .public) has no predictions")
                continue
            }
            do {
                registerLanguageModel(try BinaryLanguageModel(contentsOf: modelURL), for: language)
            } catch {
                KeyboardLog.lexicon.error("\(code, privacy: .public).klm failed to load: \(String(describing: error), privacy: .public)")
            }
        }
    }

    public func registerDictionary(_ dictionary: BinaryDictionary, for language: LanguageCode) {
        lexicons[language] = Lexicon(dictionary: dictionary)
    }

    @discardableResult
    public func registerLanguageModel(_ model: BinaryLanguageModel, for language: LanguageCode) -> Bool {
        guard lexicons[language]?.attach(model) == true else {
            KeyboardLog.lexicon.error(
                "\(language.rawValue, privacy: .public).klm was built for a different .kdict, so it is ignored"
            )
            return false
        }
        return true
    }

    public func hasLanguageModel(for language: LanguageCode) -> Bool {
        lexicons[language]?.model != nil
    }

    public func updateKeyGeometry(_ geometries: [KeyGeometry]) {
        var centers: [UInt32: KeyPoint] = [:]
        var widthSum = 0.0
        var letterCount = 0
        for item in geometries {
            guard case .character(let character) = item.keySpec.kind else { continue }
            for scalar in DiacriticFolding.foldedScalars(character) {
                centers[scalar] = item.frame.center
            }
            widthSum += item.frame.width
            letterCount += 1
        }
        keyCentersByScalar = centers
        if letterCount > 0 {
            averageKeyWidth = max(widthSum / Double(letterCount), 16.0)
        }
    }

    public func learnWord(_ word: String) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        userLearnedWords.insert(trimmed.lowercased())
    }

    // MARK: - Language momentum

    public func recordCommittedWord(_ word: String, history: WordHistory = .empty, activeLanguages: [LanguageCode]) {
        guard !word.isEmpty else { return }
        let matches = activeLanguages.compactMap { language -> (LanguageCode, UInt16)? in
            lexicons[language]?.dictionary.exactMatches(for: word).first.map { (language, $0.frequencyScore) }
        }

        // Fast decay keeps switching languages mid-conversation cheap.
        for language in activeLanguages {
            languageMomentum[language] = (languageMomentum[language] ?? 0) * 0.65
        }
        if matches.count == 1 {
            boostMomentum(of: matches[0].0, by: 0.55)
        } else if let strongest = matches.max(by: { $0.1 < $1.1 }) {
            boostMomentum(of: strongest.0, by: 0.25)
        }

        // A word shared by several languages ("to", "je") still pins the language when it forms
        // a known pair with the previous word ("to je" is Czech or Slovak).
        guard !history.isEmpty else { return }
        for language in activeLanguages {
            guard let lexicon = lexicons[language], let model = lexicon.model,
                  let wordId = lexicon.dictionary.exactWordId(for: word)
            else { continue }
            let context = lexicon.context(for: history)
            if !context.isEmpty, model.logProbability(of: wordId, in: context).matchedOrder >= 2 {
                boostMomentum(of: language, by: 0.20)
            }
        }
    }

    /// Some momentum survives a period so the next sentence's predictions stay in the language
    /// the user was writing instead of mixing starters from every language.
    public func resetSentenceMomentum() {
        languageMomentum = languageMomentum.mapValues { min($0 * 0.45, 0.40) }
    }

    private func boostMomentum(of language: LanguageCode, by amount: Double) {
        languageMomentum[language] = min(1.0, (languageMomentum[language] ?? 0) + amount)
    }

    private func momentumBoost(_ language: LanguageCode, weight: Double) -> Double {
        1.0 + (languageMomentum[language] ?? 0) * weight
    }

    // MARK: - Suggestions

    public func nextCharacterScores(forPrefix prefix: String, activeLanguages: [LanguageCode]) -> [UInt32: Double] {
        var combined: [UInt32: Double] = [:]
        for language in activeLanguages {
            guard let dictionary = lexicons[language]?.dictionary else { continue }
            let weight = momentumBoost(language, weight: 0.35)
            for (scalar, score) in dictionary.nextCharacterScores(forPrefix: prefix) {
                combined[scalar] = max(combined[scalar] ?? 0, Double(score) * weight)
            }
        }
        return combined
    }

    public func nextWordSuggestions(
        history: WordHistory,
        activeLanguages: [LanguageCode],
        limit: Int = 3
    ) -> SuggestionResult {
        guard !history.isEmpty else { return .empty }
        var candidates: [SuggestionCandidate] = []
        for language in activeLanguages {
            guard let lexicon = lexicons[language] else { continue }
            let boost = momentumBoost(language, weight: 0.45)
            for prediction in lexicon.predictions(in: lexicon.context(for: history), limit: limit + 2) {
                candidates.append(SuggestionCandidate(
                    text: Self.predictionCasing(prediction.word, language: language, sentenceStart: history.isSentenceStart),
                    language: language,
                    score: prediction.score * (prediction.isTrigram ? 1.20 : 1.0) * boost
                ))
            }
        }
        let ranked = deduplicateAndRank(candidates, limit: limit)
        return SuggestionResult(
            suggestions: ranked,
            autocorrectReplacement: nil,
            detectedLanguage: ranked.first?.language,
            isPrediction: true
        )
    }

    static func predictionCasing(_ word: String, language: LanguageCode, sentenceStart: Bool) -> String {
        let isEnglishI = language == .english && (word == "i" || word.hasPrefix("i'"))
        guard sentenceStart || isEnglishI, let first = word.first else { return word }
        return String(first).uppercased() + word.dropFirst()
    }

    public func suggestions(
        for typedWord: String,
        history: WordHistory = .empty,
        activeLanguages: [LanguageCode],
        autocorrectEnabled: Bool = true,
        limit: Int = 3
    ) -> SuggestionResult {
        guard !typedWord.isEmpty else {
            return nextWordSuggestions(history: history, activeLanguages: activeLanguages, limit: limit)
        }
        let typed = TypedWord(typedWord)
        var restorations: [SuggestionCandidate] = []
        var completions: [SuggestionCandidate] = []
        var corrections: [SuggestionCandidate] = []

        for language in activeLanguages {
            guard let lexicon = lexicons[language] else { continue }
            let scoring = Scoring(
                lexicon: lexicon,
                context: lexicon.context(for: history),
                language: language,
                boost: momentumBoost(language, weight: 0.40)
            )
            restorations += restorationCandidates(typed, scoring)
            completions += completionCandidates(typed, scoring)
            corrections += correctionCandidates(typed, scoring)
        }

        let replacement = autocorrectEnabled && !userLearnedWords.contains(typed.lowered)
            ? autocorrectReplacement(typed, restorations: restorations, corrections: corrections)
            : nil
        let candidates = restorations + corrections + completions
        var ranked = deduplicateAndRank(candidates, limit: limit)
        // Space inserts the replacement, so it takes the centre slot even when outscored.
        if let replacement,
           let chosen = candidates.filter({ $0.text == replacement }).max(by: { $0.score < $1.score })
        {
            ranked = Array(([chosen] + ranked.filter { $0.text != replacement }).prefix(limit))
        }
        if let replacement {
            ranked = highlight(replacement, keepingLiteral: typed, in: ranked, limit: limit, fallback: activeLanguages.first)
        }
        return SuggestionResult(
            suggestions: ranked,
            autocorrectReplacement: replacement,
            detectedLanguage: ranked.first?.language
        )
    }

    // MARK: - Candidate sources

    private struct TypedWord {
        let text: String
        let lowered: String
        let folded: String

        init(_ text: String) {
            self.text = text
            lowered = text.lowercased()
            folded = DiacriticFolding.fold(text)
        }

        func cased(_ word: String, _ language: LanguageCode) -> String {
            DiacriticFolding.applyCasing(of: text, to: word, language: language)
        }
    }

    private struct Scoring {
        let lexicon: Lexicon
        let context: PreparedLMContext
        let language: LanguageCode
        let boost: Double

        /// The lift is log P(w | history) - log P(w), so it adds what the previous words say
        /// without counting the word's own frequency twice.
        func contextBonus(_ wordId: UInt32, weight: Double) -> Double {
            weight * lexicon.contextLift(of: wordId, in: context)
        }
    }

    /// The typed letters with diacritics restored: "dakujem" -> "ďakujem", "еще" -> "ещё".
    private func restorationCandidates(_ typed: TypedWord, _ scoring: Scoring) -> [SuggestionCandidate] {
        scoring.lexicon.dictionary.exactMatches(for: typed.text).map { match in
            let score = (match.word.lowercased() == typed.lowered ? 2.45 : 2.35)
                + frequency(match.frequencyScore) * 0.90
                + scoring.contextBonus(match.wordId, weight: 0.25)
            return SuggestionCandidate(
                text: typed.cased(match.word, scoring.language),
                language: scoring.language,
                score: score * scoring.boost
            )
        }
    }

    private func completionCandidates(_ typed: TypedWord, _ scoring: Scoring) -> [SuggestionCandidate] {
        let length = typed.text.count
        if length == 1 {
            // A single letter is too short to rank trie completions, but the model can: "thank y" -> "you".
            return scoring.lexicon.predictions(in: scoring.context, limit: 64).compactMap { prediction in
                let folded = DiacriticFolding.fold(prediction.word)
                guard folded.hasPrefix(typed.folded), folded != typed.folded else { return nil }
                return SuggestionCandidate(
                    text: typed.cased(prediction.word, scoring.language),
                    language: scoring.language,
                    score: (1.35 + prediction.score * 0.85) * scoring.boost
                )
            }
        }
        return scoring.lexicon.dictionary.prefixCompletions(forPrefix: typed.text, limit: 4).compactMap { completion in
            guard DiacriticFolding.fold(completion.word) != typed.folded else { return nil }
            let lengthPenalty = Double(max(0, completion.word.count - length)) * 0.05
            let score = 1.15
                + frequency(completion.frequencyScore) * 0.75
                + scoring.contextBonus(completion.wordId, weight: 0.30)
                - lengthPenalty
            return SuggestionCandidate(
                text: typed.cased(completion.word, scoring.language),
                language: scoring.language,
                score: score * scoring.boost
            )
        }
    }

    private func correctionCandidates(_ typed: TypedWord, _ scoring: Scoring) -> [SuggestionCandidate] {
        let length = typed.text.count
        guard length >= 2 else { return [] }
        let editBudget = length <= 3 ? 1.05 : (length <= 6 ? 1.55 : 1.95)
        let matches = scoring.lexicon.dictionary.fuzzyMatches(
            for: typed.text,
            maxEditCost: editBudget,
            substitutionCost: { typed, candidate in
                self.keyboardSubstitutionCost(typedScalar: typed, candidateScalar: candidate)
            },
            limit: 5
        )
        return matches.compactMap { match in
            guard DiacriticFolding.fold(match.word) != typed.folded else { return nil }
            let score = 2.10
                - match.editCost * 0.85
                + frequency(match.frequencyScore) * 0.85
                + scoring.contextBonus(match.wordId, weight: 0.28)
            return SuggestionCandidate(
                text: typed.cased(match.word, scoring.language),
                language: scoring.language,
                score: score * scoring.boost
            )
        }
    }

    // MARK: - Autocorrect

    private func autocorrectReplacement(
        _ typed: TypedWord,
        restorations: [SuggestionCandidate],
        corrections: [SuggestionCandidate]
    ) -> String? {
        let literalScores = restorations.filter { $0.text.lowercased() == typed.lowered }.map(\.score)
        let literalExists = !literalScores.isEmpty

        if let best = restorations.max(by: { $0.score < $1.score }), best.text.lowercased() != typed.lowered {
            // A real word the user typed is only overridden when the restored form is clearly stronger.
            guard literalExists else { return best.text }
            return best.score > (literalScores.max() ?? 0) + 0.15 ? best.text : nil
        }
        if !literalExists, let best = corrections.max(by: { $0.score < $1.score }), best.score >= 1.30 {
            return best.text
        }
        // English "i" -> "I", but only when English is the reading that won: Czech and Slovak "i" stay.
        guard typed.folded == "i" || typed.folded.hasPrefix("i'"),
              let best = restorations.max(by: { $0.score < $1.score }),
              best.language == .english, best.text != typed.text
        else { return nil }
        return best.text
    }

    /// Marks the replacement as the primary slot and keeps what the user typed reachable.
    private func highlight(
        _ replacement: String,
        keepingLiteral typed: TypedWord,
        in ranked: [SuggestionCandidate],
        limit: Int,
        fallback: LanguageCode?
    ) -> [SuggestionCandidate] {
        var result = ranked.map {
            SuggestionCandidate(text: $0.text, language: $0.language, score: $0.score, isAutocorrectPrimary: $0.text == replacement)
        }
        guard limit >= 2, !result.contains(where: { $0.text == typed.text }) else { return result }
        let literal = SuggestionCandidate(
            text: typed.text,
            language: result.first?.language ?? fallback ?? .english,
            score: 0
        )
        if result.count >= limit, let slot = result.lastIndex(where: { $0.text != replacement }) {
            result[slot] = literal
        } else {
            result.append(literal)
        }
        return result
    }

    // MARK: - Helpers

    private func frequency(_ score: UInt16) -> Double {
        Double(score) / 65535.0
    }

    private func keyboardSubstitutionCost(typedScalar: UInt32, candidateScalar: UInt32) -> Double {
        guard let typedCenter = keyCentersByScalar[typedScalar],
              let candidateCenter = keyCentersByScalar[candidateScalar]
        else { return 1.0 }
        let distance = typedCenter.distance(to: candidateCenter) / averageKeyWidth
        if distance <= 1.15 { return 0.42 }
        if distance <= 1.75 { return 0.68 }
        return 1.0
    }

    private func deduplicateAndRank(_ candidates: [SuggestionCandidate], limit: Int) -> [SuggestionCandidate] {
        var seen: Set<String> = []
        return Array(
            candidates
                .sorted { $0.score > $1.score }
                .filter { seen.insert($0.text).inserted }
                .prefix(limit)
        )
    }
}
