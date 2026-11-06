import SwiftUI
import UIKit
import WebKit

// MARK: - WKWebView engine
//
// The real `BrowserEngine`: one `WKWebView` that is created once and never destroyed
// while the app runs. Collapsing the panel moves it off screen (or parks it, see
// `BrowserDock`); the agent can still snapshot / screenshot it.
//
// Pieces:
//   `BrowserPrivacy`      website data store and timing knobs (one place)
//   `BrowserWebView`      WKWebView that only becomes first responder after a user touch
//   `BrowserWebEngine`    the engine plus WebKit delegates (download / file-chooser blocking)
//   `BrowserUserRelay`    receives events from the user-activity listener script
//   `BrowserPickerGuard`  temporary uiDelegate that suppresses file choosers during agent actions

// MARK: Data store and timing

/// Website data and timing settings for the built-in browser.
public enum BrowserPrivacy {
    /// Website data store for the web view. Default: `.default()`, i.e. cookies, local
    /// storage and cache persist in the app's own sandbox across launches (sign-ins are
    /// remembered). This store is never shared with Safari. Set to
    /// `{ .nonPersistent() }` before the panel is first shown to forget everything on exit.
    public static var makeDataStore: () -> WKWebsiteDataStore = { .default() }

    static func store() -> WKWebsiteDataStore { makeDataStore() }

    /// How long an agent `open` waits before replying. When it fires the reply is still
    /// a success with `loading: true` and the page keeps loading in the background; real
    /// failures (DNS, certificate, connection refused) are still reported as errors.
    /// Keep it below the bridge's own `open` timeout.
    public static var openSeconds: Double = 15

    #if DEBUG
    /// Tests can shorten the watchdog. nil = use `openSeconds`.
    static var debugOpenSeconds: Double? = nil
    #endif

    /// Seconds actually used by the watchdog.
    static var watchdogSeconds: Double {
        #if DEBUG
        if let debugOpenSeconds, debugOpenSeconds > 0 { return debugOpenSeconds }
        #endif
        return openSeconds
    }

    /// Screenshots are compressed below this size before upload (mobile data is real).
    public static var shotMaxBytes = 1024 * 1024
}

/// JPEG encoding for screenshots: lowers quality step by step until the data fits.
enum BrowserJPEG {
    static let qualities: [CGFloat] = [0.85, 0.7, 0.55, 0.4, 0.3, 0.2]

    static func encode(_ image: UIImage, maxBytes: Int) -> Data? {
        var last: Data? = nil
        for quality in qualities {
            guard let data = image.jpegData(compressionQuality: quality) else { return last }
            last = data
            if data.count <= maxBytes { return data }
        }
        // Still too large at the lowest quality: hand it over anyway; the upload decides.
        return last
    }
}

/// Wording shown to the user in the panel when a page fails to load.
/// (The agent gets `BrowserAgentWords` instead.)
enum BrowserUserWords {
    static func of(_ error: Error) -> String {
        let ns = error as NSError
        switch ns.code {
        case NSURLErrorNotConnectedToInternet:
            return "You're offline. Connect and try again."
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "The server for this address couldn't be found. Check the address or try another network."
        case NSURLErrorCannotConnectToHost:
            return "The server was found but isn't accepting connections."
        case NSURLErrorTimedOut:
            return "The request timed out."
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
            return "This site's certificate isn't valid, so the connection was stopped."
        case NSURLErrorCancelled:
            return "Loading was interrupted."
        default:
            return "The page couldn't be opened: \(ns.localizedDescription)"
        }
    }
}

extension BrowserCopy {
    /// A pending `open` answered because the page was closed.
    static let pageClosed = "This page was closed."
}

// MARK: The web view

