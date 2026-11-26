import XCTest
@testable import KeyboardCore

final class ProbabilisticHitResolverTests: XCTestCase {
    private func makeSampleRowGeometries() -> [KeyGeometry] {
        let letters = ["q", "w", "e", "r", "t"]
        return letters.enumerated().map { index, letter in
            let spec = KeySpec(id: "latin_\(letter)", kind: .character(letter), primaryLabel: letter)
            let frame = KeyRect(x: Double(index) * 40.0, y: 0.0, width: 40.0, height: 50.0)
            return KeyGeometry(keySpec: spec, frame: frame)
        }
    }

    func testBoundaryTapSnapsToLinguisticallyProbableKey() {
        let resolver = ProbabilisticHitResolver()
        let geometries = makeSampleRowGeometries()

        // Touch slightly inside "w" (x = 78.5), right next to the border with "e" (starts at x = 80.0)
        let boundaryPoint = KeyPoint(x: 78.5, y: 25.0)
        let scalarE = UInt32(UnicodeScalar("e").value)
        let nextScores: [UInt32: Double] = [scalarE: 65000.0]

        let resolvedWithProbabilistic = resolver.resolveKey(
            at: boundaryPoint,
            geometries: geometries,
            nextCharacterScores: nextScores,
            probabilisticEnabled: true
        )
        XCTAssertEqual(resolvedWithProbabilistic?.keySpec.primaryLabel, "e")

        let resolvedGeometricOnly = resolver.resolveKey(
            at: boundaryPoint,
            geometries: geometries,
            nextCharacterScores: nextScores,
            probabilisticEnabled: false
        )
        XCTAssertEqual(resolvedGeometricOnly?.keySpec.primaryLabel, "w")
    }

    func testCenterTapAlwaysRespectsIntentionalTarget() {
        let resolver = ProbabilisticHitResolver()
        let geometries = makeSampleRowGeometries()

        // Dead center of "w" (x = 60.0) should stay "w" even when "e" is far more probable
        let centerOfW = KeyPoint(x: 60.0, y: 25.0)
        let scalarE = UInt32(UnicodeScalar("e").value)
        let resolved = resolver.resolveKey(
            at: centerOfW,
            geometries: geometries,
            nextCharacterScores: [scalarE: 65000.0],
            probabilisticEnabled: true
        )
        XCTAssertEqual(resolved?.keySpec.primaryLabel, "w")
    }
}
