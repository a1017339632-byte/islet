import SwiftUI
import UIKit
import WebKit

// MARK: - Expanded browser panel
//
// `BrowserLayer` is a full-screen overlay the host puts on top of its root view. It
// contains the expanded panel (address bar, back / fold / close, "Share with agent",
// "Done, show the agent", handover banner, progress bar, error card) and the root slot
// of the single web view (`BrowserStage`).
//
// The panel is collapsed by default. Collapsing does not destroy anything: the panel
// keeps its size and moves off screen, so the agent can still snapshot / screenshot.
// The overlay must stay mounted for the whole app session; the service refuses agent
// requests with "app not open" while no web view is mounted.

// MARK: Strings

/// User-visible strings of the panel. Hosts should localise them.
enum BrowserPanelCopy {
    static let addressPlaceholder = "Enter a URL"
    static let handOver = "Share with agent"
    static let handOverNote = "You opened this page. The agent can't see it until you share it."
    static let failed = "This page didn't open"

    static let readerBack = "Back"
    static let readerFold = "Collapse browser"
    static let readerClose = "Close browser"

    static let visible = [addressPlaceholder, handOver, handOverNote, failed]
}

// MARK: Web view slot

/// Mounts the single web view in the panel (root slot). Creates the engine on first use.
struct BrowserStage: UIViewRepresentable {
    let service: BrowserService

    func makeUIView(context: Context) -> BrowserDockView {
        // Create the WKWebView only once: if SwiftUI rebuilds this slot, the page must survive.
        let engine = (service.engine as? BrowserWebEngine) ?? BrowserWebEngine(service: service)
        service.stageUp(engine)
        return BrowserDockView(dock: engine.dock, role: .root)
    }

    func updateUIView(_ uiView: BrowserDockView, context: Context) {}

    static func dismantleUIView(_ uiView: BrowserDockView, coordinator: ()) {
        uiView.retire()
    }
}

/// Whether the web area is visible. A WKWebView with no page paints an opaque white
/// background, which looks wrong on a translucent panel (especially in dark mode), so
/// the web area is hidden until a page has landed. It stays mounted while hidden.
enum BrowserBlankLook {
    static func stageOpacity(hasPage: Bool) -> Double {
        hasPage ? 1 : 0
    }
}

/// Small transient message shown at the top of the web area.
struct BrowserToast: View {
    @Environment(\.isletTheme) private var theme
    let text: String
    var icon: String? = nil

    var body: some View {
        HStack(spacing: theme.spacing.s) {
            Image(systemName: icon ?? theme.browserIcon)
                .font(theme.font(theme.type.footnote))
                .foregroundStyle(theme.accent)
            Text(text)
                .font(theme.font(theme.type.footnote))
                .foregroundStyle(theme.textStrong)
        }
        .padding(.horizontal, theme.spacing.xl)
        .padding(.vertical, theme.spacing.m)
        .isletPill(theme, material: theme.toastMaterial, fill: theme.panelFill)
        .accessibilityIdentifier("browser_toast")
    }
}

// MARK: The panel

/// Full-screen overlay with the expanded browser panel. Put it on top of the host's root
/// view and keep it mounted:
///
///     RootView().overlay { BrowserLayer(browser: browser) }
///
/// or use `.isletBrowser(browser)`.
public struct BrowserLayer: View {
    @ObservedObject var browser: BrowserService
    @Environment(\.isletTheme) private var theme
    @State private var typed = ""
    @FocusState private var typing: Bool

    public init(browser: BrowserService) {
        self.browser = browser
    }

    public var body: some View {
        GeometryReader { geo in
            let panelHeight = max(360, geo.size.height * 0.82)
            ZStack(alignment: .top) {
                if browser.expanded {
                    theme.scrim
                        .ignoresSafeArea()
                        .onTapGesture { fold() }
                }
                panel(height: panelHeight)
                    .frame(width: geo.size.width, height: panelHeight)
                    // Collapsed = moved off screen, not destroyed: same size, still mounted,
                    // so agent snapshots / screenshots keep working.
                    .offset(y: browser.expanded ? 0 : -(geo.size.height + panelHeight + 40))
                    .animation(theme.panelAnimation, value: browser.expanded)
            }
            .allowsHitTesting(browser.expanded)
        }
        // No accessibility identifier on this full-screen layer itself: SwiftUI would
        // propagate it to every child. The panel below is an accessibility container.
    }