/// A `WKWebView` that only accepts first responder (and therefore the keyboard) shortly
/// after the user touched it.
///
/// Pages ask for focus on their own (an agent click lands on a button, a script calls
/// `focus()`, an opened page has `autofocus`). Without this, an agent action would pop up
/// the keyboard, and while the panel is collapsed the off-screen page could steal what
/// the user is typing elsewhere in the app. User taps on fields still work normally.
/// (`BrowserScript.type` never focuses anything; this covers focus the page asks for.)
final class BrowserWebView: WKWebView {
    /// After a user touch, focus requests are granted for this long.
    static let touchGrace: TimeInterval = 2
    /// Last time the user's finger landed on this view.
    private(set) var lastTouch = Date.distantPast
    /// Called whenever the user's finger lands on this view.
    var onUserTouch: (@MainActor () -> Void)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit != nil, event?.type == .touches {
            lastTouch = Date()
            onUserTouch?()
        }
        return hit
    }

    override func becomeFirstResponder() -> Bool {
        // Already first responder (user is typing in the page): keep it.
        guard isFirstResponder || Date().timeIntervalSince(lastTouch) < Self.touchGrace else {
            #if DEBUG
            debugRefusals += 1
            #endif
            return false
        }
        return super.becomeFirstResponder()
    }

    #if DEBUG
    /// Tests: how many focus requests were refused.
    private(set) var debugRefusals = 0
    /// Tests: simulate a user touch.
    func debugNoteUserTouch() {
        lastTouch = Date()
        onUserTouch?()
    }
    #endif
}

// MARK: The engine

@MainActor
final class BrowserWebEngine: NSObject, BrowserEngine {

    let view: BrowserWebView
    /// Where the web view is currently mounted (panel / card), and parking when unused.
    let dock: BrowserDock
    private weak var service: BrowserService?
    private var watcher: NSKeyValueObservation?
    private var waiter: CheckedContinuation<Result<(url: String, title: String), BrowserTrouble>, Never>?
    private var watchdog: Task<Void, Never>?
    /// The navigation started by the latest `open`. Failure callbacks use it to tell
    /// whether a failing navigation was already superseded (see `report`).
    private var pendingNavigation: WKNavigation?
    /// Whether that navigation has committed (decides what the watchdog reports).
    private var pendingCommitted = false
    /// `service.navigationStarts` right before the latest `open` loaded. That load counts
    /// one; anything above means a newer navigation started (link tap, script redirect,
    /// back/forward, new window).
    private var openSerial = 0

    /// uiDelegate pushed onto the web view while an agent action is in flight.
    private lazy var pickerGuard = BrowserPickerGuard(engine: self)
    /// Nesting depth of `holdFilePickers(true)`.
    private var pickerHolds = 0
    /// Whether the guard is currently installed.
    private var pickerArmed = false

    /// The blank page loaded by `blank()` is on its way. The scheme allow-list in `judge`
    /// lets exactly this one `about:` navigation through; without it the closed page would
    /// keep running in the web view.
    private var blanking = false
    /// The blank-page navigation (its callbacks are ignored; closing already did the bookkeeping).
    private var blankNavigation: WKNavigation?
    /// uiDelegate before the guard was pushed; restored on release.
    private weak var pickerSaved: WKUIDelegate?
    /// Receives trusted user events from the listener script. WebKit retains it strongly,
    /// so it only holds the engine weakly.
    private let userRelay: BrowserUserRelay
    #if DEBUG
    /// Tests: number of suppressed file choosers.
    private(set) var debugPickersStopped = 0
    /// Tests: whether the guard is installed.
    var debugPickerArmed: Bool { pickerArmed }
    #endif

