# Next-word prediction: implementation plan

The design and the reasoning behind it are in [next-word-prediction-design.md](next-word-prediction-design.md).
This file records where the implementation departs from that design and pins the interfaces
that the pieces are built against. Where the two disagree, this file wins.

Phase 1 only: the static `.klm` model. Personal learning (Option 4) and the next-word
profanity blocklist come later.

## Amendments to the design

1. **Fingerprint covers the whole vocabulary.** A `.klm` is valid only when
   `lm.vocabCount == dict.wordCount` and `lm.vocabFingerprint == dict.vocabFingerprint()`.
   There is no `prefixCount` parameter. The reference implementation is
   `Scripts/lm_common.py` (`vocab_fingerprint`, FNV-1a over every word). Swift gets
   `BinaryDictionary.vocabFingerprint() -> UInt64` with the same algorithm.
2. **One source of next-word data.** The `.klm` model is the only one. `build_dicts.py` writes the
   `.kdict` word-pair table empty (the format keeps the slot), and the engine and
   `BinaryDictionary` no longer read it. A language without a `.klm` simply gets no predictions.
3. **One tokenizer.** `Scripts/lm_common.py` (`tokenize_sentence`) produces both the production
   word lists (`Data/sources/<lang>.tsv`) and the n-gram counts, so word IDs always line up.
   A `None` token is a clause break. No n-gram spans a break, and a break clears the context.
4. **`ё` normalization** and the **profanity blocklist** are deferred. Until `ё` is restored at
   build time the Russian model cannot tell "всё" from "все" (news text mostly writes "все").
7. **Held-out evaluation.** `build_lm.py` keeps one sentence in 200 out of training, and
   `Scripts/evaluate_lm.py` measures the models on them.
5. **Tatoeba is filtered and reweighted.** Sentences that mention its stock characters (Tom,
   Mary) are dropped, because otherwise "tom" ranks among the top five English words. The ×4
   weight applies only to cs, sk and et, where Tatoeba is small.
6. **Realistic golden cases.** "ako sa máš", "jak se máš" and "kuidas läheb" are rare in the
   news and web corpora, so `verify_lm.py --golden` checks collocations that all registers
   share. Chat-style phrasing is a job for personal learning (phase 2).

## Pipeline

```
Scripts/fetch_corpora.py      -> Data/corpora/<lang>/*.txt              (gitignored)
Scripts/build_lm.py wordlists -> Data/sources/<lang>.tsv                (top 50k words)
Scripts/build_dicts.py        -> KeyboardExtension/Resources/Dictionaries/<lang>.kdict
Scripts/build_lm.py model     -> KeyboardExtension/Resources/Dictionaries/<lang>.klm
Scripts/verify_lm.py          -> format, fingerprint and golden-prediction checks
```

## Python interface: `Scripts/klm_format.py`

```python
@dataclass
class KLMModel:
    vocab_count: int                  # == .kdict wordCount, <= 65534
    vocab_fingerprint: int            # lm_common.vocab_fingerprint(...)
    # Index 0..vocab_count-1 = words, index vocab_count = <BOS>.
    # log10 P_KN(w) for words; ignored for <BOS> (written as q=0).
    unigram_log_prob: list[float]     # len == vocab_count + 1
    # log10 bow(u), or None when u has no stored bigrams (written as 0xFF).
    unigram_log_bow: list[float | None]  # len == vocab_count + 1
    # context index (0..vocab_count, <BOS> allowed) -> [(next_id, log10 P(next|ctx), log10 bow(ctx,next) or None)]
    # None in the third slot means "no trigrams stored for (ctx, next)" and is written as 0xFF.
    bigrams: dict[int, list[tuple[int, float, float | None]]]
    # (ctx index incl. <BOS>, w2 id) -> [(w3 id, log10 P(w3|ctx,w2))]
    trigrams: dict[tuple[int, int], list[tuple[int, float]]]
    min_log_prob: float = -8.0
    max_log_prob: float = 0.0
    min_log_bow: float = -6.0
    max_log_bow: float = 2.0

def write_klm(model: KLMModel, path: Path) -> int            # returns bytes written
def read_klm(path: Path) -> KLMReader                         # reference reader, mirrors Swift

class KLMReader:
    vocab_count: int; vocab_fingerprint: int
    def prepare_context(self, prev1: int | None, prev2: int | None) -> PreparedContext
        # ids are word ids; vocab_count means <BOS>; None means no context
    def log_probability(self, word_id: int, ctx: PreparedContext) -> tuple[float, int]   # (log10p, matched order)
    def unigram_log_probability(self, word_id: int) -> float
    def context_lift(self, word_id: int, ctx: PreparedContext) -> float
    def top_next_words(self, ctx: PreparedContext, limit: int) -> list[tuple[int, float, int]]  # (id, log10p, order)
```

