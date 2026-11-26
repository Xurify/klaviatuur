import UIKit
import KeyboardCore

protocol KeyboardSurfaceDelegate: AnyObject {
    func keyboardSurface(_ surface: KeyboardSurfaceView, didUpdateKeyGeometries geometries: [KeyGeometry])
    func keyboardSurface(_ surface: KeyboardSurfaceView, nextCharacterScoresForProbabilisticHit: Void) -> [UInt32: Double]
    func keyboardSurface(_ surface: KeyboardSurfaceView, didEmitCharacter text: String, from keySpec: KeySpec)
    func keyboardSurface(_ surface: KeyboardSurfaceView, didTriggerUtilityKey kind: KeyKind)
    func keyboardSurfaceDidLongPressSpacebar(_ surface: KeyboardSurfaceView)
    func keyboardSurfaceDidLongPressGlobe(_ surface: KeyboardSurfaceView)
    func keyboardSurface(_ surface: KeyboardSurfaceView, didScrubCursorBy characterDelta: Int)
    func keyboardSurfaceDidDoubleTapShift(_ surface: KeyboardSurfaceView)
}

final class KeyboardSurfaceView: UIView {
    weak var delegate: KeyboardSurfaceDelegate?

    private struct ActiveTouchState {
        let touch: UITouch
        var keyGeometry: KeyGeometry
        var startPoint: CGPoint
        var lastScrubX: CGFloat
        var isScrubbingSpacebar: Bool
        var isLongPressMenuActive: Bool
        var longPressTimer: Timer?
        var backspaceRepeatTimer: Timer?
    }

    private let hitResolver = ProbabilisticHitResolver()
    private let popupView = KeyPopupView()

    private var layoutSpec: KeyboardLayoutSpec?
    private var keyGeometries: [KeyGeometry] = []
    private var keyViewsByID: [String: KeyCapView] = [:]
    private var activeTouches: [ObjectIdentifier: ActiveTouchState] = [:]

