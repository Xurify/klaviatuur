import UIKit
import KeyboardCore

protocol SuggestionToolbarDelegate: AnyObject {
    func suggestionToolbar(_ toolbar: SuggestionToolbarView, didSelectCandidate candidate: SuggestionCandidate)
    func suggestionToolbarDidToggleClipboard(_ toolbar: SuggestionToolbarView)
    func suggestionToolbarDidTapQuickPaste(_ toolbar: SuggestionToolbarView)
    func suggestionToolbarDidTapLanguageCycle(_ toolbar: SuggestionToolbarView)
}

final class SuggestionToolbarView: UIView {
    weak var delegate: SuggestionToolbarDelegate?

    private let clipboardButton = UIButton(type: .system)
    private let languageBadgeButton = UIButton(type: .system)
    private let suggestionsStack = UIStackView()
    private let quickPasteButton = UIButton(type: .system)
    private var slotButtons: [UIButton] = []

    private var currentCandidates: [SuggestionCandidate] = []
    private var isQuickPasteAvailable = false
    private var lastResult = SuggestionResult.empty
    private var theme: PixelKeyboardTheme = .pixelDark
    private var isClipboardActive: Bool = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureViews() {
        quickPasteButton.setTitle("Paste copied text", for: .normal)
        clipboardButton.translatesAutoresizingMaskIntoConstraints = false
        clipboardButton.setImage(UIImage(systemName: "doc.on.clipboard"), for: .normal)
        clipboardButton.addTarget(self, action: #selector(handleClipboardTap), for: .touchUpInside)
        addSubview(clipboardButton)

        languageBadgeButton.translatesAutoresizingMaskIntoConstraints = false
        languageBadgeButton.titleLabel?.font = .systemFont(ofSize: 11, weight: .semibold)
        languageBadgeButton.layer.cornerRadius = 6
        languageBadgeButton.contentEdgeInsets = UIEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        languageBadgeButton.addTarget(self, action: #selector(handleLanguageCycleTap), for: .touchUpInside)
        addSubview(languageBadgeButton)

        suggestionsStack.axis = .horizontal
        suggestionsStack.distribution = .fillEqually
        suggestionsStack.alignment = .fill
        suggestionsStack.spacing = 4
        suggestionsStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(suggestionsStack)

        for slotIndex in 0..<3 {
            let button = UIButton(type: .system)
            button.tag = slotIndex
            button.titleLabel?.font = .systemFont(ofSize: 15, weight: .regular)
            button.titleLabel?.lineBreakMode = .byTruncatingTail
            button.layer.cornerRadius = 8
            button.addTarget(self, action: #selector(handleSuggestionTap(_:)), for: .touchUpInside)
            slotButtons.append(button)
            suggestionsStack.addArrangedSubview(button)
        }

        quickPasteButton.translatesAutoresizingMaskIntoConstraints = false
        quickPasteButton.isHidden = true
        quickPasteButton.layer.cornerRadius = 14
        quickPasteButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        quickPasteButton.titleLabel?.lineBreakMode = .byTruncatingTail
        quickPasteButton.contentEdgeInsets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        quickPasteButton.addTarget(self, action: #selector(handleQuickPasteTap), for: .touchUpInside)
        addSubview(quickPasteButton)

        NSLayoutConstraint.activate([
            clipboardButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            clipboardButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            clipboardButton.widthAnchor.constraint(equalToConstant: 36),
            clipboardButton.heightAnchor.constraint(equalToConstant: 34),

            languageBadgeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            languageBadgeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            languageBadgeButton.heightAnchor.constraint(equalToConstant: 26),

            suggestionsStack.leadingAnchor.constraint(equalTo: clipboardButton.trailingAnchor, constant: 4),
            suggestionsStack.trailingAnchor.constraint(equalTo: languageBadgeButton.leadingAnchor, constant: -4),
            suggestionsStack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            suggestionsStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),

            quickPasteButton.centerXAnchor.constraint(equalTo: suggestionsStack.centerXAnchor),
            quickPasteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            quickPasteButton.widthAnchor.constraint(lessThanOrEqualTo: suggestionsStack.widthAnchor, constant: -8),
            quickPasteButton.heightAnchor.constraint(equalToConstant: 30)
        ])
    }

    func applyTheme(_ theme: PixelKeyboardTheme) {
        self.theme = theme
        backgroundColor = theme.toolbarBackground
        clipboardButton.tintColor = isClipboardActive ? theme.accentTint : theme.secondaryHint
        languageBadgeButton.backgroundColor = theme.utilityKeyBackground
        languageBadgeButton.setTitleColor(theme.primaryGlyph, for: .normal)
        quickPasteButton.backgroundColor = theme.suggestionPrimaryPill
        quickPasteButton.setTitleColor(theme.primaryGlyph, for: .normal)
        renderSuggestions()
    }

    func updateLanguageTag(_ tag: String) {
        languageBadgeButton.setTitle(tag, for: .normal)
    }

    func setClipboardActive(_ active: Bool) {
        isClipboardActive = active
        clipboardButton.tintColor = active ? theme.accentTint : theme.secondaryHint
    }

    func updateSuggestions(_ result: SuggestionResult) {
        lastResult = result
        // Until the user types, a fresh copy is a likelier next action than a predicted word.
        currentCandidates = result.isPrediction && isQuickPasteAvailable ? [] : result.suggestions
        if !currentCandidates.isEmpty {
            quickPasteButton.isHidden = true
            suggestionsStack.isHidden = false
        } else if isQuickPasteAvailable {
            suggestionsStack.isHidden = true
            quickPasteButton.isHidden = false
        } else {
            quickPasteButton.isHidden = true
            suggestionsStack.isHidden = false
        }
        renderSuggestions()
    }

    /// Reading the copied text itself would trigger iOS's "Allow Paste" prompt every time the
    /// keyboard opens, so the chip only says something is there and reads it on tap.
    func setQuickPasteAvailable(_ available: Bool) {
        isQuickPasteAvailable = available
        updateSuggestions(lastResult)
    }

    private func renderSuggestions() {
        // Pixel Gboard places the primary suggestion in the center slot when 2+ suggestions exist
        var arranged: [SuggestionCandidate?] = [nil, nil, nil]
        if currentCandidates.count == 1 {
            arranged[1] = currentCandidates[0]
        } else if currentCandidates.count == 2 {
            arranged[1] = currentCandidates[0]
            arranged[0] = currentCandidates[1]
        } else if currentCandidates.count >= 3 {
            arranged[1] = currentCandidates[0]
            arranged[0] = currentCandidates[1]
            arranged[2] = currentCandidates[2]
        }

        for (slotIndex, button) in slotButtons.enumerated() {
            guard let candidate = arranged[slotIndex] else {
                button.setTitle(nil, for: .normal)
                button.backgroundColor = .clear
                button.isEnabled = false
                continue
            }
            button.isEnabled = true
            button.setTitle(candidate.text, for: .normal)
            if candidate.isAutocorrectPrimary {
                button.titleLabel?.font = .systemFont(ofSize: 15.5, weight: .semibold)
                button.backgroundColor = theme.suggestionPrimaryPill
                button.setTitleColor(theme.primaryGlyph, for: .normal)
            } else {
                button.titleLabel?.font = .systemFont(ofSize: 15, weight: .regular)
                button.backgroundColor = .clear
                button.setTitleColor(theme.primaryGlyph, for: .normal)
            }
        }
    }

    @objc private func handleSuggestionTap(_ sender: UIButton) {
        guard let title = sender.title(for: .normal),
              let candidate = currentCandidates.first(where: { $0.text == title })
        else {
            return
        }
        delegate?.suggestionToolbar(self, didSelectCandidate: candidate)
    }

    @objc private func handleClipboardTap() {
        delegate?.suggestionToolbarDidToggleClipboard(self)
    }

    @objc private func handleQuickPasteTap() {
        guard isQuickPasteAvailable else { return }
        setQuickPasteAvailable(false)
        delegate?.suggestionToolbarDidTapQuickPaste(self)
    }

    @objc private func handleLanguageCycleTap() {
        delegate?.suggestionToolbarDidTapLanguageCycle(self)
    }
}