    init(service: BrowserService) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = BrowserPrivacy.store()
        config.allowsInlineMediaPlayback = true
        // The user-activity listener runs in an isolated content world in every frame,
        // before page scripts. Page scripts cannot see its message handler, so they cannot
        // impersonate the user; agent clicks / typing are not trusted events and are never reported.
        let world = WKContentWorld.world(name: BrowserUserScript.worldName)
        let relay = BrowserUserRelay()
        config.userContentController.addUserScript(WKUserScript(source: BrowserUserScript.hook,
                                                                injectionTime: .atDocumentStart,
                                                                forMainFrameOnly: false, in: world))
        config.userContentController.add(relay, contentWorld: world, name: BrowserUserScript.channel)
        userRelay = relay
        view = BrowserWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 640), configuration: config)
        dock = BrowserDock(web: view, service: service)
        self.service = service
        super.init()
        relay.engine = self
        view.allowsBackForwardNavigationGestures = true
        view.navigationDelegate = self
        // New windows (`target=_blank`, `window.open`) load into this same web view.
        view.uiDelegate = self
        // A user touch releases the file-chooser guard at once (user-initiated choosers
        // still work) and lets the service take a text baseline for activity reports.
        view.onUserTouch = { [weak self] in
            self?.releasePickers()
            self?.service?.noteUserTouch()
        }
        watcher = view.observe(\.estimatedProgress, options: [.new]) { [weak self] web, _ in
            Task { @MainActor in self?.service?.noteProgress(web.estimatedProgress) }
        }
    }

    // MARK: BrowserEngine

    var canGoBack: Bool { view.canGoBack }

    var currentURL: String? { view.url?.absoluteString }

    var currentTitle: String? { view.title }

    var lastUserTouch: Date { view.lastTouch }

    /// Someone is about to use the web view: remount it if it was parked (see `BrowserDock`).
    func willWork() {
        dock.willWork()
    }

    func open(_ url: URL) async -> Result<(url: String, title: String), BrowserTrouble> {
        // A pending blank page that has not been allowed yet must not keep its pass.
        blanking = false
        // A previous open is still waiting: answer it first. This only happens when an
        // agent open is pending and the user opens something from the address bar (an
        // agent's own second open is answered in `runOpen` before this). Do not tell the
        // agent to retry: retrying would replace the user's page.
        finish(.failure(BrowserTrouble(BrowserCopy.replacedByUser, retryable: false, keepBooks: true)))
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        openSerial = service?.navigationStarts ?? 0
        pendingNavigation = view.load(request)
        pendingCommitted = false
        armWatchdog(asked: url)
        return await withCheckedContinuation { cont in
            self.waiter = cont
        }
    }

    func evaluate(_ js: String) async -> Result<String, BrowserTrouble> {
        do {
            let raw = try await view.evaluateJavaScript(js)
            if let text = raw as? String { return .success(text) }
            return .failure(BrowserTrouble(BrowserCopy.garbled))
        } catch {
            #if DEBUG
            let ns = error as NSError
            print("[browser] evaluateJavaScript failed: \(ns.domain) \(ns.code) \(ns.localizedDescription)")
            #endif
            // When the content process is killed, the running call does not always fail
            // with the "process terminated" code, and the termination callback may arrive
            // later. If neither is known yet, wait briefly and check again so a reclaimed
            // page is not reported as "still open".
            if !Self.webProcessGone(error), service?.reclaimed == nil {
                try? await Task.sleep(nanoseconds: UInt64(Self.goneGrace * 1_000_000_000))
            }
            if Self.webProcessGone(error) || service?.reclaimed != nil {
                return .failure(BrowserTrouble(service?.reclaimedWords() ?? BrowserCopy.reclaimed(nil),
                                               retryable: false))
            }
            return .failure(BrowserTrouble(BrowserCopy.scriptFailed))
        }
    }

    /// How long a failed script call waits for the "process gone" callback (failure path only).
    static let goneGrace: Double = 0.2

    /// Whether the error is WebKit's "web content process terminated".
    nonisolated static func webProcessGone(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == WKError.errorDomain && ns.code == WKError.Code.webContentProcessTerminated.rawValue
    }

    #if DEBUG
    /// Tests: kill the web content process through WebKit's private debug hook.
    /// Returns false when the hook is unavailable. Not compiled into release builds.
    @discardableResult
    func debugKillWebProcess() -> Bool {
        let knife = NSSelectorFromString("_killWebContentProcess")
        guard view.responds(to: knife) else { return false }
        view.perform(knife)
        return true
    }
    #endif

    func shoot() async -> Result<Data, BrowserTrouble> {
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        let image: UIImage? = await withCheckedContinuation { cont in
            view.takeSnapshot(with: config) { shot, _ in cont.resume(returning: shot) }
        }
        guard let image, let jpeg = BrowserJPEG.encode(image, maxBytes: BrowserPrivacy.shotMaxBytes) else {
            return .failure(BrowserTrouble(BrowserCopy.shotFailed))
        }
        return .success(jpeg)
    }

    func goBack() -> Bool {
        guard view.canGoBack else { return false }
        view.goBack()
        return true
    }

    func blank() {
        disarmWatchdog()
        finish(.failure(BrowserTrouble(BrowserCopy.pageClosed)))
        pendingNavigation = nil
        pendingCommitted = false
        view.stopLoading()
        // Really replace the page. This load must pass the allow-list in `judge`.
        blanking = true
        blankNavigation = view.loadHTMLString("<html><body></body></html>", baseURL: nil)
    }

    // MARK: File chooser suppression during agent actions

    /// While an agent click / type+submit is in flight (until its reply is sent, at most
    /// a few seconds), `BrowserPickerGuard` is pushed as the web view's uiDelegate. If the
    /// page asks for the system file chooser (`runOpenPanelWith`, iOS 18.4+), the guard
    /// answers nil (same as the user tapping Cancel) and tells the service.
    ///
    /// It is not installed permanently because implementing that delegate method removes
    /// the system default chooser, so user taps on file inputs would stop working. It is
    /// not installed when the user touched the page in the last `touchGrace` seconds, and
    /// a user touch removes it immediately. Before iOS 18.4 only the script-side guard applies.
    func holdFilePickers(_ on: Bool) {
        if on {
            pickerHolds += 1
            guard !pickerArmed,
                  Date().timeIntervalSince(view.lastTouch) >= BrowserWebView.touchGrace else { return }
            pickerSaved = view.uiDelegate
            // Set the fallback before installing: WebKit caches which delegate methods
            // exist at the moment the delegate is assigned, and the guard's answers depend
            // on the fallback. Do not swap these two lines.
            pickerGuard.fallback = view.uiDelegate
            view.uiDelegate = pickerGuard
            pickerArmed = true
        } else {
            pickerHolds = max(0, pickerHolds - 1)
            if pickerHolds == 0 { releasePickers() }
        }
    }

    /// Restores the original uiDelegate.
    private func releasePickers() {
        guard pickerArmed else { return }
        pickerArmed = false
        view.uiDelegate = pickerSaved
        pickerSaved = nil
        pickerGuard.fallback = nil
    }

    /// A trusted user event from the listener script.
    fileprivate func userDid(_ act: BrowserUserAct) {
        service?.noteUserAct(act)
    }

    #if DEBUG
    /// Tests: simulate an event from the listener script.
    func debugUserDid(_ act: BrowserUserAct) { userDid(act) }
    #endif

    /// The guard suppressed a file chooser.
    fileprivate func pickerStopped() {
        #if DEBUG
        debugPickersStopped += 1
        #endif
        service?.notePickerStopped()
    }

    // MARK: Open watchdog

    /// When the watchdog fires, the pending `open` is answered with success and whatever
    /// is on screen (see `onScreen`). The page is not stopped; it keeps loading and the
    /// service marks the reply `loading: true`. Real failures go through `report`.
    private func armWatchdog(asked: URL) {
        disarmWatchdog()
        let seconds = BrowserPrivacy.watchdogSeconds
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.finish(.success(self.onScreen(asked: asked)))
        }
    }

    /// What is on screen when the watchdog fires:
    ///   committed: URL and title of the new page (title may still be partial)
    ///   not committed: the old page is still showing, so report the requested URL and an empty title
    /// Only `view.title` is read (no script call): a heavy page may be busy and a script
    /// call could block past the bridge's timeout.
    private func onScreen(asked: URL) -> (url: String, title: String) {
        guard pendingCommitted else { return (url: asked.absoluteString, title: "") }
        let url = view.url?.absoluteString ?? asked.absoluteString
        let title = (view.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (url: url, title: title)
    }

    private func disarmWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    private func finish(_ result: Result<(url: String, title: String), BrowserTrouble>) {
        guard let cont = waiter else { return }
        waiter = nil
        disarmWatchdog()
        cont.resume(returning: result)
    }
}

