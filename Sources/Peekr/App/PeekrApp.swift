import Darwin
import SwiftUI
import CefSwiftUI

/// CefSwift installs its `NSApplication` subclass and initializes CEF before
/// SwiftUI/AppKit touch `NSApp`. `CefSwiftApp` owns that bootstrap and the
/// matching orderly shutdown; the existing delegate remains Peekr's composition
/// root and the Settings-only scene keeps this an LSUIElement menu-bar app.
@main
struct PeekrApp: CefSwiftApp {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @MainActor
    static var cefConfiguration: CefConfiguration {
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
        let version =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.1.0"
        configuration.userAgentProduct = "Peekr/\(version)"
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
        SwiftUI.Settings {
            EmptyView()
        }
    }
}
