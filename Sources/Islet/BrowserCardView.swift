import Combine
import SwiftUI
import UIKit
import WebKit

// MARK: - Floating browser card
//
// While a page is open and the panel is collapsed, `BrowserCardStack` shows a floating
// card with the live page scaled down inside it (scrollable and tappable), an expand
// button that opens the full panel, a fold button that shrinks it to a one-line strip,
// and a close button. All decisions are in `BrowserCard.swift`; this file only draws.
//
// Rules:
//   1. Never block scrolling of the content underneath: apart from the card itself
//      there is no full-size background, empty space takes no touches.
//   2. Fold to a strip while the keyboard is up (unless the keyboard is for a field
//      inside the card's page, see `BrowserCard.face`).
//   3. No page, no card: closed by the user, closed by the agent, or reclaimed by the OS.
//
// The card is optional. A host that only wants the full panel can skip it; the web
// view then stays in the (collapsed) panel.

/// Floating card for the built-in browser. Place it where the card should appear, for
/// example at the top of a chat screen:
///
///     ChatView().overlay(alignment: .top) { BrowserCardStack(browser: browser) }
///
/// It is empty (no frame, no touches) whenever there is nothing to show.
public struct BrowserCardStack: View {
    @ObservedObject var browser: BrowserService
    @Environment(\.isletTheme) private var theme

    /// Whether the keyboard is up. Starts as false: if the stack is mounted while the
    /// keyboard is already showing, the card folds at the next keyboard notification.
    @State private var keyboardUp = false
    /// Whether this keyboard belongs to a field inside the web page.
    @State private var typingInWeb = false

    public init(browser: BrowserService) {
        self.browser = browser
    }

    public var body: some View {
        BrowserCardLayer(browser: browser, keyboardUp: keyboardUp, typingInWeb: typingInWeb)
            .animation(theme.cardAnimation, value: keyboardUp)
            .onReceive(NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillShowNotification)) { _ in
                keyboardUp = true
                typingInWeb = (browser.engine as? BrowserWebEngine)?.dock.webHasFocus ?? false
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardUp = false
                typingInWeb = false
            }
    }
}

// MARK: Card layer

struct BrowserCardLayer: View {
    @ObservedObject var browser: BrowserService
    @Environment(\.isletTheme) private var theme
    let keyboardUp: Bool
    let typingInWeb: Bool

    private var face: BrowserCardFace {
        BrowserCard.face(hasPage: browser.hasPage, expanded: browser.expanded,
                         folded: browser.cardFolded, keyboardUp: keyboardUp, typingInWeb: typingInWeb)
    }

