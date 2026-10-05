import Darwin
import SwiftUI
import CefSwiftUI

/// CefSwift installs its `NSApplication` subclass and initializes CEF before
/// SwiftUI/AppKit touch `NSApp`. `CefSwiftApp` owns that bootstrap and the
/// matching orderly shutdown; the existing delegate remains Peekr's composition
/// root and the hidden placeholder scene keeps this an LSUIElement menu-bar app.
@main
struct PeekrApp: CefSwiftApp {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @MainActor
    static var cefConfiguration: CefConfiguration {
        makeCefConfiguration(SettingsStore().load())
    }

    /// Build the CEF bootstrap from a settings snapshot. A separate pure-ish
    /// function so the agent-access port wiring stays testable without touching
    /// real user settings on disk.
    @MainActor
    static func makeCefConfiguration(_ data: SettingsData) -> CefConfiguration {
        if ProcessInfo.processInfo.environment["PEEKR_IMPORT_PROBE"] == "1" {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let profiles = ChromeCookieImporter.discoverProfiles()
            let books = BookmarkImporter.availableSources()
            let report = """
            home=\(home.path)
            sandbox=\(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] ?? "-")
            profiles=\(profiles.map { "\($0.id)|\($0.name)|\($0.directoryURL.path)" })
            bookmarks=\(books.map { "\($0.name)|\($0.fileURL.path)" })
            """
            try? report.write(
                to: URL(fileURLWithPath: "/private/tmp/peekr-import-probe.txt"),
                atomically: true,
                encoding: .utf8
            )
            exit(0)
        }
        let unresolvedRoot =
            AppPaths.supportDirectory.appendingPathComponent("Chromium", isDirectory: true)
        // Canonicalize /tmp → /private/tmp (and other symlink/firmlink parents)
        // only after the leaf exists. Foundation's resolvingSymlinksInPath does
        // not resolve macOS firmlinks, while CEF canonicalizes root_cache_path
        // before textually validating child profile paths.
        try? FileManager.default.createDirectory(at: unresolvedRoot, withIntermediateDirectories: true)
        let canonicalPath = unresolvedRoot.path.withCString { path in
            realpath(path, nil).map { resolved in
                defer { free(resolved) }
                return String(cString: resolved)
            }
        }
        let root = canonicalPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? unresolvedRoot.standardizedFileURL
        var configuration = CefConfiguration()
        configuration.rootCachePath = root
        configuration.cachePath = root.appendingPathComponent("Default", isDirectory: true)
        configuration.logFile = root.appendingPathComponent("debug.log")
        configuration.persistSessionCookies = true
        configuration.defaultRuntimeStyle = .alloy
        configuration.locale = data.language.cefLocaleIdentifier
        // Agent access: expose Chromium's DevTools protocol on localhost so any
        // CDP-speaking tool (Playwright, browser-use, a custom CLI) can drive
        // Peekr's pages. CEF only reads this at runtime init, so a settings
        // change takes effect on relaunch.
        if data.agentAccessEnabled, (1...65535).contains(data.agentDebugPort) {
            configuration.remoteDebuggingPort = data.agentDebugPort
        }
        // Keep `userAgentProduct` nil so CEF emits its standard Chromium UA.
        // Setting this replaces the `Chrome/<version>` product token instead
        // of appending to it, which makes simple detectors misclassify Peekr as
        // Safari because `Safari/537.36` remains while `Chrome/...` disappears.
        // The bundle pipeline flips this only for a properly signed hardened
        // build. Chromium cannot derive a validation category from an ordinary
        // local/ad-hoc build, so attempting to sandbox that build produces
        // errSecCSReqFailed (-67030). Keep an explicit diagnostic escape hatch.
        let bundleEnablesSandbox =
            Bundle.main.object(forInfoDictionaryKey: "PeekrCEFSandboxEnabled") as? Bool
            ?? false
        configuration.noSandbox =
            !bundleEnablesSandbox
            || ProcessInfo.processInfo.environment["PEEKR_DISABLE_CEF_SANDBOX"] == "1"
        return configuration
    }

    var body: some Scene {
        // Peekr owns its real preferences window in AppKit so it can share the
        // already-created Settings/AppModel instances from AppDelegate. A
        // SwiftUI.Settings scene with EmptyView would make macOS create a
        // blank, user-visible "Peekr Settings" window on its own.
        WindowGroup {
            PeekrLifecyclePlaceholder()
        }
        .windowResizability(.contentSize)
    }
}

/// SwiftUI needs one scene to anchor the app lifecycle, while Peekr's visible
/// UI is the status item, slide-over panel, and AppKit-owned preferences window.
/// Hide this placeholder from the moment its window is attached.
private struct PeekrLifecyclePlaceholder: NSViewRepresentable {
    func makeNSView(context: Context) -> PlaceholderView { PlaceholderView() }

    func updateNSView(_ nsView: PlaceholderView, context: Context) {}

    final class PlaceholderView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.orderOut(nil)
        }
    }
}
