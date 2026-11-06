import Foundation

// MARK: - In-app agent browser: wire format and rules
//
// The agent does not get a headless browser. It borrows the single web view that
// lives inside the host app on the user's device, so three properties hold by
// construction:
//   * if the host app is not in the foreground, there is no browser;
//   * the user sees every page the agent reads or acts on;
//   * a page the user opened is readable only after the user explicitly shares it.
//
// Frames (see protocol/PROTOCOL.md for the normative description):
//   bridge -> host  {"type":"browser.request","req_id":"...",
//                    "op":"open|snapshot|screenshot|back|close|click|type|scroll", ...}
//   host -> bridge  {"type":"browser.response","req_id":"<echoed>","status":"ok"|"error",
//                    "body":{...ok only},"error":{"message":"...","retryable":true|false}}
//   host -> bridge  {"type":"browser.state","state":"opened|collapsed|closed",
//                    "by":"user|agent|system|shell","owner":"user|agent|null",
//                    "shared":true|false,"handed":true|false}   (unsolicited)
//   Handover / hand-back / user-activity frames live in `BrowserHand.swift`.
//
// Every frame name, field name and op name is defined in this file only.
//
// Hard rule on the host side: every browser.request gets exactly one reply.
// The only request left unanswered is one without a usable req_id (there is
// nothing to attach the reply to).

/// Frame names, field names, ops, timing constants and frame builders.
enum BrowserWire {
    /// bridge -> host: perform one operation.
    static let request = "browser.request"
    /// host -> bridge: the single reply to a request.
    static let response = "browser.response"
    /// host -> bridge (unsolicited): panel / page state changed.
    static let state = "browser.state"

    /// Supported ops. Anything else is answered with "not implemented" (retryable: false).
    enum Op: String, CaseIterable {
        case open, snapshot, screenshot, back, close
        case click, type, scroll
    }

    /// Scroll directions. Horizontal scrolling is not supported; other values are refused.
    enum Dir: String {
        case up, down
    }

    /// Who caused a state change.
    /// `user` / `agent` use the same vocabulary as `owner`.
    /// `system` is used only on the `closed` frame sent when the OS reclaimed the web
    /// content process; that frame also carries `url` / `title`.
    enum By: String {
        case user, agent
        case system
        /// The user opened the browser from the host UI; sent right after `browser.user_open`.
        case shell
    }

    static let statusOK = "ok"
    static let statusError = "error"
    /// The three panel states. They describe whether the panel is expanded and whether
    /// the page still exists, not whether the agent may use it (that is the foreground
    /// gate, an independent concern).
    ///   `opened`    panel expanded, page alive
    ///   `collapsed` panel collapsed, page still alive (the web view stays mounted)
    ///   `closed`    the page itself is gone (closed by the agent or the user, or reclaimed)
    /// A collapsed panel is still "open" for every agent operation.
    static let stateOpened = "opened"
    static let stateCollapsed = "collapsed"
    static let stateClosed = "closed"

    /// The state to report while a page is alive: `opened` or `collapsed`, never `closed`.
    static func livePhase(expanded: Bool) -> String {
        expanded ? stateOpened : stateCollapsed
    }

    /// Field names, kept in one place.
    enum Key {
        static let type = "type"
        static let reqId = "req_id"
        static let op = "op"
        static let timeoutMs = "timeout_ms"
        static let status = "status"
        static let body = "body"
        static let error = "error"
        static let message = "message"
        static let retryable = "retryable"
        static let state = "state"
        static let by = "by"
        static let owner = "owner"
        static let shared = "shared"

        // op parameters and response body fields
        static let url = "url"
        static let title = "title"
        static let text = "text"
        static let elements = "elements"
        static let ref = "ref"
        static let tag = "tag"
        static let href = "href"
        static let inputType = "inputType"
        static let wentBack = "went_back"
        static let closed = "closed"

        // click / type / scroll parameters and replies
        static let dir = "dir"
        static let navigated = "navigated"
        static let typed = "typed"
        static let atTop = "at_top"
        static let atBottom = "at_bottom"
        /// Snapshot body: `{"pct": 0...100, "at_top": Bool, "at_bottom": Bool, "box"?: true}`.
        static let scroll = "scroll"
        static let pct = "pct"
        /// Present on successful open / snapshot / screenshot bodies: the page was still
        /// loading, so what was read or captured may be only part of it.
        static let loading = "loading"
        /// Screenshot bodies carry the upload receipt verbatim, which already has a `url`
        /// (the uploaded image). The page address therefore uses the `page_` prefix.
        static let pageURL = "page_url"
        static let pageTitle = "page_title"

        /// Optional on `type`: exactly JSON `true` presses Enter after typing. Anything else
        /// (absent, false, the string "true") means no Enter.
        static let submit = "submit"
        /// The scroll acted on / reports an inner scroll container rather than the page.
        static let box = "box"
        /// On click replies: whether the page text fingerprint changed. `navigated:true`
        /// always implies `changed:true`; omitted when it could not be measured.
        static let changed = "changed"

        // screenshot body = the upload receipt, verbatim
        static let id = "id"
        static let kind = "kind"
        static let name = "name"
        static let size = "size"
    }

    /// DOM attribute used to tag elements during a snapshot. Every snapshot removes the
    /// previous tags and assigns fresh ones; click / type look elements up by it, and a
    /// missing ref means "expired, take a new snapshot".
    static let refAttribute = "data-agent-ref"

    /// After a click the host waits briefly:
    ///   `clickNoticeSeconds` how long to wait for a main-frame navigation to start
    ///   `clickTotalSeconds`  if one started, wait for it to settle, measured from request arrival
    /// If it has not settled by then, reply "navigated" with the current address.
    static let clickNoticeSeconds: Double = 1.5
    static let clickTotalSeconds: Double = 4.5

    /// Host-side deadlines for scripts injected into a page whose own scripts are busy:
    ///   `actReplySeconds`    click / type must reply within this many seconds of arrival
    ///   `scrollReplySeconds` same for scroll
    ///   `readStepSeconds`    snapshot script evaluation
    ///   `shotStepSeconds`    screenshot capture + JPEG encoding (upload is separate)
    /// The fast path is unaffected; these only cover "the injected script never returned".
    static let actReplySeconds: Double = 6
    static let scrollReplySeconds: Double = 3.5
    static let readStepSeconds: Double = 20
    static let shotStepSeconds: Double = 8