extension BrowserWebEngine: WKNavigationDelegate {

    // WebKit calls these on the main thread. They enter the main actor synchronously
    // (`MainActor.assumeIsolated`) so the service sees events in order; in particular a
    // blocked download must be reported before the navigation that follows it.

    nonisolated func webView(_ webView: WKWebView,
                             decidePolicyFor navigationAction: WKNavigationAction,
                             decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let verdict: WKNavigationActionPolicy = MainActor.assumeIsolated {
            self.judge(navigationAction, in: webView)
        }
        decisionHandler(verdict)
    }

    /// Allow or cancel a navigation, and attribute it.
    private func judge(_ action: WKNavigationAction, in webView: WKWebView) -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        // The blank page loaded by `blank()`: allow exactly this one, do not count it.
        // `about:` URLs requested by pages are still refused below.
        if blanking, url.scheme?.lowercased() == "about", action.targetFrame?.isMainFrame == true {
            blanking = false
            return .allow
        }
        // Host-side allow-list: http / https only. `javascript:`, `file:`, custom schemes
        // are refused whether they come from the agent or from a link in the page.
        guard BrowserURL.allow(url.absoluteString) != nil else {
            return .cancel
        }
        // New-window request (`target=_blank` / `window.open`): no target frame. Allow it
        // so WebKit goes on to `createWebViewWith`, which loads it into this view. Do not
        // count it as a navigation start here.
        guard let frame = action.targetFrame else { return .allow }
        // Subframe navigations are not page changes.
        guard frame.isMainFrame else { return .allow }
        // Download links: cancelled, the page stays.
        if action.shouldPerformDownload {
            service?.noteDownloadBlocked()
            return .cancel
        }
        let type = action.navigationType
        // Fragment-only navigation within the same document: not a page change.
        if type == .linkActivated || type == .other || type == .backForward,
           BrowserURL.sameDocument(url, from: webView.url) {
            return .allow
        }
        let kind: BrowserNavKind
        switch type {
        case .linkActivated, .formSubmitted: kind = .link      // tapped in the page (user or agent click)
        case .backForward: kind = .backForward
        case .other: kind = .programmatic                      // loaded by the host, or a script redirect
        default: kind = .other                                 // reload etc.: owner unchanged
        }
        // Server redirects arrive with the address already showing the target.
        service?.noteNavigationStart(url: url.absoluteString, kind: kind,
                                     sameAsShown: webView.url?.absoluteString == url.absoluteString)
        return .allow
    }

    nonisolated func webView(_ webView: WKWebView,
                             decidePolicyFor navigationResponse: WKNavigationResponse,
                             decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // No downloads (`WKDownload` is never used): responses the web view cannot show
        // are cancelled. For the main frame the service is told, so the page on screen
        // keeps its address and owner and an agent click reports "no navigation".
        let verdict: WKNavigationResponsePolicy = MainActor.assumeIsolated {
            guard !navigationResponse.canShowMIMEType else { return .allow }
            if navigationResponse.isForMainFrame { self.service?.noteDownloadBlocked() }
            return .cancel
        }
        decisionHandler(verdict)
    }

    nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            // The blank page committing is not a page.
            if let navigation, navigation === self.blankNavigation { return }
            if let navigation, navigation === self.pendingNavigation { self.pendingCommitted = true }
            self.service?.noteCommitted()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // The blank page finishing is ignored, and must not answer a pending open
        // (an open right after close belongs to the new page).
        let blankDone: Bool = MainActor.assumeIsolated {
            guard let navigation, navigation === self.blankNavigation else { return false }
            self.blankNavigation = nil
            return true
        }
        if blankDone { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let landed = webView.url?.absoluteString ?? ""
            // `webView.title` is often still empty in didFinish on the first load (even
            // for a static <title>). Ask the document once if so.
            var title = webView.title ?? ""
            if title.isEmpty {
                let asked = try? await webView.evaluateJavaScript("document.title")
                title = (asked as? String) ?? ""
            }
            self.service?.settle(url: landed, title: title)
            self.finish(.success((url: landed, title: title)))
        }
    }

    nonisolated func webView(_ webView: WKWebView,
                             didFailProvisionalNavigation navigation: WKNavigation!,
                             withError error: Error) {
        report(error, on: navigation)
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                             withError error: Error) {
        report(error, on: navigation)
    }

    nonisolated private func report(_ error: Error, on navigation: WKNavigation?) {
        // Process termination is handled by `webViewWebContentProcessDidTerminate`.
        if Self.webProcessGone(error) { return }
        // The blank page failed to load (usually superseded by an open right after close): ignore.
        let blankFailed: Bool = MainActor.assumeIsolated {
            guard let navigation, navigation === self.blankNavigation else { return false }
            self.blankNavigation = nil
            return true
        }
        if blankFailed { return }
        // Panel wording for the user vs. wording for the agent.
        let human = BrowserUserWords.of(error)
        let told = BrowserAgentWords.of(error)
        let cancelled = (error as NSError).code == NSURLErrorCancelled
        // Which navigation failed (decided synchronously, on the main thread):
        //   superseded: not the latest open's navigation (an older one replaced by a newer open)
        //   mine: the latest open's navigation (agent open or address bar)
        //   takenOver: after it loaded, the service saw a newer navigation start (link tap,
        //     script redirect, back/forward, new window; server redirects do not count)
        let (superseded, mine, takenOver): (Bool, Bool, Bool) = MainActor.assumeIsolated {
            guard let navigation, let pending = self.pendingNavigation else { return (false, false, false) }
            if navigation !== pending { return (true, false, false) }
            let taken = (self.service?.navigationStarts ?? 0) > self.openSerial + 1
            // Cancelled and no newer navigation yet: tell the service now so the next
            // navigation start is not attributed to it.
            if cancelled, !taken { self.service?.noteInFlightCancelled() }
            return (false, true, taken)
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            // The content process was reclaimed and nothing new started: this is the tail
            // of the dead page. Do not overwrite the "reclaimed" message.
            if self.service?.reclaimed != nil { return }
            // The engine cancelled a download itself (`noteDownloadBlocked` already did the
            // bookkeeping). If the agent opened a download URL, say so.
            if self.service?.takeBlockedDownload() == true {
                self.finish(.failure(BrowserTrouble(BrowserCopy.download, retryable: false)))
                return
            }
            if mine {
                // The latest open's own navigation failed. Answer it first.
                self.finish(.failure(BrowserTrouble(told.words, retryable: told.retryable, keepBooks: true)))
                // A newer navigation already took over and recorded address / owner.
                // Rolling back would attribute the user's page to the agent.
                if takenOver { return }
                if cancelled {
                    // Cancelled, usually because another navigation is starting. WebKit
                    // reports the cancel before asking about the new navigation, so wait
                    // briefly. If something took over, leave the books alone; otherwise
                    // (the page stopped itself) roll back so `loading` does not stick.
                    let serial = self.openSerial
                    try? await Task.sleep(nanoseconds: UInt64(Self.handoverGrace * 1_000_000_000))
                    guard let service = self.service,
                          service.navigationStarts <= serial + 1, service.loading else { return }
                }
                // Real failure, or cancelled with no successor: roll back.
                self.service?.noteFailure(human)
                return
            }
            // Not the latest open's navigation. A cancel is not a failed page:
            //   no pending open (user tapped a link, agent back, close): the new navigation reports itself
            //   pending open is for another navigation: this one was replaced by that open's load
            if cancelled, self.waiter == nil || superseded { return }
            self.service?.noteFailure(human)
            self.finish(.failure(BrowserTrouble(told.words, retryable: told.retryable, userWords: human)))
        }
    }

    /// The OS terminated the web content process (memory pressure, long time in the
    /// background; delivered when the app returns to the foreground). Implementing this
    /// stops WebKit from reloading on its own. The page is not reopened automatically.
    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated { self.processGone() }
    }

    /// Answer a pending open (WebKit drops its navigations and never reports a failure,
    /// and the watchdog would otherwise answer "success"), clear the engine's own
    /// bookkeeping, then let the service clear its state.
    private func processGone() {
        disarmWatchdog()
        let words = service?.reclaimedWords() ?? BrowserCopy.reclaimed(nil)
        finish(.failure(BrowserTrouble(words, retryable: false, keepBooks: true)))
        pendingNavigation = nil
        pendingCommitted = false
        blanking = false
        blankNavigation = nil
        service?.noteProcessGone()
    }

    /// After the latest open's navigation is cancelled, how long to wait for a successor
    /// navigation (the successor's policy decision follows within milliseconds).
    static let handoverGrace: Double = 0.5
}

