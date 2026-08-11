import CefKit
import Testing
@testable import Peekr

@Suite("CEF permission prompt")
@MainActor
struct CefPermissionPromptTests {
    @Test func mediaKindsExplainDeviceAndDesktopCapture() {
        #expect(
            CefPermissionPrompt.labels(for: [.camera, .microphone])
                == ["camera or screen", "microphone or shared audio"]
        )
    }

    @Test func everyPermissionKindHasAnExplicitLabel() {
        let all: CefPermissionKind = [
            .camera, .microphone, .geolocation, .notifications, .clipboard,
            .midi, .pointerLock, .storageAccess, .sensors, .windowManagement,
            .downloads, .other,
        ]
        #expect(CefPermissionPrompt.labels(for: all).count == 12)
    }

    @Test func originUsesHostAndBoundsUnparseableText() {
        #expect(CefPermissionPrompt.originLabel("https://meet.example.com/room") == "meet.example.com")
        #expect(CefPermissionPrompt.originLabel("") == "This page")
        #expect(CefPermissionPrompt.originLabel(String(repeating: "x", count: 500)).count == 160)
    }
}
