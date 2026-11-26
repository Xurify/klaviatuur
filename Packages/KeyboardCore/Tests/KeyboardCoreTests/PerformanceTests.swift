import Dispatch
import XCTest
@testable import KeyboardCore
#if canImport(Darwin)
import Darwin
#endif

final class PerformanceTests: XCTestCase {
    private static let shippedDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../../../../KeyboardExtension/Resources/Dictionaries")
        .standardizedFileURL

    private static let latinLanguages: [LanguageCode] = [.english, .czech, .slovak, .estonian]

    // Typos and missing diacritics on purpose: those keystrokes take the slow fuzzy path.
    private static let typed = "dakujem za pomoc, see you tomorow and dobry den vsetkym. aitah, kohtume homme"

    // Half a 60 Hz frame on average, leaving the other half to UIKit; no key may take a whole frame.
    private static let averageBudgetMilliseconds = 8.0
    private static let worstBudgetMilliseconds = 16.0

    #if DEBUG
    private static let isOptimized = false
    #else
    private static let isOptimized = true
    #endif

    // iOS has ended keyboard extensions at around 48 MB of footprint. Memory-mapped files are clean
    // pages and do not count, so this fails if the dictionaries or the models stop being mapped.
    private static let footprintBudgetBytes: UInt64 = 8 * 1024 * 1024

    func testTypingInFourLatinLanguagesWithAllFiveLoadedStaysWithinBudget() throws {
        try XCTSkipUnless(Self.isOptimized, "run with: swift test -c release -Xswiftc -enable-testing --filter PerformanceTests")
        let footprintBefore = Self.footprint()
        let engine = try shippedEngine()

        let timings = withExtendedLifetime(engine) {
            _ = simulateTyping(Self.typed, into: TypingSessionController(engine: engine))
            return simulateTyping(Self.typed, into: TypingSessionController(engine: engine))
        }
        var footprintGrowth: UInt64?
        if let before = footprintBefore, let after = withExtendedLifetime(engine, { Self.footprint() }) {
            footprintGrowth = after > before ? after - before : 0
        }

        let average = timings.reduce(0, +) / Double(timings.count)
        let worst = timings.max() ?? 0
        let growth = footprintGrowth.map { String(format: "%.1f MB", Double($0) / 1_048_576) } ?? "unavailable"
        print(
            "Warm keystroke latency over \(timings.count) keys, \(Self.latinLanguages.count) of "
                + "\(LanguageCode.allCases.count) languages active: "
                + String(format: "average %.2f ms, worst %.2f ms", average, worst)
                + "; footprint growth \(growth)"
        )

        XCTAssertLessThan(average, Self.averageBudgetMilliseconds)
        XCTAssertLessThan(worst, Self.worstBudgetMilliseconds)
        if let footprintGrowth {
            XCTAssertLessThan(footprintGrowth, Self.footprintBudgetBytes)
        }
    }

    private func shippedEngine() throws -> MultilingualEngine {
        let engine = MultilingualEngine()
        var loaded = 0
        for language in LanguageCode.allCases {
            let dictionaryURL = Self.shippedDirectory.appendingPathComponent("\(language.rawValue).kdict")
            guard FileManager.default.fileExists(atPath: dictionaryURL.path) else { continue }
            engine.registerDictionary(try BinaryDictionary(contentsOf: dictionaryURL), for: language)
            let model = try BinaryLanguageModel(
                contentsOf: dictionaryURL.deletingPathExtension().appendingPathExtension("klm")
            )
            XCTAssertTrue(engine.registerLanguageModel(model, for: language), language.rawValue)
            loaded += 1
        }
        try XCTSkipIf(loaded == 0, "no shipped dictionaries")
        XCTAssertEqual(loaded, LanguageCode.allCases.count, "every shipped language should load")
        engine.updateKeyGeometry(Self.phoneKeyGeometry())
        return engine
    }

    /// The default letters layout spread across a 390 pt wide phone, so typos near a key are
    /// scored as near misses, as they are on a device.
    private static func phoneKeyGeometry() -> [KeyGeometry] {
        let layout = LayoutRegistry.layout(for: .default, mode: .letters)
        return layout.rows.enumerated().flatMap { rowIndex, row in
            let unit = 390 / (row.keys.reduce(0) { $0 + $1.widthWeight } + 2 * row.horizontalInsetWeight)
            var x = row.horizontalInsetWeight * unit
            return row.keys.map { key in
                defer { x += key.widthWeight * unit }
                let frame = KeyRect(x: x, y: Double(rowIndex) * 54, width: key.widthWeight * unit, height: 54)
                return KeyGeometry(keySpec: key, frame: frame)
            }
        }
    }

    /// Milliseconds spent in the session for each key, applying its edits to a stand-in document.
    private func simulateTyping(_ text: String, into session: TypingSessionController) -> [Double] {
        var document = ""
        var timings: [Double] = []
        for character in text {
            let start = DispatchTime.now().uptimeNanoseconds
            let actions: [TextEditAction]
            switch character {
            case " ":
                actions = session.handleSpace(
                    textBeforeCursor: document, activeLanguages: Self.latinLanguages,
                    autocorrectEnabled: true, doubleSpacePeriodEnabled: true
                )
            case ",", ".":
                actions = session.handlePunctuation(
                    String(character), activeLanguages: Self.latinLanguages, autocorrectEnabled: true
                )
            default:
                actions = session.handleCharacterInput(
                    String(character), activeLanguages: Self.latinLanguages, autocorrectEnabled: true
                )
            }
            timings.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            for action in actions {
                switch action {
                case .insert(let inserted):
                    document += inserted
                case .deleteBackward(let count):
                    document.removeLast(count)
                case .replaceBackward(let deleteCount, let inserted):
                    document.removeLast(deleteCount)
                    document += inserted
                }
            }
        }
        return timings
    }

    private static func footprint() -> UInt64? {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
        #else
        return nil
        #endif
    }
}
