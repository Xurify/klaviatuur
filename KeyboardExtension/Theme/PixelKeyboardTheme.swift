import UIKit
import KeyboardCore

struct PixelKeyboardTheme {
    let isDark: Bool
    let canvasBackground: UIColor
    let toolbarBackground: UIColor
    let letterKeyBackground: UIColor
    let letterKeyHighlighted: UIColor
    let spaceKeyBackground: UIColor
    let utilityKeyBackground: UIColor
    let utilityKeyHighlighted: UIColor
    let utilityGlyph: UIColor
    let returnKeyBackground: UIColor
    let returnKeyHighlighted: UIColor
    let returnKeyForeground: UIColor
    let primaryGlyph: UIColor
    let secondaryHint: UIColor
    let keyShadow: UIColor
    let popupBackground: UIColor
    let popupSelectedPill: UIColor
    let popupSelectedForeground: UIColor
    let suggestionDivider: UIColor
    let suggestionPrimaryPill: UIColor
    let clipboardCardBackground: UIColor
    let accentTint: UIColor

    let keyCornerRadius: CGFloat
    let returnKeyIsPill: Bool
    let showsKeyShadow: Bool
    let backdropGradient: [UIColor]?

    static func resolved(
        style: KeyboardThemeStyle,
        appearance: UIKeyboardAppearance,
        traitCollection: UITraitCollection
    ) -> PixelKeyboardTheme {
        let dark: Bool
        switch appearance {
        case .dark:
            dark = true
        case .light:
            dark = false
        default:
            dark = traitCollection.userInterfaceStyle == .dark
        }
        switch style {
        case .borderless: return dark ? .borderlessDark : .borderlessLight
        case .tonal: return dark ? .tonalDark : .tonalLight
        case .vivid: return dark ? .vividDark : .vividLight
        case .glass: return dark ? .glassDark : .glassLight
        }
    }

    static let pixelDark = tonalDark
    static let pixelLight = tonalLight

    static let borderlessDark = PixelKeyboardTheme(
        isDark: true,
        canvasBackground: UIColor(hex: 0x1D2024),
        toolbarBackground: UIColor(hex: 0x1D2024),
        letterKeyBackground: .clear,
        letterKeyHighlighted: UIColor(white: 1, alpha: 0.12),
        spaceKeyBackground: UIColor(white: 1, alpha: 0.09),
        utilityKeyBackground: .clear,
        utilityKeyHighlighted: UIColor(white: 1, alpha: 0.12),
        utilityGlyph: UIColor(hex: 0xA8C7FA),
        returnKeyBackground: UIColor(hex: 0xA8C7FA),
        returnKeyHighlighted: UIColor(hex: 0x8FB4F0),
        returnKeyForeground: UIColor(hex: 0x062E6F),
        primaryGlyph: UIColor(hex: 0xE8E9ED),
        secondaryHint: UIColor(hex: 0xA9ADB5),
        keyShadow: .clear,
        popupBackground: UIColor(hex: 0x33373D),
        popupSelectedPill: UIColor(hex: 0xA8C7FA),
        popupSelectedForeground: UIColor(hex: 0x062E6F),
        suggestionDivider: UIColor(white: 1, alpha: 0.12),
        suggestionPrimaryPill: UIColor(white: 1, alpha: 0.09),
        clipboardCardBackground: UIColor(hex: 0x2A2E33),
        accentTint: UIColor(hex: 0xA8C7FA),
        keyCornerRadius: 10,
        returnKeyIsPill: true,
        showsKeyShadow: false,
        backdropGradient: nil
    )

    static let borderlessLight = PixelKeyboardTheme(
        isDark: false,
        canvasBackground: UIColor(hex: 0xEEF1F6),
        toolbarBackground: UIColor(hex: 0xEEF1F6),
        letterKeyBackground: .clear,
        letterKeyHighlighted: UIColor(white: 0, alpha: 0.08),
        spaceKeyBackground: UIColor(white: 0, alpha: 0.06),
        utilityKeyBackground: .clear,
        utilityKeyHighlighted: UIColor(white: 0, alpha: 0.08),
        utilityGlyph: UIColor(hex: 0x0B57D0),
        returnKeyBackground: UIColor(hex: 0x0B57D0),
        returnKeyHighlighted: UIColor(hex: 0x0842A0),
        returnKeyForeground: .white,
        primaryGlyph: UIColor(hex: 0x1F1F1F),
        secondaryHint: UIColor(hex: 0x5F6368),
        keyShadow: .clear,
        popupBackground: .white,
        popupSelectedPill: UIColor(hex: 0x0B57D0),
        popupSelectedForeground: .white,
        suggestionDivider: UIColor(white: 0, alpha: 0.12),
        suggestionPrimaryPill: UIColor(white: 0, alpha: 0.06),
        clipboardCardBackground: .white,
        accentTint: UIColor(hex: 0x0B57D0),
        keyCornerRadius: 10,
        returnKeyIsPill: true,
        showsKeyShadow: false,
        backdropGradient: nil
    )

