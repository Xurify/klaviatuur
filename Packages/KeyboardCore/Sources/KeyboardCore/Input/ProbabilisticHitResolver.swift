import Foundation

public struct ProbabilisticHitResolver {
    public init() {}

    public func resolveKey(
        at touchPoint: KeyPoint,
        geometries: [KeyGeometry],
        nextCharacterScores: [UInt32: Double],
        probabilisticEnabled: Bool
    ) -> KeyGeometry? {
        guard !geometries.isEmpty else { return nil }

        let directHit = geometries.first { $0.frame.contains(touchPoint) }

        // Non-letter utility keys (shift, backspace, space, return, globe, mode switch, numbers)
        // always use exact geometric boundaries so navigation keys never misfire.
        if let directHit, !directHit.keySpec.kind.isLetterInput {
            return directHit
        }

        if !probabilisticEnabled || nextCharacterScores.isEmpty {
            return directHit ?? nearestKey(to: touchPoint, in: geometries)
        }

        let letterKeys = geometries.filter { $0.keySpec.kind.isLetterInput }
        guard !letterKeys.isEmpty else {
            return directHit ?? nearestKey(to: touchPoint, in: geometries)
        }

        let referenceWidth = directHit?.frame.width ?? letterKeys[0].frame.width
        let referenceHeight = directHit?.frame.height ?? letterKeys[0].frame.height
        let searchRadius = max(referenceWidth, referenceHeight) * 1.35

        // If the tap is cleanly near the center of a letter key, trust the user's explicit aim.
        if let directHit {
            let horizontalRatio = abs(touchPoint.x - directHit.frame.center.x) / max(directHit.frame.width * 0.5, 1.0)
            let verticalRatio = abs(touchPoint.y - directHit.frame.center.y) / max(directHit.frame.height * 0.5, 1.0)
            if horizontalRatio <= 0.42 && verticalRatio <= 0.45 {
                return directHit
            }
        }

        let maxLanguageScore = nextCharacterScores.values.max() ?? 1.0
        let sigmaX = max(referenceWidth * 0.52, 8.0)
        let sigmaY = max(referenceHeight * 0.58, 10.0)

        var bestGeometry: KeyGeometry?
        var bestCombinedScore = -Double.infinity

        for candidate in letterKeys {
            let center = candidate.frame.center
            if center.distance(to: touchPoint) > searchRadius {
                continue
            }

            let deltaX = (touchPoint.x - center.x) / sigmaX
            let deltaY = (touchPoint.y - center.y) / sigmaY
            let spatialLogLikelihood = -0.5 * (deltaX * deltaX + deltaY * deltaY)

            var languageLogPrior = -0.65
            if case .character(let character) = candidate.keySpec.kind,
               let firstScalar = DiacriticFolding.foldedScalars(character).first,
               let rawScore = nextCharacterScores[firstScalar],
               rawScore > 0
            {
                let normalized = rawScore / max(maxLanguageScore, 1.0)
                languageLogPrior = 0.55 * log(0.25 + normalized * 2.5)
            }

            let combinedScore = spatialLogLikelihood + languageLogPrior
            if combinedScore > bestCombinedScore {
                bestCombinedScore = combinedScore
                bestGeometry = candidate
            }
        }

        return bestGeometry ?? directHit ?? nearestKey(to: touchPoint, in: geometries)
    }

    private func nearestKey(to point: KeyPoint, in geometries: [KeyGeometry]) -> KeyGeometry? {
        geometries.min { left, right in
            left.frame.center.distance(to: point) < right.frame.center.distance(to: point)
        }
    }
}
