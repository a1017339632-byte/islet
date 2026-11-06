import Combine
import Foundation

// MARK: - In-app agent browser: the service
//
// Receives requests -> runs them through `BrowserGate` -> drives the web view ->
// sends exactly one reply per request. Frames and rules live in `Browser.swift`.
//
// Nothing is queued across a disconnect: if a reply cannot be sent it is dropped,
// and the bridge's own timeout covers it.
//
// The host wires the service up through closures only (`sender`, `foreground`,
// `uploader`, `online`, `onNote`) and the package supplies the `BrowserEngine` (`BrowserWebEngine`). See docs/IOS.md.

/// The page side, abstracted so the service can be tested without a real web view.
/// `BrowserWebEngine` implements it with a `WKWebView`.
@MainActor
protocol BrowserEngine: AnyObject {
    var canGoBack: Bool { get }
    /// The address the web view is really showing (including fragment changes and
    /// history updates made by single-page apps).
    var currentURL: String? { get }
    /// Title of the page currently shown.
    var currentTitle: String? { get }
    /// Last time the user's finger touched the web page (`.distantPast` if never).
    /// Navigations that start after a user touch are not attributed to a pending agent click.
    var lastUserTouch: Date { get }
    /// Opens a page and returns when it finishes loading, fails, or the engine's own
    /// open deadline fires, whichever comes first. A deadline is still a success (the page
    /// keeps loading in the background); `BrowserService.loading` tells whether it finished.
    func open(_ url: URL) async -> Result<(url: String, title: String), BrowserTrouble>
    /// Runs a script in the page and returns the string it produced.
    func evaluate(_ js: String) async -> Result<String, BrowserTrouble>
    /// Captures the visible page as compressed JPEG data.
    func shoot() async -> Result<Data, BrowserTrouble>
    /// Goes back one page. false = already at the first page.
    func goBack() -> Bool
    /// Closes the page: stop loading and show a blank page. The web view itself stays.
    func blank()
    /// While an agent click / type+submit is in flight, suppress system file choosers the
    /// page tries to open. Calls come in pairs and may nest. The engine reports a
    /// suppressed attempt via `BrowserService.notePickerStopped()`, and must release the
    /// hold immediately when the user touches the page (user-initiated pickers still work).
    func holdFilePickers(_ on: Bool)
    /// Called right before the engine is used, so a host that unmounts an off-screen web
    /// view (to save power) can remount it first.
    func willWork()
}

extension BrowserEngine {
    func willWork() {}
}

/// A failure with a sentence for the agent (sent verbatim as `error.message`).
public struct BrowserTrouble: Error, Equatable {
    public let human: String
    /// Network failures are worth retrying; a bad address is not.
    public let retryable: Bool
    /// Do not roll back state when this failure is reported for an `open`: the request
    /// was superseded by a newer navigation that owns the bookkeeping now, or the engine
    /// already handled it.
    let keepBooks: Bool
    /// Optional different wording shown to the user in the panel.
    let forUser: String?
    var userWords: String { forUser ?? human }
    public init(_ human: String, retryable: Bool = true, keepBooks: Bool = false, userWords: String? = nil) {
        self.human = human
        self.retryable = retryable
        self.keepBooks = keepBooks
        self.forUser = userWords
    }
}

/// How a navigation started. Ownership attribution depends on it.
enum BrowserNavKind {
    /// Loaded by the host itself (agent `open` or address bar); see `pendingOwner`.
    case programmatic
    /// The user tapped a link in the page.
    case link
    /// Back / forward (agent `back` or the panel button).
    case backForward
    /// Everything else (script redirects, form submissions).
    case other
}

/// Owns the browser state machine. Publishes state for the host UI and talks to the
/// bridge through `sender`.
@MainActor
public final class BrowserService: ObservableObject {

    // MARK: Published state for the host UI
    @Published public private(set) var hasPage = false
    @Published public private(set) var pageURL: String? = nil
    @Published public private(set) var pageTitle: String? = nil
    /// Who navigated to the current page (the ownership gate reads this).
    @Published public private(set) var owner: BrowserOwner? = nil
    /// The user shared the current page. Reset by every navigation, with one exception:
    /// in `live` mode a user navigation away from an agent-readable page stays shared.
    @Published public private(set) var shared = false
    /// Reported as `loading` in open / snapshot / screenshot bodies.
    @Published public private(set) var loading = false
    @Published public private(set) var progress: Double = 0
    /// Panel expanded. Collapsed by default; an agent `open` does not expand it.
    @Published public internal(set) var expanded = false
    /// Error text to show in the panel.
    @Published public private(set) var trouble: String? = nil
    /// Host-UI-only presentation flag (e.g. a compact card vs. a strip). Never reported.
    @Published private(set) var cardFolded = false

    /// The agent handed the browser to the user. While true, agent hands-on ops are
    /// refused; reads and close still work. Ends on hand-back, close, or reclaim.
    @Published public private(set) var handed = false
    /// Optional sentence from the agent to show while handed over.
    @Published public private(set) var handNote: String? = nil
    /// `live` (report user activity as it happens, default) or `done` (report only when
    /// the user taps Done). Persisted in UserDefaults; every change sends `browser.user_pref`.
    @Published private(set) var userMode: BrowserUserMode

    /// The current session was opened by the user from the host UI (`browser.user_open`),
    /// from that moment until the page is closed.
    @Published public private(set) var selfOpened = false
    /// Incremented when the address bar should take focus.
    @Published private(set) var addressAsk = 0

    public var stripName: String { BrowserURL.shortName(title: pageTitle, url: pageURL) }
    /// The user can share the current page ("Share with agent").
    public var canHandOver: Bool { hasPage && owner == .user && !shared }
    /// The agent may read / act on the current page.
    public var agentCanRead: Bool { hasPage && !(owner == .user && !shared) }
    /// Show the "Done, show the agent" control.
    public var canShowAgent: Bool { hasPage && (handed || userMode == .done || canHandOver) }
    var userLooking: Bool { selfOpened && owner != .agent }

    // MARK: Wiring (closures supplied by the host)

    /// Sends one frame to the bridge. Return false when offline; frames are not queued.
    public var sender: (([String: Any]) -> Bool)?
    /// Whether the host app is in the foreground.
    public var foreground: () -> Bool = { true }
    /// Uploads a JPEG screenshot and returns the receipt (its fields become the
    /// screenshot body). nil = no upload endpoint configured.
    public var uploader: ((Data) async -> Result<[String: Any], BrowserTrouble>)?
    /// Whether the bridge connection is currently up.
    public var online: () -> Bool = { true }
    /// Shows a short transient message to the user (toast).
    public var onNote: ((String) -> Void)?

    /// A transient note shown inside the panel; cleared automatically.
    @Published public private(set) var panelNote: String? = nil

