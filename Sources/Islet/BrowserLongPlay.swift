import Foundation

// MARK: - Long sessions: reclaimed pages and state notes

/// The page that was on screen when the OS terminated the web content process.
struct BrowserLostPage: Equatable {
    var url: String?
    var title: String?
}

/// A `browser.state` frame as a value, used for re-reporting and de-duplication.
struct BrowserStateNote: Equatable {
    var phase: String
    var by: BrowserWire.By?
    var owner: BrowserOwner?
    var shared: Bool
    var url: String? = nil
    var title: String? = nil
    var handed: Bool = false

    init(phase: String, by: BrowserWire.By?, owner: BrowserOwner?, shared: Bool,
         url: String? = nil, title: String? = nil, handed: Bool = false) {
        self.phase = phase
        self.by = by
        self.owner = owner
        self.shared = shared
        self.url = url
        self.title = title
        self.handed = handed
    }

    init?(frame: [String: Any]) {
        guard (frame[BrowserWire.Key.type] as? String) == BrowserWire.state,
              let phase = frame[BrowserWire.Key.state] as? String else { return nil }
        self.phase = phase
        by = (frame[BrowserWire.Key.by] as? String).flatMap(BrowserWire.By.init(rawValue:))
        owner = (frame[BrowserWire.Key.owner] as? String).flatMap(BrowserOwner.init(rawValue:))
        shared = (frame[BrowserWire.Key.shared] as? Bool) ?? false
        url = frame[BrowserWire.Key.url] as? String
        title = frame[BrowserWire.Key.title] as? String
        handed = (frame[BrowserHandWire.Key.handed] as? Bool) ?? false
    }

    var frame: [String: Any] {
        BrowserWire.stateFrame(phase: phase, by: by, owner: owner, shared: shared, url: url, title: title,
                               handed: handed)
    }
}

/// More messages for the agent.
extension BrowserCopy {
    static func reclaimed(_ url: String?) -> String {
        guard let url, !url.isEmpty else { return "The system reclaimed the web page (most likely due to memory pressure). It has to be opened again." }
        return "The system reclaimed the web page (most likely due to memory pressure). It has to be opened again: \(url)"
    }

    /// Shown to the user in the panel.
    static let reclaimedForUser = "The system reclaimed this web page, most likely due to memory pressure. Open it again to continue."

    /// A pending `open` superseded by a later agent `open`.
    static let replacedByAgent = "This request was replaced by your later open request, which is already loading. Wait for its reply."

    /// A pending `open` superseded by the user typing an address.
    static let replacedByUser = "The user opened a different page from the address bar, so this request was replaced. Take a snapshot to see what is on screen now; do not reopen, or the user's page will be replaced."

    /// The pending navigation was cancelled (NSURLErrorCancelled). Not retryable.
    static let interrupted = "This load was interrupted (most likely by another link tap, back/forward navigation, or a redirect by the page itself). Take a snapshot to see what is on screen now before reopening."

    static let scriptFailed = "The page is still open, but injecting the script failed. Try again."

    static let snapshotBroke = "The page could not be read: the extraction script threw an error. The page is not necessarily empty; try another snapshot."
}

/// Maps network errors of a failed `open` to a sentence for the agent. Only the error
/// code is inspected, not the domain.
enum BrowserAgentWords {
    static let noHost = "The server for this address could not be found. The address may be mistyped, or the site may be unreachable from the device's current network."

    static func of(_ error: Error) -> (words: String, retryable: Bool) {
        let ns = error as NSError
        switch ns.code {
        case NSURLErrorNotConnectedToInternet:
            return ("The device is offline. Try again once it is connected.", true)
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return (noHost, true)
        case NSURLErrorCannotConnectToHost:
            return ("The server was found but refused the connection. It is probably not running.", true)
        case NSURLErrorTimedOut:
            return ("The request timed out without a response.", true)
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
            return ("The site's certificate is not valid; the connection was not made.", true)
        case NSURLErrorCancelled:
            return (BrowserCopy.interrupted, false)
        default:
            return ("The page could not be opened. System error: \(ns.localizedDescription)", true)
        }
    }
}
