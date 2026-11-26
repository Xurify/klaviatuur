import XCTest
@testable import KeyboardCore

final class BinaryLanguageModelTests: XCTestCase {
    // Same model as Scripts/test_klm_format.py.
    // 0 "i", 1 "want", 2 "to", 3 "of", 4 "you", 5 "thank", 6 <BOS>
    private static let unigrams: [(logProb: Double, logBow: Double?)] = [
        (-1.2, -0.3), (-2.0, -0.4), (-1.5, nil), (-1.6, nil), (-1.8, nil), (-2.4, -0.5), (0, -0.2)
    ]
    private static let bigrams: [(context: LMContextToken, next: UInt32, logProb: Double, trigramLogBow: Double?)] = [
        (.bos, 5, -1.1, -0.35),
        (.bos, 0, -0.6, -0.25),
        (.word(0), 1, -0.8, 0.45),
        (.word(0), 5, -2.2, nil),
        (.word(1), 3, -1.4, nil),
        (.word(1), 2, -0.5, nil),
        (.word(1), 4, -0.9, nil),
        (.word(5), 4, -0.2, nil)
    ]
    private static let trigrams: [(prev2: LMContextToken, prev1: UInt32, next: UInt32, logProb: Double)] = [
        (.bos, 0, 5, -1.9),
        (.bos, 0, 1, -0.4),
        (.bos, 5, 4, -0.15),
        (.word(0), 1, 2, -0.3)
    ]

    private func sampleData() throws -> Data {
        try BinaryLanguageModel.serialize(
            vocabCount: 6, vocabFingerprint: 0x0123_4567_89AB_CDEF,
            unigrams: Self.unigrams, bigrams: Self.bigrams, trigrams: Self.trigrams
        )
    }

    private func sampleModel() throws -> BinaryLanguageModel {
        try BinaryLanguageModel(data: sampleData())
    }

    private var halfStep: Double { 8.0 / 255 / 2 + 1e-6 }

    func testSerializerMatchesPythonWriterByteForByte() throws {
        // Output of klm_format.serialize_klm for the same model (Scripts/test_klm_format.py).
        let python = """
        4b4c414d01000000efcdab8967452301060000000800000003000000040000004000000080000000a0000000c0000000\
        000000c1000000000000c0c00000004000000000d9b5000002000000bfb2000005000000cfff000005000000ccff0000\
        05000000c6ff000005000000b3af00000600000000b800000800000000ff00000100e6cd0500b9ff0200efff0300d2ff\
        0400e2ff0400f9ff0000ecb70500dcb3000000000000000006000000010000000700000003000000ffffffff04000000\
        0200f5000100f2000500c2000400fa00
        """
        let swift = try sampleData().map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(swift, python)
    }

    func testLookupsAtEveryOrder() throws {
        let model = try sampleModel()
        XCTAssertEqual(model.vocabFingerprint, 0x0123_4567_89AB_CDEF)
        XCTAssertEqual([model.bigramCount, model.trigramContextCount, model.trigramCount], [8, 3, 4])
        for (id, expected) in [-1.2, -2.0, -1.5, -1.6, -1.8, -2.4].enumerated() {
            XCTAssertEqual(model.unigramLogProbability(of: UInt32(id)), expected, accuracy: halfStep)
        }

        let iWant = model.prepareContext(prev1: .word(1), prev2: .word(0))
        XCTAssertEqual(model.logProbability(of: 2, in: iWant).matchedOrder, 3)
        XCTAssertEqual(model.logProbability(of: 2, in: iWant).logProb, -0.3, accuracy: halfStep)

        let thank = model.prepareContext(prev1: .word(5), prev2: nil)
        XCTAssertEqual(model.logProbability(of: 4, in: thank).logProb, -0.2, accuracy: halfStep)
        XCTAssertEqual(model.contextLift(of: 4, in: thank), 1.6, accuracy: 0.05)

        let start = model.prepareContext(prev1: .bos, prev2: nil)
        XCTAssertEqual(model.topNextWords(in: start, limit: 5).map(\.wordId), [0, 5])

        let startI = model.prepareContext(prev1: .word(0), prev2: .bos)
        XCTAssertEqual(model.logProbability(of: 1, in: startI).logProb, -0.4, accuracy: halfStep)
        let startThank = model.prepareContext(prev1: .word(5), prev2: .bos)
        XCTAssertEqual(model.logProbability(of: 4, in: startThank).logProb, -0.15, accuracy: halfStep)
    }

    func testBackoffChain() throws {
        let model = try sampleModel()
        let iWant = model.prepareContext(prev1: .word(1), prev2: .word(0))
        XCTAssertGreaterThan(iWant.trigramLogBow, 0.4)
        XCTAssertEqual(model.logProbability(of: 4, in: iWant).matchedOrder, 2)

        let toUnigram = model.logProbability(of: 0, in: iWant)
        XCTAssertEqual(toUnigram.matchedOrder, 1)
        XCTAssertEqual(
            toUnigram.logProb,
            iWant.trigramLogBow + iWant.bigramLogBow + model.unigramLogProbability(of: 0),
            accuracy: 1e-9
        )

        let iThank = model.prepareContext(prev1: .word(5), prev2: .word(0))
        XCTAssertNil(iThank.trigramRange)
        XCTAssertEqual(iThank.trigramLogBow, 0)

        XCTAssertEqual(model.logProbability(of: 99, in: iWant).matchedOrder, 0)
        XCTAssertEqual(model.contextLift(of: 99, in: iWant), 0)
        let unknown = model.prepareContext(prev1: .word(99), prev2: .word(0))
        XCTAssertTrue(unknown.isEmpty)
        XCTAssertTrue(model.topNextWords(in: unknown, limit: 3).isEmpty)
    }