    public func flashPanelNote(_ text: String) {
        panelNote = text
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: BrowserOpenWire.noteLinger)
            guard let self, self.panelNote == text else { return }
            self.panelNote = nil
        }
    }

    // MARK: Internal bookkeeping
    private(set) var engine: BrowserEngine?
    private(set) var stageMounted = false

    private var pendingOwner: BrowserOwner? = nil
    /// Owner of every page landed on in this session, for back / forward attribution.
    private var ownerByURL: [String: BrowserOwner] = [:]
    /// Pages the user has shared in this session.
    private var shownURLs: Set<String> = []
    /// The last page that finished loading; restored when a navigation fails.
    private var landed: (url: String, title: String, owner: BrowserOwner?)? = nil
    private var navCommitted = false
    private var blockedDownload = false
    private var clickWatches: [BrowserClickWatch] = []
    private(set) var navigationStarts = 0
    private var inFlightCancelled = false

    // Deadlines (overridable in tests)
    var clickNoticeSeconds: Double = BrowserWire.clickNoticeSeconds
    var clickTotalSeconds: Double = BrowserWire.clickTotalSeconds
    var actReplySeconds: Double = BrowserWire.actReplySeconds
    var scrollReplySeconds: Double = BrowserWire.scrollReplySeconds
    var readStepSeconds: Double = BrowserWire.readStepSeconds
    var shotStepSeconds: Double = BrowserWire.shotStepSeconds
    private var openInFlight: String? = nil
    private var openLanded = false

    private(set) var reclaimed: BrowserLostPage? = nil
    private var lastState: BrowserStateNote? = nil
    private var lastSentState: BrowserStateNote? = nil

    // Handover and user-activity reporting
    private var handStart: BrowserHandStart? = nil
    private var userBatch = BrowserUserBatch()
    private var userTimer: Task<Void, Never>? = nil
    private var userSeen: Set<String>? = nil
    private var userSeenReading = false
    private var userNavPending = false
    private var userNavShares = false
    private var userTypedPending = false
    private var agentBackPending = false
    private var userBackPending = false
    private var userNavStartedAt: Date? = nil
    private var userOpening: BrowserUserOpening? = nil
    private var askedOpenIds: [String] = []
    var userQuietSeconds: Double = BrowserUserBatch.quietSeconds
    var userNavWaitCap: Double = BrowserUserBatch.navWaitCap
    var userReadSeconds: Double = 3
    static let userLeadSeconds: Double = 3
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        userMode = BrowserUserMode.load(defaults)
    }

    #if DEBUG
    private(set) var log: [String] = []
    private func note(_ line: String) {
        log.append(line)
        print("[browser] \(line)")
    }
    #else
    private func note(_ line: String) {}
    #endif

    // MARK: Lifecycle

    /// Call when the web view has been mounted in the view hierarchy.
    func stageUp(_ engine: BrowserEngine) {
        self.engine = engine
        stageMounted = true
        note("stage mounted")
    }

    /// Call when the web view has been removed from the view hierarchy.
    func stageDown() {
        stageMounted = false
        note("stage unmounted")
    }

    // MARK: Incoming frames

    /// Entry point for `browser.request` and `browser.handover` frames from the bridge.
    func take(_ payload: Payload) {
        if payload.type == BrowserHandWire.handover {
            takeHandover(payload)
            return
        }
        guard payload.type == BrowserWire.request else { return }
        guard let ask = BrowserRequest.from(payload) else {
            note("request has no req_id; dropped (no reply possible)")
            return
        }
        let allowed = ask.op == .open ? (BrowserURL.allow(ask.rawURL) != nil) : true
        let verdict = BrowserGate.judge(BrowserGate.Ask(
            op: ask.op, foreground: foreground(), ready: ready,
            hasPage: hasPage, loading: loading, committed: navCommitted,
            owner: owner, shared: shared,
            urlAllowed: allowed,
            hasRef: ask.ref != nil, hasText: ask.text != nil,
            dirKnown: ask.knownDir != nil,
            reclaimed: reclaimed,
            handed: handed))
        if case .refuse(let message, let retryable) = verdict {
            note("\(ask.reqId) \(ask.op?.rawValue ?? "unknown") refused: \(message)")
            reply(BrowserWire.errFrame(reqId: ask.reqId, message: message, retryable: retryable))
            return
        }
        guard let op = ask.op, let engine else {
            reply(BrowserWire.errFrame(reqId: ask.reqId,
                                       message: BrowserCopy.asleep, retryable: true))
            return
        }
        note("\(ask.reqId) accepted \(op.rawValue)")
        engine.willWork()
        switch op {
        case .open:
            guard let url = BrowserURL.allow(ask.rawURL) else {
                reply(BrowserWire.errFrame(reqId: ask.reqId,
                                           message: BrowserCopy.badScheme, retryable: false))
                return
            }
            Task { await runOpen(reqId: ask.reqId, url: url, engine: engine) }
        case .snapshot:
            Task { await runSnapshot(reqId: ask.reqId, engine: engine) }
        case .screenshot:
            Task { await runScreenshot(reqId: ask.reqId, engine: engine) }
        case .back:
            runBack(reqId: ask.reqId, engine: engine)
        case .close:
            runClose(reqId: ask.reqId, engine: engine)
        case .click:
            let arrived = Date()
            Task { await runClick(reqId: ask.reqId, ref: ask.ref ?? "", engine: engine,
                                  arrived: arrived) }
        case .type:
            let arrived = Date()
            Task { await runType(reqId: ask.reqId, ref: ask.ref ?? "", text: ask.text ?? "",
                                 submit: ask.submit, engine: engine, arrived: arrived) }
        case .scroll:
            let arrived = Date()
            Task { await runScroll(reqId: ask.reqId, dir: ask.knownDir ?? .down, engine: engine,
                                   arrived: arrived) }
        }
    }

    var ready: Bool { stageMounted && engine != nil }

    // MARK: Ops

    /// A newer `open` supersedes a pending one (the old request is answered first).
    private func runOpen(reqId: String, url: URL, engine: BrowserEngine) async {
        if let stale = openInFlight {
            reply(BrowserWire.errFrame(reqId: stale,
                                       message: BrowserCopy.replacedByAgent,
                                       retryable: false))
        }
        openInFlight = reqId
        pendingOwner = .agent
        trouble = nil
        reclaimed = nil
        openLanded = false
        hasPage = true
        loading = true
        progress = 0.02
        let result = await engine.open(url)
        guard openInFlight == reqId else { return }
        openInFlight = nil
        switch result {
        case .success(let landed):
            if !openLanded {
                reply(BrowserWire.stateFrame(phase: BrowserWire.livePhase(expanded: expanded),
                                             by: .agent, owner: owner ?? .agent, shared: shared))
            }
            openLanded = false
            reply(BrowserWire.okFrame(reqId: reqId,
                                      body: [BrowserWire.Key.url: landed.url,
                                             BrowserWire.Key.title: landed.title,
                                             BrowserWire.Key.loading: loading]))
        case .failure(let bad):
            if !bad.keepBooks { noteFailure(bad.userWords) }
            reply(BrowserWire.errFrame(reqId: reqId, message: bad.human,
                                       retryable: bad.retryable))
        }
    }

    private func runSnapshot(reqId: String, engine: BrowserEngine) async {
        let stillLoading = loading
        guard let ran = await raced("\(reqId) snapshot", until: Date().addingTimeInterval(readStepSeconds),
                                    { await engine.evaluate(BrowserScript.snapshot()) }) else {
            reply(BrowserWire.errFrame(reqId: reqId, message: BrowserCopy.pageBusyRead, retryable: true))
            return
        }
        switch ran {
        case .failure(let bad):
            reply(BrowserWire.errFrame(reqId: reqId, message: bad.human,
                                       retryable: bad.retryable))
        case .success(let raw):
            guard let data = raw.data(using: .utf8),
                  let map = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                reply(BrowserWire.errFrame(reqId: reqId,
                                           message: BrowserCopy.garbled,
                                           retryable: true))
                return
            }
            if let broke = map[BrowserWire.Key.error] as? String, !broke.isEmpty {
                note("\(reqId) snapshot script threw in page: \(broke)")
                reply(BrowserWire.errFrame(reqId: reqId, message: BrowserCopy.snapshotBroke,
                                           retryable: true))
                return
            }
            let text = (map[BrowserWire.Key.text] as? String) ?? ""
            let elements = ((map[BrowserWire.Key.elements] as? [Any]) ?? [])
                .compactMap { $0 as? [String: Any] }
                .compactMap(BrowserElement.from)
            var extra = BrowserWire.stamp([:], owner: owner, shared: shared, loading: stillLoading)
            extra[BrowserWire.Key.url] = (map[BrowserWire.Key.url] as? String)
                ?? engine.currentURL ?? pageURL ?? ""
            extra[BrowserWire.Key.title] = (map[BrowserWire.Key.title] as? String)
                ?? engine.currentTitle ?? pageTitle ?? ""
            if let spot = BrowserSnapshotBody.scrollSpot(map[BrowserWire.Key.scroll]) {
                extra[BrowserWire.Key.scroll] = spot
            }
            let packed = BrowserSnapshotBody.fit(text: text, elements: elements, extra: extra)
            if packed.clipped { note("\(reqId) page is long; body clipped") }
            reply(BrowserWire.okFrame(reqId: reqId, body: packed.body))
        }
    }

    private func runScreenshot(reqId: String, engine: BrowserEngine) async {
        let stillLoading = loading
        let shownURL = engine.currentURL ?? pageURL ?? ""
        let shownTitle = engine.currentTitle ?? pageTitle ?? ""
        guard let shot = await raced("\(reqId) screenshot", until: Date().addingTimeInterval(shotStepSeconds),
                                     { await engine.shoot() }) else {
            reply(BrowserWire.errFrame(reqId: reqId, message: BrowserCopy.pageBusyShot, retryable: true))
            return
        }
        switch shot {
        case .failure(let bad):
            reply(BrowserWire.errFrame(reqId: reqId, message: bad.human, retryable: true))
        case .success(let jpeg):
            guard let uploader else {
                reply(BrowserWire.errFrame(reqId: reqId, message: BrowserCopy.noServer,
                                           retryable: true))
                return
            }
            switch await uploader(jpeg) {
            case .failure(let bad):
                reply(BrowserWire.errFrame(reqId: reqId, message: bad.human, retryable: bad.retryable))
            case .success(let receipt):
                var body = BrowserWire.stamp(receipt, owner: owner, shared: shared, loading: stillLoading)
                body[BrowserWire.Key.pageURL] = shownURL
                body[BrowserWire.Key.pageTitle] = shownTitle
                reply(BrowserWire.okFrame(reqId: reqId, body: body))
            }
        }
    }

    private func runBack(reqId: String, engine: BrowserEngine) {
        pendingOwner = nil
        let went = engine.goBack()
        agentBackPending = went
        reply(BrowserWire.okFrame(reqId: reqId, body: [BrowserWire.Key.wentBack: went]))
    }

    private func runClose(reqId: String, engine: BrowserEngine) {
        let lastOwner = owner
        let lastShared = shared
        teardown(engine)
        reply(BrowserWire.okFrame(reqId: reqId, body: [BrowserWire.Key.closed: true]))
        reply(BrowserWire.stateFrame(phase: BrowserWire.stateClosed, by: .agent,
                                     owner: lastOwner, shared: lastShared))
    }

    /// Click, then wait briefly to see whether it navigated, and report whether the page
    /// text changed. File choosers opened during the click are suppressed and refused.
    private func runClick(reqId: String, ref: String, engine: BrowserEngine,
                          arrived: Date) async {
        let watch = BrowserClickWatch()
        clickWatches.append(watch)
        let hold = BrowserPickerHold(engine: engine, grace: clickNoticeSeconds)
        defer {
            clickWatches.removeAll { $0 === watch }
            hold.answered()
        }
        let hardLine = arrived.addingTimeInterval(actReplySeconds)
        let before = engine.currentURL
        guard let ran = await raced("\(reqId) click \(ref)", until: hardLine, hold: hold,
                                    { await engine.evaluate(BrowserScript.click(ref: ref)) }) else {
            reply(BrowserWire.errFrame(reqId: reqId, message: BrowserCopy.pageBusy, retryable: false))
            return
        }
        var printed: BrowserPagePrint? = nil
        switch ran {
        case .failure(let bad):
            reply(BrowserWire.errFrame(reqId: reqId, message: bad.human, retryable: bad.retryable))
            return
        case .success(let raw):
            switch BrowserActResult.read(raw) {
            case .refused(let message, let retryable):
                note("\(reqId) click \(ref) refused: \(message)")
                reply(BrowserWire.errFrame(reqId: reqId, message: message, retryable: retryable))
                return
            case .done(let map):
                printed = BrowserPagePrint.from(map["print"])
            }
        }
        let waited = await afterAction(watch, arrived: arrived, before: before, engine: engine)
        if watch.gone {
            replyGone(reqId, "click \(ref)")
            return
        }
        guard var body = waited else {
            note("\(reqId) click \(ref) -> page tried to open a file chooser; held")
            reply(BrowserWire.errFrame(reqId: reqId, message: BrowserCopy.fileChooser, retryable: false))
            return
        }
        if body[BrowserWire.Key.navigated] as? Bool == true {
            body[BrowserWire.Key.changed] = true
        } else if let printed {
            guard let now = await raced("\(reqId) click \(ref) fingerprint before reply", until: hardLine, hold: hold,
                                        { await engine.evaluate(BrowserScript.pagePrintNow()) }) else {
                reply(BrowserWire.errFrame(reqId: reqId, message: BrowserCopy.pageBusy, retryable: false))
                return
            }
            if case .success(let raw) = now, let after = BrowserPagePrint.read(raw) {
                body[BrowserWire.Key.changed] = after != printed
                note("\(reqId) click \(ref) text fingerprint before click \(printed.length) chars \(printed.hash) (\(printed.ms) ms), "
                     + "before reply \(after.length) chars \(after.hash) (\(after.ms) ms)")
            } else {
                note("\(reqId) click \(ref) fingerprint before reply unavailable; changed omitted")
            }
            if watch.gone {
                replyGone(reqId, "click \(ref)")
                return
            }
            if watch.picked {
                note("\(reqId) click \(ref) -> page tried to open a file chooser; held")
                reply(BrowserWire.errFrame(reqId: reqId, message: BrowserCopy.fileChooser, retryable: false))
                return
            }
        }
        note("\(reqId) click \(ref) → \(body[BrowserWire.Key.navigated] as? Bool == true ? "navigated" : "no navigation")"
             + "\((body[BrowserWire.Key.changed] as? Bool).map { $0 ? ", text changed" : ", text unchanged" } ?? "")")
        reply(BrowserWire.okFrame(reqId: reqId, body: body))
    }

    /// Waits for the navigation (if any) caused by a click / Enter. nil = a file chooser was hit.
    private func afterAction(_ watch: BrowserClickWatch, arrived: Date, before: String?,
                             engine: BrowserEngine) async -> [String: Any]? {
        let notice = arrived.addingTimeInterval(clickNoticeSeconds)
        let deadline = arrived.addingTimeInterval(clickTotalSeconds)
        func moved() -> String? {
            guard let now = engine.currentURL, now != before else { return nil }
            return now
        }
        while !watch.started, !watch.blocked, !watch.failed, !watch.picked, moved() == nil,
              Date() < notice { await nap() }
        if watch.started {
            while watch.attributing, !watch.picked, Date() < deadline { await nap() }
        }
        if watch.picked { return nil }
        if let landedURL = watch.landed {
            return [BrowserWire.Key.navigated: true, BrowserWire.Key.url: landedURL]
        } else if watch.started, !watch.failed, !watch.blocked {
            return [BrowserWire.Key.navigated: true,
                    BrowserWire.Key.url: pageURL ?? engine.currentURL ?? ""]
        } else if watch.failed || watch.blocked {
            return [BrowserWire.Key.navigated: false,
                    BrowserWire.Key.url: pageURL ?? engine.currentURL ?? ""]
        } else if let now = moved() {
            return [BrowserWire.Key.navigated: true, BrowserWire.Key.url: now]
        }
        return [BrowserWire.Key.navigated: false,
                BrowserWire.Key.url: engine.currentURL ?? pageURL ?? ""]
    }

    private func runType(reqId: String, ref: String, text: String, submit: Bool,
                         engine: BrowserEngine, arrived: Date) async {
        let watch: BrowserClickWatch? = submit ? BrowserClickWatch() : nil
        let hold: BrowserPickerHold? = submit ? BrowserPickerHold(engine: engine, grace: clickNoticeSeconds) : nil
        if let watch { clickWatches.append(watch) }
        defer {
            if let watch { clickWatches.removeAll { $0 === watch } }
            hold?.answered()
        }
        let before = engine.currentURL
        guard let ran = await raced("\(reqId) type \(ref)", until: arrived.addingTimeInterval(actReplySeconds),
                                    hold: hold,
                                    { await engine.evaluate(BrowserScript.type(ref: ref, text: text,
                                                                               submit: submit)) }) else {
            reply(BrowserWire.errFrame(reqId: reqId, message: BrowserCopy.pageBusy, retryable: false))
            return
        }
        switch ran {
        case .failure(let bad):
            reply(BrowserWire.errFrame(reqId: reqId, message: bad.human, retryable: bad.retryable))
        case .success(let raw):
            switch BrowserActResult.read(raw) {
            case .refused(let message, let retryable):
                note("\(reqId) type \(ref) refused: \(message)")
                reply(BrowserWire.errFrame(reqId: reqId, message: message, retryable: retryable))
            case .done(let map):
                guard let watch else {
                    reply(BrowserWire.okFrame(reqId: reqId, body: [BrowserWire.Key.typed: true]))
                    return
                }
                let waited = await afterAction(watch, arrived: arrived, before: before, engine: engine)
                if watch.gone {
                    replyGone(reqId, "type \(ref)")
                    return
                }
                guard var body = waited else {
                    note("\(reqId) type \(ref) Enter -> page tried to open a file chooser; held")
                    reply(BrowserWire.errFrame(reqId: reqId, message: BrowserCopy.fileChooser,
                                               retryable: false))
                    return
                }
                body[BrowserWire.Key.typed] = true
                let sent = (map["sent"] as? Bool) == true ? "form submitted" : "form not submitted"
                note("\(reqId) type \(ref) Enter (\(sent)) -> \(body[BrowserWire.Key.navigated] as? Bool == true ? "navigated" : "no navigation")")
                reply(BrowserWire.okFrame(reqId: reqId, body: body))
            }
        }
    }

    private func runScroll(reqId: String, dir: BrowserWire.Dir, engine: BrowserEngine,
                           arrived: Date) async {
        guard let ran = await raced("\(reqId) scroll \(dir.rawValue)",
                                    until: arrived.addingTimeInterval(scrollReplySeconds),
                                    { await engine.evaluate(BrowserScript.scroll(dir: dir)) }) else {
            reply(BrowserWire.errFrame(reqId: reqId, message: BrowserCopy.pageBusy, retryable: false))
            return
        }
        switch ran {
        case .failure(let bad):
            reply(BrowserWire.errFrame(reqId: reqId, message: bad.human, retryable: bad.retryable))
        case .success(let raw):
            switch BrowserActResult.read(raw) {
            case .refused(let message, let retryable):
                reply(BrowserWire.errFrame(reqId: reqId, message: message, retryable: retryable))
            case .done(let map):
                guard let top = map[BrowserWire.Key.atTop] as? Bool,
                      let bottom = map[BrowserWire.Key.atBottom] as? Bool else {
                    reply(BrowserWire.errFrame(reqId: reqId, message: BrowserCopy.garbled,
                                               retryable: true))
                    return
                }
                let inBox = (map[BrowserWire.Key.box] as? Bool) ?? false
                reply(BrowserWire.okFrame(reqId: reqId,
                                          body: [BrowserWire.Key.atTop: top,
                                                 BrowserWire.Key.atBottom: bottom,
                                                 BrowserWire.Key.box: inBox]))
            }
        }
    }

    private func nap() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    /// Runs `work` against a deadline. Returns nil when the deadline fires first; a late
    /// result is discarded so the request is never answered twice.
    private func raced<T>(_ what: String, until deadline: Date, hold: BrowserPickerHold? = nil,
                          _ work: @escaping @MainActor () async -> T) async -> T? {
        guard deadline > Date() else {
            note("\(what) deadline already passed; not injecting")
            return nil
        }
        let race = BrowserRace<T>()
        return await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            race.waiter = cont
            let clock = Task { @MainActor [weak self] in
                let wait = max(0, deadline.timeIntervalSinceNow)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard !Task.isCancelled, race.open else { return }
                hold?.straggling()
                self?.note("\(what) deadline reached, page has not answered (page busy); replying now")
                race.settle(nil)
            }
            Task { @MainActor [weak self] in
                let value = await work()
                clock.cancel()
                guard race.open else {
                    self?.dropLate(what)
                    hold?.cameBack()
                    return
                }
                race.settle(value)
            }
        }
    }

    private func replyGone(_ reqId: String, _ what: String) {
        let words = reclaimedWords()
        note("\(reqId) \(what) web content process reclaimed while waiting for navigation: \(words)")
        reply(BrowserWire.errFrame(reqId: reqId, message: words, retryable: false))
    }

    private func dropLate(_ what: String) {
        note("\(what) result arrived late; discarded (no second reply)")
        #if DEBUG
        debugLateDrops += 1
        #endif
    }

    // MARK: User actions from the host UI

    /// The user entered an address in the panel's address bar.
    public func userOpens(_ typed: String) {
        guard let engine else { return }
        engine.willWork()
        guard let url = BrowserURL.fromAddressBar(typed) else {
            trouble = "Only http or https addresses can be opened."
            return
        }
        trouble = nil
        reclaimed = nil
        pendingOwner = .user
        userTypedPending = true
        Task {
            let result = await engine.open(url)
            switch result {
            case .success:
                break
            case .failure(let bad):
                if !bad.keepBooks { self.noteFailure(bad.userWords) }
            }
        }
    }

    /// The user tapped the panel back button.
    public func userGoesBack() {
        guard let engine else { return }
        engine.willWork()
        pendingOwner = nil
        userBackPending = engine.goBack()
    }

    /// The user tapped "Share with agent" on a page the user opened.
    public func userHandsOver() {
        guard hasPage else { return }
        shared = true
        if let pageURL { shownURLs.insert(pageURL) }
        note("user shared the current page with the agent")
        reply(BrowserWire.stateFrame(phase: BrowserWire.stateOpened, by: .user,
                                     owner: owner, shared: true))
        userSeen = nil
    }

    /// The user closed the browser.
    public func userCloses() {
        guard let engine else { return }
        let lastOwner = owner
        let lastShared = shared
        teardown(engine)
        reply(BrowserWire.stateFrame(phase: BrowserWire.stateClosed, by: .user,
                                     owner: lastOwner, shared: lastShared))
    }

    /// The user expanded / collapsed the panel. Collapsing is not closing.
    public func setExpanded(_ on: Bool) {
        if !on, selfOpened, !hasPage, !loading {
            note("user-opened blank session collapsed before any page loaded; treating as close")
            userCloses()
            return
        }
        setPanel(on, by: .user)
    }

    /// Host-UI-only presentation change; nothing is reported.
    func setCardFolded(_ on: Bool) {
        guard cardFolded != on else { return }
        cardFolded = on
        note(on ? "card folded (user)" : "card unfolded (user)")
    }

    /// `browser.handover`: the agent hands the browser to the user (for sign-in, payment,
    /// anything the user must do personally).
    private func takeHandover(_ payload: Payload) {
        let reqId = (payload.string(BrowserWire.Key.reqId) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reqId.isEmpty else {
            note("handover frame has no req_id; dropped (no reply possible)")
            return
        }
        guard foreground(), ready, let engine else {
            reply(BrowserWire.errFrame(reqId: reqId, message: BrowserCopy.asleep, retryable: true))
            return
        }
        guard hasPage else {
            let message = reclaimed.map { BrowserCopy.reclaimed($0.url) } ?? BrowserCopy.noPage
            reply(BrowserWire.errFrame(reqId: reqId, message: message, retryable: false))
            return
        }
        engine.willWork()
        let words = (payload.string(BrowserHandWire.Key.note) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        handNote = words.isEmpty ? nil : words
        let first = !handed
        handed = true
        note("\(reqId) agent handed the browser to the user\(handNote.map { ": \($0)" } ?? "")")
        reply(BrowserHandWire.handoverOKFrame(reqId: reqId))
        reply(BrowserWire.stateFrame(phase: BrowserWire.livePhase(expanded: expanded), by: .agent,
                                     owner: owner, shared: shared))
        guard first else { return }
        let start = BrowserHandStart(navs: navigationStarts, url: engine.currentURL ?? pageURL)
        handStart = start
        userSeen = nil
        Task { await measureHandStart(start, engine: engine) }
    }

    /// The user tapped "Done, show the agent": end the handover (if any), share the page,
    /// then send `browser.handback` with whether anything changed since the handover.
    public func userShowsAgent() {
        guard hasPage, let engine else { return }
        engine.willWork()
        let start = handStart
        let wasHanded = handed
        handed = false
        handNote = nil
        handStart = nil
        shared = true
        if let pageURL { shownURLs.insert(pageURL) }
        dropUserBatch()
        userSeen = nil
        note("user tapped Done/show agent\(wasHanded ? ", handover ended" : " (not handed over; sharing directly)")")
        reply(BrowserWire.stateFrame(phase: BrowserWire.livePhase(expanded: expanded), by: .user,
                                     owner: owner, shared: true))
        let url = engine.currentURL ?? pageURL ?? ""
        let title = (engine.currentTitle ?? pageTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let at = Date()
        Task {
            let changed = await handChanged(start, engine: engine)
            reply(BrowserHandWire.handbackFrame(url: url, title: title, changed: changed, at: at))
        }
    }

    /// The user switched between `live` and `done` reporting.
    func setUserMode(_ mode: BrowserUserMode) {
        guard mode != userMode else { return }
        userMode = mode
        defaults.set(mode.rawValue, forKey: BrowserUserMode.defaultsKey)
        note("user activity mode set to \(mode.rawValue)")
        reply(BrowserHandWire.prefFrame(mode))
        dropUserBatch()
        userSeen = nil
        if mode == .done, userOpening?.openPending == true {
            userTimer?.cancel()
            userTimer = nil
            _ = announceIfPending()
        }
    }

    /// A trusted user action reported by the injected listener (see `BrowserUserScript`).
    /// Only reported in `live` mode and only on pages the agent may read.
    func noteUserAct(_ act: BrowserUserAct) {
        guard hasPage else { return }
        if act != .click { handStart?.typed = true }
        guard userMode == .live else { return }
        guard agentCanRead else {
            note("user acted on a page not readable by the agent (\(act.rawValue)); not reported")
            return
        }
        userBatch.add(act)
        if act == .submit {
            flushUser(.submit)
        } else {
            armUserTimer()
        }
    }

    /// The user started touching the page: take a baseline of visible text lines so the
    /// next report can include only newly appeared text.
    func noteUserTouch() {
        guard userMode == .live, agentCanRead, userSeen == nil, !userSeenReading, let engine else { return }
        userSeenReading = true
        let navs = navigationStarts
        Task {
            let lines = await readUserLines(engine)
            userSeenReading = false
            guard navs == navigationStarts, userSeen == nil, let lines else { return }
            userSeen = Set(lines)
        }
    }

    private var userTouchedLately: Bool {
        let touched = engine?.lastUserTouch ?? .distantPast
        return Date().timeIntervalSince(touched) < Self.userLeadSeconds || !userBatch.isEmpty
    }

    private func armUserTimer() {
        userTimer?.cancel()
        let wait = userQuietSeconds
        userTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.flushUser(nil)
        }
    }

    /// Sends the coalesced batch after the quiet period (or immediately for submit).
    private func flushUser(_ forced: BrowserUserWhat?) {
        userTimer?.cancel()
        userTimer = nil
        if forced == nil, selfOpened, userNavPending, loading, let started = userNavStartedAt,
           Date().timeIntervalSince(started) < userNavWaitCap {
            note("timer fired but a user-led navigation is still loading; waiting for it to land")
            armUserTimer()
            return
        }
        let what = forced ?? userBatch.what
        let count = what.map { userBatch.count(for: $0) } ?? 0
        let fresh = userBatch.navs > 0
        userBatch.clear()
        let pending = userOpening?.openPending == true
        guard let what, userMode == .live, agentCanRead else {
            if pending { _ = announceIfPending() }
            return
        }
        var lead: (@MainActor () -> Bool)? = nil
        if pending {
            lead = { [weak self] in self?.announceIfPending() ?? false }
        }
        sendUser(what, count: count, fresh: fresh, lead: lead)
    }

    private func dropUserBatch() {
        userTimer?.cancel()
        userTimer = nil
        userBatch.clear()
        if userOpening?.openPending == true { armUserTimer() }
    }

    private func sendUser(_ what: BrowserUserWhat, count: Int, fresh: Bool, lead: (@MainActor () -> Bool)? = nil) {
        guard let engine else { return }
        let reqId = BrowserHandWire.newReqId()
        let url = engine.currentURL ?? pageURL ?? ""
        let title = (engine.currentTitle ?? pageTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let navs = navigationStarts
        let at = Date()
        let seen = fresh ? nil : userSeen
        Task {
            let lines = await readUserLines(engine)
            let same = navs == navigationStarts
            let added = same ? BrowserAdded.pick(now: lines ?? [], seen: seen) : ""
            if same, let lines { userSeen = Set(lines) }
            if let lead, !lead() {
                note("\(reqId) session already closed; batched frame not sent")
                return
            }
            note("\(reqId) user \(what.rawValue)\(what == .click || what == .nav ? " x\(count)" : ""), \(added.count) new chars\(same ? "" : " (page changed while reading; omitted)")")
            reply(BrowserHandWire.userFrame(reqId: reqId, what: what, count: count, url: url, title: title,
                                           added: added, at: at))
        }
    }

    private func readUserLines(_ engine: BrowserEngine) async -> [String]? {
        guard let ran = await raced("read page text for user activity", until: Date().addingTimeInterval(userReadSeconds),
                                    { await engine.evaluate(BrowserUserScript.text) }),
              case .success(let raw) = ran else { return nil }
        return BrowserUserScript.readLines(raw)
    }

    private func measureHandStart(_ start: BrowserHandStart, engine: BrowserEngine) async {
        guard let ran = await raced("fingerprint at handover", until: Date().addingTimeInterval(userReadSeconds),
                                    { await engine.evaluate(BrowserScript.pagePrintNow()) }),
              case .success(let raw) = ran, let print = BrowserPagePrint.read(raw) else { return }
        guard handStart?.navs == start.navs, navigationStarts == start.navs else { return }
        handStart?.print = print
    }

    private func handChanged(_ start: BrowserHandStart?, engine: BrowserEngine) async -> Bool? {
        guard let start else { return nil }
        if navigationStarts != start.navs || (engine.currentURL ?? pageURL) != start.url || start.typed {
            return true
        }
        guard let before = start.print,
              let ran = await raced("fingerprint at handback", until: Date().addingTimeInterval(userReadSeconds),
                                    { await engine.evaluate(BrowserScript.pagePrintNow()) }),
              case .success(let raw) = ran, let after = BrowserPagePrint.read(raw) else { return nil }
        return after != before
    }

    /// Panel expand / collapse, reported as `opened` / `collapsed`.
    private func setPanel(_ on: Bool, by: BrowserWire.By) {
        guard expanded != on else { return }
        expanded = on
        note(on ? "panel expanded (\(by.rawValue))" : "panel collapsed (\(by.rawValue), web view stays mounted)")
        if !hasPage, reclaimed != nil {
            note("page was reclaimed by the system; panel toggle not reported")
            return
        }
        reply(BrowserWire.stateFrame(phase: BrowserWire.livePhase(expanded: on),
                                     by: by, owner: owner, shared: shared))
    }

    // MARK: User-opened browser

    /// The user opened the browser from the host UI. In `live` mode the
    /// `browser.user_open` frame is delayed by the quiet period so that it goes out together
    /// with the first activity batch; in `done` mode it is sent immediately.
    public func userOpen(now: Date = Date()) {
        if hasPage || loading || expanded || selfOpened {
            note("user tapped Browser: already open; bringing it forward, no frame sent")
            bringForward()
            return
        }
        guard online(), let engine else {
            note("user tapped Browser: offline; not opening, not sending, not queuing")
            onNote?(BrowserOpenCopy.offline)
            return
        }
        engine.willWork()
        trouble = nil
        reclaimed = nil
        dropUserBatch()
        userSeen = nil
        userOpening = BrowserUserOpening(at: now, openPending: true)
        selfOpened = true
        note("user opened the browser (\(userMode.rawValue))")
        setPanel(true, by: .shell)
        if userMode == .live {
            armUserTimer()
        } else {
            _ = announceIfPending()
        }
        addressAsk += 1
    }

    @discardableResult
    /// Sends the pending `browser.user_open` followed by a state frame (by: shell).
    /// Returns false if the session has already ended.
    private func announceIfPending() -> Bool {
        guard var opening = userOpening, selfOpened else { return false }
        guard opening.openPending else { return true }
        opening.openPending = false
        let reqId = BrowserOpenWire.newReqId()
        opening.asked.append(reqId)
        userOpening = opening
        rememberOpen(reqId)
        guard sender?(BrowserOpenWire.openFrame(reqId: reqId)) == true else {
            note("\(reqId) browser.user_open not sent (offline); not queued")
            return true
        }
        note("\(reqId) sent browser.user_open, followed by a state frame (by: shell)")
        reply(BrowserWire.stateFrame(phase: BrowserWire.livePhase(expanded: expanded), by: .shell,
                                     owner: owner, shared: shared))
        return true
    }

    private func rememberOpen(_ reqId: String) {
        askedOpenIds.append(reqId)
        if askedOpenIds.count > BrowserOpenWire.rememberCap {
            askedOpenIds.removeFirst(askedOpenIds.count - BrowserOpenWire.rememberCap)
        }
    }

    private func bringForward() {
        if expanded { return }
        if hasPage {
            setCardFolded(false)
            return
        }
        setPanel(true, by: .user)
    }

    /// Handles an error reply to one of our `browser.user_open` frames. Returns true if the
    /// frame was ours. "Already open" while no page is open locally: send a corrective
    /// `closed` state and retry once.
    func takeOpenError(_ payload: Payload) -> Bool {
        guard let reqId = payload.string("req_id"), !reqId.isEmpty,
              askedOpenIds.contains(reqId) else { return false }
        guard var opening = userOpening, selfOpened, opening.asked.last == reqId else {
            note("\(reqId) error for a user_open that is not the latest of the current session (closed or already retried); ignored")
            return true
        }
        guard BrowserOpenWire.isAlreadyOpen(payload), !opening.retried else {
            note("\(reqId) user_open was not accepted (\(payload.string("frame_kind") ?? "generic error")); telling the user")
            onNote?(BrowserOpenCopy.missed)
            return true
        }
        if hasPage {
            note("\(reqId) bridge says already open and a page is open locally: bringing it forward, no resend")
            bringForward()
            return true
        }
        note("\(reqId) bridge thinks it is open but no page is open locally: sending a closed state to correct it, then resending once")
        opening.retried = true
        opening.openPending = true
        userOpening = opening
        reply(BrowserWire.stateFrame(phase: BrowserWire.stateClosed, by: nil, owner: nil, shared: false))
        announceIfPending()
        return true
    }

    func noteUserAddressTyping() {
        guard selfOpened, userMode == .live, userTimer != nil else { return }
        armUserTimer()
    }

    // MARK: Navigation callbacks (called by the engine)

    /// A main-frame navigation started. Decides the new owner and whether the page stays
    /// shared. Server redirects of an in-flight load keep the current owner.
    func noteNavigationStart(url: String?, kind: BrowserNavKind, sameAsShown: Bool = false) {
        let agentClick = agentClickPending
        let inherited = pendingOwner == nil && !agentClick && (kind == .programmatic || kind == .other)
        let redirect = inherited && sameAsShown && loading && !navCommitted && !inFlightCancelled
        if !redirect { navigationStarts += 1 }
        inFlightCancelled = false
        var screenOwner = owner
        if !navCommitted, let landed, let landedOwner = landed.owner { screenOwner = landedOwner }
        let fromAgent = hasPage && !(screenOwner == .user && !shared)
        let agentBack = agentBackPending
        let userBack = userBackPending
        let userTyped = userTypedPending
        agentBackPending = false
        userBackPending = false
        userTypedPending = false
        let touched = userTouchedLately
        let userLed: Bool
        switch kind {
        case .link: userLed = !agentClick && touched
        case .backForward: userLed = !agentBack && (userBack || touched)
        case .programmatic, .other:
            userLed = pendingOwner == .user || (pendingOwner == nil && !agentClick && !redirect && touched)
        }
        if !redirect {
            userNavPending = userLed
            if userLed { userNavStartedAt = Date() }
            let backToUserOwn = kind == .backForward && (ownerByURL[url ?? ""] ?? .user) == .user
                && !shownURLs.contains(url ?? "")
            userNavShares = userLed && userMode == .live && !backToUserOwn
                && (selfOpened || (!userTyped && fromAgent))
            if !(selfOpened && userLed) { dropUserBatch() }
            userSeen = nil
        }
        switch kind {
        case .programmatic:
            owner = pendingOwner ?? (agentClick ? .agent : (redirect ? owner : screenOwner))
        case .link:
            owner = agentClick ? .agent : .user
        case .backForward:
            owner = ownerByURL[url ?? ""] ?? .user
        case .other:
            owner = pendingOwner ?? (agentClick ? .agent : (redirect ? owner : screenOwner))
        }
        for watch in clickWatches where watch.attributing { watch.started = true }
        pendingOwner = nil
        navCommitted = false
        blockedDownload = false
        shared = userNavShares && owner == .user
        if userNavShares, owner == .user, !redirect { note("user navigated away from an agent-readable page; new page stays shared") }
        loading = true
        trouble = nil
        reclaimed = nil
        if let url, !url.isEmpty { pageURL = url }
    }

    func noteProgress(_ value: Double) {
        progress = value
    }

    /// A navigation finished (didFinish). Records the owner for back / forward and sends
    /// a state frame.
    func settle(url: String, title: String) {
        guard !url.isEmpty, url != "about:blank" else {
            note("didFinish reported \(url.isEmpty ? "an empty URL" : url); not counted as a landing")
            return
        }
        hasPage = true
        pageURL = url
        pageTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        loading = false
        progress = 1
        if owner == nil { owner = .agent }
        navCommitted = true
        landed = (url: url, title: pageTitle ?? "", owner: owner)
        for watch in clickWatches where watch.started && watch.attributing { watch.landed = url }
        ownerByURL[url] = owner
        if shared { shownURLs.insert(url) }
        note("landed \(url) (navigated by \(owner?.rawValue ?? "?"))")
        openLanded = true
        reply(BrowserWire.stateFrame(
            phase: BrowserWire.livePhase(expanded: expanded),
            by: owner == .user ? .user : .agent, owner: owner, shared: shared))
        if userNavPending {
            userNavPending = false
            if userMode == .live, agentCanRead {
                if selfOpened {
                    userBatch.addNav()
                    armUserTimer()
                } else {
                    sendUser(.nav, count: 1, fresh: true)
                }
            }
        }
        userNavShares = false
    }

    /// A navigation failed: revert to the page still on screen.
    func noteFailure(_ human: String) {
        trouble = human
        userNavPending = false
        backToLastLanding()
        userNavShares = false
        for watch in clickWatches where watch.started { watch.failed = true }
    }

    private func backToLastLanding() {
        inFlightCancelled = false
        loading = false
        progress = 0
        pageURL = landed?.url
        pageTitle = landed?.title
        hasPage = landed != nil
        if !navCommitted {
            owner = landed?.owner
            if userNavShares, owner != .user { shared = false }
        }
    }

    private var agentClickPending: Bool {
        let touched = engine?.lastUserTouch ?? .distantPast
        return clickWatches.contains { $0.attributing && touched < $0.since }
    }

    /// The in-flight navigation was cancelled by a newer one.
    func noteInFlightCancelled() {
        inFlightCancelled = true
    }

    /// The new page has been committed to the screen (didCommit).
    func noteCommitted() {
        navCommitted = true
        if loading { hasPage = true }
    }

    /// The engine cancelled a download (navigation response that is not displayable).
    func noteDownloadBlocked() {
        blockedDownload = true
        userNavPending = false
        for watch in clickWatches where watch.attributing { watch.blocked = true }
        backToLastLanding()
        userNavShares = false
        note("download blocked; page stays where it was")
    }

    /// The engine suppressed a file chooser while an agent action was in flight.
    func notePickerStopped() {
        for watch in clickWatches { watch.picked = true }
        note("page tried to open a file chooser during an agent action; held")
    }

    /// Consumes the "a download was just blocked" flag (used by the engine for `open`).
    func takeBlockedDownload() -> Bool {
        guard blockedDownload else { return false }
        blockedDownload = false
        return true
    }

    /// `window.open` / target=_blank is loaded into the same web view.
    func noteNewWindow() {
        pendingOwner = agentClickPending ? .agent : .user
        note("new window loaded into this web view (\(pendingOwner?.rawValue ?? "?"))")
    }

    /// The OS terminated the web content process. Everything is cleared, nothing is
    /// reopened automatically, and a `closed` state with `by: system` and the lost
    /// address is sent.
    func noteProcessGone() {
        guard hasPage || loading else {
            note("web content process gone, but no page is open or loading; nothing to clear")
            return
        }
        let lost = lostPageNow()
        let lastOwner = owner
        let lastShared = shared
        let panelOpen = expanded
        for watch in clickWatches { watch.gone = true }
        clearBooks()
        expanded = panelOpen
        reclaimed = lost
        trouble = BrowserCopy.reclaimedForUser
        note("web content process reclaimed by the system (\(lost.url ?? "no URL")); state cleared, not reopening automatically")
        reply(BrowserWire.stateFrame(phase: BrowserWire.stateClosed, by: .system, owner: lastOwner,
                                     shared: lastShared, url: lost.url, title: lost.title))
    }

    func lostPageNow() -> BrowserLostPage {
        let url = pageURL ?? engine?.currentURL
        var title: String? = nil
        if navCommitted || !loading {
            title = loading ? engine?.currentTitle : pageTitle
        }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return BrowserLostPage(url: url, title: trimmed.isEmpty ? nil : trimmed)
    }

    func reclaimedWords() -> String {
        BrowserCopy.reclaimed((reclaimed ?? lostPageNow()).url)
    }

    // MARK: Re-reporting

    /// Why the current state is being re-reported.
    public enum Restate {
        case lineUp
        case foreground
    }

    /// Re-reports the current state after (re)connecting or returning to the foreground.
    /// After connecting, the user mode is re-sent too.
    public func restate(_ why: Restate) {
        guard online() else {
            note("re-report: offline; skipped")
            return
        }
        let now = stateNow()
        if why == .foreground, now == lastSentState {
            note("re-report: identical to the last frame sent; skipped")
            return
        }
        note("re-report \(now.phase) (\(why == .lineUp ? "connected" : "foreground"))")
        reply(now.frame)
        if why == .lineUp { reply(BrowserHandWire.prefFrame(userMode)) }
    }

    func stateNow() -> BrowserStateNote {
        if hasPage || selfOpened {
            let phase = BrowserWire.livePhase(expanded: expanded)
            if let last = lastState, last.phase == phase, last.owner == owner, last.shared == shared,
               last.handed == handed {
                return last
            }
            return BrowserStateNote(phase: phase, by: nil, owner: owner, shared: shared, handed: handed)
        }
        if let last = lastState, last.phase == BrowserWire.stateClosed { return last }
        return BrowserStateNote(phase: BrowserWire.stateClosed, by: nil, owner: nil, shared: false)
    }

    // MARK: Teardown and sending
    private func teardown(_ engine: BrowserEngine) {
        engine.blank()
        clearBooks()
    }

    private func clearBooks() {
        hasPage = false
        pageURL = nil
        pageTitle = nil
        loading = false
        progress = 0
        trouble = nil
        reclaimed = nil
        owner = nil
        shared = false
        pendingOwner = nil
        landed = nil
        ownerByURL.removeAll()
        shownURLs.removeAll()
        openLanded = false
        expanded = false
        cardFolded = false
        navCommitted = false
        blockedDownload = false
        inFlightCancelled = false
        handed = false
        handNote = nil
        handStart = nil
        if selfOpened { selfOpened = false }
        userOpening = nil
        userNavStartedAt = nil
        dropUserBatch()
        userSeen = nil
        userNavPending = false
        userNavShares = false
        userTypedPending = false
        agentBackPending = false
        userBackPending = false
        for watch in clickWatches { watch.failed = true }
        note("page closed")
    }

    @discardableResult
    /// Single exit for every frame. Adds `handed` to every state frame; while a
    /// `browser.user_open` is pending, non-closed state frames are held back so the open
    /// frame goes first.
    private func reply(_ frame: [String: Any]) -> Bool {
        var frame = frame
        if (frame[BrowserWire.Key.type] as? String) == BrowserWire.state,
           frame[BrowserHandWire.Key.handed] == nil {
            frame[BrowserHandWire.Key.handed] = handed
        }
        if let told = BrowserStateNote(frame: frame), userOpening?.openPending == true,
           told.phase != BrowserWire.stateClosed {
            lastState = told
            note("user_open still pending; state frame (\(told.phase)) held until after it")
            return false
        }
        let sent = sender?(frame) ?? false
        if !sent { note("frame not sent (offline); not retried") }
        if let told = BrowserStateNote(frame: frame) {
            lastState = told
            if sent { lastSentState = told }
        }
        return sent
    }

    #if DEBUG
    func debugUseEngine(_ fake: BrowserEngine) {
        engine = fake
        stageMounted = true
    }

    func debugSetPage(url: String?, title: String? = nil, owner: BrowserOwner? = .agent,
                      shared: Bool = false, loading: Bool = false) {
        hasPage = url != nil
        pageURL = url
        pageTitle = title
        self.owner = url == nil ? nil : owner
        self.shared = shared
        self.loading = loading
        landed = url.map { (url: $0, title: title ?? "", owner: owner) }
        if let url, let owner { ownerByURL[url] = owner }
    }

    func debugSetExpanded(_ on: Bool) { expanded = on }

    func debugOwner(of url: String) -> BrowserOwner? { ownerByURL[url] }

    func debugStageDown() { stageMounted = false }

    var debugClickWatchCount: Int { clickWatches.count }

    private(set) var debugLateDrops = 0

    var debugUserSeen: Set<String>? { userSeen }

    var debugUserOpening: BrowserUserOpening? { userOpening }

    var debugUserTimerRunning: Bool { userTimer != nil }

    #endif
}

// MARK: - Helpers

/// Tracks the navigation (if any) caused by one agent click / Enter.
@MainActor
final class BrowserClickWatch {
    let since = Date()
    var started = false
    var landed: String? = nil
    var failed = false
    var blocked = false
    var picked = false
    var gone = false
    var attributing: Bool { landed == nil && !failed && !blocked }
}

/// One-shot result slot shared by a deadline and the work it guards.
@MainActor
final class BrowserRace<T> {
    var waiter: CheckedContinuation<T?, Never>?
    var open: Bool { waiter != nil }

    func settle(_ value: T?) {
        guard let waiter else { return }
        self.waiter = nil
        waiter.resume(returning: value)
    }
}

/// Keeps file choosers suppressed for the lifetime of one agent action. If the injected
/// script outlives the reply, the hold is released only after it comes back (plus a
/// grace period).
@MainActor
final class BrowserPickerHold {
    private let engine: BrowserEngine
    private let grace: Double
    private var out = 0
    private var straggled = false
    private var done = false
    private var released = false

    init(engine: BrowserEngine, grace: Double) {
        self.engine = engine
        self.grace = grace
        engine.holdFilePickers(true)
    }

    func straggling() {
        out += 1
        straggled = true
    }

    func cameBack() {
        out = max(0, out - 1)
        if done, out == 0 { releaseLater() }
    }

    func answered() {
        done = true
        guard out == 0 else { return }
        if straggled { releaseLater() } else { release() }
    }

    private func releaseLater() {
        let wait = grace
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            self.release()
        }
    }

    private func release() {
        guard !released else { return }
        released = true
        engine.holdFilePickers(false)
    }
}

#if DEBUG
/// Test double that records calls and never opens a real page.
@MainActor
final class BrowserEngineDouble: BrowserEngine {
    var canGoBack = false
    var currentURL: String? = nil
    var currentTitle: String? = nil
    var lastUserTouch: Date = .distantPast
    var openResult: Result<(url: String, title: String), BrowserTrouble> =
        .success((url: "https://example.com/", title: "Example"))
    var evaluateResult: Result<String, BrowserTrouble> = .success("{\"text\":\"\",\"elements\":[]}")
    var shootResult: Result<Data, BrowserTrouble> = .success(Data([0xFF, 0xD8, 0xFF]))
    var goBackResult = true

    private(set) var opened: [URL] = []
    private(set) var evaluated: [String] = []
    private(set) var shots = 0
    private(set) var backs = 0
    private(set) var blanks = 0
    private(set) var pickerHolds: [Bool] = []

    var onOpen: (@MainActor () -> Void)?
    var onEvaluate: (@MainActor (String) -> Void)?
    var evaluateReply: (@MainActor (String) -> Result<String, BrowserTrouble>)?
    var evaluateStall: (@MainActor (String) -> Double)?
    var shootStall: Double = 0
    private(set) var evaluatedLate: [String] = []

    func open(_ url: URL) async -> Result<(url: String, title: String), BrowserTrouble> {
        opened.append(url)
        onOpen?()
        return openResult
    }

    func evaluate(_ js: String) async -> Result<String, BrowserTrouble> {
        evaluated.append(js)
        let stall = evaluateStall?(js) ?? 0
        if stall > 0 {
            try? await Task.sleep(nanoseconds: UInt64(stall * 1_000_000_000))
            evaluatedLate.append(js)
        }
        onEvaluate?(js)
        if let evaluateReply { return evaluateReply(js) }
        return evaluateResult
    }

    func shoot() async -> Result<Data, BrowserTrouble> {
        shots += 1
        if shootStall > 0 { try? await Task.sleep(nanoseconds: UInt64(shootStall * 1_000_000_000)) }
        return shootResult
    }

    func goBack() -> Bool {
        backs += 1
        return goBackResult
    }

    func blank() { blanks += 1 }

    func holdFilePickers(_ on: Bool) { pickerHolds.append(on) }
}
#endif
