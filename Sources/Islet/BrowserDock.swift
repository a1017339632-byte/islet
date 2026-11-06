import Combine
import SwiftUI
import UIKit
import WebKit

// MARK: - Where the single web view is mounted
//
// There is exactly one `BrowserWebView` (owned by the engine, never recreated). The dock
// decides which host view it lives in right now:
//
//   `.root`  the slot inside the expanded panel (`BrowserLayer`). When the panel is
//            collapsed this slot sits off screen.
//   `.card`  the slot inside the floating card (`BrowserCardStack`), scaled down.
//
// When the card is on screen the web view moves into it; otherwise (panel expanded,
// card folded to a strip, card not shown) it goes back to the root slot. Both slots are
// in the same window, so moving does not resign first responder or flicker.
//
// Parking: a web view attached to a window keeps rendering even off screen. When it is
// parked off screen (panel collapsed, card not visible) and idle for `napAfter` seconds
// (no agent request, not loading, no media playing, no camera / microphone, user not
// typing in it), it is removed from the window. The page itself (DOM, scroll position,
// sign-in state) is kept. Any agent request calls `willWork()` first, which remounts it;
// `takeSnapshot(afterScreenUpdates:)` then waits for a fresh frame.

@MainActor
final class BrowserDock: ObservableObject {

    /// Size of the web area in the expanded panel. The web view is always laid out at
    /// this size; the card only scales it down. Reported by the root slot.
    @Published private(set) var logical: CGSize

    /// Seconds of idleness before an off-screen web view is parked.
    static var napAfter: TimeInterval = 10
    /// How often the parked condition is checked.
    static var napCheck: TimeInterval = 2

    let web: BrowserWebView
    private weak var service: BrowserService?
    private weak var root: BrowserDockView?
    private weak var card: BrowserDockView?
    /// Currently removed from the window.
    private(set) var asleep = false
    /// Last time somebody needed the web view.
    private var lastWork = Date()
    private var napper: Task<Void, Never>?
    private var expandedWatch: AnyCancellable?

    #if DEBUG
    private(set) var debugNaps = 0
    private(set) var debugWakes = 0
    #endif

