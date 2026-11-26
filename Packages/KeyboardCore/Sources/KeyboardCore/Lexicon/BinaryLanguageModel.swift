import Foundation

public enum LMContextToken: Equatable, Sendable {
    case bos
    case word(UInt32)
}

public struct LMNextWordPrediction: Equatable, Sendable {
    public let wordId: UInt32
    public let logProb: Double
    public let matchedOrder: UInt8
}

public struct PreparedLMContext: Sendable {
    public static let empty = PreparedLMContext(
        bigramRange: nil, bigramLogBow: 0, trigramRange: nil, trigramLogBow: 0
    )

    let bigramRange: Range<Int>?
    let bigramLogBow: Double
    let trigramRange: Range<Int>?
    let trigramLogBow: Double

    public var isEmpty: Bool { bigramRange == nil && trigramRange == nil }
}

public enum LanguageModelError: Error, Equatable {
    case invalidHeader
    case unsupportedVersion(UInt16)
    case corrupted
}

/// Reader for the KLAM n-gram format written by Scripts/klm_format.py. See
/// Docs/next-word-prediction-design.md for the byte layout.
public final class BinaryLanguageModel: @unchecked Sendable {
    private static let headerSize = 64
    private static let unigramSize = 8
    private static let bigramSize = 4
    private static let contextSize = 8
    private static let trigramSize = 4
    private static let noBackoff: UInt8 = 0xFF

    private let storage: NSData
    private let bytes: UnsafeRawPointer

    public let vocabCount: Int
    public let vocabFingerprint: UInt64
    public let bigramCount: Int
    public let trigramContextCount: Int
    public let trigramCount: Int
    public let minLogProb: Double
    public let maxLogProb: Double
    private let minLogBow: Double
    private let maxLogBow: Double

    private let unigramsOffset: Int
    private let bigramsOffset: Int
    private let contextsOffset: Int
    private let trigramsOffset: Int

    public convenience init(contentsOf url: URL) throws {
        try self.init(storage: NSData(contentsOf: url, options: [.alwaysMapped]))
    }

    public convenience init(data: Data) throws {
        try self.init(storage: NSData(data: data))
    }

    private init(storage: NSData) throws {
        let length = storage.length
        guard length >= Self.headerSize else { throw LanguageModelError.invalidHeader }
        self.storage = storage
        bytes = storage.bytes
        let reader = ByteReader(storage.bytes)
        guard reader.u32(0) == 0x4D41_4C4B else { throw LanguageModelError.invalidHeader } // "KLAM"
        let version = reader.u16(4)
        guard version == 1 else { throw LanguageModelError.unsupportedVersion(version) }
        guard reader.u16(6) == 0 else { throw LanguageModelError.invalidHeader }

        vocabFingerprint = reader.u64(8)
        vocabCount = Int(reader.u32(16))
        bigramCount = Int(reader.u32(20))
        trigramContextCount = Int(reader.u32(24))
        trigramCount = Int(reader.u32(28))
        unigramsOffset = Int(reader.u32(32))
        bigramsOffset = Int(reader.u32(36))
        contextsOffset = Int(reader.u32(40))
        trigramsOffset = Int(reader.u32(44))
        minLogProb = Double(reader.f32(48))
        maxLogProb = Double(reader.f32(52))
        minLogBow = Double(reader.f32(56))
        maxLogBow = Double(reader.f32(60))

        guard minLogProb.isFinite, maxLogProb.isFinite, minLogProb < maxLogProb,
              minLogBow.isFinite, maxLogBow.isFinite, minLogBow < maxLogBow
        else { throw LanguageModelError.invalidHeader }

        // Offsets are u32 counts times small record sizes, so Int arithmetic cannot overflow.
        guard vocabCount <= 0xFFFE,
              unigramsOffset == Self.headerSize,
              bigramsOffset == unigramsOffset + (vocabCount + 2) * Self.unigramSize,
              contextsOffset == bigramsOffset + bigramCount * Self.bigramSize,
              trigramsOffset == contextsOffset + (trigramContextCount + 1) * Self.contextSize,
              trigramsOffset + trigramCount * Self.trigramSize == length
        else { throw LanguageModelError.corrupted }

        let unigramSentinel = unigramsOffset + (vocabCount + 1) * Self.unigramSize
        let contextSentinel = contextsOffset + trigramContextCount * Self.contextSize
        guard reader.u32(unigramSentinel) == UInt32(bigramCount),
              reader.u8(unigramSentinel + 5) == Self.noBackoff,
              reader.u32(contextSentinel) == UInt32.max,
              reader.u32(contextSentinel + 4) == UInt32(trigramCount)
        else { throw LanguageModelError.corrupted }
    }