    private var theme: PixelKeyboardTheme = .pixelDark
    private var shiftState: ShiftState = .lowercase
    private var settings: KeyboardSettings = .default
    private var lastShiftTapTime: Date = .distantPast

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        clipsToBounds = false
        popupView.isHidden = true
        addSubview(popupView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        layoutSpec: KeyboardLayoutSpec,
        shiftState: ShiftState,
        settings: KeyboardSettings,
        theme: PixelKeyboardTheme
    ) {
        let layoutChanged = self.layoutSpec != layoutSpec
        self.layoutSpec = layoutSpec
        self.shiftState = shiftState
        self.settings = settings
        self.theme = theme
        backgroundColor = theme.canvasBackground

        if layoutChanged {
            cancelAllActiveTouches()
            rebuildKeyViews()
            setNeedsLayout()
            layoutIfNeeded()
        } else {
            refreshKeyAppearances()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let layoutSpec, bounds.width > 0, bounds.height > 0 else { return }

        let rowCount = layoutSpec.rows.count
        guard rowCount > 0 else { return }

        let horizontalPadding: CGFloat = 3
        let topPadding: CGFloat = 4
        let bottomPadding: CGFloat = 4
        let availableWidth = bounds.width - horizontalPadding * 2
        let availableHeight = bounds.height - topPadding - bottomPadding

        let hasNumberRow = layoutSpec.mode == .letters && settings.showNumberRow
        let totalHeightUnits: CGFloat = hasNumberRow
            ? 0.78 + CGFloat(rowCount - 1)
            : CGFloat(rowCount)

        var currentY = topPadding
        var computedGeometries: [KeyGeometry] = []

        for (rowIndex, row) in layoutSpec.rows.enumerated() {
            let rowUnit: CGFloat = (hasNumberRow && rowIndex == 0) ? 0.78 : 1.0
            let rowHeight = availableHeight * (rowUnit / totalHeightUnits)

            let totalWeight = row.keys.reduce(0.0) { partialResult, key in
                partialResult + key.widthWeight
            } + row.horizontalInsetWeight * 2.0

            let unitWidth = availableWidth / CGFloat(max(totalWeight, 1.0))
            var currentX = horizontalPadding + unitWidth * CGFloat(row.horizontalInsetWeight)

            for key in row.keys {
                let keyWidth = unitWidth * CGFloat(key.widthWeight)
                let frame = CGRect(x: currentX, y: currentY, width: keyWidth, height: rowHeight)
                if let keyView = keyViewsByID[key.id] {
                    keyView.frame = frame
                }
                computedGeometries.append(
                    KeyGeometry(
                        keySpec: key,
                        frame: KeyRect(
                            x: Double(frame.minX),
                            y: Double(frame.minY),
                            width: Double(frame.width),
                            height: Double(frame.height)
                        )
                    )
                )
                currentX += keyWidth
            }
            currentY += rowHeight
        }

        keyGeometries = computedGeometries
        bringSubviewToFront(popupView)
        delegate?.keyboardSurface(self, didUpdateKeyGeometries: computedGeometries)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !keyGeometries.isEmpty else { return }

        for (identifier, existing) in activeTouches where !existing.isLongPressMenuActive && !existing.isScrubbingSpacebar {
            if existing.keyGeometry.keySpec.kind.isLetterInput {
                commitTouch(identifier: identifier)
            }
        }

        let nextScores = delegate?.keyboardSurface(self, nextCharacterScoresForProbabilisticHit: ()) ?? [:]

        for touch in touches {
            let point = touch.location(in: self)
            let keyPoint = KeyPoint(x: Double(point.x), y: Double(point.y))
            guard let resolved = hitResolver.resolveKey(
                at: keyPoint,
                geometries: keyGeometries,
                nextCharacterScores: nextScores,
                probabilisticEnabled: settings.enableProbabilisticHitboxes
            ) else {
                continue
            }

            let identifier = ObjectIdentifier(touch)
            keyViewsByID[resolved.keySpec.id]?.setHighlighted(true)

            var state = ActiveTouchState(
                touch: touch,
                keyGeometry: resolved,
                startPoint: point,
                lastScrubX: point.x,
                isScrubbingSpacebar: false,
                isLongPressMenuActive: false,
                longPressTimer: nil,
                backspaceRepeatTimer: nil
            )

            switch resolved.keySpec.kind {
            case .backspace:
                delegate?.keyboardSurface(self, didTriggerUtilityKey: .backspace)
                state.longPressTimer = Timer.scheduledTimer(withTimeInterval: 0.36, repeats: false) { [weak self] _ in
                    self?.startBackspaceRepeat(for: identifier)
                }

            case .shift, .modeSwitch:
                break

            case .globe:
                state.longPressTimer = Timer.scheduledTimer(withTimeInterval: 0.42, repeats: false) { [weak self] _ in
                    self?.handleGlobeLongPress(for: identifier)
                }

            case .space:
                state.longPressTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
                    self?.handleSpacebarLongPress(for: identifier)
                }

            case .character, .number, .punctuation:
                if settings.enableKeyPopups, let keyView = keyViewsByID[resolved.keySpec.id] {
                    popupView.showSingleCharacter(
                        resolved.keySpec.displayLabel(shiftState: shiftState),
                        anchorFrame: keyView.frame,
                        in: bounds,
                        theme: theme
                    )
                }
                let variants = resolved.keySpec.resolvedLongPressVariants(shiftState: shiftState)
                if !variants.isEmpty {
                    let delay = Double(max(160, settings.longPressDelayMilliseconds)) / 1000.0
                    state.longPressTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                        self?.activateLongPressMenu(for: identifier)
                    }
                }

            case .returnKey:
                break
            }

            activeTouches[identifier] = state
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let identifier = ObjectIdentifier(touch)
            guard var state = activeTouches[identifier] else { continue }
            let location = touch.location(in: self)

            if state.isLongPressMenuActive {
                popupView.updateSelection(forTouchX: location.x)
                continue
            }

            if state.keyGeometry.keySpec.kind == .space {
                let deltaFromStart = location.x - state.startPoint.x
                if !state.isScrubbingSpacebar && abs(deltaFromStart) >= 14 {
                    state.isScrubbingSpacebar = true
                    state.longPressTimer?.invalidate()
                    state.longPressTimer = nil
                    state.lastScrubX = location.x
                    activeTouches[identifier] = state
                } else if state.isScrubbingSpacebar {
                    let stepThreshold: CGFloat = 10
                    let delta = location.x - state.lastScrubX
                    if abs(delta) >= stepThreshold {
                        let steps = Int(delta / stepThreshold)
                        state.lastScrubX += CGFloat(steps) * stepThreshold
                        activeTouches[identifier] = state
                        delegate?.keyboardSurface(self, didScrubCursorBy: steps)
                    }
                }
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            commitTouch(identifier: ObjectIdentifier(touch))
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let identifier = ObjectIdentifier(touch)
            cleanupTouch(identifier: identifier)
        }
    }

