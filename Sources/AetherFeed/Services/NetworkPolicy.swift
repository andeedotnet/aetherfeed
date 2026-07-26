import Foundation

/// Decides where cleartext HTTP is still acceptable. The app's ATS settings
/// allow it for local networking only, and AI servers on the LAN (Ollama,
/// LM Studio) genuinely speak plain HTTP — but a *public* host must not
/// receive article text or an API key unencrypted.
enum NetworkPolicy {
    /// True for loopback, `.local`, single-label hostnames and the private
    /// IPv4 ranges — i.e. everything `NSAllowsLocalNetworking` covers.
    static func isLocalHost(_ host: String) -> Bool {
        let name = host.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if name.isEmpty { return false }
        if name == "localhost" || name == "::1" { return true }
        if name.hasSuffix(".local") || name.hasSuffix(".localhost") { return true }

        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else {
            // Not an IPv4 literal: a name without a dot is a LAN hostname.
            return !name.contains(".")
        }
        let octets = parts.compactMap { UInt8($0) }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (169, 254):
            return true
        case (192, 168):
            return true
        case (172, 16...31):
            return true
        default:
            return false
        }
    }

    /// Whether a URL may carry credentials or article content as-is.
    static func isSecureOrLocal(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": true
        case "http": url.host().map(isLocalHost) ?? false
        default: false
        }
    }
}
