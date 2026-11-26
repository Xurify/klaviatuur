import Foundation

public struct DictionaryWordMatch: Equatable, Sendable {
    public let wordId: UInt32
    public let word: String
    public let frequencyScore: UInt16

    public init(wordId: UInt32, word: String, frequencyScore: UInt16) {
        self.wordId = wordId
        self.word = word
        self.frequencyScore = frequencyScore
    }
}

public struct FuzzyWordMatch: Equatable, Sendable {
    public let wordId: UInt32
    public let word: String
    public let frequencyScore: UInt16
    public let editCost: Double

    public init(wordId: UInt32, word: String, frequencyScore: UInt16, editCost: Double) {
        self.wordId = wordId
        self.word = word
        self.frequencyScore = frequencyScore
        self.editCost = editCost
    }
}

public enum BinaryDictionaryError: Error, Equatable {
    case truncatedHeader
    case invalidMagic
    case unsupportedVersion(UInt16)
    case corruptedOffsets
}

public final class BinaryDictionary: @unchecked Sendable {
    private static let magicBytes: [UInt8] = [0x4B, 0x4C, 0x41, 0x44] // "KLAD"
    private static let supportedVersion: UInt16 = 1
    private static let headerSize = 56
    private static let wordRecordSize = 8
    private static let nodeRecordSize = 16
    private static let edgeRecordSize = 8

    // NSData's bytes stay put for the object's lifetime, so lookups can read through one raw
    // pointer instead of paying Data's per-byte subscript cost on every trie step.
    private let storage: NSData
    private let bytes: UnsafeRawPointer
    public let wordCount: Int
    public let nodeCount: Int
    public let edgeCount: Int
    public let wordIdListCount: Int

    private let wordsOffset: Int
    private let nodesOffset: Int
    private let edgesOffset: Int
    private let wordIdsOffset: Int
    private let stringsOffset: Int
    private let stringsLength: Int

    public convenience init(contentsOf url: URL) throws {
        let mapped = try NSData(contentsOf: url, options: [.alwaysMapped])
        try self.init(storage: mapped)
    }

    public convenience init(data: Data) throws {
        try self.init(storage: NSData(data: data))
    }

    private init(storage: NSData) throws {
        guard storage.length >= Self.headerSize else {
            throw BinaryDictionaryError.truncatedHeader
        }
        let data = Data(
            bytesNoCopy: UnsafeMutableRawPointer(mutating: storage.bytes),
            count: storage.length,
            deallocator: .none
        )
        guard data.count >= Self.headerSize else {
            throw BinaryDictionaryError.truncatedHeader
        }
        guard data[0] == Self.magicBytes[0],
              data[1] == Self.magicBytes[1],
              data[2] == Self.magicBytes[2],
              data[3] == Self.magicBytes[3]
        else {
            throw BinaryDictionaryError.invalidMagic
        }

        let version = Self.readUInt16(in: data, at: 4)
        guard version == Self.supportedVersion else {
            throw BinaryDictionaryError.unsupportedVersion(version)
        }

        self.storage = storage
        self.bytes = storage.bytes
        self.wordCount = Int(Self.readUInt32(in: data, at: 8))
        self.nodeCount = Int(Self.readUInt32(in: data, at: 12))
        self.edgeCount = Int(Self.readUInt32(in: data, at: 16))
        self.wordIdListCount = Int(Self.readUInt32(in: data, at: 20))
        self.wordsOffset = Int(Self.readUInt32(in: data, at: 28))
        self.nodesOffset = Int(Self.readUInt32(in: data, at: 32))
        self.edgesOffset = Int(Self.readUInt32(in: data, at: 36))
        self.wordIdsOffset = Int(Self.readUInt32(in: data, at: 40))
        self.stringsOffset = Int(Self.readUInt32(in: data, at: 44))
        self.stringsLength = Int(Self.readUInt32(in: data, at: 52))

        // The format still reserves a word-pair table after the strings; next-word data now
        // lives in the .klm language model, so it is always empty and never read.
        let pairTableOffset = Int(Self.readUInt32(in: data, at: 48))
        let pairTableEnd = pairTableOffset + Int(Self.readUInt32(in: data, at: 24)) * 12
        guard wordsOffset >= Self.headerSize,
              nodesOffset >= wordsOffset + wordCount * Self.wordRecordSize,
              edgesOffset >= nodesOffset + nodeCount * Self.nodeRecordSize,
              wordIdsOffset >= edgesOffset + edgeCount * Self.edgeRecordSize,
              stringsOffset >= wordIdsOffset + wordIdListCount * 4,
              stringsOffset + stringsLength <= pairTableOffset,
              pairTableEnd <= data.count
        else {
            throw BinaryDictionaryError.corruptedOffsets
        }
    }