    static let tonalDark = PixelKeyboardTheme(
        isDark: true,
        canvasBackground: UIColor(hex: 0x1D2024),
        toolbarBackground: UIColor(hex: 0x1D2024),
        letterKeyBackground: UIColor(hex: 0x33373D),
        letterKeyHighlighted: UIColor(hex: 0x4A4F57),
        spaceKeyBackground: UIColor(hex: 0x33373D),
        utilityKeyBackground: UIColor(hex: 0x2B3A4F),
        utilityKeyHighlighted: UIColor(hex: 0x3A4D66),
        utilityGlyph: UIColor(hex: 0xD3E3FD),
        returnKeyBackground: UIColor(hex: 0xA8C7FA),
        returnKeyHighlighted: UIColor(hex: 0x8FB4F0),
        returnKeyForeground: UIColor(hex: 0x062E6F),
        primaryGlyph: UIColor(hex: 0xE3E3E8),
        secondaryHint: UIColor(hex: 0xA9ADB5),
        keyShadow: .clear,
        popupBackground: UIColor(hex: 0x44474E),
        popupSelectedPill: UIColor(hex: 0xA8C7FA),
        popupSelectedForeground: UIColor(hex: 0x062E6F),
        suggestionDivider: UIColor(white: 1, alpha: 0.12),
        suggestionPrimaryPill: UIColor(hex: 0x2B3A4F),
        clipboardCardBackground: UIColor(hex: 0x2A2E33),
        accentTint: UIColor(hex: 0xA8C7FA),
        keyCornerRadius: 10,
        returnKeyIsPill: true,
        showsKeyShadow: false,
        backdropGradient: nil
    )

    static let tonalLight = PixelKeyboardTheme(
        isDark: false,
        canvasBackground: UIColor(hex: 0xE8EDF5),
        toolbarBackground: UIColor(hex: 0xE8EDF5),
        letterKeyBackground: UIColor(hex: 0xFDFCFF),
        letterKeyHighlighted: UIColor(hex: 0xDFE5EE),
        spaceKeyBackground: UIColor(hex: 0xFDFCFF),
        utilityKeyBackground: UIColor(hex: 0xD3E3FD),
        utilityKeyHighlighted: UIColor(hex: 0xBCD2F7),
        utilityGlyph: UIColor(hex: 0x041E49),
        returnKeyBackground: UIColor(hex: 0x0B57D0),
        returnKeyHighlighted: UIColor(hex: 0x0842A0),
        returnKeyForeground: .white,
        primaryGlyph: UIColor(hex: 0x1F1F1F),
        secondaryHint: UIColor(hex: 0x5F6368),
        keyShadow: .clear,
        popupBackground: .white,
        popupSelectedPill: UIColor(hex: 0x0B57D0),
        popupSelectedForeground: .white,
        suggestionDivider: UIColor(white: 0, alpha: 0.12),
        suggestionPrimaryPill: UIColor(hex: 0xD3E3FD),
        clipboardCardBackground: .white,
        accentTint: UIColor(hex: 0x0B57D0),
        keyCornerRadius: 10,
        returnKeyIsPill: true,
        showsKeyShadow: false,
        backdropGradient: nil
    )

    static let vividDark = PixelKeyboardTheme(
        isDark: true,
        canvasBackground: UIColor(hex: 0x0F2A20),
        toolbarBackground: UIColor(hex: 0x0F2A20),
        letterKeyBackground: UIColor(hex: 0x1E4636),
        letterKeyHighlighted: UIColor(hex: 0x2D5C48),
        spaceKeyBackground: UIColor(hex: 0x1E4636),
        utilityKeyBackground: UIColor(hex: 0x2F6A51),
        utilityKeyHighlighted: UIColor(hex: 0x3B7D61),
        utilityGlyph: UIColor(hex: 0xD2F7E4),
        returnKeyBackground: UIColor(hex: 0x8FE0B8),
        returnKeyHighlighted: UIColor(hex: 0x74CDA2),
        returnKeyForeground: UIColor(hex: 0x00391F),
        primaryGlyph: UIColor(hex: 0xE2F5EA),
        secondaryHint: UIColor(hex: 0xA6CDB9),
        keyShadow: UIColor(white: 0, alpha: 0.35),
        popupBackground: UIColor(hex: 0x2F6A51),
        popupSelectedPill: UIColor(hex: 0x8FE0B8),
        popupSelectedForeground: UIColor(hex: 0x00391F),
        suggestionDivider: UIColor(white: 1, alpha: 0.12),
        suggestionPrimaryPill: UIColor(hex: 0x2F6A51),
        clipboardCardBackground: UIColor(hex: 0x1E4636),
        accentTint: UIColor(hex: 0x8FE0B8),
        keyCornerRadius: 14,
        returnKeyIsPill: true,
        showsKeyShadow: true,
        backdropGradient: nil
    )

