import Foundation
import Testing

@testable import AetherFeed

/// Guards the checks that keep feed- and API-controlled URLs from reaching
/// LaunchServices, the updater, or the network layer.
@Suite struct SecurityTests {
    @Test func updaterOnlyTrustsGitHubOverTLS() {
        let allowed = [
            "https://github.com/andeedotnet/aetherfeed/releases/download/v1/A.zip",
            "https://objects.githubusercontent.com/x/A.zip",
            "https://api.github.com/repos/x/releases/latest",
        ]
        for string in allowed {
            #expect(UpdateChecker.isTrustedReleaseURL(URL(string: string)!), "\(string)")
        }

        let refused = [
            // Cleartext would be permitted by the app's ATS settings.
            "http://github.com/andeedotnet/aetherfeed/releases/download/v1/A.zip",
            "https://evil.example/A.zip",
            // Suffix confusion: not actually a github.com host.
            "https://notgithub.com/A.zip",
            "https://github.com.evil.example/A.zip",
            "file:///tmp/A.zip",
        ]
        for string in refused {
            #expect(!UpdateChecker.isTrustedReleaseURL(URL(string: string)!), "\(string)")
        }
    }

    @Test func onlyWebLinksAreHandedToLaunchServices() {
        #expect(WorkspaceOpener.isOpenable(URL(string: "https://example.com/a")!))
        #expect(WorkspaceOpener.isOpenable(URL(string: "HTTP://example.com")!))
        for string in [
            "file:///Users/andee/Documents", "smb://server/share", "ftp://example.com",
            "javascript:alert(1)", "someapp://run", "mailto:a@b.c",
        ] {
            #expect(!WorkspaceOpener.isOpenable(URL(string: string)!), "\(string)")
        }
    }

    @Test func feedURLsRejectLookalikeSchemes() {
        #expect(FeedFetcher.isWebURL(URL(string: "https://example.com/feed")!))
        #expect(FeedFetcher.isWebURL(URL(string: "http://example.com/feed")!))
        // `scheme?.hasPrefix("http")` used to accept these.
        #expect(!FeedFetcher.isWebURL(URL(string: "httpfoo://example.com")!))
        #expect(!FeedFetcher.isWebURL(URL(string: "file:///etc/passwd")!))
    }
}
