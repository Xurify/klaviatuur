import UIKit
import KeyboardCore

final class KeyCapView: UIView {
    private let backgroundView = UIView()
    private let primaryLabel = UILabel()
    private let secondaryHintLabel = UILabel()
    private let iconImageView = UIImageView()

    private(set) var keySpec: KeySpec?
    private var theme: PixelKeyboardTheme = .pixelDark
    private var shiftState: ShiftState = .lowercase

    private struct ShapeSignature: Equatable {
        let cornerRadius: CGFloat
        let returnKeyIsPill: Bool
        let showsKeyShadow: Bool
    }

    private var shapeSignature: ShapeSignature?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false

        backgroundView.layer.cornerRadius = 6.5
        backgroundView.layer.shadowOffset = CGSize(width: 0, height: 1)
        backgroundView.layer.shadowRadius = 0.5
        backgroundView.layer.shadowOpacity = 1.0
        addSubview(backgroundView)

        primaryLabel.textAlignment = .center
        primaryLabel.adjustsFontSizeToFitWidth = true
        primaryLabel.minimumScaleFactor = 0.72
        backgroundView.addSubview(primaryLabel)

        secondaryHintLabel.textAlignment = .right
        secondaryHintLabel.font = .systemFont(ofSize: 9.5, weight: .medium)
        backgroundView.addSubview(secondaryHintLabel)

        iconImageView.contentMode = .scaleAspectFit
        backgroundView.addSubview(iconImageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let keyInsetX: CGFloat = 2.5
        let keyInsetY: CGFloat = 3.5
        backgroundView.frame = bounds.insetBy(dx: keyInsetX, dy: keyInsetY)
        let isPillReturn = keySpec?.kind == .returnKey && theme.returnKeyIsPill
        let radius = isPillReturn
            ? backgroundView.bounds.height / 2
            : min(theme.keyCornerRadius, backgroundView.bounds.height / 2)
        backgroundView.layer.cornerRadius = radius
        // An explicit path keeps Core Animation from rendering each key offscreen to find its shadow.
        backgroundView.layer.shadowPath = theme.showsKeyShadow
            ? UIBezierPath(roundedRect: backgroundView.bounds, cornerRadius: radius).cgPath
            : nil
        primaryLabel.frame = backgroundView.bounds.insetBy(dx: 3, dy: 2)
        secondaryHintLabel.frame = CGRect(
            x: backgroundView.bounds.width - 15,
            y: 2,
            width: 12,
            height: 11
        )
        let iconSize: CGFloat = min(backgroundView.bounds.width, backgroundView.bounds.height) * 0.44
        iconImageView.frame = CGRect(
            x: (backgroundView.bounds.width - iconSize) * 0.5,
            y: (backgroundView.bounds.height - iconSize) * 0.5,
            width: iconSize,
            height: iconSize
        )
    }

    func configure(
        keySpec: KeySpec,
        shiftState: ShiftState,
        theme: PixelKeyboardTheme,
        highlighted: Bool
    ) {
        self.keySpec = keySpec
        self.shiftState = shiftState
        self.theme = theme

        let previousShape = shapeSignature
        backgroundView.layer.shadowColor = theme.keyShadow.cgColor
        backgroundView.layer.shadowOpacity = theme.showsKeyShadow ? 1 : 0
        setHighlighted(highlighted)
        shapeSignature = ShapeSignature(
            cornerRadius: theme.keyCornerRadius,
            returnKeyIsPill: theme.returnKeyIsPill,
            showsKeyShadow: theme.showsKeyShadow
        )
        if shapeSignature != previousShape {
            setNeedsLayout()
        }

        switch keySpec.kind {
        case .shift:
            primaryLabel.isHidden = true
            secondaryHintLabel.isHidden = true
            iconImageView.isHidden = false
            let symbolName: String
            switch shiftState {
            case .lowercase:
                symbolName = "shift"
            case .shifted:
                symbolName = "shift.fill"
            case .capsLock:
                symbolName = "capslock.fill"
            }
            iconImageView.image = UIImage(systemName: symbolName)
            iconImageView.tintColor = shiftState.isUppercased ? theme.accentTint : theme.utilityGlyph

        case .backspace:
            primaryLabel.isHidden = true
            secondaryHintLabel.isHidden = true
            iconImageView.isHidden = false
            iconImageView.image = UIImage(systemName: "delete.left")
            iconImageView.tintColor = theme.utilityGlyph

        case .globe:
            primaryLabel.isHidden = true
            secondaryHintLabel.isHidden = true
            iconImageView.isHidden = false
            iconImageView.image = UIImage(systemName: "globe")
            iconImageView.tintColor = theme.utilityGlyph

        case .returnKey:
            secondaryHintLabel.isHidden = true
            let usesIcon = keySpec.primaryLabel == "↵"
            iconImageView.isHidden = !usesIcon
            primaryLabel.isHidden = usesIcon
            iconImageView.image = usesIcon ? UIImage(systemName: "return.left") : nil
            iconImageView.tintColor = theme.returnKeyForeground
            primaryLabel.text = keySpec.primaryLabel
            primaryLabel.font = .systemFont(ofSize: 15, weight: .semibold)
            primaryLabel.textColor = theme.returnKeyForeground

        case .space:
            iconImageView.isHidden = true
            secondaryHintLabel.isHidden = true
            primaryLabel.isHidden = false
            primaryLabel.text = keySpec.primaryLabel
            primaryLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
            primaryLabel.textColor = theme.secondaryHint

        case .modeSwitch:
            iconImageView.isHidden = true
            secondaryHintLabel.isHidden = true
            primaryLabel.isHidden = false
            primaryLabel.text = keySpec.primaryLabel
            primaryLabel.font = .systemFont(ofSize: 14.5, weight: .medium)
            primaryLabel.textColor = theme.utilityGlyph

        case .number:
            iconImageView.isHidden = true
            secondaryHintLabel.isHidden = true
            primaryLabel.isHidden = false
            primaryLabel.text = keySpec.primaryLabel
            primaryLabel.font = .systemFont(ofSize: 18, weight: .regular)
            primaryLabel.textColor = theme.primaryGlyph

        case .character, .punctuation:
            iconImageView.isHidden = true
            primaryLabel.isHidden = false
            primaryLabel.text = keySpec.displayLabel(shiftState: shiftState)
            primaryLabel.font = .systemFont(ofSize: 22, weight: .regular)
            primaryLabel.textColor = theme.primaryGlyph

            if let hint = keySpec.secondaryHint {
                secondaryHintLabel.isHidden = false
                secondaryHintLabel.text = hint
                secondaryHintLabel.textColor = theme.secondaryHint
            } else {
                secondaryHintLabel.isHidden = true
            }
        }
    }

    func setHighlighted(_ highlighted: Bool) {
        guard let keySpec else { return }
        switch keySpec.kind {
        case .returnKey:
            backgroundView.backgroundColor = highlighted
                ? theme.returnKeyHighlighted
                : theme.returnKeyBackground
        case .shift, .backspace, .modeSwitch, .globe:
            backgroundView.backgroundColor = highlighted
                ? theme.utilityKeyHighlighted
                : theme.utilityKeyBackground
        case .space:
            backgroundView.backgroundColor = highlighted
                ? theme.letterKeyHighlighted
                : theme.spaceKeyBackground
        case .character, .number, .punctuation:
            backgroundView.backgroundColor = highlighted
                ? theme.letterKeyHighlighted
                : theme.letterKeyBackground
        }
    }
}