The writer sorts each slice by `next_id`, enforces the caps (bigram slice ≤ 512, trigram slice
≤ 32), drops trigram contexts with no trigrams, and raises `ValueError` when a trigram
context's bigram is missing or its `log_bow` is `None`.

## Swift interface: `BinaryLanguageModel.swift`

```swift
public enum LMContextToken: Equatable, Sendable { case bos; case word(UInt32) }

public struct LMNextWordPrediction: Equatable, Sendable {
    public let wordId: UInt32
    public let logProb: Double        // log10
    public let matchedOrder: UInt8    // 3 trigram, 2 bigram
}

public struct PreparedLMContext: Sendable {
    public static let empty: PreparedLMContext
    public var isEmpty: Bool          // no bigram range and no trigram range
    // internal: bigramRange, bigramLogBow, trigramRange, trigramLogBow
}

public enum LanguageModelError: Error, Equatable {
    case truncatedHeader, invalidMagic, unsupportedVersion(UInt16), unsupportedFlags(UInt16)
    case invalidQuantization, corruptedOffsets, corruptedSentinel
}

public final class BinaryLanguageModel: @unchecked Sendable {
    public let vocabCount: Int
    public let vocabFingerprint: UInt64
    public let minLogProb: Double
    public convenience init(contentsOf url: URL) throws   // NSData(.alwaysMapped)
    public convenience init(data: Data) throws
    public func prepareContext(prev1: LMContextToken?, prev2: LMContextToken?) -> PreparedLMContext
    public func unigramLogProbability(of wordId: UInt32) -> Double
    public func logProbability(of wordId: UInt32, in context: PreparedLMContext) -> (logProb: Double, matchedOrder: UInt8)
    /// clamp(logP(w|ctx) - logP(w), -1.5, 2.5); 0 when context.isEmpty or wordId >= vocabCount.
    public func contextLift(of wordId: UInt32, in context: PreparedLMContext) -> Double
    public func topNextWords(in context: PreparedLMContext, limit: Int) -> [LMNextWordPrediction]
    public static func buildInMemory(
        vocabCount: Int,
        vocabFingerprint: UInt64,
        unigrams: [(logProb: Double, logBow: Double?)],                    // count == vocabCount + 1
        bigrams: [(context: LMContextToken, next: UInt32, logProb: Double, trigramLogBow: Double?)],
        trigrams: [(prev2: LMContextToken, prev1: UInt32, next: UInt32, logProb: Double)]
    ) throws -> BinaryLanguageModel
}
```

`BinaryDictionary` gains (Claude): `FuzzyWordMatch.wordId`, `word(at:)`,
`exactWordId(for:)` and `vocabFingerprint()`.

## Ownership

| Owner | Files |
|---|---|
| Gemini | `Scripts/fetch_corpora.py`, `Scripts/klm_format.py`, `Scripts/verify_lm.py`, `Scripts/test_klm_format.py`, `BinaryLanguageModel.swift`, `BinaryLanguageModelTests.swift`, `THIRD_PARTY_NOTICES.md`, README data section, `.github/workflows/ios-ci.yml`, `.gitignore` |
| Claude | `Scripts/lm_common.py`, `Scripts/build_lm.py`, `Scripts/test_build_lm.py`, `BinaryDictionary.swift`, `MultilingualEngine.swift`, `TypingSessionController.swift`, the keyboard extension, engine/controller tests |
