import AppKit
import CefKit

/// Native permission UI for CEF's synchronous permission delegate. The web
/// origin remains the authority displayed to the user; Peekr never grants a
/// capability silently and Chromium/macOS still enforce their own constraints.
@MainActor
enum CefPermissionPrompt {
    #if DEBUG
    private static func recordSmokePrompt(origin: String, requested: [String]) {
        let resultURL = AppPaths.supportDirectory.appendingPathComponent("permission-smoke.log")
        let message = "__PEEKR_PERMISSION_PROMPT__:\(origin):\(requested.joined(separator: ","))\n"
        let bytes = Data(message.utf8)
        if !FileManager.default.fileExists(atPath: resultURL.path) {
            FileManager.default.createFile(atPath: resultURL.path, contents: bytes)
        } else if let handle = try? FileHandle(forWritingTo: resultURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: bytes)
            try? handle.close()
        }
    }
    #endif

    static func labels(for kinds: CefPermissionKind) -> [String] {
        var labels: [String] = []
        // CEF maps desktop video/audio capture onto the same public kinds, so
        // the labels explicitly cover screen/system-audio sharing as well.
        if kinds.contains(.camera) { labels.append("camera or screen") }
        if kinds.contains(.microphone) { labels.append("microphone or shared audio") }
        if kinds.contains(.geolocation) { labels.append("location") }
        if kinds.contains(.notifications) { labels.append("notifications") }
        if kinds.contains(.clipboard) { labels.append("clipboard") }
        if kinds.contains(.midi) { labels.append("MIDI devices") }
        if kinds.contains(.pointerLock) { labels.append("pointer lock") }
        if kinds.contains(.storageAccess) { labels.append("cross-site storage") }
        if kinds.contains(.sensors) { labels.append("motion sensors") }
        if kinds.contains(.windowManagement) { labels.append("window management") }
        if kinds.contains(.downloads) { labels.append("multiple downloads") }
        if kinds.contains(.other) { labels.append("additional browser capabilities") }
        return labels
    }

    static func originLabel(_ origin: String) -> String {
        if let url = URL(string: origin), let host = url.host, !host.isEmpty {
            return host
        }
        let trimmed = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "This page" : String(trimmed.prefix(160))
    }

    static func decide(_ request: CefPermissionRequest) -> CefPermissionDecision {
        let requested = labels(for: request.kinds)
        guard !requested.isEmpty else { return .deny }

        let origin = originLabel(request.origin)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Allow \(origin)?"
        alert.informativeText = "This page wants to use \(naturalList(requested))."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        // Avoid granting a sensitive capability through an accidental Return;
        // Escape always takes the deny path.
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\u{1b}"
        alert.window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        #if DEBUG
        if ProcessInfo.processInfo.environment["PEEKR_SMOKE_AUTO_DENY_PERMISSIONS"] == "1" {
            recordSmokePrompt(origin: origin, requested: requested)
            // The production path below is deliberately synchronous. CEF's
            // permission callback does not service queued main-thread blocks
            // while NSAlert.runModal owns that callback stack, so the explicit
            // smoke mode records the fully constructed native prompt and takes
            // the safe deny path without entering a modal session.
            return .deny
        }
        #endif
        return alert.runModal() == .alertFirstButtonReturn ? .allow : .deny
    }

    private static func naturalList(_ values: [String]) -> String {
        switch values.count {
        case 0: return "browser capabilities"
        case 1: return values[0]
        case 2: return "\(values[0]) and \(values[1])"
        default: return values.dropLast().joined(separator: ", ") + ", and " + values.last!
        }
    }
}
