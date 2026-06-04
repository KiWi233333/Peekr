import AppKit

/// One open browser tab discovered via AppleScript.
struct ImportedTab: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let urlString: String
    let browser: String
}

/// Reads the URLs/titles of tabs currently open in the user's running browsers
/// through each browser's AppleScript dictionary.
///
/// Run this OFF the main thread. `NSAppleScript.executeAndReturnError` blocks
/// until the Apple Event replies — and the *first* call needs the system
/// Automation consent prompt to draw, which it can't do while the main thread
/// is blocked. Running on a background thread keeps the main run loop free so
/// the prompt appears; the background call then waits for the user's choice.
///
/// Needs `NSAppleEventsUsageDescription` in Info.plist and a signed `.app`
/// bundle (not bare `swift run`). Firefox and Arc don't expose tabs to
/// AppleScript and are skipped.
enum OpenTabsImporter {
    private struct Source {
        let bundleID: String
        let displayName: String
        let appName: String   // AppleScript application name
        let titleKey: String  // Safari uses `name`; Chromium uses `title`
    }

    private static let sources = [
        Source(bundleID: "com.apple.Safari", displayName: "Safari", appName: "Safari", titleKey: "name"),
        Source(bundleID: "com.google.Chrome", displayName: "Chrome", appName: "Google Chrome", titleKey: "title"),
        Source(bundleID: "com.microsoft.edgemac", displayName: "Edge", appName: "Microsoft Edge", titleKey: "title"),
        Source(bundleID: "com.brave.Browser", displayName: "Brave", appName: "Brave Browser", titleKey: "title"),
    ]

    /// Open tabs across every running, scriptable browser. Call off-main.
    static func readOpenTabs() -> [ImportedTab] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let active = sources.filter { running.contains($0.bundleID) }
        var log = ["scriptable browsers running: \(active.map(\.displayName))"]
        var all: [ImportedTab] = []
        for source in active {
            let (tabs, error) = read(source)
            log.append("\(source.displayName): \(tabs.count) tabs" + (error.map { " — error: \($0)" } ?? ""))
            all += tabs
        }
        writeDebug(log.joined(separator: "\n"))
        return all
    }

    private static func read(_ source: Source) -> (tabs: [ImportedTab], error: String?) {
        // AppleScript joins each tab as `URL <tab> title`, one per line. `tab`
        // and `linefeed` are AppleScript constants (real \t / \n).
        let script = """
        tell application "\(source.appName)"
            set out to ""
            repeat with w in windows
                repeat with t in tabs of w
                    set out to out & (URL of t) & tab & (\(source.titleKey) of t) & linefeed
                end repeat
            end repeat
        end tell
        return out
        """
        var error: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            // -1743 = not permitted (Automation not granted / prompt declined).
            NSLog("Peekr: open-tabs read failed for \(source.displayName): \(error)")
            return ([], "\(error[NSAppleScript.errorNumber] ?? error)")
        }
        guard let raw = result?.stringValue else { return ([], "nil result") }

        let tabs = raw.split(separator: "\n").compactMap { line -> ImportedTab? in
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 2 else { return nil }
            let url = parts[0].trimmingCharacters(in: .whitespaces)
            guard url.hasPrefix("http") else { return nil } // skip chrome://, about:, etc.
            return ImportedTab(
                title: parts[1].trimmingCharacters(in: .whitespaces),
                urlString: url,
                browser: source.displayName
            )
        }
        return (tabs, nil)
    }

    /// Last-scan outcome, for debugging the Automation flow.
    private static func writeDebug(_ text: String) {
        let url = AppPaths.supportDirectory.appendingPathComponent("import-debug.log")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
