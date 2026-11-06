# islet · App内置浏览器小组件参考

[English](README.md)

一套协议加一份 iOS 参考实现：让 AI agent 操作**你自己 App 里的**内置浏览器，用户在同一块屏幕上实时看着，随时可以接手。

## 解决什么问题

常见的「AI 帮你上网」是在服务器上跑一个无头浏览器：用户看不见 agent 在干什么，插不上手，agent 碰到密码框、支付页的时候也没人盯着。

这里 agent 借用的是用户设备上、宿主 App 里唯一的那个浏览器：

- **同一块屏幕，实时可见。** agent 在 App 内置的 WebView 里打开、读取、点击、输入、滚动，用户每一步都看得见。
- **随时接手。** agent 可以把浏览器交给用户（登录、支付、一切需要本人做的事），用户点「好了」之后 agent 会收到通知。用户也可以直接上手操作页面；在 `live` 模式下，agent 会被告知用户做了什么。
- **密码框硬拒。** 宿主从不向 `type=password` / `autocomplete=password` 的输入框写字，也从不读取任何表单字段的值。
- **拦截下载和文件选择器。** 下载类导航一律取消；agent 的操作若会弹出系统文件选择器，直接拒绝。
- **agent 只能读自己打开的页，或用户明确共享的页。** 用户自己打开的页面，在用户主动共享之前 agent 看不到。前进后退沿用页面最初的归属，没法靠来回跳转绕过这道闸。
- **App 不开就没有浏览器。** 宿主 App 不在前台时，所有请求立即失败，不排队。
- 只打开 `http`/`https` 网址（协议头不区分大小写）。

这些闸都在宿主（设备）上强制执行，而不只是写在 agent 的提示词里。页面内容带来的提示注入仍然是风险：协议把页面内容当作不可信数据，但这一层防线只在提示词层面。

## 架构

```
 +---------+   工具调用（如 MCP）       +---------------+   带帧 JSON（如 WebSocket）      +----------------------+
 |  agent  | ------------------------> | bridge server | <------------------------------> |      host app        |
 |  (LLM)  | <------------------------ |   （桥接服务）  |            已鉴权                 |  +----------------+  |
 +---------+   文本 / 图片结果          +---------------+                                  |  |    WebView     |<-+-- 用户看着，
                                               ^                                          |  +----------------+  |   随时接手
                                               +------- 截图上传（HTTP）-------------------+                      |
                                                                                          +----------------------+
```

- **agent**：调用 `browser_open`、`browser_snapshot`、`browser_click`、`browser_type`、`browser_scroll`、`browser_handover` 等工具。
- **bridge server（桥接服务）**：把每次工具调用转成一帧 `browser.request`，对上回包，处理超时和限流，缓存面板状态，把宿主事件（交还、用户操作）转成给 agent 的通知。
- **host app / WebView（宿主 App）**：持有唯一的浏览器实例，展示给用户，执行请求，并强制执行全部安全闸。

## 目录说明

| 路径 | 内容 |
|---|---|
| [`protocol/PROTOCOL.md`](protocol/PROTOCOL.md) | 线上协议（英文）。 |
| [`protocol/PROTOCOL.zh-CN.md`](protocol/PROTOCOL.zh-CN.md) | 同一份协议的中文版。 |
| [`protocol/schema/`](protocol/schema/) | 九种 `browser.*` 帧的 JSON Schema。 |
| [`Package.swift`](Package.swift) | Swift Package `Islet`（iOS 15+，库产品名 `Islet`）。 |
| [`Sources/Islet/`](Sources/Islet/) | iOS 实现：闸、状态机、注入的 JavaScript、`WKWebView` 引擎、展开面板和浮卡。 |
| [`docs/IOS.md`](docs/IOS.md) | 集成说明（英文）：公开 API、主题、宿主要自己实现的部分。 |

## 在 iOS App 里使用

用 Swift Package Manager 引入（Xcode：*File > Add Package Dependencies...*，或写进 `Package.swift`）：

```swift
.package(url: "https://github.com/<owner>/islet.git", branch: "main")
// target 依赖：.product(name: "Islet", package: "islet")
```

最少的接线：

```swift
import Islet

let browser = BrowserService()
browser.connect(
    send: { frame in socket.send(json: frame) },                 // 断线时返回 false，不排队
    isOnline: { socket.isAuthenticated },
    isForeground: { UIApplication.shared.applicationState == .active },
    upload: { jpeg in await uploadScreenshot(jpeg) })            // 可选

socket.onFrame = { frame in browser.receive(frame) }             // 收到的每一帧都丢进来
socket.onAuthenticated = { browser.restate(.lineUp) }            // 回到前台时用 .foreground

// SwiftUI 根视图；整个会话期间一直挂着
ContentView()
    .overlay(alignment: .top) { BrowserCardStack(browser: browser) }  // 可选的浮卡
    .isletBrowser(browser)                                          // 展开面板
```

在自己的界面里显示/隐藏：`browser.userOpen()`、`browser.show()`、`browser.hide()`、`browser.userCloses()`。

主题：所有颜色、字号、圆角、间距都来自 `IsletTheme`（默认用系统颜色和材质）：

```swift
var theme = IsletTheme()
theme.accent = .indigo
theme.corners.panel = 24
ContentView().isletBrowser(browser).isletTheme(theme)
```

宿主仍需自己实现：到桥接服务的传输通道（以及桥接服务本身）、截图上传接口、重连后和回到前台时调用 `restate(_:)`、想让用户自己打开浏览器的话要有一个入口按钮、界面英文文案的本地化。详见 [`docs/IOS.md`](docs/IOS.md)。

## 状态声明

这是**从一个私有 App 里抽出来的参考实现**。

- 只有 iOS（iOS 15+）。
- 包里带了 `WKWebView` 引擎（含下载拦截和文件选择器拦截）、展开面板（「Share with agent」「Done, show the agent」、接手提示条、收起/展开）和浮卡，都可以通过 `IsletTheme` 换皮。
- 不包含桥接服务；协议文档写明了桥接服务要做的事。
- 已用 Xcode 27.2（Swift 6.4.2，Swift 5 语言模式）为 iOS 15 模拟器编译通过，零警告；真机和 Release 配置还没编过。
- 暂时没有测试。
- 协议文档里描述了少数几项代码还没有实现的字段（例如机器可读的错误 `code`），见 `docs/IOS.md` 的 “Differences from the protocol document” 一节。

## 许可证

[MIT](LICENSE)
