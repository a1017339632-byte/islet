# iOS package (`Islet`)

The host-app half of the protocol in [`../protocol/PROTOCOL.md`](../protocol/PROTOCOL.md),
as a Swift package: it receives agent requests, enforces every safety gate, drives a
`WKWebView`, shows the browser to the user (expanded panel + optional floating card)
and reports state back to the bridge server.

- Swift Package, `swift-tools-version: 5.9`, iOS 15+.
- Library product and target: `Islet` (sources in [`../Sources/Islet/`](../Sources/Islet/)).
- Depends only on Apple SDKs: Foundation, UIKit, WebKit, SwiftUI, Combine.
- No networking: the host supplies the transport through closures.

## Installing

Xcode: *File > Add Package Dependencies...*, enter the repository URL, add the `Islet`
library to your app target.

`Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/<owner>/islet.git", branch: "main")
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "Islet", package: "islet")])
]
```

(Replace `<owner>` with wherever you host the repository; no release tags exist yet.)

## Minimal wiring

```swift
import Islet
import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {
    let browser = BrowserService()
    let socket = MyBridgeSocket()          // your WebSocket client

    init() {
        browser.connect(
            send: { [socket] frame in socket.send(json: frame) },   // false when offline; never queue
            isOnline: { [socket] in socket.isAuthenticated },
            isForeground: { UIApplication.shared.applicationState == .active },
            upload: { jpeg in await uploadScreenshot(jpeg) },      // optional, see below
            showNote: { text in print(text) })                      // optional toast

        socket.onFrame = { [browser] frame in                       // decoded [String: Any]
            browser.receive(frame)                                  // ignores non-browser frames
        }
        socket.onAuthenticated = { [browser] in browser.restate(.lineUp) }
    }
}

@main
struct MyApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .overlay(alignment: .top) { BrowserCardStack(browser: model.browser) } // optional card
                .isletBrowser(model.browser)                                          // panel, keep mounted
                .onChange(of: phase) { now in
                    if now == .active { model.browser.restate(.foreground) }
                }
        }
    }
}
```

Showing and hiding from your own UI:

```swift
browser.userOpen()      // user opens the browser from your UI (sends browser.user_open)
browser.show()          // expand the panel (same as setExpanded(true))
browser.hide()          // collapse it; the page stays open and readable by the agent
browser.userCloses()    // close the page (sends browser.state closed)
```

## Public API

```swift
@MainActor public final class BrowserService: ObservableObject {
    public init(defaults: UserDefaults = .standard)

    // wiring
    public var sender: (([String: Any]) -> Bool)?
    public var foreground: () -> Bool
    public var online: () -> Bool
    public var uploader: ((Data) async -> Result<[String: Any], BrowserTrouble>)?
    public var onNote: ((String) -> Void)?
    public func connect(send:isOnline:isForeground:upload:showNote:)
    @discardableResult public func receive(_ frame: [String: Any]) -> Bool
    @discardableResult public func receive(text: String) -> Bool
    public func restate(_ why: Restate)            // .lineUp / .foreground

    // controls
    public func userOpen(now: Date = Date())
    public func show(), hide(), setExpanded(_ on: Bool)
    public func userOpens(_ typed: String), userGoesBack(), userCloses()
    public func userHandsOver(), userShowsAgent()
    public func flashPanelNote(_ text: String)

    // observable state (read-only)
    public var hasPage, pageURL, pageTitle, owner, shared, loading, progress,
               expanded, trouble, handed, handNote, selfOpened, panelNote
    public var stripName, canHandOver, agentCanRead, canShowAgent
}

public struct BrowserTrouble: Error, Equatable {
    public let human: String; public let retryable: Bool
    public init(_ human: String, retryable: Bool = true, keepBooks: Bool = false, userWords: String? = nil)
}
public enum BrowserOwner: String { case agent, user }

public struct BrowserLayer: View      { public init(browser: BrowserService) }  // expanded panel overlay
public struct BrowserCardStack: View  { public init(browser: BrowserService) }  // floating card
extension View { public func isletBrowser(_ browser: BrowserService) -> some View }

public struct IsletTheme { public init(); public static let standard: IsletTheme; ... }
extension View { public func isletTheme(_ theme: IsletTheme) -> some View }

public enum BrowserPrivacy {
    public static var makeDataStore: () -> WKWebsiteDataStore   // default .default()
    public static var openSeconds: Double                       // default 15
    public static var shotMaxBytes: Int                         // default 1 MB
}
```

## Theme

All colors, font sizes, corner radii, spacing, animations and the header icon come from
`IsletTheme`. Defaults use system colors and materials.

```swift
var theme = IsletTheme()
theme.accent = .indigo
theme.panelMaterial = nil                 // solid panel instead of a material
theme.panelFill = Color(.systemBackground)
theme.corners.panel = 24
theme.type.footnote = 14
theme.makeFont = { size, weight in .custom("Inter", size: size).weight(weight) }
theme.browserIcon = "globe"

ContentView()
    .isletBrowser(browser)
    .isletTheme(theme)                    // applies to the panel and the card below this point
```

## What the host still has to provide

