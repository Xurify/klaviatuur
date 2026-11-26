import Foundation

struct Lexicon {
    let dictionary: BinaryDictionary
    private(set) var model: BinaryLanguageModel?

    init(dictionary: BinaryDictionary) {
        self.dictionary = dictionary
    }

    /// Word ids index straight into the dictionary, so a model built from any other word list
    /// would predict the wrong words.
    mutating func attach(_ model: BinaryLanguageModel) -> Bool {
        guard model.vocabCount == dictionary.wordCount,
              model.vocabFingerprint == dictionary.vocabFingerprint()
        else { return false }
        self.model = model
        return true
    }

    func context(for history: WordHistory) -> PreparedLMContext {
        guard let model, let last = history.tokens.last, let previous1 = token(last) else { return .empty }
        let previous2 = history.tokens.count == 2 ? token(history.tokens[0]) : nil
        return model.prepareContext(prev1: previous1, prev2: previous2)
    }

    func contextLift(of wordId: UInt32, in context: PreparedLMContext) -> Double {
        model?.contextLift(of: wordId, in: context) ?? 0
    }

    func predictions(in context: PreparedLMContext, limit: Int) -> [(word: String, score: Double, isTrigram: Bool)] {
        guard let model else { return [] }
        let span = model.maxLogProb - model.minLogProb
        return model.topNextWords(in: context, limit: limit).compactMap { prediction in
            guard let word = dictionary.word(at: prediction.wordId)?.word else { return nil }
            let score = max(0, (prediction.logProb - model.minLogProb) / span)
            return (word: word, score: score, isTrigram: prediction.matchedOrder == 3)
        }
    }

    private func token(_ item: HistoryToken) -> LMContextToken? {
        switch item {
        case .sentenceStart: return .bos
        case .word(let word): return dictionary.exactWordId(for: word).map { .word($0) }
        }
    }
}