    func testBigramProbabilityIsCappedAtCertainty() throws {
        let model = try BinaryLanguageModel.buildInMemory(
            vocabCount: 3, vocabFingerprint: 1,
            unigrams: [(-1, -0.1), (-1, -0.1), (-1, nil), (0, nil)],
            bigrams: [(.word(0), 1, -0.2, 1.5), (.word(1), 0, -0.1, nil), (.word(1), 2, -0.5, nil)],
            trigrams: [(.word(0), 1, 2, -0.3)]
        )
        let context = model.prepareContext(prev1: .word(1), prev2: .word(0))
        XCTAssertEqual(model.logProbability(of: 0, in: context).logProb, 0)
    }

    func testTopNextWordsSkipsBigramsAlreadyScoredAsTrigrams() throws {
        let model = try sampleModel()
        let iWant = model.prepareContext(prev1: .word(1), prev2: .word(0))
        let predictions = model.topNextWords(in: iWant, limit: 5)
        XCTAssertEqual(predictions.map(\.wordId), [2, 4, 3])
        XCTAssertEqual(predictions.map(\.matchedOrder), [3, 2, 2])
        XCTAssertTrue(model.topNextWords(in: .empty, limit: 3).isEmpty)

        let lowTrigram = try BinaryLanguageModel.buildInMemory(
            vocabCount: 4, vocabFingerprint: 2,
            unigrams: [(-1, -0.1), (-1, -0.1), (-1, nil), (-1, nil), (0, nil)],
            bigrams: [(.word(0), 1, -0.2, 1.0), (.word(1), 2, -0.2, nil), (.word(1), 3, -0.8, nil)],
            trigrams: [(.word(0), 1, 2, -3.0), (.word(0), 1, 3, -0.5)]
        )
        let context = lowTrigram.prepareContext(prev1: .word(1), prev2: .word(0))
        XCTAssertEqual(lowTrigram.topNextWords(in: context, limit: 1).map(\.wordId), [3])
    }

    func testLoaderRejectsCorruptFiles() throws {
        let valid = try sampleData()
        func corrupt(_ offset: Int, _ bytes: [UInt8]) -> Data {
            var data = valid
            data.replaceSubrange(offset..<offset + bytes.count, with: bytes)
            return data
        }
        func le(_ value: Float32) -> [UInt8] { withUnsafeBytes(of: value.bitPattern.littleEndian, Array.init) }
        let contextsOffset = Int(valid[40]) | Int(valid[41]) << 8
        let contextCount = Int(valid[24])

        let cases: [(String, Data, LanguageModelError)] = [
            ("empty", Data(), .invalidHeader),
            ("truncated", valid.prefix(63), .invalidHeader),
            ("magic", corrupt(0, [0x58]), .invalidHeader),
            ("version", corrupt(4, [2, 0]), .unsupportedVersion(2)),
            ("flags", corrupt(6, [1, 0]), .invalidHeader),
            ("NaN bound", corrupt(48, le(.nan)), .invalidHeader),
            ("inverted bounds", corrupt(48, le(0) + le(-8)), .invalidHeader),
            ("offset", corrupt(32, [68]), .corrupted),
            ("short body", valid.dropLast(), .corrupted),
            ("trailing bytes", valid + Data([0]), .corrupted),
            ("unigram sentinel", corrupt(64 + 7 * 8, [0x7F]), .corrupted),
            ("context sentinel", corrupt(contextsOffset + contextCount * 8, [0x12]), .corrupted)
        ]
        for (name, data, expected) in cases {
            XCTAssertThrowsError(try BinaryLanguageModel(data: data), name) { error in
                XCTAssertEqual(error as? LanguageModelError, expected, name)
            }
        }
    }

    func testShippedModelsMatchTheirDictionaries() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../../KeyboardExtension/Resources/Dictionaries")
            .standardizedFileURL
        let models = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "klm" } ?? []
        try XCTSkipIf(models.isEmpty, "no shipped .klm files")

        for url in models {
            let model = try BinaryLanguageModel(contentsOf: url)
            let dictionary = try BinaryDictionary(
                contentsOf: url.deletingPathExtension().appendingPathExtension("kdict")
            )
            XCTAssertEqual(model.vocabCount, dictionary.wordCount, url.lastPathComponent)
            XCTAssertEqual(model.vocabFingerprint, dictionary.vocabFingerprint(), url.lastPathComponent)
            let start = model.prepareContext(prev1: .bos, prev2: nil)
            XCTAssertFalse(model.topNextWords(in: start, limit: 3).isEmpty, url.lastPathComponent)
        }
    }
}
