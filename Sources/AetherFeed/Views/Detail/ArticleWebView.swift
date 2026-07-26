import SwiftUI
import WebKit

/// Bridges the WKWebView out of the representable so the detail toolbar
/// can ask the live view for a PDF snapshot.
@MainActor
@Observable
final class WebViewProxy {
    weak var webView: WKWebView?
}

/// Renders the article's actual web page (or feed HTML as fallback) in a
/// WKWebView. Clicked links open in the default browser, not in the app.
struct ArticleWebView: NSViewRepresentable {
    enum Content: Equatable {
        case remote(URL)
        case html(String, baseURL: URL?)
    }

    var content: Content
    @Binding var isLoading: Bool
    /// Called when a remote page fails to load (e.g. offline) so the caller
    /// can fall back to the feed text.
    var onFailure: () -> Void = {}
    /// Compiled ad-block content rules and a version that bumps when they change.
    var contentRuleLists: [WKContentRuleList] = []
    var ruleListsVersion: Int = 0
    /// Optional bridge for callers that need the underlying web view.
    var proxy: WebViewProxy?

    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator(isLoading: $isLoading, onFailure: onFailure)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        // WKWebView's default UA lacks the "Version/… Safari/…" suffix, which
        // lets servers detect embedded views — send the full Safari UA instead.
        webView.customUserAgent = SafariUserAgent.value
        // Avoids a white flash while pages load in dark mode.
        webView.underPageBackgroundColor = .windowBackgroundColor
        applyRuleLists(to: webView, context: context)
        applyAppearance(to: webView)
        proxy?.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Signals light/dark to web content: WebKit maps the view's
        // NSAppearance to the page's `prefers-color-scheme`.
        applyAppearance(to: webView)
        context.coordinator.isLoading = $isLoading
        context.coordinator.onFailure = onFailure

        let ruleListsChanged = context.coordinator.ruleListsVersion != ruleListsVersion
        if ruleListsChanged {
            applyRuleLists(to: webView, context: context)
        }
        guard context.coordinator.lastContent != content || ruleListsChanged else { return }
        context.coordinator.lastContent = content

        switch content {
        case .remote(let url):
            isLoading = true
            webView.load(URLRequest(url: url))
        case .html(let html, let baseURL):
            isLoading = false
            webView.loadHTMLString(Self.page(for: html), baseURL: baseURL)
        }
    }

    private func applyRuleLists(to webView: WKWebView, context: Context) {
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        for list in contentRuleLists {
            controller.add(list)
        }
        context.coordinator.ruleListsVersion = ruleListsVersion
    }

    private func applyAppearance(to webView: WKWebView) {
        let name: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
        if webView.appearance?.name != name {
            webView.appearance = NSAppearance(named: name)
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastContent: Content?
        var ruleListsVersion = -1
        var isLoading: Binding<Bool>
        var onFailure: () -> Void

        init(isLoading: Binding<Bool>, onFailure: @escaping () -> Void) {
            self.isLoading = isLoading
            self.onFailure = onFailure
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading.wrappedValue = false
        }

        func webView(
            _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
        ) {
            isLoading.wrappedValue = false
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            isLoading.wrappedValue = false
            // NSURLErrorCancelled fires when a new load replaces this one.
            if (error as NSError).code != NSURLErrorCancelled {
                onFailure()
            }
        }
    }

    private static func page(for body: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root { color-scheme: light dark; }
        body {
            font-family: -apple-system, "Helvetica Neue", sans-serif;
            font-size: 15px;
            line-height: 1.55;
            color: canvastext;
            background-color: canvas;
            max-width: 44em;
            margin: 0 auto;
            padding: 1.25em 1.5em 3em;
            word-wrap: break-word;
        }
        img, video, iframe { max-width: 100%; height: auto; }
        a { color: linktext; }
        pre {
            overflow-x: auto;
            padding: 0.75em;
            background: rgba(127, 127, 127, 0.12);
            border-radius: 6px;
        }
        code { font-family: ui-monospace, Menlo, monospace; font-size: 0.9em; }
        blockquote {
            margin-left: 0;
            padding-left: 1em;
            border-left: 3px solid rgba(127, 127, 127, 0.4);
            color: color-mix(in srgb, canvastext 70%, transparent);
        }
        figure { margin: 1em 0; }
        figcaption { font-size: 0.85em; opacity: 0.7; }
        hr { border: none; border-top: 1px solid rgba(127, 127, 127, 0.3); }
        table { border-collapse: collapse; display: block; overflow-x: auto; }
        td, th { border: 1px solid rgba(127, 127, 127, 0.3); padding: 0.3em 0.6em; }
        </style>
        </head>
        <body>\(body)</body>
        </html>
        """
    }
}