    public func prepareContext(prev1: LMContextToken?, prev2: LMContextToken?) -> PreparedLMContext {
        guard let index1 = slot(prev1) else { return .empty }
        let bigramRange = bigramSlice(of: index1)
        let bigramLogBow = bigramRange == nil ? 0 : decodeBow(read.u8(unigramOffset(index1) + 5))

        var trigramRange: Range<Int>?
        var trigramLogBow = 0.0
        if case .word(let word1)? = prev1,
           let index2 = slot(prev2),
           let pairs = bigramSlice(of: index2),
           let pair = findBigram(UInt16(word1), in: pairs),
           case let bowQ = read.u8(bigramOffset(pair) + 3), bowQ != Self.noBackoff,
           let range = trigramSlice(forBigram: pair)
        {
            trigramRange = range
            trigramLogBow = decodeBow(bowQ)
        }

        if bigramRange == nil && trigramRange == nil { return .empty }
        return PreparedLMContext(
            bigramRange: bigramRange,
            bigramLogBow: bigramLogBow,
            trigramRange: trigramRange,
            trigramLogBow: trigramLogBow
        )
    }

    public func unigramLogProbability(of wordId: UInt32) -> Double {
        guard Int(wordId) < vocabCount else { return minLogProb }
        return decodeProb(read.u8(unigramOffset(Int(wordId)) + 4))
    }

    public func logProbability(
        of wordId: UInt32,
        in context: PreparedLMContext
    ) -> (logProb: Double, matchedOrder: UInt8) {
        guard Int(wordId) < vocabCount else { return (minLogProb, 0) }
        let word = UInt16(wordId)
        if let range = context.trigramRange, let index = findTrigram(word, in: range) {
            return (decodeProb(read.u8(trigramOffset(index) + 2)), 3)
        }
        if let range = context.bigramRange, let index = findBigram(word, in: range) {
            return (min(0, context.trigramLogBow + decodeProb(read.u8(bigramOffset(index) + 2))), 2)
        }
        let backedOff = context.trigramLogBow + context.bigramLogBow + unigramLogProbability(of: wordId)
        return (min(0, max(minLogProb - 2, backedOff)), 1)
    }

    /// How much more likely the context makes this word than its plain frequency suggests.
    public func contextLift(of wordId: UInt32, in context: PreparedLMContext) -> Double {
        guard !context.isEmpty, Int(wordId) < vocabCount else { return 0 }
        let lift = logProbability(of: wordId, in: context).logProb - unigramLogProbability(of: wordId)
        return min(2.5, max(-1.5, lift))
    }

    public func topNextWords(in context: PreparedLMContext, limit: Int) -> [LMNextWordPrediction] {
        guard limit > 0, !context.isEmpty else { return [] }
        var results: [LMNextWordPrediction] = []
        results.reserveCapacity(limit + 1)

        func offer(_ candidate: LMNextWordPrediction) {
            if results.count == limit, let worst = results.last, !ranksAbove(candidate, worst) { return }
            let position = results.firstIndex { ranksAbove(candidate, $0) } ?? results.count
            results.insert(candidate, at: position)
            if results.count > limit { results.removeLast() }
        }

        if let range = context.trigramRange {
            for index in range {
                let base = trigramOffset(index)
                offer(LMNextWordPrediction(
                    wordId: UInt32(read.u16(base)),
                    logProb: decodeProb(read.u8(base + 2)),
                    matchedOrder: 3
                ))
            }
        }
        if let range = context.bigramRange {
            for index in range {
                let base = bigramOffset(index)
                let word = read.u16(base)
                let candidate = LMNextWordPrediction(
                    wordId: UInt32(word),
                    logProb: min(0, context.trigramLogBow + decodeProb(read.u8(base + 2))),
                    matchedOrder: 2
                )
                if results.count == limit, let worst = results.last, !ranksAbove(candidate, worst) { continue }
                if let trigrams = context.trigramRange, findTrigram(word, in: trigrams) != nil { continue }
                offer(candidate)
            }
        }
        return results
    }

