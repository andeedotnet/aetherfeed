import WebKit

/// Reader-style content extraction from the live article web view: picks the
/// main content container (article/main heuristic, like Safari Reader) and
/// serializes its DOM straight to Markdown. Runs in the page's JS context,
/// so it captures the full rendered page — not just the feed excerpt.
@MainActor
enum ReaderExtractor {
    static func markdown(from webView: WKWebView) async -> String? {
        guard let result = try? await webView.evaluateJavaScript(script) as? String else {
            return nil
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let script = #"""
        (() => {
            const SKIP = new Set([
                "SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "NAV", "ASIDE",
                "FOOTER", "HEADER", "FORM", "IFRAME", "BUTTON", "SVG",
                "CANVAS", "VIDEO", "AUDIO", "SELECT", "INPUT", "TEXTAREA",
            ]);
            const skipped = (el) =>
                SKIP.has(el.tagName) || el.hidden
                    || el.getAttribute("aria-hidden") === "true";

            // Reader heuristic: the marked-up main container wins when it
            // holds substantial text; otherwise fall back to the body.
            const pickRoot = () => {
                let best = null, bestLength = 0;
                for (const el of document.querySelectorAll("article, main, [role='main']")) {
                    const length = (el.innerText || "").length;
                    if (length > bestLength) { best = el; bestLength = length; }
                }
                return bestLength > 200 ? best : document.body;
            };

            const inline = (node) => {
                let out = "";
                for (const child of node.childNodes) {
                    if (child.nodeType === Node.TEXT_NODE) {
                        out += child.textContent.replace(/\s+/g, " ");
                        continue;
                    }
                    if (child.nodeType !== Node.ELEMENT_NODE || skipped(child)) continue;
                    const tag = child.tagName;
                    if (tag === "BR") out += "\n";
                    else if (tag === "A") {
                        const text = inline(child).trim();
                        out += child.href && text ? `[${text}](${child.href})` : text;
                    } else if (tag === "STRONG" || tag === "B") {
                        const text = inline(child).trim();
                        if (text) out += `**${text}**`;
                    } else if (tag === "EM" || tag === "I") {
                        const text = inline(child).trim();
                        if (text) out += `*${text}*`;
                    } else if (tag === "CODE") {
                        const text = child.innerText.trim();
                        if (text) out += "`" + text + "`";
                    } else if (tag === "IMG") {
                        if (child.src) out += `![${child.getAttribute("alt") || ""}](${child.src})`;
                    } else {
                        out += inline(child);
                    }
                }
                return out;
            };

            const blocks = [];
            const push = (text) => { if (text) blocks.push(text); };
            const walk = (node) => {
                for (const child of node.children) {
                    if (skipped(child)) continue;
                    const tag = child.tagName;
                    if (/^H[1-6]$/.test(tag)) {
                        push("#".repeat(+tag[1]) + " " + inline(child).trim());
                    } else if (tag === "P") {
                        push(inline(child).trim());
                    } else if (tag === "UL" || tag === "OL") {
                        const items = [];
                        let index = 1;
                        for (const li of child.children) {
                            if (li.tagName !== "LI") continue;
                            const text = inline(li).trim();
                            if (text) items.push((tag === "OL" ? `${index}. ` : "- ") + text);
                            index += 1;
                        }
                        push(items.join("\n"));
                    } else if (tag === "BLOCKQUOTE") {
                        const text = inline(child).trim();
                        if (text) push("> " + text.split("\n").join("\n> "));
                    } else if (tag === "PRE") {
                        const code = child.innerText.replace(/\n$/, "");
                        if (code) push("```\n" + code + "\n```");
                    } else if (tag === "IMG") {
                        if (child.src) push(`![${child.getAttribute("alt") || ""}](${child.src})`);
                    } else if (tag === "FIGURE") {
                        const img = child.querySelector("img");
                        if (img && img.src) {
                            const caption = child.querySelector("figcaption");
                            push(`![${(caption ? caption.innerText : img.getAttribute("alt")) || ""}](${img.src})`);
                        }
                    } else if (tag === "TABLE") {
                        push(child.innerText.trim());
                    } else if (child.children.length === 0) {
                        // Bare text in a container (e.g. <div>text</div>).
                        push(inline(child).trim());
                    } else {
                        walk(child);
                    }
                }
            };

            walk(pickRoot());
            return blocks.join("\n\n");
        })()
        """#
}