    init(web: BrowserWebView, service: BrowserService?) {
        self.web = web
        self.service = service
        logical = web.bounds.size
        // Re-place on every expand / collapse, on the next run loop turn (the card slot
        // may not be attached / detached yet).
        expandedWatch = service?.$expanded
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.settle() }
            }
    }

    // MARK: Reports from the slots

    func hostMoved(_ host: BrowserDockView) {
        switch host.role {
        case .root:
            if host.window != nil { root = host }
        case .card:
            if host.window != nil {
                card = host
            } else if card === host {
                card = nil
            }
        }
        settle()
    }

    func hostGone(_ host: BrowserDockView) {
        if card === host { card = nil }
        if root === host { root = nil }
        settle()
    }

    func hostLaidOut(_ host: BrowserDockView) {
        if host.role == .root { noteLogical(host.bounds.size) }
        lay(host)
    }

    // MARK: Placement

    /// Expanded panel wins; then the card if on screen; otherwise park in the root slot.
    /// The expanded check comes first because the card animates out while the panel
    /// animates in; preferring the card would leave the panel empty during that time.
    func settle() {
        if service?.expanded == true, let root, root.window != nil {
            put(into: root)
            return
        }
        if let card, card.window != nil {
            put(into: card)
            return
        }
        guard let root, root.window != nil else { return }
        if service?.expanded ?? true {
            put(into: root)
            return
        }
        // Parked off screen. If already asleep, stay asleep until woken.
        if asleep { return }
        put(into: root)
        armNap()
    }

    /// Somebody needs the web view (agent request, address bar, back): wake it and
    /// restart the idle clock.
    func willWork() {
        lastWork = Date()
        if asleep {
            asleep = false
            #if DEBUG
            debugWakes += 1
            #endif
        }
        settle()
    }

    /// Whether the user is typing in the web view (first responder is it or inside it).
    var webHasFocus: Bool {
        guard let first = UIResponder.isletFirstResponder() as? UIView else { return false }
        return first === web || first.isDescendant(of: web)
    }

    private func put(into host: BrowserDockView) {
        if asleep {
            asleep = false
            #if DEBUG
            debugWakes += 1
            #endif
        }
        if web.superview !== host { host.addSubview(web) }
        lay(host)
    }

    /// Root slot: fill it. Card slot: lay out at the panel size and scale to fit.
    private func lay(_ host: BrowserDockView) {
        guard web.superview === host else { return }
        switch host.role {
        case .root:
            web.transform = .identity
            web.frame = host.bounds
        case .card:
            let size = (logical.width > 1 && logical.height > 1) ? logical : host.bounds.size
            let box = host.bounds.size
            guard size.width > 1, size.height > 1, box.width > 1, box.height > 1 else { return }
            let scale = min(box.width / size.width, box.height / size.height)
            web.transform = .identity
            web.bounds = CGRect(origin: .zero, size: size)
            web.center = CGPoint(x: box.width / 2, y: box.height / 2)
            web.transform = CGAffineTransform(scaleX: scale, y: scale)
        }
    }

    /// Size reported by the root slot. Do not mutate `@Published` during layout; defer it.
    private func noteLogical(_ size: CGSize) {
        guard size.width > 1, size.height > 1, size != logical else { return }
        Task { @MainActor [weak self] in
            guard let self, self.logical != size else { return }
            self.logical = size
            if let card = self.card { self.lay(card) }
        }
    }

    // MARK: Parking

    /// In the root slot, panel collapsed, card not on screen.
    private var parked: Bool {
        guard let root, web.superview === root else { return false }
        if let card, card.window != nil { return false }
        return !(service?.expanded ?? true)
    }

    private func armNap() {
        guard napper == nil else { return }
        napper = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.napCheck * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                guard self.parked else {
                    self.napper = nil
                    return
                }
                if await self.napIfIdle() {
                    self.napper = nil
                    return
                }
            }
        }
    }

    /// Park if idle. Not when: recent work, loading, user typing in the page, media
    /// playing, camera or microphone in use.
    private func napIfIdle() async -> Bool {
        guard parked, !asleep, Date().timeIntervalSince(lastWork) >= Self.napAfter else { return false }
        if service?.loading == true { return false }
        if webHasFocus { return false }
        if web.cameraCaptureState == .active || web.microphoneCaptureState == .active { return false }
        let playing = await web.requestMediaPlaybackState() == .playing
        // Things may have changed while waiting for the answer: check again.
        guard !playing, parked, !asleep,
              Date().timeIntervalSince(lastWork) >= Self.napAfter else { return false }
        asleep = true
        web.removeFromSuperview()
        #if DEBUG
        debugNaps += 1
        #endif
        return true
    }
}

/// A slot the web view can be mounted in. Draws nothing; reports window and layout changes.
final class BrowserDockView: UIView {
    enum Role { case root, card }

    let role: Role
    private weak var dock: BrowserDock?

    init(dock: BrowserDock, role: Role, corner: CGFloat = BrowserCard.windowCorner) {
        self.dock = dock
        self.role = role
        super.init(frame: .zero)
        if role == .card {
            // Card slot: clip the scaled web view to the card's corner radius.
            clipsToBounds = true
            layer.cornerRadius = corner
            layer.cornerCurve = .continuous
        }
    }

    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        dock?.hostMoved(self)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        dock?.hostLaidOut(self)
    }

    /// SwiftUI dismantled the slot.
    func retire() {
        dock?.hostGone(self)
    }
}

/// The card slot as a SwiftUI view.
struct BrowserCardWindow: UIViewRepresentable {
    let dock: BrowserDock
    var corner: CGFloat = BrowserCard.windowCorner

    func makeUIView(context: Context) -> BrowserDockView {
        BrowserDockView(dock: dock, role: .card, corner: corner)
    }

    func updateUIView(_ uiView: BrowserDockView, context: Context) {}

    static func dismantleUIView(_ uiView: BrowserDockView, coordinator: ()) {
        uiView.retire()
    }
}

// MARK: - Current first responder

extension UIResponder {
    private static weak var isletCaught: UIResponder?

    /// The current first responder (send an action to nil; the first responder catches it).
    static func isletFirstResponder() -> UIResponder? {
        isletCaught = nil
        UIApplication.shared.sendAction(#selector(UIResponder.isletCatch(_:)), to: nil, from: nil, for: nil)
        return isletCaught
    }

    @objc private func isletCatch(_ sender: Any?) {
        UIResponder.isletCaught = self
    }
}
