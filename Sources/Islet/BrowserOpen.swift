import Foundation

// MARK: - User-opened browser
//
// The user can open the browser from the host UI without any agent request. The host
// tells the bridge with `browser.user_open`; pages the user opens in such a session
// are shared with the agent in `live` mode. Logic lives in `BrowserService.userOpen`.

/// Frame name and helpers for `browser.user_open`.
enum BrowserOpenWire {
    static let open = "browser.user_open"

    /// Marker on the bridge's error reply meaning "the browser is already open".
    /// The reference bridge sends it as a top-level `frame_kind` field.
    static let alreadyOpenKind = "browser_already_open"

    static func openFrame(reqId: String) -> [String: Any] {
        [BrowserWire.Key.type: open, BrowserWire.Key.reqId: reqId]
    }

    static func isAlreadyOpen(_ payload: Payload) -> Bool {
        payload.string("frame_kind") == alreadyOpenKind
    }

    static func newReqId() -> String {
        let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "bo_" + String(hex.prefix(12))
    }

    /// How many recently sent `browser.user_open` ids are remembered to match error replies.
    static let rememberCap = 16

    /// How long a transient note stays visible (nanoseconds).
    static let noteLinger: UInt64 = 3_000_000_000
}

/// Bookkeeping for one user-opened session (not published to the UI).
struct BrowserUserOpening: Equatable {
    var at: Date
    /// `browser.user_open` has not been sent yet (held during the quiet period in `live` mode).
    var openPending: Bool
    /// Ids sent in this session, in order. Only the latest one is matched against errors.
    var asked: [String] = []
    /// Whether the single retry after an "already open" error has been used.
    var retried = false
}

/// User-visible strings. Hosts should localise them.
enum BrowserOpenCopy {
    static let cell = "Browser"
    static let offline = "Not connected right now, so the browser cannot be opened."
    static let missed = "The agent was not notified that you opened the browser. You can keep browsing."

    static let notes = [offline, missed]
}