    private func commitTouch(identifier: ObjectIdentifier) {
        guard let state = activeTouches[identifier] else { return }
        let keySpec = state.keyGeometry.keySpec
        let wasLongPress = state.isLongPressMenuActive
        let wasScrubbing = state.isScrubbingSpacebar
        let selectedPopupVariant = wasLongPress ? popupView.selectedVariant : nil

        cleanupTouch(identifier: identifier)

        if wasScrubbing {
            return
        }

        if let variant = selectedPopupVariant {
            delegate?.keyboardSurface(self, didEmitCharacter: variant, from: keySpec)
            return
        }

        switch keySpec.kind {
        case .backspace:
            // Initial delete already fired on touchesBegan for snappy feel
            break

        case .shift:
            let now = Date()
            if now.timeIntervalSince(lastShiftTapTime) <= 0.35 {
                lastShiftTapTime = .distantPast
                delegate?.keyboardSurfaceDidDoubleTapShift(self)
            } else {
                lastShiftTapTime = now
                delegate?.keyboardSurface(self, didTriggerUtilityKey: .shift)
            }

        case .globe, .modeSwitch, .space, .returnKey:
            delegate?.keyboardSurface(self, didTriggerUtilityKey: keySpec.kind)

        case .character, .number, .punctuation:
            if let output = keySpec.outputText(shiftState: shiftState) {
                delegate?.keyboardSurface(self, didEmitCharacter: output, from: keySpec)
            }
        }
    }

    private func activateLongPressMenu(for identifier: ObjectIdentifier) {
        guard var state = activeTouches[identifier] else { return }
        let keySpec = state.keyGeometry.keySpec
        let variants = keySpec.resolvedLongPressVariants(shiftState: shiftState)
        guard !variants.isEmpty, let keyView = keyViewsByID[keySpec.id] else { return }

        state.isLongPressMenuActive = true
        state.longPressTimer = nil
        activeTouches[identifier] = state

        popupView.showVariants(
            variants,
            anchorFrame: keyView.frame,
            in: bounds,
            theme: theme
        )
    }

    private func handleSpacebarLongPress(for identifier: ObjectIdentifier) {
        guard let state = activeTouches[identifier], !state.isScrubbingSpacebar else { return }
        cleanupTouch(identifier: identifier)
        delegate?.keyboardSurfaceDidLongPressSpacebar(self)
    }

    private func handleGlobeLongPress(for identifier: ObjectIdentifier) {
        guard activeTouches[identifier] != nil else { return }
        cleanupTouch(identifier: identifier)
        delegate?.keyboardSurfaceDidLongPressGlobe(self)
    }

    private func startBackspaceRepeat(for identifier: ObjectIdentifier) {
        guard var state = activeTouches[identifier] else { return }
        state.backspaceRepeatTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.delegate?.keyboardSurface(self, didTriggerUtilityKey: .backspace)
        }
        activeTouches[identifier] = state
    }

    private func cleanupTouch(identifier: ObjectIdentifier) {
        guard let state = activeTouches.removeValue(forKey: identifier) else { return }
        state.longPressTimer?.invalidate()
        state.backspaceRepeatTimer?.invalidate()
        keyViewsByID[state.keyGeometry.keySpec.id]?.setHighlighted(false)
        if activeTouches.isEmpty {
            popupView.hide()
        }
    }

    func cancelAllActiveTouches() {
        for identifier in Array(activeTouches.keys) {
            cleanupTouch(identifier: identifier)
        }
        popupView.hide()
    }

    private func rebuildKeyViews() {
        for view in keyViewsByID.values {
            view.removeFromSuperview()
        }
        keyViewsByID.removeAll()

        guard let layoutSpec else { return }
        for row in layoutSpec.rows {
            for key in row.keys {
                let keyView = KeyCapView()
                keyView.configure(
                    keySpec: key,
                    shiftState: shiftState,
                    theme: theme,
                    highlighted: false
                )
                addSubview(keyView)
                keyViewsByID[key.id] = keyView
            }
        }
        bringSubviewToFront(popupView)
    }

    private func refreshKeyAppearances() {
        guard let layoutSpec else { return }
        for row in layoutSpec.rows {
            for key in row.keys {
                keyViewsByID[key.id]?.configure(
                    keySpec: key,
                    shiftState: shiftState,
                    theme: theme,
                    highlighted: false
                )
            }
        }
    }
}
