import SwiftUI
import UIKit

// MARK: - Theme
//
// Every color, font size, corner radius and spacing used by the built-in browser UI
// (the expanded panel and the floating card) comes from here. The defaults use system
// colors and materials, so the UI looks reasonable in light and dark mode without any
// configuration. Hosts can change any field:
//
//     var theme = IsletTheme()
//     theme.accent = .orange
//     theme.corners.panel = 24
//     RootView().isletTheme(theme)

/// Visual settings for the built-in browser panel and floating card.
public struct IsletTheme {

    // MARK: Colors

    /// Progress bar, primary buttons, card icon.
    public var accent: Color = .accentColor
    /// Titles and icons.
    public var textStrong: Color = .primary
    /// Secondary text (page name, notes).
    public var textSoft: Color = .secondary
    /// Least prominent text and icons.
    public var textFaint: Color = Color.secondary.opacity(0.75)
    /// Hairline borders.
    public var stroke: Color = Color.primary.opacity(0.14)
    /// Dimming layer behind the expanded panel.
    public var scrim: Color = Color.black.opacity(0.28)

    /// Background material of the expanded panel. nil = use `panelFill` only.
    public var panelMaterial: Material? = .regularMaterial
    /// Fill drawn on top of `panelMaterial` (or alone when it is nil).
    public var panelFill: Color = .clear
    /// Background material of the floating card / strip. nil = use `cardFill` only.
    public var cardMaterial: Material? = .thinMaterial
    /// Fill drawn on top of `cardMaterial` (or alone when it is nil).
    public var cardFill: Color = .clear
    /// Background of the toast shown inside the panel.
    public var toastMaterial: Material? = .thickMaterial

    // MARK: Type

    /// Font sizes in points. The UI picks a role, `font(_:_:)` turns it into a `Font`.
    public struct TypeScale {
        public var tiny: CGFloat = 10
        public var small: CGFloat = 11
        public var caption: CGFloat = 12
        public var footnote: CGFloat = 13
        public var body: CGFloat = 14
        public var callout: CGFloat = 15
        public var subhead: CGFloat = 16
        public var title3: CGFloat = 18
        public var display: CGFloat = 30
        public init() {}
    }

    public var type = TypeScale()
    /// Builds a font from a size and weight. Replace it to use a custom typeface.
    public var makeFont: (_ size: CGFloat, _ weight: Font.Weight) -> Font = { size, weight in
        .system(size: size, weight: weight)
    }

    // MARK: Shape and spacing

    public struct Corners {
        /// Expanded panel.
        public var panel: CGFloat = 18
        /// Floating card.
        public var card: CGFloat = 20
        /// Collapsed strip.
        public var strip: CGFloat = 15
        /// The scaled-down web view inside the card.
        public var webWindow: CGFloat = 12
        public init() {}
    }

    public struct Spacing {
        public var xxs: CGFloat = 2
        public var xs: CGFloat = 4
        public var s: CGFloat = 6
        public var m: CGFloat = 8
        public var ml: CGFloat = 10
        public var l: CGFloat = 12
        public var xl: CGFloat = 14
        public var huge: CGFloat = 24
        /// Card padding.
        public var cardPadH: CGFloat = 15
        public var cardPadV: CGFloat = 13
        /// Strip padding.
        public var stripPadH: CGFloat = 13
        public var stripPadV: CGFloat = 8
        /// Gap between the card and the screen edges.
        public var cardSideGap: CGFloat = 10
        public init() {}
    }

    public var corners = Corners()
    public var spacing = Spacing()
    /// Border width.
    public var hairline: CGFloat = 0.8

    // MARK: Motion

    /// Card appear / fold animation.
    public var cardAnimation: Animation = .spring(response: 0.32, dampingFraction: 0.78)
    /// Panel expand / collapse animation.
    public var panelAnimation: Animation = .easeOut(duration: 0.22)

    // MARK: Icons (SF Symbols)

    /// Icon on the card header and the strip.
    public var browserIcon: String = "safari"

    public init() {}

    /// The default theme.
    public static let standard = IsletTheme()

    /// A font of the given size and weight, built with `makeFont`.
    public func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        makeFont(size, weight)
    }
}

// MARK: - Environment

private struct IsletThemeKey: EnvironmentKey {
    static let defaultValue = IsletTheme.standard
}

extension EnvironmentValues {
    /// The theme used by Islet views below this point.
    public var isletTheme: IsletTheme {
        get { self[IsletThemeKey.self] }
        set { self[IsletThemeKey.self] = newValue }
    }
}

extension View {
    /// Sets the theme for Islet views inside this view.
    public func isletTheme(_ theme: IsletTheme) -> some View {
        environment(\.isletTheme, theme)
    }
}

// MARK: - Shared drawing helpers (internal)

extension View {
    /// Rounded background made of an optional material plus a fill, with a hairline border.
    func isletSurface(_ theme: IsletTheme, material: Material?, fill: Color, corner: CGFloat,
                      border: Bool = true) -> some View {
        background {
            ZStack {
                if let material {
                    RoundedRectangle(cornerRadius: corner, style: .continuous).fill(material)
                }
                RoundedRectangle(cornerRadius: corner, style: .continuous).fill(fill)
            }
        }
        .overlay {
            if border {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(theme.stroke, lineWidth: theme.hairline)
            }
        }
    }

    /// Capsule background, same recipe as `isletSurface`.
    func isletPill(_ theme: IsletTheme, material: Material?, fill: Color) -> some View {
        background {
            ZStack {
                if let material { Capsule().fill(material) }
                Capsule().fill(fill)
            }
        }
        .overlay { Capsule().strokeBorder(theme.stroke, lineWidth: theme.hairline) }
    }

    /// Outline button look (text inside a thin accent capsule).
    func isletLineButton(_ theme: IsletTheme) -> some View {
        padding(.horizontal, theme.spacing.ml)
            .padding(.vertical, theme.spacing.s)
            .overlay { Capsule().strokeBorder(theme.accent.opacity(0.6), lineWidth: theme.hairline) }
            .contentShape(Capsule())
    }
}
