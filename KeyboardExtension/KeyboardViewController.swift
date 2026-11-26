import UIKit
import KeyboardCore
import os

final class KeyboardViewController: UIInputViewController {
    private let storage = AppGroupStorage()
    private let engine = MultilingualEngine()
    private lazy var typingSession = TypingSessionController(engine: engine)
    private lazy var clipboardStore = ClipboardStore(fileURL: storage.clipboardFileURL)
    private let hapticGenerator = UIImpactFeedbackGenerator(style: .light)

    private let backdropView = GradientBackdropView()
    private let toolbarView = SuggestionToolbarView()
    private let surfaceView = KeyboardSurfaceView()
    private let clipboardPanelView = ClipboardPanelView()

    private var heightConstraint: NSLayoutConstraint?
    private var settings: KeyboardSettings = .default
    private var layoutMode: KeyboardLayoutMode = .letters
    private var shiftState: ShiftState = .lowercase
    private var isClipboardVisible: Bool = false
    private var lastObservedPasteboardChangeCount: Int = -1

    private struct AppliedAppearance: Equatable {
        let style: KeyboardThemeStyle
        let isDark: Bool
        let returnKeyLabel: String
    }

    private var appliedAppearance: AppliedAppearance?

    override func viewDidLoad() {
        super.viewDidLoad()
        settings = storage.loadSettings()
        let loadStart = Date()
        engine.loadDictionaries(from: Bundle.main, languages: LanguageCode.allCases)
        let withModels = LanguageCode.allCases.filter(engine.hasLanguageModel(for:)).map(\.rawValue)
        KeyboardLog.lifecycle.info(
            "Loaded languages in \(Date().timeIntervalSince(loadStart) * 1000, format: .fixed(precision: 1)) ms; predictions for \(withModels.joined(separator: ", "), privacy: .public)"
        )
        configureHierarchy()
        applyCurrentState()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        settings = storage.loadSettings()
        clipboardStore.reload()
        clipboardPanelView.setFullAccess(hasFullAccess)
        KeyboardLog.lifecycle.info("Keyboard appeared; Full Access \(self.hasFullAccess ? "on" : "off", privacy: .public)")
        if canPlayHaptics {
            hapticGenerator.prepare()
        }
        updateQuickPasteChip()
        syncDocumentContext()
        applyCurrentState()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // A held backspace's repeat timer must not outlive the keyboard if iOS hides it
        // without delivering touchesCancelled.
        surfaceView.cancelAllActiveTouches()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        KeyboardLog.lifecycle.notice("Memory warning received")
        if !isClipboardVisible {
            clipboardPanelView.releaseCards()
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyThemeIfChanged()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        syncDocumentContext()
        applyThemeIfChanged()
    }

    private func configureHierarchy() {
        backdropView.translatesAutoresizingMaskIntoConstraints = false
        backdropView.isUserInteractionEnabled = false
        view.addSubview(backdropView)

        toolbarView.translatesAutoresizingMaskIntoConstraints = false
        toolbarView.delegate = self
        view.addSubview(toolbarView)

        surfaceView.translatesAutoresizingMaskIntoConstraints = false
        surfaceView.delegate = self
        view.addSubview(surfaceView)

        clipboardPanelView.translatesAutoresizingMaskIntoConstraints = false
        clipboardPanelView.delegate = self
        clipboardPanelView.isHidden = true
        view.addSubview(clipboardPanelView)

        let computedHeight = targetKeyboardHeight()
        let constraint = view.heightAnchor.constraint(equalToConstant: computedHeight)
        constraint.priority = UILayoutPriority(999)
        constraint.isActive = true
        heightConstraint = constraint

        NSLayoutConstraint.activate([
            backdropView.topAnchor.constraint(equalTo: view.topAnchor),
            backdropView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdropView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            toolbarView.topAnchor.constraint(equalTo: view.topAnchor),
            toolbarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbarView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbarView.heightAnchor.constraint(equalToConstant: 42),

            surfaceView.topAnchor.constraint(equalTo: toolbarView.bottomAnchor),
            surfaceView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            surfaceView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            surfaceView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            clipboardPanelView.topAnchor.constraint(equalTo: toolbarView.bottomAnchor),
            clipboardPanelView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            clipboardPanelView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            clipboardPanelView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func targetKeyboardHeight() -> CGFloat {
        let baseKeyArea: CGFloat = settings.showNumberRow ? 248 : 216
        let scaled = baseKeyArea * CGFloat(max(0.85, min(1.25, settings.keyboardHeightScale)))
        return 42 + scaled
    }

    private func currentTheme() -> PixelKeyboardTheme {
        let appearance = textDocumentProxy.keyboardAppearance ?? .default
        return PixelKeyboardTheme.resolved(
            style: settings.themeStyle,
            appearance: appearance,
            traitCollection: traitCollection
        )
    }

    private func resolvedReturnKeyLabel() -> String {
        switch textDocumentProxy.returnKeyType ?? .default {
        case .go: return "Go"
        case .google, .search, .yahoo: return "Search"
        case .join: return "Join"
        case .next: return "Next"
        case .route: return "Route"
        case .send: return "Send"
        case .done: return "Done"
        case .continue: return "Continue"
        default: return "↵"
        }
    }

    private func applyTheme() {
        let theme = currentTheme()
        appliedAppearance = AppliedAppearance(
            style: settings.themeStyle,
            isDark: theme.isDark,
            returnKeyLabel: resolvedReturnKeyLabel()
        )
        applyChrome(theme: theme)
        applyCurrentLayout(theme: theme)
    }

    /// textDidChange fires on most edits, so the full re-theme only runs when something it
    /// depends on (dark mode, theme, the field's return key) actually changed.
    private func applyThemeIfChanged() {
        let current = AppliedAppearance(
            style: settings.themeStyle,
            isDark: currentTheme().isDark,
            returnKeyLabel: resolvedReturnKeyLabel()
        )
        guard current != appliedAppearance else { return }
        applyTheme()
    }

    private func applyCurrentState() {
        heightConstraint?.constant = targetKeyboardHeight()
        applyTheme()
        refreshClipboardUI()
    }

    private func applyChrome(theme: PixelKeyboardTheme) {
        view.backgroundColor = theme.canvasBackground
        backdropView.setColors(theme.backdropGradient)
        toolbarView.applyTheme(theme)
        clipboardPanelView.applyTheme(theme)
    }

    private func applyCurrentLayout(theme: PixelKeyboardTheme) {
        let layoutSpec = LayoutRegistry.layout(
            for: settings,
            mode: layoutMode,
            returnKeyLabel: resolvedReturnKeyLabel()
        )
        let activeTag = settings.activeLanguagesForCurrentLayout()
            .map { $0.profile.shortTag }
            .joined(separator: "/")
        toolbarView.updateLanguageTag(activeTag)
        surfaceView.update(
            layoutSpec: layoutSpec,
            shiftState: shiftState,
            settings: settings,
            theme: theme
        )
    }

    private func showSuggestions() {
        let suggestions = typingSession.currentSuggestions
        toolbarView.updateSuggestions(shiftState == .capsLock ? suggestions.uppercased() : suggestions)
    }

    private func syncDocumentContext() {
        let beforeCursor = textDocumentProxy.documentContextBeforeInput
        KeyboardLog.input.debug("Host gave \(beforeCursor?.count ?? 0) characters before the cursor")
        let activeLanguages = settings.activeLanguagesForCurrentLayout()
        typingSession.syncWithDocumentContext(
            textBeforeCursor: beforeCursor,
            activeLanguages: activeLanguages,
            autocorrectEnabled: settings.enableAutocorrect
        )
        showSuggestions()

        if settings.enableAutoCapitalization && shiftState != .capsLock {
            let targetShift: ShiftState = typingSession.shouldAutoCapitalize(textBeforeCursor: beforeCursor)
                ? .shifted
                : .lowercase
            if targetShift != shiftState {
                shiftState = targetShift
                applyCurrentLayout(theme: currentTheme())
            }
        }
    }

    // Third-party keyboards only get haptics with Full Access; without it every call fails
    // inside the sandbox.
    private var canPlayHaptics: Bool {
        settings.enableHaptics && hasFullAccess
    }

    private func triggerHapticIfEnabled() {
        guard canPlayHaptics else { return }
        hapticGenerator.impactOccurred(intensity: 0.72)
        hapticGenerator.prepare()
    }

    private func applyTextActions(_ actions: [TextEditAction]) {
        for action in actions {
            switch action {
            case .insert(let text):
                textDocumentProxy.insertText(text)
            case .deleteBackward(let count):
                for _ in 0..<count {
                    textDocumentProxy.deleteBackward()
                }
            case .replaceBackward(let deleteCount, let insertText):
                for _ in 0..<deleteCount {
                    textDocumentProxy.deleteBackward()
                }
                textDocumentProxy.insertText(insertText)
            }
        }
    }

    private func captureSystemPasteboardIfChanged() {
        guard settings.enableClipboardHistory, hasFullAccess else { return }
        let pasteboard = UIPasteboard.general
        guard pasteboard.changeCount != lastObservedPasteboardChangeCount else { return }
        lastObservedPasteboardChangeCount = pasteboard.changeCount
        toolbarView.setQuickPasteAvailable(false)

        if let copiedString = pasteboard.string,
           !copiedString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            _ = clipboardStore.recordCopiedText(
                copiedString,
                retentionMinutes: settings.clipboardRetentionMinutes
            )
            refreshClipboardUI()
        }
    }

    /// changeCount and hasStrings don't count as reading the pasteboard, so they can be checked
    /// on every open without iOS showing its paste permission prompt.
    private func updateQuickPasteChip() {
        guard settings.enableClipboardHistory, hasFullAccess else {
            toolbarView.setQuickPasteAvailable(false)
            return
        }
        let pasteboard = UIPasteboard.general
        let hasNewCopy = pasteboard.changeCount != lastObservedPasteboardChangeCount && pasteboard.hasStrings
        toolbarView.setQuickPasteAvailable(hasNewCopy)
    }

    private func refreshClipboardUI() {
        let entries = clipboardStore.allEntries(retentionMinutes: settings.clipboardRetentionMinutes)
        clipboardPanelView.updateEntries(entries)
    }

    private func setClipboardPanelVisible(_ visible: Bool) {
        isClipboardVisible = visible
        clipboardPanelView.isHidden = !visible
        surfaceView.isHidden = visible
        toolbarView.setClipboardActive(visible)
        if visible {
            captureSystemPasteboardIfChanged()
            refreshClipboardUI()
        }
    }

    private func cycleLayoutAndPersist() {
        settings.cycleActiveLayout()
        storage.saveSettings(settings)
        layoutMode = .letters
        applyCurrentState()
        syncDocumentContext()
    }
}

// MARK: - KeyboardSurfaceDelegate

extension KeyboardViewController: KeyboardSurfaceDelegate {
    func keyboardSurface(_ surface: KeyboardSurfaceView, didUpdateKeyGeometries geometries: [KeyGeometry]) {
        engine.updateKeyGeometry(geometries)
    }

    func keyboardSurface(
        _ surface: KeyboardSurfaceView,
        nextCharacterScoresForProbabilisticHit: Void
    ) -> [UInt32: Double] {
        guard layoutMode == .letters else { return [:] }
        return engine.nextCharacterScores(
            forPrefix: typingSession.currentWord,
            activeLanguages: settings.activeLanguagesForCurrentLayout()
        )
    }

    func keyboardSurface(_ surface: KeyboardSurfaceView, didEmitCharacter text: String, from keySpec: KeySpec) {
        triggerHapticIfEnabled()
        toolbarView.setQuickPasteAvailable(false)
        let activeLanguages = settings.activeLanguagesForCurrentLayout()

        switch keySpec.kind {
        case .character:
            let actions = typingSession.handleCharacterInput(
                text,
                activeLanguages: activeLanguages,
                autocorrectEnabled: settings.enableAutocorrect
            )
            applyTextActions(actions)
            if shiftState == .shifted {
                shiftState = .lowercase
                applyCurrentLayout(theme: currentTheme())
            }

        case .punctuation:
            let actions = typingSession.handlePunctuation(
                text,
                activeLanguages: activeLanguages,
                autocorrectEnabled: settings.enableAutocorrect
            )
            applyTextActions(actions)
            if layoutMode != .letters {
                layoutMode = .letters
                applyCurrentLayout(theme: currentTheme())
            }

        case .number:
            let actions = typingSession.handleCharacterInput(
                text,
                activeLanguages: activeLanguages,
                autocorrectEnabled: settings.enableAutocorrect
            )
            applyTextActions(actions)
            if shiftState == .shifted {
                shiftState = .lowercase
                applyCurrentLayout(theme: currentTheme())
            }

        default:
            textDocumentProxy.insertText(text)
        }

        showSuggestions()
    }

    func keyboardSurface(_ surface: KeyboardSurfaceView, didTriggerUtilityKey kind: KeyKind) {
        triggerHapticIfEnabled()
        let activeLanguages = settings.activeLanguagesForCurrentLayout()

        switch kind {
        case .shift:
            switch shiftState {
            case .lowercase:
                shiftState = .shifted
            case .shifted, .capsLock:
                shiftState = .lowercase
            }
            applyCurrentLayout(theme: currentTheme())
            showSuggestions()

        case .backspace:
            toolbarView.setQuickPasteAvailable(false)
            let actions = typingSession.handleBackspace(
                textBeforeCursor: textDocumentProxy.documentContextBeforeInput,
                activeLanguages: activeLanguages,
                autocorrectEnabled: settings.enableAutocorrect
            )
            applyTextActions(actions)
            showSuggestions()
            if settings.enableAutoCapitalization && shiftState != .capsLock {
                let shouldCapitalize = typingSession.shouldAutoCapitalize(
                    textBeforeCursor: textDocumentProxy.documentContextBeforeInput
                )
                let targetShift: ShiftState = shouldCapitalize ? .shifted : .lowercase
                if targetShift != shiftState {
                    shiftState = targetShift
                    applyCurrentLayout(theme: currentTheme())
                }
            }

        case .space:
            toolbarView.setQuickPasteAvailable(false)
            let actions = typingSession.handleSpace(
                textBeforeCursor: textDocumentProxy.documentContextBeforeInput,
                activeLanguages: activeLanguages,
                autocorrectEnabled: settings.enableAutocorrect,
                doubleSpacePeriodEnabled: settings.enableDoubleSpacePeriod
            )
            applyTextActions(actions)
            showSuggestions()
            let previousShift = shiftState
            let previousMode = layoutMode
            layoutMode = .letters
            if settings.enableAutoCapitalization && shiftState != .capsLock {
                shiftState = typingSession.shouldAutoCapitalize(
                    textBeforeCursor: textDocumentProxy.documentContextBeforeInput
                ) ? .shifted : .lowercase
            }
            if shiftState != previousShift || layoutMode != previousMode {
                applyCurrentLayout(theme: currentTheme())
            }

        case .returnKey:
            toolbarView.setQuickPasteAvailable(false)
            let actions = typingSession.handlePunctuation(
                "\n",
                activeLanguages: activeLanguages,
                autocorrectEnabled: settings.enableAutocorrect
            )
            applyTextActions(actions)
            showSuggestions()
            if settings.enableAutoCapitalization && shiftState != .capsLock {
                shiftState = .shifted
                applyCurrentLayout(theme: currentTheme())
            }

        case .modeSwitch(let targetMode):
            layoutMode = targetMode
            applyCurrentLayout(theme: currentTheme())

        case .globe:
            if settings.availableScripts().count > 1 || !settings.simultaneousMultilingual {
                cycleLayoutAndPersist()
            } else {
                advanceToNextInputMode()
            }

        default:
            break
        }
    }

    func keyboardSurfaceDidLongPressSpacebar(_ surface: KeyboardSurfaceView) {
        triggerHapticIfEnabled()
        cycleLayoutAndPersist()
    }

    func keyboardSurfaceDidLongPressGlobe(_ surface: KeyboardSurfaceView) {
        triggerHapticIfEnabled()
        advanceToNextInputMode()
    }

    func keyboardSurface(_ surface: KeyboardSurfaceView, didScrubCursorBy characterDelta: Int) {
        typingSession.cursorDidMove()
        textDocumentProxy.adjustTextPosition(byCharacterOffset: characterDelta)
    }

    func keyboardSurfaceDidDoubleTapShift(_ surface: KeyboardSurfaceView) {
        triggerHapticIfEnabled()
        shiftState = shiftState == .capsLock ? .lowercase : .capsLock
        applyCurrentLayout(theme: currentTheme())
        showSuggestions()
    }
}

// MARK: - SuggestionToolbarDelegate

extension KeyboardViewController: SuggestionToolbarDelegate {
    func suggestionToolbar(
        _ toolbar: SuggestionToolbarView,
        didSelectCandidate candidate: SuggestionCandidate
    ) {
        triggerHapticIfEnabled()
        toolbarView.setQuickPasteAvailable(false)
        let actions = typingSession.acceptSuggestion(
            candidate,
            activeLanguages: settings.activeLanguagesForCurrentLayout(),
            autocorrectEnabled: settings.enableAutocorrect
        )
        applyTextActions(actions)
        showSuggestions()
        if shiftState == .shifted {
            shiftState = .lowercase
            applyCurrentLayout(theme: currentTheme())
        }
    }

    func suggestionToolbarDidToggleClipboard(_ toolbar: SuggestionToolbarView) {
        triggerHapticIfEnabled()
        setClipboardPanelVisible(!isClipboardVisible)
    }

    func suggestionToolbarDidTapQuickPaste(_ toolbar: SuggestionToolbarView) {
        triggerHapticIfEnabled()
        // Reading here is a direct response to the tap, which is when iOS expects a paste.
        let pasteboard = UIPasteboard.general
        lastObservedPasteboardChangeCount = pasteboard.changeCount
        guard let text = pasteboard.string, !text.isEmpty else { return }
        textDocumentProxy.insertText(text)
        syncDocumentContext()
        if settings.enableClipboardHistory {
            clipboardStore.recordCopiedText(text, retentionMinutes: settings.clipboardRetentionMinutes)
            refreshClipboardUI()
        }
    }

    func suggestionToolbarDidTapLanguageCycle(_ toolbar: SuggestionToolbarView) {
        triggerHapticIfEnabled()
        if settings.availableScripts().count > 1 || !settings.simultaneousMultilingual {
            cycleLayoutAndPersist()
        } else {
            advanceToNextInputMode()
        }
    }
}

// MARK: - ClipboardPanelDelegate

extension KeyboardViewController: ClipboardPanelDelegate {
    func clipboardPanel(_ panel: ClipboardPanelView, didSelectText text: String) {
        triggerHapticIfEnabled()
        textDocumentProxy.insertText(text)
        toolbarView.setQuickPasteAvailable(false)
        syncDocumentContext()
        setClipboardPanelVisible(false)
    }

    func clipboardPanel(_ panel: ClipboardPanelView, didTogglePin entryID: UUID) {
        triggerHapticIfEnabled()
        clipboardStore.togglePin(entryID: entryID)
        refreshClipboardUI()
    }

    func clipboardPanel(_ panel: ClipboardPanelView, didDeleteEntry entryID: UUID) {
        triggerHapticIfEnabled()
        clipboardStore.delete(entryID: entryID)
        refreshClipboardUI()
    }

    func clipboardPanelDidClearRecent(_ panel: ClipboardPanelView) {
        triggerHapticIfEnabled()
        clipboardStore.clearUnpinned()
        refreshClipboardUI()
    }

    func clipboardPanelDidRequestClose(_ panel: ClipboardPanelView) {
        triggerHapticIfEnabled()
        setClipboardPanelVisible(false)
    }
}

private final class GradientBackdropView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    func setColors(_ colors: [UIColor]?) {
        guard let colors, let gradient = layer as? CAGradientLayer else {
            isHidden = true
            return
        }
        isHidden = false
        gradient.colors = colors.map(\.cgColor)
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
    }
}