    var body: some View {
        // Nothing to show: an empty stack, no background, no frame, no touches.
        VStack(spacing: 0) {
            if face != .none, let engine = browser.engine as? BrowserWebEngine {
                BrowserCardView(browser: browser, dock: engine.dock, face: face)
                    .padding(.horizontal, theme.spacing.cardSideGap)
                    .padding(.top, theme.spacing.s)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(theme.cardAnimation, value: face)
    }
}

// MARK: The card

struct BrowserCardView: View {
    @Environment(\.isletTheme) private var theme
    @ObservedObject var browser: BrowserService
    @ObservedObject var dock: BrowserDock
    let face: BrowserCardFace

    private var strip: Bool { face == .strip }
    private var corner: CGFloat { strip ? theme.corners.strip : theme.corners.card }

    var body: some View {
        Group {
            if strip { stripRow } else { cardBody }
        }
        .isletSurface(theme, material: theme.cardMaterial, fill: theme.cardFill, corner: corner)
        // The card takes touches; nothing outside it does.
        .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(strip ? "browser_card_strip" : "browser_card")
    }

    // MARK: Card: web window on the left, text and buttons on the right

    private var cardBody: some View {
        let screen = UIScreen.main.bounds.size
        let window = BrowserCard.window(logical: dock.logical, screen: screen,
                                        sideGap: theme.spacing.cardSideGap, padding: theme.spacing.cardPadH)
        return HStack(alignment: .top, spacing: BrowserCard.columnGap) {
            webWindow(window.size)
            column
                .frame(height: window.size.height)
        }
        .padding(.horizontal, theme.spacing.cardPadH)
        .padding(.vertical, theme.spacing.cardPadV)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func webWindow(_ size: CGSize) -> some View {
        BrowserCardWindow(dock: dock, corner: theme.corners.webWindow)
            .frame(width: size.width, height: size.height)
            .overlay(RoundedRectangle(cornerRadius: theme.corners.webWindow, style: .continuous)
                .strokeBorder(theme.stroke, lineWidth: theme.hairline))
            .overlay(alignment: .top) { progressLine(width: size.width) }
            .overlay {
                if let trouble = browser.trouble { troubleMini(trouble) }
            }
            .accessibilityIdentifier("browser_card_web")
    }

    @ViewBuilder
    private func progressLine(width: CGFloat) -> some View {
        if browser.progress > 0.01 && browser.progress < 1 {
            Rectangle()
                .fill(theme.accent)
                .frame(width: width * browser.progress, height: 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: theme.corners.webWindow, style: .continuous))
                .allowsHitTesting(false)
        }
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: theme.browserIcon)
                    .font(theme.font(11.5))
                    .foregroundStyle(theme.accent)
                    .frame(width: 26, height: 26)
                    .overlay(Circle().strokeBorder(theme.accent.opacity(0.45), lineWidth: 0.9))
                Spacer(minLength: 4)
                closeButton
            }
            if browser.handed {
                // Handed over: header becomes "Your turn" plus the agent's note.
                Text(BrowserHandCopy.handedToUser)
                    .font(theme.font(theme.type.callout, .semibold))
                    .foregroundStyle(theme.textStrong)
                    .lineLimit(1)
                    .padding(.top, theme.spacing.ml)
                    .accessibilityIdentifier("browser_card_handed")
                if let words = browser.handNote {
                    Text(words)
                        .font(theme.font(theme.type.small))
                        .foregroundStyle(theme.textStrong.opacity(0.85))
                        .lineLimit(2)
                        .padding(.top, 5)
                        .accessibilityIdentifier("browser_card_handnote")
                }
            } else {
                // User-opened session on a page that is not the agent's: "You're browsing".
                Text(browser.userLooking ? BrowserCardCopy.userWho : BrowserCardCopy.who)
                    .font(theme.font(theme.type.callout, .semibold))
                    .foregroundStyle(theme.textStrong)
                    .lineLimit(1)
                    .padding(.top, theme.spacing.ml)
            }
            if !browser.stripName.isEmpty {
                Text(browser.stripName)
                    .font(theme.font(theme.type.small))
                    .foregroundStyle(theme.textSoft)
                    // One line while handed over, so the buttons still fit.
                    .lineLimit(browser.handed ? 1 : 3)
                    .truncationMode(.middle)
                    .padding(.top, 5)
            }
            if browser.canHandOver {
                handOver
                    .padding(.top, theme.spacing.ml)
            }
            if browser.canShowAgent {
                showAgentButton
                    .padding(.top, browser.canHandOver ? 8 : 10)
            }
            Spacer(minLength: 8)
            // Mode switch between expand and fold, taking the middle width (no spacers:
            // they would squeeze the label).
            HStack(spacing: theme.spacing.xs) {
                expandButton
                modeSwitch
                    .frame(maxWidth: .infinity)
                foldButton
            }
        }
    }

    /// "Done, show the agent": shares the page and notifies the agent; ends a handover.
    /// When it shows: see `BrowserService.canShowAgent`.
    private var showAgentButton: some View {
        Button {
            browser.userShowsAgent()
        } label: {
            Text(BrowserHandCopy.showAgent)
                .font(theme.font(theme.type.small, .semibold))
                .foregroundStyle(theme.accent)
                .lineLimit(1)
                .isletLineButton(theme)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("btn_browser_card_showagent")
    }

    private var modeSwitch: some View {
        BrowserUserModeChip(browser: browser, font: 10, id: "btn_browser_card_mode")
    }

    /// "Share with agent" (only on a page the user opened).
    private var handOver: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                browser.userHandsOver()
            } label: {
                Text(BrowserCardCopy.handOver)
                    .font(theme.font(theme.type.small, .medium))
                    .foregroundStyle(theme.accent)
                    .isletLineButton(theme)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("btn_browser_card_hand")
            Text(BrowserCardCopy.handOverNote)
                .font(theme.font(theme.type.tiny))
                .foregroundStyle(theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Small version of the panel's error card, over the web window.
    private func troubleMini(_ words: String) -> some View {
        VStack(spacing: theme.spacing.s) {
            Image(systemName: "wifi.exclamationmark")
                .font(theme.font(theme.type.title3))
                .foregroundStyle(theme.textFaint)
            Text(BrowserCardCopy.failed)
                .font(theme.font(12.5, .semibold))
                .foregroundStyle(theme.textStrong)
            Text(words)
                .font(theme.font(theme.type.tiny))
                .foregroundStyle(theme.textSoft)
                .multilineTextAlignment(.center)
                .padding(.horizontal, theme.spacing.m)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .isletSurface(theme, material: theme.cardMaterial, fill: theme.cardFill,
                      corner: theme.corners.webWindow, border: false)
        .accessibilityIdentifier("browser_card_failed")
    }

    // MARK: Strip: one line, tap to expand

    private var stripRow: some View {
        HStack(spacing: 7) {
            Button {
                browser.setExpanded(true)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: theme.browserIcon)
                        .font(theme.font(11.5))
                        .foregroundStyle(theme.accent)
                    Text(browser.handed ? BrowserHandCopy.line(browser.stripName)
                         : browser.userLooking ? BrowserCardCopy.userLine(browser.stripName)
                         : BrowserCardCopy.line(browser.stripName))
                        .font(theme.font(12.5))
                        .foregroundStyle(theme.textSoft)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("browser_strip")
            foldButton
        }
        .padding(.horizontal, theme.spacing.stripPadH)
        .padding(.vertical, theme.spacing.stripPadV)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Buttons (outline icons)

    private var expandButton: some View {
        Button {
            browser.setExpanded(true)
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(theme.font(theme.type.footnote, .semibold))
                .foregroundStyle(theme.textStrong)
                .frame(width: 34, height: 30)
                .overlay(Capsule().strokeBorder(theme.stroke, lineWidth: theme.hairline))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(BrowserCardCopy.readerExpand)
        .accessibilityIdentifier("btn_browser_card_expand")
    }

    /// Fold to a strip / unfold to the card. The chevron rotates.
    private var foldButton: some View {
        Button {
            browser.setCardFolded(!strip)
        } label: {
            Image(systemName: "chevron.down")
                .font(theme.font(theme.type.tiny, .semibold))
                .foregroundStyle(theme.textFaint)
                .rotationEffect(.degrees(strip ? 0 : -180))
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(strip ? BrowserCardCopy.readerUnfold : BrowserCardCopy.readerFold)
        .accessibilityIdentifier("btn_browser_card_fold")
    }

    private var closeButton: some View {
        Button {
            browser.userCloses()
        } label: {
            Image(systemName: "xmark")
                .font(theme.font(theme.type.caption, .semibold))
                .foregroundStyle(theme.textFaint)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(BrowserCardCopy.readerClose)
        .accessibilityIdentifier("btn_browser_card_close")
    }
}

/// The `live` / `done` switch (card and panel): an outline pill showing the current mode;
/// tapping switches to the other one (`BrowserService.setUserMode`, sends
/// `browser.user_pref`). The label is never truncated (`fixedSize`).
struct BrowserUserModeChip: View {
    @Environment(\.isletTheme) private var theme
    @ObservedObject var browser: BrowserService
    let font: CGFloat
    let id: String

    var body: some View {
        Button {
            browser.setUserMode(browser.userMode.other)
        } label: {
            Text(browser.userMode.label)
                .font(theme.font(font, .medium))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(theme.textSoft)
                .padding(.horizontal, theme.spacing.s)
                .padding(.vertical, 5)
                .overlay(Capsule().strokeBorder(theme.stroke, lineWidth: theme.hairline))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(browser.userMode.label)
        .accessibilityIdentifier(id)
    }
}
