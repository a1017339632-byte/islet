# islet · In-App Browser Widget Reference

[中文](README.zh-CN.md)

A protocol and an iOS reference implementation that let an AI agent operate the web
view **inside your app** while the user watches the same screen and can take over at
any moment.

## What problem it solves

Most "AI browses the web" setups run a headless browser on a server. The user cannot see
what the agent is doing, cannot step in, and the agent ends up near passwords and
payment forms with nobody watching.

Here the agent borrows the one browser that lives inside the host app on the user's
device:

- **Shared screen, live.** The agent opens, reads, clicks, types and scrolls in an
  in-app web view. The user sees every step as it happens.
- **Take over at any time.** The agent can hand the browser to the user (sign-in,
  payment, anything personal) and is notified when the user taps "Done". The user can
  also just start using the page; in `live` mode the agent is told what the user did.
- **Password fields are a hard refusal.** The host never types into
  `type=password` / `autocomplete=password` fields and never reads any form field value.
- **Downloads and file choosers are blocked.** Download navigations are cancelled, and an
  agent action that would open the system file chooser is refused.
- **The agent reads only what it opened or what the user shared.** A page the user
  opened is invisible to the agent until the user explicitly shares it. Back/forward
  keeps the original owner, so the gate cannot be bypassed by navigating.
- **No app, no browser.** If the host app is not in the foreground, every request fails
  immediately. Nothing is queued.
- Only `http`/`https` URLs are opened (scheme compared case-insensitively).

All of these gates are enforced on the host (the device), not just by the agent's
prompt. Prompt injection from page content is still a risk; the protocol treats page
content as untrusted data, but that defence lives at the prompt level.

## Architecture

```
 +---------+   tool calls (e.g. MCP)   +---------------+   framed JSON (e.g. WebSocket)   +----------------------+
 |  agent  | ------------------------> | bridge server | <------------------------------> |      host app        |
 |  (LLM)  | <------------------------ |               |          authenticated           |  +----------------+  |
 +---------+   text / image results    +---------------+                                  |  |    WebView     |<-+-- user watches,
                                               ^                                          |  +----------------+  |   can take over
                                               +------- screenshot upload (HTTP) ---------+                      |
                                                                                          +----------------------+
```

- **agent**: calls tools such as `browser_open`, `browser_snapshot`, `browser_click`,
  `browser_type`, `browser_scroll`, `browser_handover`.
- **bridge server**: turns each tool call into a `browser.request` frame, correlates the
  reply, applies timeouts and throttling, caches panel state, and turns host events
  (hand-back, user activity) into agent notifications.
- **host app / WebView**: owns the only browser instance, shows it to the user, runs the
  request, and enforces every safety gate.

## Repository layout

| Path | Contents |
|---|---|
| [`protocol/PROTOCOL.md`](protocol/PROTOCOL.md) | The wire protocol (English). |
| [`protocol/PROTOCOL.zh-CN.md`](protocol/PROTOCOL.zh-CN.md) | The same protocol in Chinese. |
| [`protocol/schema/`](protocol/schema/) | JSON Schemas for the nine `browser.*` frames. |
| [`Package.swift`](Package.swift) | Swift package `Islet` (iOS 15+, library product `Islet`). |
| [`Sources/Islet/`](Sources/Islet/) | iOS implementation: gate, state machine, injected JavaScript, the `WKWebView` engine, the expanded panel and the floating card. |
| [`docs/IOS.md`](docs/IOS.md) | Integration guide: public API, theming, what the host has to provide. |

## Using it in an iOS app

Add the package with Swift Package Manager (Xcode: *File > Add Package Dependencies...*,
or in `Package.swift`):

```swift
.package(url: "https://github.com/<owner>/islet.git", branch: "main")
// target dependency: .product(name: "Islet", package: "islet")
```

Minimal wiring:

```swift
import Islet

let browser = BrowserService()
browser.connect(
    send: { frame in socket.send(json: frame) },                 // return false when offline
    isOnline: { socket.isAuthenticated },
    isForeground: { UIApplication.shared.applicationState == .active },
    upload: { jpeg in await uploadScreenshot(jpeg) })            // optional

socket.onFrame = { frame in browser.receive(frame) }             // every decoded frame
socket.onAuthenticated = { browser.restate(.lineUp) }            // and .foreground on resume

// SwiftUI root view; keep it mounted for the whole session
ContentView()
    .overlay(alignment: .top) { BrowserCardStack(browser: browser) }  // optional floating card
    .isletBrowser(browser)                                          // expanded panel
```

Show / hide from your own UI with `browser.userOpen()`, `browser.show()`,
`browser.hide()` and `browser.userCloses()`.

Theming: every color, font size, corner radius and spacing comes from `IsletTheme`
(system colors and materials by default):

```swift
var theme = IsletTheme()
theme.accent = .indigo
theme.corners.panel = 24
ContentView().isletBrowser(browser).isletTheme(theme)
```

What you still provide yourself: the transport to your bridge server (and the bridge
itself), the screenshot upload endpoint, calls to `restate(_:)` after reconnecting and on
returning to the foreground, an entry button if you want users to open the browser, and
localisation of the English UI strings. Details in [`docs/IOS.md`](docs/IOS.md).

## Status

This is a **reference implementation extracted from a private app**.

- iOS only (iOS 15+).
- The package includes the `WKWebView` engine (with download blocking and file-chooser
  suppression), the expanded panel ("Share with agent", "Done, show the agent", take-over
  banner, collapse / expand) and the floating card, all themeable through `IsletTheme`.
- No bridge server is included; the protocol document describes what it has to do.
- Builds cleanly with Xcode 27.2 (Swift 6.4.2, Swift 5 language mode) for the iOS 15 Simulator target, with zero warnings. Device (iphoneos) and Release builds have not been tried yet.
- No tests are shipped yet.
- The protocol document describes a few fields (for example machine-readable error
  `code`s) that the code does not emit yet; see "Differences from the protocol
  document" in `docs/IOS.md`.

## License

[MIT](LICENSE)