    // MARK: - Lookup

    private var read: ByteReader { ByteReader(bytes) }

    private func slot(_ token: LMContextToken?) -> Int? {
        switch token {
        case .bos: return vocabCount
        case .word(let id) where Int(id) < vocabCount: return Int(id)
        default: return nil
        }
    }

    private func unigramOffset(_ index: Int) -> Int { unigramsOffset + index * Self.unigramSize }
    private func bigramOffset(_ index: Int) -> Int { bigramsOffset + index * Self.bigramSize }
    private func trigramOffset(_ index: Int) -> Int { trigramsOffset + index * Self.trigramSize }

    private func bigramSlice(of slot: Int) -> Range<Int>? {
        let start = Int(read.u32(unigramOffset(slot)))
        let end = Int(read.u32(unigramOffset(slot + 1)))
        return start < end && end <= bigramCount ? start..<end : nil
    }

    private func trigramSlice(forBigram bigramIndex: Int) -> Range<Int>? {
        let target = UInt32(bigramIndex)
        guard let context = binarySearch(0..<trigramContextCount, for: target, key: {
            self.read.u32(self.contextsOffset + $0 * Self.contextSize)
        }) else { return nil }
        let base = contextsOffset + context * Self.contextSize
        let start = Int(read.u32(base + 4))
        let end = Int(read.u32(base + Self.contextSize + 4))
        return start < end && end <= trigramCount ? start..<end : nil
    }

    private func findBigram(_ word: UInt16, in range: Range<Int>) -> Int? {
        binarySearch(range, for: word) { self.read.u16(self.bigramOffset($0)) }
    }

    private func findTrigram(_ word: UInt16, in range: Range<Int>) -> Int? {
        binarySearch(range, for: word) { self.read.u16(self.trigramOffset($0)) }
    }

    private func binarySearch<T: Comparable>(_ range: Range<Int>, for target: T, key: (Int) -> T) -> Int? {
        var low = range.lowerBound
        var high = range.upperBound
        while low < high {
            let middle = (low + high) / 2
            let value = key(middle)
            if value == target { return middle }
            if value < target { low = middle + 1 } else { high = middle }
        }
        return nil
    }

    private func ranksAbove(_ left: LMNextWordPrediction, _ right: LMNextWordPrediction) -> Bool {
        if left.logProb != right.logProb { return left.logProb > right.logProb }
        if left.matchedOrder != right.matchedOrder { return left.matchedOrder > right.matchedOrder }
        return left.wordId < right.wordId
    }

    private func decodeProb(_ q: UInt8) -> Double {
        minLogProb + Double(q) / 255 * (maxLogProb - minLogProb)
    }

    private func decodeBow(_ q: UInt8) -> Double {
        q == Self.noBackoff ? 0 : minLogBow + Double(q) / 254 * (maxLogBow - minLogBow)
    }
}

private struct ByteReader {
    let bytes: UnsafeRawPointer

    init(_ bytes: UnsafeRawPointer) { self.bytes = bytes }

