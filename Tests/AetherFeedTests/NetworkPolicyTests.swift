import Foundation
import Testing

@testable import AetherFeed

/// The app allows cleartext HTTP for local networking only, so these
/// classifications decide where an API key or article text may travel.
@Suite struct NetworkPolicyTests {
    @Test func recognisesLocalHosts() {
        for host in [
            "localhost", "127.0.0.1", "127.1.2.3", "::1", "printer.local",
            "192.168.1.239", "10.0.0.5", "172.16.0.1", "172.31.255.254",
            "169.254.1.1", "ollama",
        ] {
            #expect(NetworkPolicy.isLocalHost(host), "\(host)")
        }
    }

    @Test func treatsPublicHostsAsRemote() {
        for host in [
            "api.openai.com", "example.com", "8.8.8.8", "172.32.0.1",
            "192.169.1.1", "11.0.0.1", "",
        ] {
            #expect(!NetworkPolicy.isLocalHost(host), "\(host)")
        }
    }

    @Test func onlyHTTPSOrLocalCountsAsSecure() {
        #expect(NetworkPolicy.isSecureOrLocal(URL(string: "https://api.openai.com/v1")!))
        #expect(NetworkPolicy.isSecureOrLocal(URL(string: "http://127.0.0.1:1234/v1")!))
        #expect(NetworkPolicy.isSecureOrLocal(URL(string: "http://192.168.1.239:11434")!))
        #expect(!NetworkPolicy.isSecureOrLocal(URL(string: "http://api.example.com/v1")!))
        #expect(!NetworkPolicy.isSecureOrLocal(URL(string: "ftp://example.com")!))
    }

    /// A bare host name defaults to plain http only on the local network.
    @Test func ollamaPicksSchemeByLocality() {
        func url(_ host: String) -> String? {
            OllamaConfig(host: host, port: 11434, model: "m").baseURL?.absoluteString
        }
        #expect(url("192.168.1.239") == "http://192.168.1.239:11434")
        #expect(url("localhost") == "http://localhost:11434")
        #expect(url("ollama.example.com") == "https://ollama.example.com:11434")
        // An explicit scheme always wins.
        #expect(url("http://ollama.example.com:11434") == "http://ollama.example.com:11434")
    }
}