    // MARK: Frame builders
    static func okFrame(reqId: String, body: [String: Any]) -> [String: Any] {
        [Key.type: response, Key.reqId: reqId, Key.status: statusOK, Key.body: body]
    }

    static func errFrame(reqId: String, message: String, retryable: Bool) -> [String: Any] {
        [Key.type: response, Key.reqId: reqId, Key.status: statusError,
         Key.error: [Key.message: message, Key.retryable: retryable]]
    }

    /// Unsolicited state frame (no url except on system-reclaim frames).
    /// Sent when: the agent opens a page (normally `collapsed`, because an agent `open`
    /// does not expand the panel); the user expands / collapses the panel; the page is
    /// closed; the user shares the page; every navigation lands (owner updated, shared
    /// usually reset, panel state unchanged). Duplicates are fine: the bridge keeps the latest.
    /// `by` may be nil for re-reports. `handed` is filled in centrally by `BrowserService.reply`.
    static func stateFrame(phase: String, by: By?,
                           owner: BrowserOwner?, shared: Bool,
                           url: String? = nil, title: String? = nil,
                           handed: Bool? = nil) -> [String: Any] {
        var frame: [String: Any] = [Key.type: state, Key.state: phase,
                                    Key.owner: owner?.rawValue ?? NSNull(), Key.shared: shared]
        if let by { frame[Key.by] = by.rawValue }
        if let url, !url.isEmpty { frame[Key.url] = url }
        if let title, !title.isEmpty { frame[Key.title] = title }
        if let handed { frame[BrowserHandWire.Key.handed] = handed }
        return frame
    }

    /// Adds `owner` / `shared` / `loading` to a successful snapshot / screenshot body.
    static func stamp(_ body: [String: Any],
                      owner: BrowserOwner?, shared: Bool, loading: Bool) -> [String: Any] {
        var out = body
        out[Key.owner] = owner?.rawValue ?? NSNull()
        out[Key.shared] = shared
        out[Key.loading] = loading
        return out
    }
}

// MARK: - Messages for the agent (relayed verbatim as error.message)

/// Sentences written for the agent, not UI text. Hosts may localise them.
enum BrowserCopy {
    /// App not in the foreground or the web view is not ready. Retryable.
    static let asleep = "The app is not open in the foreground right now. Try again once the user opens it."
    /// Unknown op.
    static let notYet = "This operation is not implemented yet."
    /// URL scheme is not http / https (the bridge may pre-check; the host checks again).
    static let badScheme = "Only http and https URLs can be opened."
    static let noPage = "No page is open. Open one first."
    /// A navigation is in progress and the new page has not been committed to the screen
    /// yet (reading now would return the previous page). A committed but still-loading
    /// page is not blocked.
    static let stillLoading = "This page is still loading. Wait a moment and try again."
    /// Ownership gate: the user opened this page and has not shared it.
    static let userOwned = "The user opened this page and has not shared it with you."
    static let shotFailed = "The screenshot failed. Try again."
    /// No uploader configured.
    static let noServer = "No upload endpoint is configured, so the screenshot cannot be uploaded."
    /// Appended to a truncated snapshot text.
    static let clipped = "The page is long; only the first part is shown. Use browser_scroll to see more."
    static let garbled = "The page returned something unreadable. Try again."

    // click / type / scroll refusals (retryable: false)
    static let refGone = "This ref no longer exists on the page (it may have navigated or re-rendered). Take a new snapshot to get fresh refs."
    static let noRef = "The request has no ref. Take a snapshot to get one first."
    static let noText = "The request has no text, so there is nothing to type."
    /// Hard refusal: password fields are never written to.
    static let password = "This is a password field. I can't fill it in for you; the user has to."
    static let untypeable = "This element is not a text field; nothing can be typed into it."
    static let badDir = "Only the directions up and down are supported."
    /// The injected script itself failed (not a page refusal). Worth retrying.
    static let actFailed = "The action did not go through. Try again."
    /// Downloads are never accepted.
    static let download = "This URL is a file download; downloads are not accepted here."
    /// The click would open the system file chooser (file input, a label pointing at
    /// one, or a script clicking one). Hard refusal, same treatment as password fields.
    static let fileChooser = "This opens the system file chooser; the user has to do this personally."

    /// Host deadline fired for click / type / scroll. Not retryable: the injected call
    /// cannot be withdrawn and may still run later, so repeating it blindly could act twice.
    static let pageBusy = "The page is busy (its own scripts are still running). The action may still take effect later; take a snapshot before deciding whether to repeat it."
    /// Host deadline fired for snapshot. Reading has no side effects, so retryable.
    static let pageBusyRead = "The page is busy (its own scripts are still running) and cannot be read right now. Snapshot again in a moment."
    /// Host deadline fired for screenshot. Retryable.
    static let pageBusyShot = "The page is busy (its own scripts are still running) and cannot be captured right now. Try the screenshot again in a moment."

    static func openFailed(_ human: String) -> String { human }
}

// MARK: - URL allow-list

/// Only http / https URLs with a host are accepted.
enum BrowserURL {
    static let schemes: Set<String> = ["http", "https"]

    /// Scheme comparison is case-insensitive. `javascript:`, `file:`, `data:`, custom
    /// schemes and scheme-less input (`//example.com/x`, `example.com`) are all rejected.
    static func allow(_ raw: String?) -> URL? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), schemes.contains(scheme),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// Address-bar input from the user: a bare `example.com` gets `https://` prepended.
    /// Nothing else is guessed, and the result still has to pass `allow`.
    static func fromAddressBar(_ typed: String) -> URL? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let direct = allow(trimmed) { return direct }
        guard !trimmed.contains("://"), !trimmed.hasPrefix("javascript:"),
              !trimmed.hasPrefix("data:"), !trimmed.hasPrefix("file:") else { return nil }
        return allow("https://" + trimmed)
    }

    /// Display name for a compact UI: the title if present, otherwise the host.
    static func shortName(title: String?, url: String?) -> String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let url, let host = URL(string: url)?.host, !host.isEmpty { return host }
        return url ?? ""
    }

    /// Fragment-only navigation within the same document. WebKit asks the navigation
    /// policy but never sends didFinish for it; treating it as a page change would leave
    /// "loading" stuck and block every later op. Same document = identical once the
    /// fragment is removed, and at least one side has a fragment.
    static func sameDocument(_ next: URL?, from current: URL?) -> Bool {
        guard let next, let current else { return false }
        guard next.fragment != nil || current.fragment != nil else { return false }
        return withoutFragment(next) == withoutFragment(current)
    }

    private static func withoutFragment(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        parts.fragment = nil
        return parts.string ?? url.absoluteString
    }
}

