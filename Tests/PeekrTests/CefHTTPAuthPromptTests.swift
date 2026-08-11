import CefKit
import Testing
@testable import Peekr

@Suite("CEF HTTP authentication prompt")
@MainActor
struct CefHTTPAuthPromptTests {
    @Test func serverLabelIncludesNonDefaultPort() {
        let challenge = CefAuthChallenge(
            origin: "https://fallback.example",
            isProxy: false,
            host: "secure.example",
            port: 8443,
            realm: "Members",
            scheme: "basic"
        )
        #expect(CefHTTPAuthPrompt.serverLabel(for: challenge) == "secure.example:8443")
    }

    @Test func missingHostFallsBackToBoundedOriginLabel() {
        let challenge = CefAuthChallenge(
            origin: "https://fallback.example/path",
            isProxy: true,
            host: "",
            port: 0,
            realm: "",
            scheme: ""
        )
        #expect(CefHTTPAuthPrompt.serverLabel(for: challenge) == "fallback.example")
    }
}