    func u8(_ offset: Int) -> UInt8 { bytes.load(fromByteOffset: offset, as: UInt8.self) }
    func u16(_ offset: Int) -> UInt16 { UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) }
    func u32(_ offset: Int) -> UInt32 { UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    func u64(_ offset: Int) -> UInt64 { UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
    func f32(_ offset: Int) -> Float32 { Float32(bitPattern: u32(offset)) }
}

// MARK: - In-memory builder for tests

extension BinaryLanguageModel {
    public static func buildInMemory(
        vocabCount: Int,
        vocabFingerprint: UInt64,
        unigrams: [(logProb: Double, logBow: Double?)],
        bigrams: [(context: LMContextToken, next: UInt32, logProb: Double, trigramLogBow: Double?)],
        trigrams: [(prev2: LMContextToken, prev1: UInt32, next: UInt32, logProb: Double)]
    ) throws -> BinaryLanguageModel {
        try BinaryLanguageModel(data: serialize(
            vocabCount: vocabCount,
            vocabFingerprint: vocabFingerprint,
            unigrams: unigrams,
            bigrams: bigrams,
            trigrams: trigrams
        ))
    }

    static func serialize(
        vocabCount: Int,
        vocabFingerprint: UInt64,
        unigrams: [(logProb: Double, logBow: Double?)],
        bigrams: [(context: LMContextToken, next: UInt32, logProb: Double, trigramLogBow: Double?)],
        trigrams: [(prev2: LMContextToken, prev1: UInt32, next: UInt32, logProb: Double)]
    ) throws -> Data {
        guard (0...0xFFFE).contains(vocabCount), unigrams.count == vocabCount + 1 else {
            throw LanguageModelError.corrupted
        }
        let (minProb, maxProb, minBow, maxBow): (Float32, Float32, Float32, Float32) = (-8, 0, -6, 2)
        func slot(_ token: LMContextToken) -> Int {
            if case .word(let id) = token { return Int(id) }
            return vocabCount
        }
        func prob(_ value: Double) -> UInt8 {
            UInt8(min(255, max(0, ((value - Double(minProb)) / Double(maxProb - minProb) * 255).rounded())))
        }
        func bow(_ value: Double?) -> UInt8 {
            guard let value else { return noBackoff }
            return UInt8(min(254, max(0, ((value - Double(minBow)) / Double(maxBow - minBow) * 254).rounded())))
        }

        struct Pair: Hashable { let context: Int; let word: UInt32 }
        var trigramsByPair: [Pair: [(word: UInt32, logProb: Double)]] = [:]
        for trigram in trigrams {
            trigramsByPair[Pair(context: slot(trigram.prev2), word: trigram.prev1), default: []]
                .append((trigram.next, trigram.logProb))
        }
        var bigramsBySlot = [[(word: UInt32, logProb: Double, trigramLogBow: Double?)]](repeating: [], count: vocabCount + 1)
        for bigram in bigrams {
            bigramsBySlot[slot(bigram.context)].append((bigram.next, bigram.logProb, bigram.trigramLogBow))
        }

        var unigramTable = Data()
        var bigramTable = Data()
        var contexts: [(bigramIndex: Int, trigrams: [(word: UInt32, logProb: Double)])] = []
        var bigramIndex = 0
        for slotIndex in 0...vocabCount {
            unigramTable.appendLE(UInt32(bigramIndex))
            unigramTable.append(slotIndex == vocabCount ? 0 : prob(unigrams[slotIndex].logProb))
            unigramTable.append(bow(unigrams[slotIndex].logBow))
            unigramTable.appendLE(UInt16(0))
            for bigram in bigramsBySlot[slotIndex].sorted(by: { $0.word < $1.word }) {
                let children = trigramsByPair[Pair(context: slotIndex, word: bigram.word)]?
                    .sorted { $0.word < $1.word }
                bigramTable.appendLE(UInt16(bigram.word))
                bigramTable.append(prob(bigram.logProb))
                bigramTable.append(children == nil ? noBackoff : bow(bigram.trigramLogBow ?? 0))
                if let children { contexts.append((bigramIndex, children)) }
                bigramIndex += 1
            }
        }
        unigramTable.appendLE(UInt32(bigramIndex))
        unigramTable.append(contentsOf: [0, noBackoff, 0, 0])

        var contextTable = Data()
        var trigramTable = Data()
        var trigramIndex = 0
        for context in contexts {
            contextTable.appendLE(UInt32(context.bigramIndex))
            contextTable.appendLE(UInt32(trigramIndex))
            for trigram in context.trigrams {
                trigramTable.appendLE(UInt16(trigram.word))
                trigramTable.append(contentsOf: [prob(trigram.logProb), 0])
                trigramIndex += 1
            }
        }
        contextTable.appendLE(UInt32.max)
        contextTable.appendLE(UInt32(trigramIndex))

        let unigramsOffset = headerSize
        let bigramsOffset = unigramsOffset + unigramTable.count
        let contextsOffset = bigramsOffset + bigramTable.count
        let trigramsOffset = contextsOffset + contextTable.count

        var data = Data("KLAM".utf8)
        data.appendLE(UInt16(1))
        data.appendLE(UInt16(0))
        data.appendLE(vocabFingerprint)
        for value in [vocabCount, bigramIndex, contexts.count, trigramIndex,
                      unigramsOffset, bigramsOffset, contextsOffset, trigramsOffset] {
            data.appendLE(UInt32(value))
        }
        for value in [minProb, maxProb, minBow, maxBow] {
            data.appendLE(value.bitPattern)
        }
        data.append(unigramTable)
        data.append(bigramTable)
        data.append(contextTable)
        data.append(trigramTable)
        return data
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