// MARK: - Ownership

/// Who navigated to the page currently on screen.
/// `agent`: caused by an agent tool call (`open`, or a navigation caused by `click`).
/// `user`: the user acted in the panel (address bar, tapping a link, reload).
/// nil when no page is open (sent as JSON null).
///
/// Back / forward is the one exception: the landing page keeps the owner it had when it
/// was first opened (tracked in `BrowserService.ownerByURL`). Otherwise an agent `back`
/// onto a user page would make it agent-owned and bypass the ownership gate.
/// When a navigation fails, the owner reverts to that of the page still on screen.
public enum BrowserOwner: String {
    case agent, user
}

// MARK: - One request

/// A parsed `browser.request`.
struct BrowserRequest: Equatable {
    let reqId: String
    /// nil when the op is not recognised (answered with "not implemented").
    let op: BrowserWire.Op?
    /// `open` only: the URL exactly as received (not yet validated).
    let rawURL: String?
    /// The bridge's own deadline. Advisory only: the host never needs it; host-side
    /// deadlines are its own constants.
    let timeoutMs: Int?
    /// click / type: ref from the most recent snapshot (nil if absent or blank).
    var ref: String? = nil
    /// type: text taken verbatim, not trimmed. nil = absent; "" clears the field.
    var text: String? = nil
    /// scroll: kept verbatim even if unknown, so the gate can refuse it.
    var dir: String? = nil
    /// type: press Enter afterwards. Only JSON `true` counts.
    var submit: Bool = false

