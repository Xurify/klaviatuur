import Foundation

public enum KeyboardLayoutMode: String, Codable, Equatable, Sendable {
    case letters
    case symbolsPrimary
    case symbolsSecondary
}

public enum ShiftState: Equatable, Sendable {
    case lowercase
    case shifted
    case capsLock

    public var isUppercased: Bool {
        self == .shifted || self == .capsLock
    }
}

public enum KeyKind: Equatable, Hashable, Sendable {
    case character(String)
    case number(String)
    case shift
    case backspace
    case modeSwitch(KeyboardLayoutMode)
    case globe
    case space
    case returnKey
    case punctuation(String)

    public var isLetterInput: Bool {
        if case .character = self {
            return true
        }
        return false
    }
}

public struct KeySpec: Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let kind: KeyKind
    public let primaryLabel: String
    public let shiftedLabel: String?
    public let secondaryHint: String?
    public let longPressVariants: [String]
    public let widthWeight: Double

    public init(
        id: String,
        kind: KeyKind,
        primaryLabel: String,
        shiftedLabel: String? = nil,
        secondaryHint: String? = nil,
        longPressVariants: [String] = [],
        widthWeight: Double = 1.0
    ) {
        self.id = id
        self.kind = kind
        self.primaryLabel = primaryLabel
        self.shiftedLabel = shiftedLabel
        self.secondaryHint = secondaryHint
        self.longPressVariants = longPressVariants
        self.widthWeight = widthWeight
    }

    public func displayLabel(shiftState: ShiftState) -> String {
        switch kind {
        case .character:
            if shiftState.isUppercased {
                return shiftedLabel ?? primaryLabel.uppercased()
            }
            return primaryLabel
        default:
            return primaryLabel
        }
    }

    public func outputText(shiftState: ShiftState) -> String? {
        switch kind {
        case .character(let value):
            if shiftState.isUppercased {
                return shiftedLabel ?? value.uppercased()
            }
            return value
        case .number(let digit):
            return digit
        case .punctuation(let symbol):
            return symbol
        case .space:
            return " "
        case .returnKey:
            return "\n"
        case .shift, .backspace, .modeSwitch, .globe:
            return nil
        }
    }

    public func resolvedLongPressVariants(shiftState: ShiftState) -> [String] {
        guard shiftState.isUppercased else {
            return longPressVariants
        }
        return longPressVariants.map { variant in
            variant.uppercased()
        }
    }
}

public struct KeyRow: Equatable, Sendable {
    public let keys: [KeySpec]
    public let horizontalInsetWeight: Double

    public init(keys: [KeySpec], horizontalInsetWeight: Double = 0.0) {
        self.keys = keys
        self.horizontalInsetWeight = horizontalInsetWeight
    }
}

public struct KeyboardLayoutSpec: Equatable, Sendable {
    public let script: ScriptKind
    public let mode: KeyboardLayoutMode
    public let rows: [KeyRow]
    public let spacebarLabel: String

    public init(
        script: ScriptKind,
        mode: KeyboardLayoutMode,
        rows: [KeyRow],
        spacebarLabel: String
    ) {
        self.script = script
        self.mode = mode
        self.rows = rows
        self.spacebarLabel = spacebarLabel
    }
}

public struct KeyPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public func distance(to other: KeyPoint) -> Double {
        let deltaX = x - other.x
        let deltaY = y - other.y
        return (deltaX * deltaX + deltaY * deltaY).squareRoot()
    }
}

public struct KeyRect: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var center: KeyPoint {
        KeyPoint(x: x + width * 0.5, y: y + height * 0.5)
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    public func contains(_ point: KeyPoint) -> Bool {
        point.x >= x && point.x <= maxX && point.y >= y && point.y <= maxY
    }
}

public struct KeyGeometry: Equatable, Sendable {
    public let keySpec: KeySpec
    public let frame: KeyRect

    public init(keySpec: KeySpec, frame: KeyRect) {
        self.keySpec = keySpec
        self.frame = frame
    }
}