    public func exactMatches(for word: String) -> [DictionaryWordMatch] {
        let scalars = DiacriticFolding.foldedScalars(word)
        guard let nodeIndex = findNode(for: scalars) else {
            return []
        }
        return wordsAtNode(nodeIndex)
    }

    public func word(at wordId: UInt32) -> DictionaryWordMatch? {
        readWord(at: Int(wordId))
    }

    /// The id a committed word is looked up under in the language model. The exact lowercase
    /// spelling wins, so "все" and "всё" keep separate contexts; otherwise the most frequent
    /// diacritic-folded match, so an unaccented "dakujem" still resolves to "ďakujem".
    public func exactWordId(for word: String) -> UInt32? {
        let matches = exactMatches(for: word)
        let lowered = DiacriticFolding.normalizingApostrophes(word.lowercased())
        return (matches.first { $0.word == lowered } ?? matches.first)?.wordId
    }

    /// Must match `vocab_fingerprint` in Scripts/lm_common.py byte for byte.
    public func vocabFingerprint() -> UInt64 {
        var state: UInt64 = 0xcbf2_9ce4_8422_2325
        func feed(_ byte: UInt8) {
            state = (state ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        withUnsafeBytes(of: UInt32(wordCount).littleEndian) { $0.forEach(feed) }
        let stringsEnd = stringsOffset + stringsLength
        for index in 0..<wordCount {
            let base = wordsOffset + index * Self.wordRecordSize
            let start = stringsOffset + Int(u32(base))
            let end = min(start + Int(u16(base + 4)), stringsEnd)
            for offset in start..<max(start, end) {
                feed(bytes.load(fromByteOffset: offset, as: UInt8.self))
            }
            feed(0)
        }
        return state
    }

    public func nextCharacterScores(forPrefix prefix: String) -> [UInt32: UInt16] {
        let scalars = DiacriticFolding.foldedScalars(prefix)
        guard let nodeIndex = findNode(for: scalars) else {
            return [:]
        }
        let node = readNode(at: nodeIndex)
        guard node.edgeCount > 0 else { return [:] }

        var scores: [UInt32: UInt16] = [:]
        scores.reserveCapacity(Int(node.edgeCount))
        let start = Int(node.edgeStart)
        let end = start + Int(node.edgeCount)
        for edgeIndex in start..<end {
            let edge = readEdge(at: edgeIndex)
            let targetNode = readNode(at: Int(edge.targetNode))
            scores[edge.scalar] = targetNode.maxSubtreeScore
        }
        return scores
    }

    public func prefixCompletions(forPrefix prefix: String, limit: Int = 5) -> [DictionaryWordMatch] {
        guard limit > 0 else { return [] }
        let scalars = DiacriticFolding.foldedScalars(prefix)
        guard let startNodeIndex = findNode(for: scalars) else {
            return []
        }

        // Best-first exploration ordered by node.maxSubtreeScore
        var frontier: [(nodeIndex: Int, maxScore: UInt16)] = [
            (startNodeIndex, readNode(at: startNodeIndex).maxSubtreeScore)
        ]
        var results: [DictionaryWordMatch] = []
        var visitedNodes = 0
        let maxVisitedNodes = 220

        while !frontier.isEmpty && visitedNodes < maxVisitedNodes {
            var bestFrontierIndex = 0
            for index in 1..<frontier.count where frontier[index].maxScore > frontier[bestFrontierIndex].maxScore {
                bestFrontierIndex = index
            }
            let current = frontier.remove(at: bestFrontierIndex)
            visitedNodes += 1

            if results.count >= limit,
               let worstResult = results.last,
               current.maxScore < worstResult.frequencyScore
            {
                break
            }

            let node = readNode(at: current.nodeIndex)
            if node.wordCountAtNode > 0 {
                let matches = wordsAtNode(current.nodeIndex)
                for match in matches {
                    insertRankedMatch(match, into: &results, limit: limit)
                }
            }

            let edgeStart = Int(node.edgeStart)
            let edgeEnd = edgeStart + Int(node.edgeCount)
            for edgeIndex in edgeStart..<edgeEnd {
                let edge = readEdge(at: edgeIndex)
                let childIndex = Int(edge.targetNode)
                let childScore = readNode(at: childIndex).maxSubtreeScore
                if results.count >= limit,
                   let worstResult = results.last,
                   childScore < worstResult.frequencyScore
                {
                    continue
                }
                frontier.append((childIndex, childScore))
            }
        }

        return results
    }

    public func fuzzyMatches(
        for typedWord: String,
        maxEditCost: Double = 1.65,
        substitutionCost: (UInt32, UInt32) -> Double,
        limit: Int = 6
    ) -> [FuzzyWordMatch] {
        guard nodeCount > 0, limit > 0 else { return [] }
        let query = DiacriticFolding.foldedScalars(typedWord)
        guard !query.isEmpty else { return [] }

        let queryLength = query.count
        var initialRow = [Double](repeating: 0, count: queryLength + 1)
        for index in 0...queryLength {
            initialRow[index] = Double(index)
        }

        var collected: [FuzzyWordMatch] = []
        var visitedNodes = 0
        let maxVisitedNodes = 900

        // Depth-first search only ever needs the rows on the current path, so one table with a
        // row per depth replaces allocating a fresh row for every edge visited.
        let rowWidth = queryLength + 1
        let maxDepth = queryLength + 2
        var table = [Double](repeating: 0, count: rowWidth * (maxDepth + 2))
        for index in 0...queryLength {
            table[index] = initialRow[index]
        }

        func traverse(nodeIndex: Int, previousScalar: UInt32?, depth: Int) {
            if visitedNodes >= maxVisitedNodes { return }
            visitedNodes += 1

            let current = depth * rowWidth
            let previous = (depth - 1) * rowWidth
            let next = (depth + 1) * rowWidth

            let node = readNode(at: nodeIndex)
            let terminalCost = table[current + queryLength]
            if node.wordCountAtNode > 0 && terminalCost <= maxEditCost {
                for match in wordsAtNode(nodeIndex) {
                    collected.append(
                        FuzzyWordMatch(
                            wordId: match.wordId,
                            word: match.word,
                            frequencyScore: match.frequencyScore,
                            editCost: terminalCost
                        )
                    )
                }
            }

            if depth >= maxDepth { return }
            let edgeStart = Int(node.edgeStart)
            let edgeEnd = edgeStart + Int(node.edgeCount)

            for edgeIndex in edgeStart..<edgeEnd {
                let edge = readEdge(at: edgeIndex)
                let edgeScalar = edge.scalar
                table[next] = table[current] + 1.0
                var rowMinimum = table[next]

                for column in 1...queryLength {
                    let queryScalar = query[column - 1]
                    let deleteCost = table[current + column] + 1.0
                    let insertCost = table[next + column - 1] + 1.0
                    let replacePenalty = edgeScalar == queryScalar
                        ? 0.0
                        : substitutionCost(queryScalar, edgeScalar)
                    let replaceCost = table[current + column - 1] + replacePenalty

                    var best = min(deleteCost, min(insertCost, replaceCost))

                    // Adjacent transposition (Damerau-Levenshtein)
                    if column > 1,
                       depth > 0,
                       let previousScalar,
                       queryScalar == previousScalar,
                       query[column - 2] == edgeScalar
                    {
                        let transposeCost = table[previous + column - 2] + 0.55
                        if transposeCost < best {
                            best = transposeCost
                        }
                    }

                    table[next + column] = best
                    if best < rowMinimum {
                        rowMinimum = best
                    }
                }

                if rowMinimum <= maxEditCost {
                    traverse(
                        nodeIndex: Int(edge.targetNode),
                        previousScalar: edgeScalar,
                        depth: depth + 1
                    )
                }
            }
        }

        traverse(nodeIndex: 0, previousScalar: nil, depth: 0)

        // Costs within one 0.05 bucket tie on frequency; buckets keep the ordering transitive.
        func bucket(_ cost: Double) -> Int { Int((cost * 20).rounded()) }
        collected.sort { left, right in
            if bucket(left.editCost) != bucket(right.editCost) {
                return bucket(left.editCost) < bucket(right.editCost)
            }
            return left.frequencyScore > right.frequencyScore
        }

        var unique: [FuzzyWordMatch] = []
        var seen: Set<String> = []
        for candidate in collected {
            if seen.insert(candidate.word).inserted {
                unique.append(candidate)
                if unique.count >= limit {
                    break
                }
            }
        }
        return unique
    }

    // MARK: - In-memory builder for tests

    public static func buildInMemory(words: [(word: String, score: UInt16)]) throws -> BinaryDictionary {
        final class BuilderNode {
            var children: [UInt32: BuilderNode] = [:]
            var wordIds: [UInt32] = []
            var maxSubtreeScore: UInt16 = 0
        }

        let sortedWords = words.sorted { left, right in
            if left.score != right.score {
                return left.score > right.score
            }
            return left.word < right.word
        }

        var stringsBlob = Data()
        var wordsTable = Data()
        let root = BuilderNode()

        for (index, item) in sortedWords.enumerated() {
            let wordId = UInt32(index)

            let utf8 = Data(item.word.utf8)
            appendUInt32(UInt32(stringsBlob.count), to: &wordsTable)
            appendUInt16(UInt16(utf8.count), to: &wordsTable)
            appendUInt16(item.score, to: &wordsTable)
            stringsBlob.append(utf8)

            var current = root
            if item.score > current.maxSubtreeScore {
                current.maxSubtreeScore = item.score
            }
            for scalar in DiacriticFolding.foldedScalars(item.word) {
                let child: BuilderNode
                if let existing = current.children[scalar] {
                    child = existing
                } else {
                    child = BuilderNode()
                    current.children[scalar] = child
                }
                current = child
                if item.score > current.maxSubtreeScore {
                    current.maxSubtreeScore = item.score
                }
            }
            current.wordIds.append(wordId)
        }

        var flatNodes: [BuilderNode] = [root]
        var nodeIndices: [ObjectIdentifier: UInt32] = [ObjectIdentifier(root): 0]
        var cursor = 0
        while cursor < flatNodes.count {
            let current = flatNodes[cursor]
            cursor += 1
            for scalar in current.children.keys.sorted() {
                let child = current.children[scalar]!
                nodeIndices[ObjectIdentifier(child)] = UInt32(flatNodes.count)
                flatNodes.append(child)
            }
        }

        var nodesTable = Data()
        var edgesTable = Data()
        var wordIdsTable = Data()
        var totalEdges: UInt32 = 0
        var totalWordIds: UInt32 = 0

        for node in flatNodes {
            let edgeStart = totalEdges
            let sortedScalars = node.children.keys.sorted()
            for scalar in sortedScalars {
                let targetIndex = nodeIndices[ObjectIdentifier(node.children[scalar]!)]!
                appendUInt32(scalar, to: &edgesTable)
                appendUInt32(targetIndex, to: &edgesTable)
            }
            totalEdges += UInt32(sortedScalars.count)

            let wordListOffset = totalWordIds
            for wordId in node.wordIds {
                appendUInt32(wordId, to: &wordIdsTable)
            }
            totalWordIds += UInt32(node.wordIds.count)

            appendUInt32(edgeStart, to: &nodesTable)
            appendUInt16(UInt16(sortedScalars.count), to: &nodesTable)
            appendUInt16(UInt16(node.wordIds.count), to: &nodesTable)
            appendUInt32(wordListOffset, to: &nodesTable)
            appendUInt16(node.maxSubtreeScore, to: &nodesTable)
            appendUInt16(0, to: &nodesTable)
        }

        let stringsPadding = (4 - (stringsBlob.count % 4)) % 4

        let wordsOffset = UInt32(headerSize)
        let nodesOffset = wordsOffset + UInt32(wordsTable.count)
        let edgesOffset = nodesOffset + UInt32(nodesTable.count)
        let wordIdsOffset = edgesOffset + UInt32(edgesTable.count)
        let stringsOffset = wordIdsOffset + UInt32(wordIdsTable.count)
        let pairTableOffset = stringsOffset + UInt32(stringsBlob.count + stringsPadding)

        var binary = Data()
        binary.append(contentsOf: magicBytes)
        appendUInt16(supportedVersion, to: &binary)
        appendUInt16(0, to: &binary)
        appendUInt32(UInt32(sortedWords.count), to: &binary)
        appendUInt32(UInt32(flatNodes.count), to: &binary)
        appendUInt32(totalEdges, to: &binary)
        appendUInt32(totalWordIds, to: &binary)
        appendUInt32(0, to: &binary)
        appendUInt32(wordsOffset, to: &binary)
        appendUInt32(nodesOffset, to: &binary)
        appendUInt32(edgesOffset, to: &binary)
        appendUInt32(wordIdsOffset, to: &binary)
        appendUInt32(stringsOffset, to: &binary)
        appendUInt32(pairTableOffset, to: &binary)
        appendUInt32(UInt32(stringsBlob.count), to: &binary)

        binary.append(wordsTable)
        binary.append(nodesTable)
        binary.append(edgesTable)
        binary.append(wordIdsTable)
        binary.append(stringsBlob)
        if stringsPadding > 0 {
            binary.append(Data(repeating: 0, count: stringsPadding))
        }

        return try BinaryDictionary(data: binary)
    }

    // MARK: - Low-Level Binary Readers

    private struct TrieNodeRecord {
        let edgeStart: UInt32
        let edgeCount: UInt16
        let wordCountAtNode: UInt16
        let wordListOffset: UInt32
        let maxSubtreeScore: UInt16
    }

    private struct TrieEdgeRecord {
        let scalar: UInt32
        let targetNode: UInt32
    }

    private func findNode(for scalars: [UInt32]) -> Int? {
        guard nodeCount > 0 else { return nil }
        var currentIndex = 0
        for scalar in scalars {
            let node = readNode(at: currentIndex)
            guard let target = binarySearchEdge(
                edgeStart: Int(node.edgeStart),
                edgeCount: Int(node.edgeCount),
                scalar: scalar
            ) else {
                return nil
            }
            currentIndex = Int(target)
        }
        return currentIndex
    }

    private func binarySearchEdge(edgeStart: Int, edgeCount: Int, scalar: UInt32) -> UInt32? {
        var low = edgeStart
        var high = edgeStart + edgeCount - 1
        while low <= high {
            let middle = (low + high) / 2
            let edge = readEdge(at: middle)
            if edge.scalar == scalar {
                return edge.targetNode
            } else if edge.scalar < scalar {
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return nil
    }

    private func wordsAtNode(_ nodeIndex: Int) -> [DictionaryWordMatch] {
        let node = readNode(at: nodeIndex)
        guard node.wordCountAtNode > 0 else { return [] }
        var matches: [DictionaryWordMatch] = []
        matches.reserveCapacity(Int(node.wordCountAtNode))
        let start = Int(node.wordListOffset)
        let end = start + Int(node.wordCountAtNode)
        for index in start..<end {
            let wordId = u32(wordIdsOffset + index * 4)
            if let match = readWord(at: Int(wordId)) {
                matches.append(match)
            }
        }
        return matches
    }

    private func readWord(at wordIndex: Int) -> DictionaryWordMatch? {
        guard wordIndex >= 0, wordIndex < wordCount else { return nil }
        let base = wordsOffset + wordIndex * Self.wordRecordSize
        let utf8Offset = Int(u32(base))
        let utf8Length = Int(u16(base + 4))
        let frequencyScore = u16(base + 6)
        let start = stringsOffset + utf8Offset
        let end = start + utf8Length
        guard end <= stringsOffset + stringsLength else { return nil }
        let word = String(
            decoding: UnsafeRawBufferPointer(start: bytes + start, count: utf8Length),
            as: UTF8.self
        )
        return DictionaryWordMatch(
            wordId: UInt32(wordIndex),
            word: word,
            frequencyScore: frequencyScore
        )
    }

    private func readNode(at nodeIndex: Int) -> TrieNodeRecord {
        let base = nodesOffset + nodeIndex * Self.nodeRecordSize
        return TrieNodeRecord(
            edgeStart: u32(base),
            edgeCount: u16(base + 4),
            wordCountAtNode: u16(base + 6),
            wordListOffset: u32(base + 8),
            maxSubtreeScore: u16(base + 12)
        )
    }

    private func readEdge(at edgeIndex: Int) -> TrieEdgeRecord {
        let base = edgesOffset + edgeIndex * Self.edgeRecordSize
        return TrieEdgeRecord(
            scalar: u32(base),
            targetNode: u32(base + 4)
        )
    }

    private func insertRankedMatch(
        _ match: DictionaryWordMatch,
        into results: inout [DictionaryWordMatch],
        limit: Int
    ) {
        if let existingIndex = results.firstIndex(where: { $0.word == match.word }) {
            if match.frequencyScore > results[existingIndex].frequencyScore {
                results.remove(at: existingIndex)
            } else {
                return
            }
        }
        let insertionIndex = results.firstIndex { $0.frequencyScore < match.frequencyScore } ?? results.count
        if insertionIndex < limit {
            results.insert(match, at: insertionIndex)
            if results.count > limit {
                results.removeLast()
            }
        }
    }

    @inline(__always)
    private func u16(_ offset: Int) -> UInt16 {
        UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }

    @inline(__always)
    private func u32(_ offset: Int) -> UInt32 {
        UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    private static func readUInt16(in data: Data, at offset: Int) -> UInt16 {
        let low = UInt16(data[offset])
        let high = UInt16(data[offset + 1]) << 8
        return low | high
    }

    private static func readUInt32(in data: Data, at offset: Int) -> UInt32 {
        let byte0 = UInt32(data[offset])
        let byte1 = UInt32(data[offset + 1]) << 8
        let byte2 = UInt32(data[offset + 2]) << 16
        let byte3 = UInt32(data[offset + 3]) << 24
        return byte0 | byte1 | byte2 | byte3
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }
}