    /// Returns nil when there is no usable req_id; the frame is then dropped silently.
    /// This is the only case in which a request gets no reply.
    static func from(_ payload: Payload) -> BrowserRequest? {
        guard payload.type == BrowserWire.request else { return nil }
        let reqId = (payload.string(BrowserWire.Key.reqId) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reqId.isEmpty else { return nil }
        let opName = (payload.string(BrowserWire.Key.op) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let ref = payload.string(BrowserWire.Key.ref)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return BrowserRequest(reqId: reqId,
                              op: BrowserWire.Op(rawValue: opName),
                              rawURL: payload.string(BrowserWire.Key.url),
                              timeoutMs: payload.int(BrowserWire.Key.timeoutMs),
                              ref: (ref?.isEmpty ?? true) ? nil : ref,
                              text: payload.string(BrowserWire.Key.text),
                              dir: payload.string(BrowserWire.Key.dir)?
                                .trimmingCharacters(in: .whitespacesAndNewlines),
                              submit: payload.bool(BrowserWire.Key.submit) == true)
    }

    var knownDir: BrowserWire.Dir? { dir.flatMap(BrowserWire.Dir.init(rawValue:)) }
}

// MARK: - Gate (foreground, ownership, allow-list), pure logic

/// Decides whether a request may run. Evaluation order:
/// known op -> foreground and web view ready -> handed over -> per-op checks
/// (URL allow-list / page exists / ownership / still loading / ref, text, dir present).
enum BrowserGate {

    /// Everything the gate needs to know about the host right now.
    struct Ask {
        var op: BrowserWire.Op?
        /// App in the foreground. A collapsed panel still counts: the user is in the app and
        /// the page is alive.
        var foreground: Bool
        /// The web view is mounted in the view hierarchy (needed for JS and screenshots).
        var ready: Bool
        var hasPage: Bool
        var loading: Bool
        /// The latest navigation has been committed to the screen (didCommit). Only consulted
        /// while loading: committed pages may be read; uncommitted ones are refused.
        var committed: Bool = false
        var owner: BrowserOwner?
        var shared: Bool = false
        var urlAllowed: Bool = true
        var hasRef: Bool = true
        var hasText: Bool = true
        var dirKnown: Bool = true
        /// Set when the OS reclaimed the web content process; refusals then name the lost page.
        var reclaimed: BrowserLostPage? = nil
        /// The browser is handed over to the user; agent hands-on ops are refused.
        var handed: Bool = false
    }

    enum Verdict: Equatable {
        case go
        case refuse(message: String, retryable: Bool)
    }

    static func judge(_ ask: Ask) -> Verdict {
        guard let op = ask.op else {
            return .refuse(message: BrowserCopy.notYet, retryable: false)
        }
        guard ask.foreground, ask.ready else {
            return .refuse(message: BrowserCopy.asleep, retryable: true)
        }
        if ask.handed, handsOn(op) {
            return .refuse(message: BrowserHandCopy.inUserHands, retryable: false)
        }
        switch op {
        case .open:
            guard ask.urlAllowed else {
                return .refuse(message: BrowserCopy.badScheme, retryable: false)
            }
            return .go
        case .snapshot, .screenshot:
            return pageGate(ask)
        case .click, .type, .scroll:
            let page = pageGate(ask)
            guard page == .go else { return page }
            switch op {
            case .click:
                guard ask.hasRef else { return .refuse(message: BrowserCopy.noRef, retryable: false) }
            case .type:
                guard ask.hasRef else { return .refuse(message: BrowserCopy.noRef, retryable: false) }
                guard ask.hasText else { return .refuse(message: BrowserCopy.noText, retryable: false) }
            default:
                guard ask.dirKnown else { return .refuse(message: BrowserCopy.badDir, retryable: false) }
            }
            return .go
        case .back:
            guard ask.hasPage else { return noPage(ask) }
            return .go
        case .close:
            return .go
        }
    }

    /// Ops that change what is on screen. Refused while handed over; reads and close are not.
    static func handsOn(_ op: BrowserWire.Op) -> Bool {
        switch op {
        case .open, .click, .type, .scroll, .back: return true
        case .snapshot, .screenshot, .close: return false
        }
    }

    /// Shared checks for ops that need a readable page.
    private static func pageGate(_ ask: Ask) -> Verdict {
        guard ask.hasPage else { return noPage(ask) }
        guard !(ask.owner == .user && !ask.shared) else {
            return .refuse(message: BrowserCopy.userOwned, retryable: false)
        }
        guard !(ask.loading && !ask.committed) else {
            return .refuse(message: BrowserCopy.stillLoading, retryable: true)
        }
        return .go
    }

    private static func noPage(_ ask: Ask) -> Verdict {
        if let lost = ask.reclaimed {
            return .refuse(message: BrowserCopy.reclaimed(lost.url), retryable: false)
        }
        return .refuse(message: BrowserCopy.noPage, retryable: false)
    }
}

// MARK: - Snapshot body

/// One interactive element in a snapshot. Values of form fields are never read.
struct BrowserElement: Equatable {
    var ref: String
    var tag: String
    var text: String
    var href: String? = nil
    var inputType: String? = nil

    var wire: [String: Any] {
        var map: [String: Any] = [BrowserWire.Key.ref: ref,
                                  BrowserWire.Key.tag: tag,
                                  BrowserWire.Key.text: text]
        if let href, !href.isEmpty { map[BrowserWire.Key.href] = href }
        if let inputType, !inputType.isEmpty { map[BrowserWire.Key.inputType] = inputType }
        return map
    }

    static func from(_ raw: [String: Any]) -> BrowserElement? {
        guard let ref = raw[BrowserWire.Key.ref] as? String, !ref.isEmpty,
              let tag = raw[BrowserWire.Key.tag] as? String, !tag.isEmpty else { return nil }
        return BrowserElement(ref: ref, tag: tag,
                              text: (raw[BrowserWire.Key.text] as? String) ?? "",
                              href: raw[BrowserWire.Key.href] as? String,
                              inputType: raw[BrowserWire.Key.inputType] as? String)
    }
}

/// Fits a snapshot into the size budget. Elements are dropped from the end first (down
/// to a floor), then the text is truncated and `BrowserCopy.clipped` appended.
enum BrowserSnapshotBody {
    /// Upper bound for the encoded body.
    static let maxBytes = 8 * 1024

    /// Elements are kept at least up to this size before the text is cut.
    static let elementFloorBytes = 2 * 1024

    static func fit(text: String, elements: [BrowserElement],
                    extra: [String: Any] = [:],
                    maxBytes: Int = maxBytes,
                    elementFloor: Int = elementFloorBytes) -> (body: [String: Any], clipped: Bool) {
        var kept = elements
        var body = pack(text: text, elements: kept, extra: extra)
        guard bytes(body) > maxBytes else { return (body, false) }

        var tally = ElementTally(kept)
        while !kept.isEmpty, tally.bytes > elementFloor {
            kept.removeLast()
            tally.dropLast()
            body = pack(text: text, elements: kept, extra: extra)
            if bytes(body) <= maxBytes {
                return (packClipped(text: text, elements: kept, extra: extra,
                                    maxBytes: maxBytes), true)
            }
        }
        return (packClipped(text: text, elements: kept, extra: extra, maxBytes: maxBytes), true)
    }

    struct ElementTally {
        private var sizes: [Int]
        init(_ elements: [BrowserElement]) {
            sizes = elements.map { BrowserSnapshotBody.bytes(of: $0.wire) }
        }
        var bytes: Int { 2 + sizes.reduce(0, +) + max(0, sizes.count - 1) }
        mutating func dropLast() {
            if !sizes.isEmpty { sizes.removeLast() }
        }
    }

    private static func pack(text: String, elements: [BrowserElement],
                             extra: [String: Any]) -> [String: Any] {
        var body: [String: Any] = [BrowserWire.Key.text: text,
                                   BrowserWire.Key.elements: elements.map(\.wire)]
        for (key, value) in extra { body[key] = value }
        return body
    }

    private static func packClipped(text: String, elements: [BrowserElement],
                                    extra: [String: Any], maxBytes: Int) -> [String: Any] {
        var body = pack(text: text + "\n" + BrowserCopy.clipped, elements: elements, extra: extra)
        guard bytes(body) > maxBytes else { return body }
        var chars = Array(text)
        var low = 0, high = chars.count
        while low < high {
            let mid = (low + high + 1) / 2
            let trial = pack(text: String(chars[0..<mid]) + "\n" + BrowserCopy.clipped,
                             elements: elements, extra: extra)
            if bytes(trial) <= maxBytes { low = mid } else { high = mid - 1 }
        }
        chars = Array(chars[0..<low])
        body = pack(text: String(chars) + "\n" + BrowserCopy.clipped, elements: elements,
                    extra: extra)
        return body
    }

    static func bytes(_ body: [String: Any]) -> Int {
        (JSONBox.encode(body) ?? "").utf8.count
    }

    static func bytes(of item: [String: Any]) -> Int {
        guard JSONSerialization.isValidJSONObject(item),
              let data = try? JSONSerialization.data(withJSONObject: item) else { return 0 }
        return data.count
    }

    /// Normalises the scroll object returned by the snapshot script.
    static func scrollSpot(_ raw: Any?) -> [String: Any]? {
        guard let map = raw as? [String: Any],
              let pct = (map[BrowserWire.Key.pct] as? NSNumber)?.doubleValue,
              let top = map[BrowserWire.Key.atTop] as? Bool,
              let bottom = map[BrowserWire.Key.atBottom] as? Bool else { return nil }
        let whole = Int(min(100, max(0, pct.rounded())))
        var spot: [String: Any] = [BrowserWire.Key.pct: whole, BrowserWire.Key.atTop: top,
                                   BrowserWire.Key.atBottom: bottom]
        if (map[BrowserWire.Key.box] as? Bool) == true { spot[BrowserWire.Key.box] = true }
        return spot
    }
}

// MARK: - Injected JavaScript
//
// Every script is self-contained, wrapped in try/catch and returns a JSON string.
// Arguments are passed through `literal(_:)` (JSON-encoded), never spliced raw.

/// All scripts injected into the page by the agent-facing ops.
enum BrowserScript {

    /// Scroll position of the page, of an inner scroll container, and discovery of
    /// visible inner scroll containers (largest visible area first).
    static let scrollSpot = """
    function abScrollSpot() {
      var root = document.scrollingElement || document.documentElement || document.body;
      var view = window.innerHeight || (root ? root.clientHeight : 0) || 0;
      var y = window.pageYOffset || (root ? root.scrollTop : 0) || 0;
      var room = Math.max(0, (root ? root.scrollHeight : 0) - view);
      if (room <= 0) { return { pct: 0, at_top: true, at_bottom: true }; }
      var pct = Math.round(y / room * 100);
      if (pct < 0) { pct = 0; }
      if (pct > 100) { pct = 100; }
      return { pct: pct, at_top: y <= 1, at_bottom: y >= room - 1 };
    }
    function abBoxSpot(box) {
      var room = Math.max(0, (box.scrollHeight || 0) - (box.clientHeight || 0));
      var y = box.scrollTop || 0;
      if (room <= 0) { return { pct: 0, at_top: true, at_bottom: true, box: true }; }
      var pct = Math.round(y / room * 100);
      if (pct < 0) { pct = 0; }
      if (pct > 100) { pct = 100; }
      return { pct: pct, at_top: y <= 1, at_bottom: y >= room - 1, box: true };
    }
    function abShown(box) {
      var r = box.getBoundingClientRect();
      var w = Math.min(r.right, window.innerWidth || 0) - Math.max(r.left, 0);
      var h = Math.min(r.bottom, window.innerHeight || 0) - Math.max(r.top, 0);
      return (w > 0 && h > 0) ? { h: h, area: w * h } : null;
    }
    function abBoxes(dir) {
      var page = document.scrollingElement || document.documentElement;
      var all = document.querySelectorAll('*');
      var found = [];
      for (var q = 0; q < all.length; q++) {
        var box = all[q];
        if (box === page || box === document.documentElement) { continue; }
        var room = (box.scrollHeight || 0) - (box.clientHeight || 0);
        if (!(room > 1)) { continue; }
        var css = window.getComputedStyle(box);
        var flow = css ? css.overflowY : '';
        if (flow !== 'auto' && flow !== 'scroll' && flow !== 'overlay') { continue; }
        if (css.visibility === 'hidden') { continue; }
        var shown = abShown(box);
        if (!shown) { continue; }
        var y = box.scrollTop || 0;
        if (dir === 'down' && y >= room - 1) { continue; }
        if (dir === 'up' && y <= 1) { continue; }
        found.push({ el: box, shown: shown });
      }
      found.sort(function (a, b) { return b.shown.area - a.shown.area; });
      return found;
    }
    """

    /// One scroll step = this fraction of the visible height.
    static let scrollShare = 0.8

    /// Text extraction + element numbering.
    /// - Clears previous refs, then tags up to `limit` visible interactive elements
    ///   (`a, button, input, select, textarea, [role=button]`) as r1, r2, ...
    /// - Main text: the candidate container with the most non-link text.
    /// - Once scrolled, text starts at the top of the viewport and elements above the
    ///   viewport are listed after those in view.
    /// - Never reads the value of any form field (password fields included).
    static func snapshot(limit: Int = 400) -> String {
        #"""
        (function () {
          try {
            \#(scrollSpot)
            function abBlocky(el) {
              var css = window.getComputedStyle(el);
              var shown = css ? css.display : '';
              return !!shown && shown !== 'none' && shown !== 'contents' && shown.indexOf('inline') !== 0;
            }
            function abHasBlockKids(el) {
              var kids = el.children;
              for (var i = 0; i < kids.length; i++) { if (abBlocky(kids[i])) { return true; } }
              return false;
            }
            var abRolled = [];
            function abEdge(el) {
              var top = 0;
              for (var t = 0; t < abRolled.length; t++) {
                if (abRolled[t].el !== el && abRolled[t].el.contains(el)) { top = Math.max(top, abRolled[t].top); }
              }
              return top;
            }
            function abHolds(el) {
              for (var t = 0; t < abRolled.length; t++) {
                if (abRolled[t].el === el || el.contains(abRolled[t].el)) { return true; }
              }
              return false;
            }
            function abInner(el, edge) {
              for (var t = 0; t < abRolled.length; t++) {
                if (abRolled[t].el === el) { return Math.max(edge, abRolled[t].top); }
              }
              return edge;
            }
            function abFromViewport(root) {
              var parts = [];
              function add(words, block) { if (words) { parts.push({ words: words, block: block }); } }
              function walk(el, edge) {
                if (!el.getClientRects || el.getClientRects().length === 0) { return; }
                var box = el.getBoundingClientRect();
                if (box.height > 0 && box.bottom <= edge) { return; }
                if (box.height > 0 && !abHolds(el) && (box.top >= edge || !abHasBlockKids(el))) {
                  add(el.innerText, abBlocky(el));
                  return;
                }
                var inner = abInner(el, edge);
                var kids = el.childNodes;
                for (var i = 0; i < kids.length; i++) {
                  var kid = kids[i];
                  if (kid.nodeType === 1) {
                    if ((kid.tagName || '').toLowerCase() === 'br') {
                      var br = kid.getBoundingClientRect();
                      if (!(br.height > 0 && br.bottom <= inner)) { add('\n', false); }
                      continue;
                    }
                    walk(kid, inner);
                  } else if (kid.nodeType === 3) {
                    var words = (kid.nodeValue || '').replace(/\s+/g, ' ');
                    if (!words.trim()) { continue; }
                    var range = document.createRange();
                    range.selectNodeContents(kid);
                    var line = range.getBoundingClientRect();
                    if (!(line.height > 0) || line.bottom <= inner) { continue; }
                    add(words, false);
                  }
                }
              }
              walk(root, abEdge(root));
              var text = '';
              var lastBlock = false;
              for (var p = 0; p < parts.length; p++) {
                if (text && (lastBlock || parts[p].block)) { text += '\n'; }
                text += parts[p].words;
                lastBlock = parts[p].block;
              }
              return text.replace(/\n{3,}/g, '\n\n');
            }
            var out = { text: "", elements: [] };
            var old = document.querySelectorAll('[\#(BrowserWire.refAttribute)]');
            for (var i = 0; i < old.length; i++) {
              old[i].removeAttribute('\#(BrowserWire.refAttribute)');
            }
            var spot = abScrollSpot();
            var agentBox = window.__abScrollBox;
            if (!(agentBox && agentBox.nodeType === 1 && agentBox.isConnected && abShown(agentBox)
                  && (agentBox.scrollHeight || 0) - (agentBox.clientHeight || 0) > 1)) { agentBox = null; }
            if (spot.at_top && spot.at_bottom) {
              var framed = agentBox || ((abBoxes('')[0] || {}).el || null);
              if (framed) { spot = abBoxSpot(framed); }
            }
            var scrolled = !spot.at_top || (!!agentBox && (agentBox.scrollTop || 0) > 1);
            if (scrolled) {
              var every = document.querySelectorAll('*');
              for (var w = 0; w < every.length; w++) {
                var rolled = every[w];
                if (rolled === document.documentElement || rolled === document.scrollingElement) { continue; }
                if ((rolled.scrollTop || 0) > 1) {
                  abRolled.push({ el: rolled, top: rolled.getBoundingClientRect().top + (rolled.clientTop || 0) });
                }
              }
            }
            var sel = 'a,button,input,select,textarea,[role=button]';
            var nodes = document.querySelectorAll(sel);
            var seen = [];
            for (var j = 0; j < nodes.length; j++) {
              if (!scrolled && seen.length >= \#(limit)) { break; }
              var el = nodes[j];
              var box = el.getBoundingClientRect();
              if (!box || box.width <= 1 || box.height <= 1) { continue; }
              var css = window.getComputedStyle(el);
              if (!css || css.visibility === 'hidden' || css.display === 'none') { continue; }
              seen.push({ el: el, above: box.bottom <= abEdge(el) });
            }
            var order = seen;
            if (scrolled) {
              order = [];
              for (var a = 0; a < seen.length; a++) { if (!seen[a].above) { order.push(seen[a]); } }
              for (var b = 0; b < seen.length; b++) { if (seen[b].above) { order.push(seen[b]); } }
            }
            for (var n = 0; n < order.length && n < \#(limit); n++) {
              var node = order[n].el;
              var ref = 'r' + (n + 1);
              node.setAttribute('\#(BrowserWire.refAttribute)', ref);
              var tag = (node.tagName || '').toLowerCase();
              var label = node.innerText || node.getAttribute('aria-label')
                          || node.getAttribute('placeholder') || node.getAttribute('name') || '';
              var item = { ref: ref, tag: tag, text: String(label).trim().slice(0, 80) };
              var href = node.getAttribute('href');
              if (href) { item.href = href; }
              if (tag === 'input') { item.inputType = (node.getAttribute('type') || 'text'); }
              out.elements.push(item);
            }
            var picks = document.querySelectorAll('article,main,[role=main],#content,.content,body');
            var best = null, bestScore = -1;
            for (var k = 0; k < picks.length; k++) {
              var pick = picks[k];
              var words = (pick.innerText || '').trim();
              if (!words) { continue; }
              var linked = 0;
              var links = pick.querySelectorAll('a');
              for (var m = 0; m < links.length; m++) { linked += (links[m].innerText || '').length; }
              var score = words.length - linked;
              if (score > bestScore) { bestScore = score; best = pick; }
            }
            if (!scrolled) {
              out.text = ((best ? best.innerText : (document.body ? document.body.innerText : '')) || '').trim();
            } else {
              var root = best || document.body;
              if (root && document.body && root !== document.body) {
                var whole = root.getBoundingClientRect();
                if (whole.height > 0 && whole.bottom <= abEdge(root)) { root = document.body; }
              }
              out.text = root ? abFromViewport(root).trim() : '';
            }
            out.scroll = spot;
            out.url = String(location.href || '');
            out.title = String(document.title || '');
            return JSON.stringify(out);
          } catch (e) {
            return JSON.stringify({ text: '', elements: [], error: String(e) });
          }
        })()
        """#
    }

    /// Looks up an element by exact attribute comparison (no selector building).
    private static let findByRef = #"""
    function abFind(ref) {
      var all = document.querySelectorAll('[\#(BrowserWire.refAttribute)]');
      for (var i = 0; i < all.length; i++) {
        if (all[i].getAttribute('\#(BrowserWire.refAttribute)') === ref) { return all[i]; }
      }
      return null;
    }
    """#

    /// Detects and suppresses actions that would open the system file chooser
    /// (file inputs, labels pointing at them, `showPicker()` on a file input).
    private static let pickerGuard = #"""
    function abIsFileBox(n) {
      return !!n && n.nodeType === 1 && (n.tagName || '').toLowerCase() === 'input'
        && String(n.type || '').toLowerCase() === 'file';
    }
    function abClaimsClick(n) {
      var tag = (n.tagName || '').toLowerCase();
      if (tag === 'a' || tag === 'area') { return n.hasAttribute('href'); }
      if (tag === 'audio' || tag === 'video') { return n.hasAttribute('controls'); }
      return tag === 'button' || tag === 'select' || tag === 'textarea'
        || tag === 'details' || tag === 'iframe' || tag === 'embed';
    }
    function abOpensPicker(node) {
      for (var n = node; n && n.nodeType === 1; n = n.parentElement) {
        var tag = (n.tagName || '').toLowerCase();
        if (tag === 'input') { return abIsFileBox(n); }
        if (tag === 'label') { return abIsFileBox(n.control); }
        if (abClaimsClick(n)) { return false; }
      }
      return false;
    }
    function abWithoutPickers(run) {
      var hit = false;
      function stop(ev) {
        if (!(ev instanceof MouseEvent)) { return; }
        var path = ev.composedPath ? ev.composedPath() : [];
        if (abOpensPicker(path.length ? path[0] : ev.target)) {
          hit = true;
          ev.preventDefault();
        }
      }
      var proto = window.HTMLInputElement ? window.HTMLInputElement.prototype : null;
      var picker = proto ? proto.showPicker : null;
      if (picker) {
        proto.showPicker = function () {
          if (abIsFileBox(this)) { hit = true; return; }
          return picker.apply(this, arguments);
        };
      }
      window.addEventListener('click', stop, true);
      try {
        run();
      } finally {
        window.removeEventListener('click', stop, true);
        if (picker) { proto.showPicker = picker; }
      }
      return hit;
    }
    """#

    /// Cheap page fingerprint: FNV-1a over the body text (head and tail for very long
    /// pages) plus checkbox / radio states.
    static let pagePrint = """
    function abPagePrint() {
      var began = Date.now();
      var root = document.body || document.documentElement;
      var words = root ? String(root.innerText || '') : '';
      var n = words.length;
      var h = 2166136261;
      function abEat(from, to) {
        for (var i = from; i < to; i++) { h = Math.imul(h ^ words.charCodeAt(i), 16777619); }
      }
      if (n <= 200000) { abEat(0, n); } else { abEat(0, 100000); abEat(n - 100000, n); }
      var ticks = document.querySelectorAll('input[type=checkbox],input[type=radio]');
      for (var t = 0; t < ticks.length && t < 2000; t++) {
        h = Math.imul(h ^ (ticks[t].checked ? 49 : 48), 16777619);
      }
      return { n: n, h: (h >>> 0).toString(16), ms: Date.now() - began };
    }
    """

    static func pagePrintNow() -> String {
        #"""
        (function () {
          try {
            \#(pagePrint)
            return JSON.stringify({ print: abPagePrint() });
          } catch (e) {
            return JSON.stringify({ why: 'error', detail: String(e) });
          }
        })()
        """#
    }

    /// Clicks an element without focusing it. Refuses file choosers; returns the
    /// fingerprint taken before the click.
    static func click(ref: String) -> String {
        #"""
        (function (ref) {
          try {
            \#(findByRef)
            \#(pickerGuard)
            \#(pagePrint)
            var el = abFind(ref);
            if (!el) { return JSON.stringify({ why: 'gone' }); }
            if (abOpensPicker(el)) { return JSON.stringify({ why: 'file' }); }
            var before = null;
            try { before = abPagePrint(); } catch (e) { before = null; }
            var picked = abWithoutPickers(function () {
              if (typeof el.click === 'function') {
                el.click();
              } else {
                el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
              }
            });
            if (picked) { return JSON.stringify({ why: 'file' }); }
            return JSON.stringify({ ok: true, print: before });
          } catch (e) {
            return JSON.stringify({ why: 'error', detail: String(e) });
          }
        })(\#(literal(ref)))
        """#
    }

    /// Input types that accept typed text.
    static let typableInputs = ["text", "search", "email", "url", "tel", "number"]

    /// Replaces the value of a text input / textarea through the native setter and fires
    /// `input` + `change`, without focusing the element (the user's keyboard is never taken).
    /// Hard refusal for `type=password` and `autocomplete` containing "password".
    /// With `submit`, presses Enter afterwards (see `pressEnter`).
    static func type(ref: String, text: String, submit: Bool = false) -> String {
        let helpers = submit ? "\n" + pickerGuard + "\n" + pressEnter : ""
        let finish = submit ? #"""
        var entered = abPressEnter(el);
                    if (entered.picked) { return JSON.stringify({ why: 'file' }); }
                    return JSON.stringify({ ok: true, sent: entered.sent });
        """# : "return JSON.stringify({ ok: true });"
        return #"""
        (function (ref, text) {
          try {
            \#(findByRef)\#(helpers)
            var el = abFind(ref);
            if (!el) { return JSON.stringify({ why: 'gone' }); }
            var tag = (el.tagName || '').toLowerCase();
            var proto = null;
            if (tag === 'input') {
              var kind = String(el.type || 'text').toLowerCase();
              var auto = String(el.getAttribute('autocomplete') || '').toLowerCase();
              if (kind === 'password' || auto.indexOf('password') >= 0) {
                return JSON.stringify({ why: 'password' });
              }
              if (\#(jsArray(typableInputs)).indexOf(kind) < 0) {
                return JSON.stringify({ why: 'untypeable' });
              }
              proto = window.HTMLInputElement ? window.HTMLInputElement.prototype : null;
            } else if (tag === 'textarea') {
              proto = window.HTMLTextAreaElement ? window.HTMLTextAreaElement.prototype : null;
            } else {
              return JSON.stringify({ why: 'untypeable' });
            }
            if (el.disabled || el.readOnly) { return JSON.stringify({ why: 'untypeable' }); }
            var native = proto ? Object.getOwnPropertyDescriptor(proto, 'value') : null;
            if (!native || !native.set) { return JSON.stringify({ why: 'error', detail: 'no native value setter' }); }
            native.set.call(el, text);
            var typed;
            try {
              typed = new InputEvent('input', { bubbles: true, cancelable: false, inputType: 'insertText', data: text });
            } catch (e) {
              typed = new Event('input', { bubbles: true });
            }
            el.dispatchEvent(typed);
            el.dispatchEvent(new Event('change', { bubbles: true }));
            \#(finish)
          } catch (e) {
            return JSON.stringify({ why: 'error', detail: String(e) });
          }
        })(\#(literal(ref)), \#(literal(text)))
        """#
    }

    /// Synthesises keydown / keypress / keyup for Enter. If the page does not handle it,
    /// falls back to the browser's implicit submission rules (click the first submit
    /// button, or `requestSubmit()` when the form has exactly one text field).
    private static let pressEnter = #"""
    function abKey(el, kind) {
      var code = kind === 'keypress' ? 13 : 0;
      var init = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, charCode: code,
                   bubbles: true, cancelable: true, composed: true, view: window };
      var ev;
      try {
        ev = new KeyboardEvent(kind, init);
      } catch (e) {
        ev = document.createEvent('Event');
        ev.initEvent(kind, true, true);
      }
      var legacy = { key: 'Enter', keyCode: 13, which: 13, charCode: code };
      Object.keys(legacy).forEach(function (name) {
        if (ev[name] === legacy[name]) { return; }
        try { Object.defineProperty(ev, name, { value: legacy[name] }); } catch (e) {}
      });
      return el.dispatchEvent(ev);
    }
    function abSubmitLikeEnter(form) {
      var fields = ['text', 'search', 'email', 'url', 'tel', 'password', 'date', 'month', 'week',
                    'time', 'datetime-local', 'number'];
      var count = 0;
      var parts = form.elements;
      for (var i = 0; i < parts.length; i++) {
        var part = parts[i];
        var tag = (part.tagName || '').toLowerCase();
        var kind = String(part.type || '').toLowerCase();
        var sends = (tag === 'button' && kind === 'submit')
          || (tag === 'input' && (kind === 'submit' || kind === 'image'));
        if (sends && !(part.matches && part.matches(':disabled'))) { part.click(); return; }
        if (tag === 'input' && fields.indexOf(kind) >= 0) { count += 1; }
      }
      if (count === 1 && typeof form.requestSubmit === 'function') { form.requestSubmit(); }
    }
    function abPressEnter(el) {
      var sent = false;
      var tried = false;
      var form = el.form || null;
      function mine(node) { return !!node && !!form && (node === form || node.form === form); }
      function heard(ev) {
        if (mine(ev.target)) { sent = true; tried = true; }
      }
      function pressed(ev) {
        var node = ev.target;
        var tag = node && node.tagName ? node.tagName.toLowerCase() : '';
        var kind = node ? String(node.type || '').toLowerCase() : '';
        var sends = (tag === 'button' && kind === 'submit')
          || (tag === 'input' && (kind === 'submit' || kind === 'image'));
        if (sends && mine(node)) { tried = true; }
      }
      function hush(ev) {
        ev.preventDefault();
        if (mine(ev.target)) { tried = true; }
      }
      var picked = abWithoutPickers(function () {
        window.addEventListener('submit', heard, true);
        window.addEventListener('click', pressed, true);
        window.addEventListener('invalid', hush, true);
        try {
          var down = abKey(el, 'keydown');
          var press = down && abKey(el, 'keypress');
          var owner = (el.tagName || '').toLowerCase() === 'input' ? el.form : null;
          if (press && owner && !tried) { abSubmitLikeEnter(owner); }
          abKey(el, 'keyup');
        } finally {
          window.removeEventListener('submit', heard, true);
          window.removeEventListener('click', pressed, true);
          window.removeEventListener('invalid', hush, true);
        }
      });
      return { picked: picked, sent: sent };
    }
    """#

    /// Scrolls the page by one step; if the page cannot move in that direction, scrolls
    /// the largest visible inner container instead and remembers it for the next snapshot.
    static func scroll(dir: BrowserWire.Dir) -> String {
        #"""
        (function (dir) {
          try {
            \#(scrollSpot)
            var root = document.scrollingElement || document.documentElement || document.body;
            var view = window.innerHeight || (root ? root.clientHeight : 0) || 0;
            var step = Math.max(1, Math.round(view * \#(scrollShare)));
            var x = window.pageXOffset || 0;
            var y = window.pageYOffset || (root ? root.scrollTop : 0) || 0;
            var room = Math.max(0, (root ? root.scrollHeight : 0) - view);
            var pageMoves = dir === 'up' ? y > 1 : y < room - 1;
            if (!pageMoves) {
              var boxes = abBoxes(dir);
              for (var i = 0; i < boxes.length; i++) {
                var box = boxes[i].el;
                var from = box.scrollTop || 0;
                var jump = Math.max(1, Math.round(Math.min(box.clientHeight || 0, boxes[i].shown.h) * \#(scrollShare)));
                var to = dir === 'up' ? from - jump : from + jump;
                try {
                  box.scrollTo({ top: to, behavior: 'instant' });
                } catch (e) {
                  box.scrollTop = to;
                }
                if (Math.abs((box.scrollTop || 0) - from) >= 1) {
                  window.__abScrollBox = box;
                  var inBox = abBoxSpot(box);
                  return JSON.stringify({ at_top: inBox.at_top, at_bottom: inBox.at_bottom, box: true });
                }
              }
            }
            var target = dir === 'up' ? y - step : y + step;
            try {
              window.scrollTo({ left: x, top: target, behavior: 'instant' });
            } catch (e) {
              window.scrollTo(x, target);
            }
            var spot = abScrollSpot();
            return JSON.stringify({ at_top: spot.at_top, at_bottom: spot.at_bottom, box: false });
          } catch (e) {
            return JSON.stringify({ why: 'error', detail: String(e) });
          }
        })(\#(literal(dir.rawValue)))
        """#
    }

    /// JSON-encodes a string for safe use as a JS literal (U+2028 / U+2029 escaped too).
    static func literal(_ raw: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [raw]),
              let packed = String(data: data, encoding: .utf8),
              packed.count >= 2 else { return "\"\"" }
        return String(packed.dropFirst().dropLast())
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    private static func jsArray(_ items: [String]) -> String {
        "[" + items.map(literal).joined(separator: ", ") + "]"
    }
}

// MARK: - Results

/// Interprets the JSON returned by click / type / scroll scripts.
enum BrowserActResult {
    case done([String: Any])
    case refused(message: String, retryable: Bool)

    static func read(_ raw: String) -> BrowserActResult {
        guard let data = raw.data(using: .utf8),
              let map = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .refused(message: BrowserCopy.garbled, retryable: true)
        }
        guard let why = map["why"] as? String else { return .done(map) }
        switch why {
        case "gone": return .refused(message: BrowserCopy.refGone, retryable: false)
        case "password": return .refused(message: BrowserCopy.password, retryable: false)
        case "untypeable": return .refused(message: BrowserCopy.untypeable, retryable: false)
        case "file": return .refused(message: BrowserCopy.fileChooser, retryable: false)
        default: return .refused(message: BrowserCopy.actFailed, retryable: true)
        }
    }
}

/// A page fingerprint. Equality ignores `ms` (time taken to compute it).
struct BrowserPagePrint: Equatable {
    let length: Int
    let hash: String
    var ms: Int = 0

    static func == (lhs: BrowserPagePrint, rhs: BrowserPagePrint) -> Bool {
        lhs.length == rhs.length && lhs.hash == rhs.hash
    }

    static func from(_ raw: Any?) -> BrowserPagePrint? {
        guard let map = raw as? [String: Any],
              let length = (map["n"] as? NSNumber)?.intValue,
              let hash = map["h"] as? String, !hash.isEmpty else { return nil }
        return BrowserPagePrint(length: length, hash: hash,
                                ms: (map["ms"] as? NSNumber)?.intValue ?? 0)
    }

    static func read(_ raw: String) -> BrowserPagePrint? {
        guard let data = raw.data(using: .utf8),
              let map = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return from(map["print"])
    }
}

/// File name for an uploaded screenshot.
enum BrowserShotName {
    static func make(now: Date = Date()) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        return "webshot_\(fmt.string(from: now)).jpg"
    }
}
