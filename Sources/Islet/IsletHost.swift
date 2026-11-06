import Foundation
import SwiftUI

// MARK: - Host wiring
//
// The smallest integration:
//
//     let browser = BrowserService()
//     browser.connect(
//         send: { frame in socket.send(json: frame) },          // false when offline
//         isOnline: { socket.isAuthenticated },
//         isForeground: { UIApplication.shared.applicationState == .active },
//         upload: { jpeg in await uploadScreenshot(jpeg) })     // optional
//
//     // every decoded frame from the bridge:
//     browser.receive(frame)
//
//     // after (re)connecting / returning to the foreground:
//     browser.restate(.lineUp)        // or .foreground
//
//     // UI (keep mounted for the whole session):
//     RootView().isletBrowser(browser)
//
// Show / hide: `userOpen()`, `setExpanded(_:)`, `userCloses()`.

extension BrowserService {

    /// Wires the service to the host's transport in one call.
    /// - Parameters:
    ///   - send: Sends one JSON object to the bridge. Return false when offline; frames are
    ///     never queued (the bridge's timeouts cover dropped replies).
    ///   - isOnline: Whether the bridge connection is currently up (authenticated).
    ///   - isForeground: Whether the host app is in the foreground. Every agent request is
    ///     refused while this returns false.
    ///   - upload: Uploads a screenshot (JPEG) and returns a receipt whose fields become the
    ///     `browser.response` body. nil = screenshots are refused with a clear message.
    ///   - showNote: Shows a short message to the user (for example a toast). Optional.
    public func connect(send: @escaping ([String: Any]) -> Bool,
                        isOnline: @escaping () -> Bool,
                        isForeground: @escaping () -> Bool,
                        upload: ((Data) async -> Result<[String: Any], BrowserTrouble>)? = nil,
                        showNote: ((String) -> Void)? = nil) {
        sender = send
        online = isOnline
        foreground = isForeground
        uploader = upload
        onNote = showNote
    }

    /// Feeds one decoded frame from the bridge. Returns true when the frame was handled
    /// by the browser (`browser.request`, `browser.handover`, or an error reply to this
    /// host's own `browser.user_open`). Other frames are ignored and return false, so the
    /// host can pass every incoming frame through here first.
    @discardableResult
    public func receive(_ frame: [String: Any]) -> Bool {
        let payload = Payload(frame)
        switch payload.type {
        case BrowserWire.request, BrowserHandWire.handover:
            take(payload)
            return true
        case "error":
            return takeOpenError(payload)
        default:
            return false
        }
    }

    /// Same as `receive(_:)` for a JSON text frame. Returns false if the text is not a JSON object.
    @discardableResult
    public func receive(text: String) -> Bool {
        guard let payload = Payload(text: text) else { return false }
        return receive(payload.raw)
    }

    /// Shows the expanded panel (the page, if any, stays as it is).
    public func show() {
        setExpanded(true)
    }

    /// Collapses the panel. The page stays open and readable by the agent; use
    /// `userCloses()` to close it.
    public func hide() {
        setExpanded(false)
    }
}

extension View {
    /// Overlays the built-in browser panel (`BrowserLayer`) on this view. Apply it to the
    /// root view and keep it mounted for the whole app session.
    public func isletBrowser(_ browser: BrowserService) -> some View {
        overlay { BrowserLayer(browser: browser) }
    }
}
