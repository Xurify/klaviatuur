import UIKit
import KeyboardCore

final class KeyPopupView: UIView {
    private let stackView = UIStackView()
    private var optionLabels: [UILabel] = []
    private(set) var variants: [String] = []
    private(set) var selectedIndex: Int = 0
    private var theme: PixelKeyboardTheme = .pixelDark

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.cornerRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: 3)
        layer.shadowRadius = 7
        layer.shadowOpacity = 0.28

        stackView.axis = .horizontal
        stackView.distribution = .fillEqually
        stackView.alignment = .fill
        stackView.spacing = 2
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showSingleCharacter(
        _ character: String,
        anchorFrame: CGRect,
        in containerBounds: CGRect,
        theme: PixelKeyboardTheme
    ) {
        showVariants(
            [character],
            anchorFrame: anchorFrame,
            in: containerBounds,
            theme: theme
        )
    }

    func showVariants(
        _ variants: [String],
        anchorFrame: CGRect,
        in containerBounds: CGRect,
        theme: PixelKeyboardTheme
    ) {
        self.theme = theme
        self.variants = variants
        self.selectedIndex = 0
        backgroundColor = theme.popupBackground
        layer.shadowColor = UIColor.black.cgColor

        // Shown on every tap, so labels are pooled rather than rebuilt; hidden arranged
        // subviews drop out of the stack's layout.
        while optionLabels.count < variants.count {
            let label = UILabel()
            label.textAlignment = .center
            label.layer.cornerRadius = 7
            label.layer.masksToBounds = true
            optionLabels.append(label)
            stackView.addArrangedSubview(label)
        }
        let font: UIFont = variants.count == 1
            ? .systemFont(ofSize: 26, weight: .regular)
            : .systemFont(ofSize: 21, weight: .medium)
        for (index, label) in optionLabels.enumerated() {
            let isUsed = index < variants.count
            label.isHidden = !isUsed
            if isUsed {
                label.text = variants[index]
                label.font = font
            }
        }

        let itemWidth = max(anchorFrame.width * 1.12, 38)
        let totalWidth = min(
            containerBounds.width - 8,
            itemWidth * CGFloat(variants.count) + 8
        )
        let popupHeight: CGFloat = variants.count == 1 ? 54 : 50
        var originX = anchorFrame.midX - totalWidth * 0.5
        originX = max(4, min(originX, containerBounds.width - totalWidth - 4))
        let originY = max(-popupHeight + 6, anchorFrame.minY - popupHeight - 6)

        frame = CGRect(x: originX, y: originY, width: totalWidth, height: popupHeight)
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
        updateSelectionAppearance()
        isHidden = false
    }

    func updateSelection(forTouchX touchX: CGFloat) {
        guard variants.count > 1, bounds.width > 0 else { return }
        let localX = touchX - frame.minX
        let fraction = max(0, min(0.999, localX / frame.width))
        let newIndex = Int(fraction * CGFloat(variants.count))
        if newIndex != selectedIndex {
            selectedIndex = newIndex
            updateSelectionAppearance()
        }
    }

    var selectedVariant: String? {
        guard selectedIndex >= 0, selectedIndex < variants.count else { return nil }
        return variants[selectedIndex]
    }

    func hide() {
        isHidden = true
        variants = []
        selectedIndex = 0
    }

    private func updateSelectionAppearance() {
        let highlightSelected = variants.count > 1
        for (index, label) in optionLabels.enumerated() {
            if highlightSelected && index == selectedIndex {
                label.backgroundColor = theme.popupSelectedPill
                label.textColor = theme.popupSelectedForeground
            } else {
                label.backgroundColor = .clear
                label.textColor = theme.primaryGlyph
            }
        }
    }
}