| Piece | Notes |
|---|---|
| Transport | A connection to your bridge (e.g. an authenticated WebSocket). `send` must return false when offline; nothing is queued. Feed every incoming frame to `receive(_:)`. |
| Re-reporting | Call `restate(.lineUp)` after every (re)authentication and `restate(.foreground)` when the app becomes active. |
| Foreground signal | `isForeground` must reflect the real app state; requests are refused while it is false. |
| Screenshot upload | `upload` receives JPEG data (at most `BrowserPrivacy.shotMaxBytes`) and returns the receipt dictionary for the `browser.screenshot` response body (for example an attachment id / URL). Without it, screenshots are refused with a clear message. |
| Entry point | A button somewhere in your UI that calls `userOpen()` (optional; the agent can also open the browser). |
| Localisation | All user-visible strings are neutral English constants (`BrowserPanelCopy`, `BrowserCardCopy`, `BrowserHandCopy`, `BrowserOpenCopy`). Agent-facing messages are in `BrowserCopy` / `BrowserAgentWords`. Edit them in place or localise them. |
| The bridge server | Not included. See the protocol document. |

## Files

| File | Lines | What it does |
|---|---:|---|
| `Browser.swift` | 1212 | Wire format (`BrowserWire`), agent-facing messages (`BrowserCopy`), URL allow-list (`BrowserURL`), ownership, request parsing, **the gate** (`BrowserGate`), snapshot size budget, **all injected JavaScript** (`BrowserScript`), result parsing. |
| `BrowserService.swift` | 1545 | `BrowserEngine` protocol, `BrowserService` state machine (request -> gate -> engine -> exactly one reply; ownership, sharing, handover, user-activity batching, user-opened sessions, re-reporting), helpers, `BrowserEngineDouble` (DEBUG). |
| `BrowserHand.swift` | 258 | Handover / hand-back / `browser.user_action` / `browser.user_pref`, `live` / `done`, activity batching, user-activity listener script. |
| `BrowserOpen.swift` | 55 | `browser.user_open`. |
| `BrowserLongPlay.swift` | 98 | Reclaimed web content process, state-frame value type, more agent messages, network error wording for the agent. |
| `Payload.swift` | 85 | Read-only wrapper around a decoded JSON frame. |
| `BrowserWebEngine.swift` | 746 | The `WKWebView` engine: data store and timing (`BrowserPrivacy`), first-responder guard (`BrowserWebView`), navigation / UI delegates (scheme allow-list, **download blocking**, new windows into the same view, process termination), **file-chooser suppression** during agent actions (`BrowserPickerGuard`), user-activity relay, JPEG encoding. |
| `BrowserDock.swift` | 293 | Moves the single web view between the panel and the card; parks it off screen when idle. |
| `BrowserPanelView.swift` | 319 | `BrowserLayer`: expanded panel (address bar, back / collapse / close, "Share with agent", "Done, show the agent", handover banner, progress, error card). |
| `BrowserCard.swift` | 122 | Card layout math and strings. |
| `BrowserCardView.swift` | 382 | `BrowserCardStack`: floating card / strip, keyboard handling, `live` / `done` switch. |
| `IsletTheme.swift` | 190 | `IsletTheme` and drawing helpers. |
| `IsletHost.swift` | 93 | `connect`, `receive`, `show` / `hide`, `.isletBrowser(_:)`. |

## Safety behaviour implemented in the engine

- Only `http` / `https` navigations are allowed (`judge`), for agent opens and for links
  in the page alike. The only exception is the engine's own `about:` blank page on close.
- Downloads: `shouldPerformDownload` navigations and responses with
  `!canShowMIMEType` are cancelled; `WKDownload` is never used. An agent `open` of a
  download URL is answered with `BrowserCopy.download`.
- File choosers: during an agent click / type+submit the page's file chooser request is
  answered with nil (iOS 18.4+ delegate method; compiled only with the iOS 18.4 SDK or
  newer). The script-side guard in `BrowserScript` applies on every iOS version. User
  taps still open the chooser.
- New windows (`target=_blank`, `window.open`) load into the same web view.
- The web view only becomes first responder within 2 seconds of a user touch, so agent
  actions never pop up the keyboard or steal typing from the rest of the app.
- The user-activity listener runs in an isolated `WKContentWorld`; only trusted events
  are reported; password fields are never reported or typed into.

## Differences from the protocol document

- Error objects carry only `message` and `retryable`; the machine-readable `code` field
  described in the protocol is not emitted yet.
- The "already open" reply to `browser.user_open` is expected as the bridge's generic
  error frame (`"type": "error"`, same `req_id`) with a top-level
  `frame_kind: "browser_already_open"` field (see `BrowserOpenWire.alreadyOpenKind`),
  not as a `browser.response` with `error.code: "already_open"`.
- Agent-facing messages are English sentences; localise them if your agent prefers
  another language.

## Testing

`BrowserEngineDouble` (DEBUG) records every call and lets tests script `open`,
`evaluate` and `shoot` results and delays, so the service can be tested without a web
view. The injected scripts should be tested against real pages in a `WKWebView`
(for example served from a local HTTP server in a test target). This repository does
not ship tests yet; CI only builds the package.