extension BrowserWebEngine: WKUIDelegate {

    /// New-window requests (`target=_blank` links, `window.open`) load into this same web
    /// view; there are no tabs. Returning nil denies the page a new window; the request
    /// still goes through the allow-list in `judge`. Popups without a user gesture are
    /// blocked by WebKit before reaching here.
    nonisolated func webView(_ webView: WKWebView,
                             createWebViewWith configuration: WKWebViewConfiguration,
                             for navigationAction: WKNavigationAction,
                             windowFeatures: WKWindowFeatures) -> WKWebView? {
        MainActor.assumeIsolated {
            let request = navigationAction.request
            guard let url = request.url, BrowserURL.allow(url.absoluteString) != nil else { return }
            self.service?.noteNewWindow()
            webView.load(request)
        }
        return nil
    }
}

/// Receives `{kind: "click" | "type" | "submit"}` from the listener script
/// (`BrowserUserScript.hook`); anything else is dropped.
@MainActor
final class BrowserUserRelay: NSObject, WKScriptMessageHandler {
    weak var engine: BrowserWebEngine?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let map = message.body as? [String: Any], let kind = map["kind"] as? String,
              let act = BrowserUserAct(rawValue: kind) else { return }
        engine?.userDid(act)
    }
}

/// The uiDelegate installed while an agent action is in flight (see
/// `BrowserWebEngine.holdFilePickers`). It refuses system file choosers and forwards
/// new-window requests to the engine.
///
/// Every other `WKUIDelegate` method that the previous delegate implements is forwarded
/// to it automatically (`responds(to:)` + `forwardingTarget(for:)`), so alerts, confirms,
/// media permission prompts etc. keep working during agent actions.
///
/// `responds(to:)` must be exact: WebKit records which methods exist when the delegate
/// is assigned. It answers yes for its own methods plus the fallback's WKUIDelegate
/// methods, and only for selectors that belong to WKUIDelegate.
@MainActor
final class BrowserPickerGuard: NSObject, WKUIDelegate {
    private weak var engine: BrowserWebEngine?
    /// The delegate that was installed before this one.
    weak var fallback: WKUIDelegate?

