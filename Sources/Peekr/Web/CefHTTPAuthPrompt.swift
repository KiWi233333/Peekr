import AppKit
import CefKit

/// Native HTTP Basic/Digest/proxy authentication prompt. Credentials are sent
/// directly to CEF's one-shot callback and are never persisted by Peekr.
@MainActor
enum CefHTTPAuthPrompt {
    static func serverLabel(for challenge: CefAuthChallenge) -> String {
        let host = challenge.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let server = host.isEmpty ? CefPermissionPrompt.originLabel(challenge.origin) : host
        let port = challenge.port > 0 ? ":\(challenge.port)" : ""
        return server + port
    }

    static func present(_ challenge: CefAuthChallenge, callback: CefAuthCallback) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = challenge.isProxy ? "Proxy authentication required" : "Authentication required"

        let realm = challenge.realm.trimmingCharacters(in: .whitespacesAndNewlines)
        let scheme = challenge.scheme.trimmingCharacters(in: .whitespacesAndNewlines)
        var details = serverLabel(for: challenge)
        if !realm.isEmpty { details += " — \(realm)" }
        if !scheme.isEmpty { details += " (\(scheme))" }
        alert.informativeText = details

        let username = NSTextField(string: "")
        username.placeholderString = "Username"
        let password = NSSecureTextField(string: "")
        password.placeholderString = "Password"
        let fields = NSStackView(views: [username, password])
        fields.orientation = .vertical
        fields.spacing = 8
        fields.frame = NSRect(x: 0, y: 0, width: 300, height: 56)
        alert.accessoryView = fields

        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[1].keyEquivalent = "\u{1b}"
        alert.window.initialFirstResponder = username
        alert.window.level = .floating
        NSApp.activate(ignoringOtherApps: true)

        if alert.runModal() == .alertFirstButtonReturn {
            callback.continue(username: username.stringValue, password: password.stringValue)
        } else {
            callback.cancel()
        }
        return true
    }
}
