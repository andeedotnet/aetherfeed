import Foundation

/// Presents the app to servers exactly like the installed Safari, so feed
/// hosts and article pages cannot distinguish AetherFeed from a regular browser.
///
/// Safari's user agent has been frozen for years (macOS token `10_15_7`,
/// WebKit `605.1.15`); the only moving part is the `Version/x.y` number,
/// which is read from the installed Safari at launch.
enum SafariUserAgent {
    static let value: String = {
        let version = installedSafariVersion ?? fallbackVersion
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/\(version) Safari/605.1.15"
    }()

    /// Safari's default document Accept header.
    static let accept = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"

    /// Browser-style Accept-Language built from the system's preferred languages,
    /// e.g. "de-DE,de;q=0.9,en;q=0.8".
    static let acceptLanguage: String = {
        var parts: [String] = []
        var quality = 10
        for language in Locale.preferredLanguages.prefix(4) {
            parts.append(quality == 10 ? language : "\(language);q=0.\(quality)")
            quality -= 1
        }
        return parts.isEmpty ? "en-US" : parts.joined(separator: ",")
    }()

    private static var installedSafariVersion: String? {
        guard
            let info = NSDictionary(
                contentsOfFile: "/Applications/Safari.app/Contents/Info.plist"),
            let version = info["CFBundleShortVersionString"] as? String,
            !version.isEmpty
        else { return nil }
        return version
    }

    /// Used only if Safari's Info.plist is unreadable.
    private static let fallbackVersion = "26.0"
}