    init(engine: BrowserWebEngine) {
        self.engine = engine
    }

    #if compiler(>=6.1)
    // `WKOpenPanelParameters` exists on iOS from the iOS 18.4 SDK (Xcode 16.3, Swift 6.1).
    @available(iOS 18.4, *)
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
        completionHandler(nil)
        engine?.pickerStopped()
    }
    #endif

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        fallback?.webView?(webView, createWebViewWith: configuration, for: navigationAction,
                           windowFeatures: windowFeatures)
    }

    // MARK: Forwarding everything else to the previous delegate

    // WebKit asks on the main thread. If asked on another thread, answer like NSObject
    // (own methods only) and do not touch the main-actor fallback.

    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        guard Thread.isMainThread else { return false }
        return MainActor.assumeIsolated { handOver(aSelector) != nil }
    }

    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        guard Thread.isMainThread,
              let target = MainActor.assumeIsolated({ handOver(aSelector) }) else {
            return super.forwardingTarget(for: aSelector)
        }
        return target
    }

    /// Forward only WKUIDelegate selectors this class does not implement and the fallback does.
    private func handOver(_ ask: Selector) -> WKUIDelegate? {
        guard Self.isUIDelegateAsk(ask), !Self.instancesRespond(to: ask),
              let target = fallback, target !== self, target.responds(to: ask) else { return nil }
        return target
    }

    /// Whether the selector is an (optional, instance) method of WKUIDelegate, checked at runtime.
    nonisolated private static func isUIDelegateAsk(_ ask: Selector) -> Bool {
        protocol_getMethodDescription(WKUIDelegate.self, ask, false, true).name != nil
    }
}