    static let vividLight = PixelKeyboardTheme(
        isDark: false,
        canvasBackground: UIColor(hex: 0xCFEADB),
        toolbarBackground: UIColor(hex: 0xCFEADB),
        letterKeyBackground: UIColor(hex: 0xEAF7EF),
        letterKeyHighlighted: UIColor(hex: 0xD2EBDD),
        spaceKeyBackground: UIColor(hex: 0xEAF7EF),
        utilityKeyBackground: UIColor(hex: 0x9ED7BB),
        utilityKeyHighlighted: UIColor(hex: 0x86C9A8),
        utilityGlyph: UIColor(hex: 0x00391F),
        returnKeyBackground: UIColor(hex: 0x1B6B4A),
        returnKeyHighlighted: UIColor(hex: 0x145538),
        returnKeyForeground: .white,
        primaryGlyph: UIColor(hex: 0x0F2A1F),
        secondaryHint: UIColor(hex: 0x3D5C4F),
        keyShadow: UIColor(red: 0.0, green: 0.22, blue: 0.12, alpha: 0.25),
        popupBackground: UIColor(hex: 0xEAF7EF),
        popupSelectedPill: UIColor(hex: 0x1B6B4A),
        popupSelectedForeground: .white,
        suggestionDivider: UIColor(white: 0, alpha: 0.12),
        suggestionPrimaryPill: UIColor(hex: 0x9ED7BB),
        clipboardCardBackground: UIColor(hex: 0xEAF7EF),
        accentTint: UIColor(hex: 0x1B6B4A),
        keyCornerRadius: 14,
        returnKeyIsPill: true,
        showsKeyShadow: true,
        backdropGradient: nil
    )

    static let glassDark = PixelKeyboardTheme(
        isDark: true,
        canvasBackground: .clear,
        toolbarBackground: .clear,
        letterKeyBackground: UIColor(white: 1, alpha: 0.13),
        letterKeyHighlighted: UIColor(white: 1, alpha: 0.28),
        spaceKeyBackground: UIColor(white: 1, alpha: 0.13),
        utilityKeyBackground: UIColor(white: 1, alpha: 0.06),
        utilityKeyHighlighted: UIColor(white: 1, alpha: 0.18),
        utilityGlyph: UIColor(hex: 0xF2F2F7),
        returnKeyBackground: UIColor(hex: 0xF2F2F7),
        returnKeyHighlighted: UIColor(hex: 0xD1D1D6),
        returnKeyForeground: UIColor(hex: 0x111111),
        primaryGlyph: .white,
        secondaryHint: UIColor(red: 0.92, green: 0.92, blue: 0.96, alpha: 0.62),
        keyShadow: UIColor(white: 0, alpha: 0.3),
        popupBackground: UIColor(hex: 0x3A3550),
        popupSelectedPill: UIColor(hex: 0xF2F2F7),
        popupSelectedForeground: UIColor(hex: 0x111111),
        suggestionDivider: UIColor(white: 1, alpha: 0.14),
        suggestionPrimaryPill: UIColor(white: 1, alpha: 0.16),
        clipboardCardBackground: UIColor(white: 1, alpha: 0.1),
        accentTint: UIColor(hex: 0xC9B8FF),
        keyCornerRadius: 13,
        returnKeyIsPill: false,
        // A shadow would show through the translucent fill and muddy it.
        showsKeyShadow: false,
        backdropGradient: [UIColor(hex: 0x3A2F5C), UIColor(hex: 0x14141C), UIColor(hex: 0x1F4A5A)]
    )

    static let glassLight = PixelKeyboardTheme(
        isDark: false,
        canvasBackground: .clear,
        toolbarBackground: .clear,
        letterKeyBackground: UIColor(white: 1, alpha: 0.62),
        letterKeyHighlighted: UIColor(white: 1, alpha: 0.35),
        spaceKeyBackground: UIColor(white: 1, alpha: 0.62),
        utilityKeyBackground: UIColor(white: 1, alpha: 0.3),
        utilityKeyHighlighted: UIColor(white: 1, alpha: 0.6),
        utilityGlyph: UIColor(hex: 0x1C1C1E),
        returnKeyBackground: UIColor(hex: 0x1C1C1E),
        returnKeyHighlighted: UIColor(hex: 0x3A3A3C),
        returnKeyForeground: .white,
        primaryGlyph: UIColor(hex: 0x111111),
        secondaryHint: UIColor(red: 0.24, green: 0.24, blue: 0.26, alpha: 0.7),
        keyShadow: UIColor(white: 0, alpha: 0.12),
        popupBackground: .white,
        popupSelectedPill: UIColor(hex: 0x1C1C1E),
        popupSelectedForeground: .white,
        suggestionDivider: UIColor(white: 0, alpha: 0.1),
        suggestionPrimaryPill: UIColor(white: 1, alpha: 0.55),
        clipboardCardBackground: UIColor(white: 1, alpha: 0.6),
        accentTint: UIColor(hex: 0x5B3FD0),
        keyCornerRadius: 13,
        returnKeyIsPill: false,
        // A shadow would show through the translucent fill and muddy it.
        showsKeyShadow: false,
        backdropGradient: [UIColor(hex: 0xE6E0F7), UIColor(hex: 0xF4F5F8), UIColor(hex: 0xD8ECEF)]
    )
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
