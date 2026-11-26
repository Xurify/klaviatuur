import UIKit
import KeyboardCore

protocol ClipboardPanelDelegate: AnyObject {
    func clipboardPanel(_ panel: ClipboardPanelView, didSelectText text: String)
    func clipboardPanel(_ panel: ClipboardPanelView, didTogglePin entryID: UUID)
    func clipboardPanel(_ panel: ClipboardPanelView, didDeleteEntry entryID: UUID)
    func clipboardPanelDidClearRecent(_ panel: ClipboardPanelView)
    func clipboardPanelDidRequestClose(_ panel: ClipboardPanelView)
}

final class ClipboardPanelView: UIView {
    weak var delegate: ClipboardPanelDelegate?

    private let headerStack = UIStackView()
    private let titleLabel = UILabel()
    private let clearRecentButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private let scrollView = UIScrollView()
    private let cardsStack = UIStackView()
    private let emptyStateLabel = UILabel()

    private var entries: [ClipboardEntry] = []
    private var theme: PixelKeyboardTheme = .pixelDark
    private var cardsAreStale = true
    private var hasFullAccess = true

    override var isHidden: Bool {
        didSet { rebuildCardsIfVisible() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureViews() {
        headerStack.axis = .horizontal
        headerStack.alignment = .center
        headerStack.spacing = 8
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerStack)

        titleLabel.text = "Clipboard"
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        headerStack.addArrangedSubview(titleLabel)

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerStack.addArrangedSubview(spacer)

        clearRecentButton.setTitle("Clear recent", for: .normal)
        clearRecentButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        clearRecentButton.addTarget(self, action: #selector(handleClearRecent), for: .touchUpInside)
        headerStack.addArrangedSubview(clearRecentButton)

        closeButton.setImage(UIImage(systemName: "keyboard.chevron.compact.down"), for: .normal)
        closeButton.addTarget(self, action: #selector(handleClose), for: .touchUpInside)
        headerStack.addArrangedSubview(closeButton)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsVerticalScrollIndicator = true
        addSubview(scrollView)

        cardsStack.axis = .vertical
        cardsStack.spacing = 8
        cardsStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(cardsStack)

        emptyStateLabel.text = "Copy text anywhere or pin snippets in the Klaviatuur app."
        emptyStateLabel.font = .systemFont(ofSize: 13, weight: .regular)
        emptyStateLabel.textAlignment = .center
        emptyStateLabel.numberOfLines = 2
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyStateLabel)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            headerStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            headerStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            headerStack.heightAnchor.constraint(equalToConstant: 30),

            scrollView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),

            cardsStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            cardsStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor),
            cardsStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor),
            cardsStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),

            emptyStateLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyStateLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            emptyStateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24)
        ])
    }

    func applyTheme(_ theme: PixelKeyboardTheme) {
        self.theme = theme
        backgroundColor = theme.canvasBackground
        titleLabel.textColor = theme.primaryGlyph
        clearRecentButton.tintColor = theme.accentTint
        closeButton.tintColor = theme.primaryGlyph
        emptyStateLabel.textColor = theme.secondaryHint
        cardsAreStale = true
        rebuildCardsIfVisible()
    }

    func updateEntries(_ entries: [ClipboardEntry]) {
        self.entries = entries
        cardsAreStale = true
        rebuildCardsIfVisible()
    }

    func setFullAccess(_ granted: Bool) {
        guard granted != hasFullAccess else { return }
        hasFullAccess = granted
        titleLabel.text = granted ? "Clipboard" : "Clipboard · read-only"
        emptyStateLabel.text = granted
            ? "Copy text anywhere or pin snippets in the Klaviatuur app."
            : "To save what you copy, turn on Full Access in Settings › General › Keyboard › Keyboards › Klaviatuur."
        emptyStateLabel.numberOfLines = granted ? 2 : 3
        cardsAreStale = true
        rebuildCardsIfVisible()
    }

    // Cards are a few views each; rebuilding them while the panel is hidden was wasted work
    // on every text change.
    private func rebuildCardsIfVisible() {
        guard !isHidden, cardsAreStale else { return }
        cardsAreStale = false
        rebuildCards()
    }

    func releaseCards() {
        for subview in cardsStack.arrangedSubviews {
            cardsStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        cardsAreStale = true
    }

    private func rebuildCards() {
        for subview in cardsStack.arrangedSubviews {
            cardsStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        emptyStateLabel.isHidden = !entries.isEmpty
        clearRecentButton.isHidden = !hasFullAccess || !entries.contains(where: { !$0.isPinned })

        // Render entries in pairs (2-column Pixel clipboard grid)
        var index = 0
        while index < entries.count {
            let rowStack = UIStackView()
            rowStack.axis = .horizontal
            rowStack.distribution = .fillEqually
            rowStack.spacing = 8

            rowStack.addArrangedSubview(makeCard(for: entries[index]))
            if index + 1 < entries.count {
                rowStack.addArrangedSubview(makeCard(for: entries[index + 1]))
            } else {
                rowStack.addArrangedSubview(UIView())
            }
            cardsStack.addArrangedSubview(rowStack)
            index += 2
        }
    }

    private func makeCard(for entry: ClipboardEntry) -> UIView {
        let container = UIView()
        container.backgroundColor = theme.clipboardCardBackground
        container.layer.cornerRadius = 10
        container.translatesAutoresizingMaskIntoConstraints = false
        container.heightAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true

        let textButton = UIButton(type: .system)
        textButton.contentHorizontalAlignment = .left
        textButton.contentVerticalAlignment = .top
        textButton.titleLabel?.font = .systemFont(ofSize: 13.5, weight: .regular)
        textButton.titleLabel?.numberOfLines = 3
        textButton.titleLabel?.lineBreakMode = .byTruncatingTail
        textButton.setTitleColor(theme.primaryGlyph, for: .normal)
        textButton.setTitle(entry.text, for: .normal)
        textButton.translatesAutoresizingMaskIntoConstraints = false
        textButton.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                self.delegate?.clipboardPanel(self, didSelectText: entry.text)
            },
            for: .touchUpInside
        )

        let pinButton = UIButton(type: .system)
        pinButton.setImage(
            UIImage(systemName: entry.isPinned ? "pin.fill" : "pin"),
            for: .normal
        )
        pinButton.tintColor = entry.isPinned ? theme.accentTint : theme.secondaryHint
        pinButton.translatesAutoresizingMaskIntoConstraints = false
        pinButton.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                self.delegate?.clipboardPanel(self, didTogglePin: entry.id)
            },
            for: .touchUpInside
        )

        let deleteButton = UIButton(type: .system)
        deleteButton.setImage(UIImage(systemName: "trash"), for: .normal)
        deleteButton.tintColor = theme.secondaryHint
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                self.delegate?.clipboardPanel(self, didDeleteEntry: entry.id)
            },
            for: .touchUpInside
        )

        pinButton.isHidden = !hasFullAccess
        deleteButton.isHidden = !hasFullAccess

        container.addSubview(textButton)
        container.addSubview(pinButton)
        container.addSubview(deleteButton)

        NSLayoutConstraint.activate([
            textButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            textButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            textButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            textButton.bottomAnchor.constraint(equalTo: pinButton.topAnchor, constant: -4),

            pinButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            pinButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            pinButton.widthAnchor.constraint(equalToConstant: 28),
            pinButton.heightAnchor.constraint(equalToConstant: 24),

            deleteButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            deleteButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            deleteButton.widthAnchor.constraint(equalToConstant: 28),
            deleteButton.heightAnchor.constraint(equalToConstant: 24)
        ])

        return container
    }

    @objc private func handleClearRecent() {
        delegate?.clipboardPanelDidClearRecent(self)
    }

    @objc private func handleClose() {
        delegate?.clipboardPanelDidRequestClose(self)
    }
}
