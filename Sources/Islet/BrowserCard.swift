import CoreGraphics
import Foundation

// MARK: - Floating card: pure layout logic
//
// While a page is open and the panel is collapsed, the host can show a floating card
// (`BrowserCardStack`) with the live web view scaled down inside it. Tapping expand opens
// the full panel; the card folds to a one-line strip while the keyboard is up; closing
// removes it.
//
// Nothing changes on the wire:
//   - card and strip are both reported as `collapsed`, the expanded panel as `opened`
//   - the web view is always laid out at the expanded panel's size and only scaled down
//     in the card, so scroll distance, snapshot viewport and screenshot size do not
//     depend on how the user is currently looking at it
//
// This file only computes: which face to show, how big the web window is, which text to
// print. No UI code, fully unit-testable. The view is in `BrowserCardView.swift`.

/// What the card area shows right now.
enum BrowserCardFace: Equatable {
    /// Nothing: no page, or the panel is expanded.
    case none
    /// Card with the scaled-down live page.
    case card
    /// One-line strip (keyboard up, or folded by the user).
    case strip
}

enum BrowserCard {

    /// Rules, in order:
    ///   1. no page, or panel expanded: nothing
    ///   2. keyboard up: strip, unless the keyboard belongs to a field inside the card's
    ///      web page (the user is typing into the page)
    ///   3. folded by the user: strip
    ///   4. otherwise: card
    static func face(hasPage: Bool, expanded: Bool, folded: Bool,
                     keyboardUp: Bool, typingInWeb: Bool) -> BrowserCardFace {
        guard hasPage, !expanded else { return .none }
        if keyboardUp && !typingInWeb { return .strip }
        return folded ? .strip : .card
    }

    // MARK: Web window size

    /// Maximum share of the screen height used by the web window.
    static let heightShare: CGFloat = 0.3
    /// Minimum / maximum web window height in points.
    static let minHeight: CGFloat = 180
    static let maxHeight: CGFloat = 300
    /// Maximum share of the card's inner width used by the web window (the rest is the
    /// text and button column).
    static let widthShare: CGFloat = 0.6
    /// Default corner radius of the web window (the theme can override it).
    static let windowCorner: CGFloat = 12
    /// Gap between the web window and the column.
    static let columnGap: CGFloat = 12

    /// Scale the panel-sized page (`logical`) to fit both limits. Returns zero for bad input.
    static func window(logical: CGSize, maxWidth: CGFloat, maxHeight: CGFloat) -> (size: CGSize, scale: CGFloat) {
        guard logical.width > 0, logical.height > 0, maxWidth > 0, maxHeight > 0 else { return (.zero, 0) }
        let scale = min(maxWidth / logical.width, maxHeight / logical.height)
        let size = CGSize(width: (logical.width * scale).rounded(.down),
                          height: (logical.height * scale).rounded(.down))
        return (size, scale)
    }

    /// 30% of the screen height, clamped to 180...300 points.
    static func windowHeight(screenHeight: CGFloat) -> CGFloat {
        min(maxHeight, max(minHeight, (screenHeight * heightShare).rounded(.down)))
    }

    /// Screen width minus side gaps minus the card's horizontal padding.
    static func innerWidth(screenWidth: CGFloat, sideGap: CGFloat, padding: CGFloat) -> CGFloat {
        max(0, screenWidth - sideGap * 2 - padding * 2)
    }

    /// The web window for a given screen (the one call the view makes).
    static func window(logical: CGSize, screen: CGSize, sideGap: CGFloat,
                       padding: CGFloat) -> (size: CGSize, scale: CGFloat) {
        let inner = innerWidth(screenWidth: screen.width, sideGap: sideGap, padding: padding)
        return window(logical: logical, maxWidth: inner * widthShare,
                      maxHeight: windowHeight(screenHeight: screen.height))
    }
}

// MARK: - Text on the card

/// User-visible strings on the card. Hosts should localise them.
enum BrowserCardCopy {
    /// Header line while the agent is browsing.
    static let who = "Agent is browsing"

    /// Strip line: `Agent is browsing · <title or host>`.
    static func line(_ name: String) -> String {
        name.isEmpty ? who : "\(who) · \(name)"
    }

    /// Header line in a user-opened session while the page is not the agent's.
    static let userWho = "You're browsing"

    static func userLine(_ name: String) -> String {
        name.isEmpty ? userWho : "\(userWho) · \(name)"
    }

    /// "Share with agent" button and its hint (same as the panel).
    static let handOver = BrowserPanelCopy.handOver
    static let handOverNote = BrowserPanelCopy.handOverNote

    /// Header of the small error overlay.
    static let failed = BrowserPanelCopy.failed

    /// VoiceOver labels.
    static let readerExpand = "Expand browser"
    static let readerFold = "Fold browser card"
    static let readerUnfold = "Unfold browser card"
    static let readerClose = "Close page"

    static let visible = [who, handOver, handOverNote, failed, userWho]
    static let readerLabels = [readerExpand, readerFold, readerUnfold, readerClose]
}
