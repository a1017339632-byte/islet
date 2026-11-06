import Foundation

// MARK: - Handover, hand-back and user activity
//
//   bridge -> host  {"type":"browser.handover","req_id":"...","note"?:"..."}
//   host -> bridge  {"type":"browser.handover.ok","req_id":"..."}
//   host -> bridge  {"type":"browser.handback","url","title","changed"?,"at"}
//   host -> bridge  {"type":"browser.user_action","req_id","what","count","url","title","added","at"}
//   host -> bridge  {"type":"browser.user_pref","mode":"live"|"done"}
//
// The user-activity listener only reports trusted (real finger) events, runs in an
// isolated content world, and never reports anything about password fields.

/// Frame names, fields and builders for handover and user activity.
enum BrowserHandWire {
    static let handover = "browser.handover"
    static let handoverOK = "browser.handover.ok"
    static let handback = "browser.handback"
    static let user = "browser.user_action"
    static let userPref = "browser.user_pref"

    enum Key {
        static let note = "note"
        static let handed = "handed"
        static let changed = "changed"
        static let at = "at"
        static let what = "what"
        static let count = "count"
        static let added = "added"
        static let mode = "mode"
    }

    static func handoverOKFrame(reqId: String) -> [String: Any] {
        [BrowserWire.Key.type: handoverOK, BrowserWire.Key.reqId: reqId]
    }

    static func handbackFrame(url: String, title: String, changed: Bool?, at: Date) -> [String: Any] {
        var frame: [String: Any] = [BrowserWire.Key.type: handback, BrowserWire.Key.url: url,
                                    BrowserWire.Key.title: title, Key.at: stamp(at)]
        if let changed { frame[Key.changed] = changed }
        return frame
    }

    static func userFrame(reqId: String, what: BrowserUserWhat, count: Int, url: String, title: String,
                         added: String, at: Date) -> [String: Any] {
        [BrowserWire.Key.type: user, BrowserWire.Key.reqId: reqId, Key.what: what.rawValue,
         Key.count: count, BrowserWire.Key.url: url, BrowserWire.Key.title: title,
         Key.added: added, Key.at: stamp(at)]
    }

    static func prefFrame(_ mode: BrowserUserMode) -> [String: Any] {
        [BrowserWire.Key.type: userPref, Key.mode: mode.rawValue]
    }

    /// ISO 8601 timestamp with the device time zone offset.
    static func stamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        let pen = ISO8601DateFormatter()
        pen.formatOptions = [.withInternetDateTime]
        pen.timeZone = timeZone
        return pen.string(from: date)
    }

    /// Host-generated id: `bh_` + 12 hex digits (for log readability only).
    static func newReqId() -> String {
        let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "bh_" + String(hex.prefix(12))
    }
}

/// How user activity is reported to the agent: `live` = as it happens (default),
/// `done` = only when the user taps "Done, show the agent".
enum BrowserUserMode: String, CaseIterable {
    case live, done

    static let defaultsKey = "browser_user_mode"

    static func load(_ defaults: UserDefaults) -> BrowserUserMode {
        defaults.string(forKey: defaultsKey).flatMap(BrowserUserMode.init(rawValue:)) ?? .live
    }

    var other: BrowserUserMode { self == .live ? .done : .live }

    var label: String { self == .live ? BrowserHandCopy.live : BrowserHandCopy.done }
}

/// The `what` of a `browser.user_action` frame.
enum BrowserUserWhat: String {
    case click, type, nav, submit
}

/// A single event reported by the injected listener.
enum BrowserUserAct: String {
    case click, type, submit
}

/// Coalesces user activity. A batch is flushed after `quietSeconds` without new
/// activity; a user navigation still in flight may delay it up to `navWaitCap`.
struct BrowserUserBatch: Equatable {
    static let quietSeconds: Double = 2
    static let navWaitCap: Double = 15

    private(set) var clicks = 0
    private(set) var typed = false
    private(set) var navs = 0

    var isEmpty: Bool { clicks == 0 && !typed && navs == 0 }

    mutating func add(_ act: BrowserUserAct) {
        switch act {
        case .click: clicks += 1
        case .type: typed = true
        case .submit: break
        }
    }

    mutating func addNav() {
        navs += 1
    }