    private func panel(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            chrome
            if browser.progress > 0.01 && browser.progress < 1 {
                GeometryReader { bar in
                    Rectangle()
                        .fill(theme.accent)
                        .frame(width: bar.size.width * browser.progress, height: 2.5)
                }
                .frame(height: 2.5)
                .accessibilityIdentifier("browser_progress")
            } else {
                Color.clear.frame(height: 2.5)
            }
            ZStack {
                // No page yet: hide the web area (see `BrowserBlankLook`). It stays mounted,
                // so agent requests and a typed address keep loading behind it.
                BrowserStage(service: browser)
                    .opacity(BrowserBlankLook.stageOpacity(hasPage: browser.hasPage))
                if let trouble = browser.trouble {
                    troubleCard(trouble)
                }
            }
            .animation(.easeOut(duration: 0.2), value: browser.hasPage)
            // Transient note while the panel is expanded (see `BrowserService.panelNote`).
            .overlay(alignment: .top) {
                if let note = browser.panelNote {
                    BrowserToast(text: note)
                        .padding(.horizontal, theme.spacing.l)
                        .padding(.top, theme.spacing.ml)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(theme.panelAnimation, value: browser.panelNote)
        }
        .clipShape(RoundedRectangle(cornerRadius: theme.corners.panel, style: .continuous))
        .isletSurface(theme, material: theme.panelMaterial, fill: theme.panelFill,
                      corner: theme.corners.panel)
        .padding(.horizontal, theme.spacing.m)
        .padding(.top, theme.spacing.m)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser_panel")
    }

    private var chrome: some View {
        VStack(spacing: theme.spacing.m) {
            HStack(spacing: theme.spacing.ml) {
                Button {
                    browser.userGoesBack()
                } label: {
                    Image(systemName: "chevron.left").font(theme.font(theme.type.callout, .semibold))
                }
                .accessibilityLabel(BrowserPanelCopy.readerBack)
                .accessibilityIdentifier("btn_browser_back")

                TextField(BrowserPanelCopy.addressPlaceholder, text: $typed)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .font(theme.font(theme.type.footnote))
                    .padding(.horizontal, theme.spacing.ml)
                    .padding(.vertical, theme.spacing.s)
                    .isletPill(theme, material: nil, fill: theme.stroke.opacity(0.35))
                    .onSubmit { browser.userOpens(typed) }
                    .accessibilityIdentifier("browser_address")
                    // While the user is not typing, the address bar follows the current page.
                    .focused($typing)
                    .onChange(of: browser.pageURL) { now in
                        if !typing { typed = now ?? "" }
                    }
                    // The user opened the browser from the host UI: clear and focus the address bar.
                    .onChange(of: browser.addressAsk) { _ in
                        typed = ""
                        typing = true
                    }
                    // Typing in the address bar counts as activity in a user-opened session.
                    .onChange(of: typed) { _ in
                        if typing { browser.noteUserAddressTyping() }
                    }

                // live / done switch, next to the address bar (an extra row would shrink
                // the web view and change the agent's viewport).
                if browser.hasPage || browser.selfOpened {
                    BrowserUserModeChip(browser: browser, font: 11, id: "btn_browser_mode")
                }

                Button {
                    fold()
                } label: {
                    Image(systemName: "chevron.down").font(theme.font(theme.type.callout, .semibold))
                }
                .accessibilityLabel(BrowserPanelCopy.readerFold)
                .accessibilityIdentifier("btn_browser_fold")

                Button {
                    browser.userCloses()
                    typed = ""
                    typing = false
                } label: {
                    Image(systemName: "xmark").font(theme.font(theme.type.body, .semibold))
                }
                .accessibilityLabel(BrowserPanelCopy.readerClose)
                .accessibilityIdentifier("btn_browser_close")
            }
            .foregroundStyle(theme.textStrong)

            // "Share with agent": only on a page the user opened and has not shared.
            if browser.canHandOver {
                HStack(spacing: theme.spacing.m) {
                    Button {
                        browser.userHandsOver()
                    } label: {
                        Text(BrowserPanelCopy.handOver)
                            .font(theme.font(theme.type.footnote, .medium))
                            .padding(.horizontal, theme.spacing.xl).padding(.vertical, theme.spacing.s)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accent)
                    .accessibilityIdentifier("btn_browser_hand")

                    Text(BrowserPanelCopy.handOverNote)
                        .font(theme.font(theme.type.small))
                        .foregroundStyle(theme.textFaint)
                    Spacer(minLength: 0)
                }
            }

            // Handed over: banner with the agent's note plus "Done, show the agent".
            // Not handed over but the Done control applies (see `canShowAgent`): just the button.
            if browser.handed || browser.canShowAgent {
                HStack(alignment: .center, spacing: theme.spacing.m) {
                    if browser.handed {
                        VStack(alignment: .leading, spacing: theme.spacing.xxs) {
                            Text(BrowserHandCopy.handedToUser)
                                .font(theme.font(theme.type.footnote, .semibold))
                                .foregroundStyle(theme.textStrong)
                                .accessibilityIdentifier("browser_panel_handed")
                            if let words = browser.handNote {
                                Text(words)
                                    .font(theme.font(theme.type.small))
                                    .foregroundStyle(theme.textSoft)
                                    .lineLimit(2)
                                    .accessibilityIdentifier("browser_panel_handnote")
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    if browser.canShowAgent {
                        Button {
                            browser.userShowsAgent()
                        } label: {
                            Text(BrowserHandCopy.showAgent)
                                .font(theme.font(theme.type.footnote, .medium))
                                .padding(.horizontal, theme.spacing.xl).padding(.vertical, theme.spacing.s)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(theme.accent)
                        .accessibilityIdentifier("btn_browser_showagent")
                    }
                }
            }
        }
        .padding(.horizontal, theme.spacing.l)
        .padding(.top, theme.spacing.ml)
        .padding(.bottom, theme.spacing.m)
    }

    private func troubleCard(_ words: String) -> some View {
        VStack(spacing: theme.spacing.l) {
            Image(systemName: "wifi.exclamationmark")
                .font(theme.font(theme.type.display))
                .foregroundStyle(theme.textFaint)
            Text(BrowserPanelCopy.failed)
                .font(theme.font(theme.type.subhead, .semibold))
                .foregroundStyle(theme.textStrong)
            Text(words)
                .font(theme.font(theme.type.caption))
                .foregroundStyle(theme.textSoft)
                .multilineTextAlignment(.center)
                .padding(.horizontal, theme.spacing.huge)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .isletSurface(theme, material: theme.panelMaterial, fill: theme.panelFill,
                      corner: theme.corners.panel, border: false)
        .accessibilityIdentifier("browser_failed")
    }

    /// Collapse. Release the address bar focus first so the keyboard does not stay
    /// attached to an off-screen field. A user-opened session with no page yet is
    /// treated as closed (see `BrowserService.setExpanded`).
    private func fold() {
        typing = false
        browser.setExpanded(false)
    }
}
