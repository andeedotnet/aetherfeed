import Foundation

/// Converts Adblock-format filter lists (e.g. hagezi `multi.txt`, mostly
/// `||domain^` network rules) into WebKit's `WKContentRuleList` JSON.
///
/// Scope: network blocking only. Cosmetic rules (`##selector`), regex filters
/// and complex `$options` are skipped — matching what DNS-style lists contain.
enum AdblockConverter {
    struct Rule: Encodable, Equatable {
        struct Trigger: Encodable, Equatable {
            var urlFilter: String
            enum CodingKeys: String, CodingKey { case urlFilter = "url-filter" }
        }
        struct Action: Encodable, Equatable {
            var type: String
        }
        var trigger: Trigger
        var action: Action
    }

    struct Result {
        var rules: [Rule]
        var skipped: Int
    }

    static func convert(_ text: String) -> Result {
        var rules: [Rule] = []
        var skipped = 0

        text.enumerateLines { rawLine, _ in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            switch classify(line) {
            case .ignore:
                break
            case .block(let domain):
                rules.append(
                    Rule(
                        trigger: .init(urlFilter: urlFilter(for: domain)),
                        action: .init(type: "block")))
            case .exception(let domain):
                rules.append(
                    Rule(
                        trigger: .init(urlFilter: urlFilter(for: domain)),
                        action: .init(type: "ignore-previous-rules")))
            case .unsupported:
                skipped += 1
            }
        }

        return Result(rules: rules, skipped: skipped)
    }

    /// Encodes rules as the JSON array WebKit expects.
    static func json(for rules: [Rule]) throws -> String {
        let data = try JSONEncoder().encode(rules)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Line classification

    private enum LineKind {
        case ignore
        case block(domain: String)
        case exception(domain: String)
        case unsupported
    }

    private static func classify(_ line: String) -> LineKind {
        if line.isEmpty { return .ignore }
        // Comments and Adblock headers.
        if line.hasPrefix("!") || line.hasPrefix("[") { return .ignore }
        // Cosmetic rules — not representable as network rules here.
        if line.contains("##") || line.contains("#@#")
            || line.contains("#?#") || line.contains("#$#") {
            return .ignore
        }

        // Exception: @@||domain^ or @@||domain^$options
        if line.hasPrefix("@@") {
            if let domain = domain(fromAnchored: String(line.dropFirst(2))) {
                return .exception(domain: domain)
            }
            return .unsupported
        }

        // Network anchored rule: ||domain^ (optionally with $options we ignore).
        if line.hasPrefix("||") {
            if let domain = domain(fromAnchored: line) {
                return .block(domain: domain)
            }
            return .unsupported
        }

        // Hosts-style ("0.0.0.0 domain" / "127.0.0.1 domain") or a bare domain.
        if let domain = domain(fromHostsOrBare: line) {
            return .block(domain: domain)
        }

        return .unsupported
    }

    /// Extracts the domain from a `||domain^`-anchored rule, rejecting anything
    /// with wildcards, paths or regex we can't map to a plain domain block.
    private static func domain(fromAnchored rule: String) -> String? {
        guard rule.hasPrefix("||") else { return nil }
        var body = String(rule.dropFirst(2))

        // Drop $options — we block the domain regardless of them.
        if let dollar = body.firstIndex(of: "$") {
            body = String(body[..<dollar])
        }
        // The separator `^` must terminate the domain; also accept end-of-string.
        if let caret = body.firstIndex(of: "^") {
            body = String(body[..<caret])
        }
        return validDomain(body)
    }

    private static func domain(fromHostsOrBare line: String) -> String? {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        let candidate: Substring
        switch parts.count {
        case 1:
            candidate = parts[0]
        case 2 where ["0.0.0.0", "127.0.0.1", "::1"].contains(String(parts[0])):
            candidate = parts[1]
        default:
            return nil
        }
        return validDomain(String(candidate))
    }

    /// Accepts only plain hostnames (letters, digits, dots, hyphens with a dot).
    private static func validDomain(_ value: String) -> String? {
        let domain = value.hasSuffix(".") ? String(value.dropLast()) : value
        guard !domain.isEmpty, domain.contains(".") else { return nil }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        guard domain.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return domain.lowercased()
    }

    /// Builds a WebKit `url-filter` regex that matches the domain and its
    /// subdomains, without partial-word matches (`mydomain.com` ≠ `domain.com`).
    static func urlFilter(for domain: String) -> String {
        let escaped = domain.replacingOccurrences(of: ".", with: "\\.")
        return "^https?://([^/]*\\.)?" + escaped + "[:/]"
    }
}