    var what: BrowserUserWhat? {
        if navs > 0 { return .nav }
        if typed { return .type }
        return clicks > 0 ? .click : nil
    }

    func count(for what: BrowserUserWhat) -> Int {
        switch what {
        case .click: return max(1, clicks)
        case .nav: return max(1, navs)
        default: return 1
        }
    }

    mutating func clear() {
        clicks = 0
        typed = false
        navs = 0
    }
}

/// Computes the text lines that appeared since the baseline (capped at `cap` chars).
enum BrowserAdded {
    static let cap = 1500

    static func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
    }

    static func pick(now: [String], seen: Set<String>?) -> String {
        var kept: [String] = []
        var taken = Set<String>()
        for line in now where !(seen?.contains(line) ?? false) && !taken.contains(line) {
            taken.insert(line)
            kept.append(line)
        }
        return clip(kept.joined(separator: "\n"))
    }

    static func clip(_ text: String) -> String {
        guard text.count > cap else { return text }
        return String(text.prefix(cap - 1)) + "…"
    }
}

/// Listener injected into an isolated content world (`worldName`), posting to the
/// `channel` message handler. Only `isTrusted` events are reported; `submit` only
/// counts if a trusted touch / key happened within the last 1.5 s.
enum BrowserUserScript {
    static let channel = "abUser"
    static let worldName = "agent_browser_user"

    static let hook = #"""
    (function () {
      if (window.__abUserHooked) { return; }
      window.__abUserHooked = true;
      var lastHand = 0;
      var texty = ['text', 'search', 'email', 'url', 'tel', 'number'];
      function tell(kind) {
        try { window.webkit.messageHandlers.abUser.postMessage({ kind: kind }); } catch (e) {}
      }
      function hand(ev) { if (ev.isTrusted) { lastHand = Date.now(); } }
      function typing(node) {
        if (!node) { return false; }
        if (node.isContentEditable) { return true; }
        var tag = String(node.tagName || '').toLowerCase();
        if (tag === 'textarea') { return true; }
        if (tag !== 'input') { return false; }
        return texty.indexOf(String(node.type || 'text').toLowerCase()) >= 0;
      }
      document.addEventListener('pointerdown', hand, true);
      document.addEventListener('touchstart', hand, { capture: true, passive: true });
      document.addEventListener('keydown', hand, true);
      document.addEventListener('click', function (ev) {
        if (!ev.isTrusted) { return; }
        lastHand = Date.now();
        tell('click');
      }, true);
      document.addEventListener('input', function (ev) {
        if (!ev.isTrusted || !typing(ev.target)) { return; }
        tell('type');
      }, true);
      document.addEventListener('submit', function () {
        if (Date.now() - lastHand > 1500) { return; }
        tell('submit');
      }, true);
    })();
    """#

    /// Reads the visible body text (capped) for the "new text" diff.
    static let text = #"""
    (function () {
      try {
        var root = document.body || document.documentElement;
        var words = root ? String(root.innerText || '') : '';
        if (words.length > 300000) { words = words.slice(0, 300000); }
        return JSON.stringify({ text: words });
      } catch (e) {
        return JSON.stringify({ why: 'error', detail: String(e) });
      }
    })()
    """#

    static let textMark = "ab-user-text"

    static func readLines(_ raw: String) -> [String]? {
        guard let data = raw.data(using: .utf8),
              let map = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let text = map["text"] as? String else { return nil }
        return BrowserAdded.lines(text)
    }
}

/// Baseline taken when the browser is handed over, used to compute `changed` on hand-back.
struct BrowserHandStart: Equatable {
    var navs: Int
    var url: String?
    var print: BrowserPagePrint? = nil
    var typed = false
}

/// User-visible strings for the handover UI. Hosts should localise them.
enum BrowserHandCopy {
    static let handedToUser = "Your turn"
    static let showAgent = "Done, show the agent"
    static let live = "Report as I go"
    static let done = "Report when done"

    static let visible = [handedToUser, showAgent, live, done]

    static func line(_ name: String) -> String {
        name.isEmpty ? handedToUser : "\(handedToUser) · \(name)"
    }

    /// Message for the agent: hands-on op refused while handed over.
    static let inUserHands = "The browser is in the user's hands right now. You will be notified when the user is done."
}
