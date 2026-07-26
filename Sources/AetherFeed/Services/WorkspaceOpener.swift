import AppKit

/// Hands URLs to the user's default apps — but only web URLs. Every caller
/// passes a value that ultimately comes from a feed or a rendered page, so
/// `file://`, `smb://` or a third-party app's custom scheme must never
/// reach LaunchServices: a single malicious feed item would otherwise be
/// enough to launch another app or reveal a local file.
enum WorkspaceOpener {
    /// Only plain web schemes are safe to hand to LaunchServices.
    static func isOpenable(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https": true
        default: false
        }
    }

    @discardableResult
    static func open(_ url: URL) -> Bool {
        guard isOpenable(url) else { return false }
        return NSWorkspace.shared.open(url)
    }
}
