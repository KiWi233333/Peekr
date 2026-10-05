import AppKit
import SwiftUI

/// One category of data a browser can contribute to Peekr. The set is fixed;
/// which categories are actually available depends on the selected browser.
enum BrowserImportDataType: String, CaseIterable, Identifiable, Hashable {
    case bookmarks
    case openTabs
    case cookies
    case session

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .bookmarks: return "book"
        case .openTabs: return "macwindow.on.rectangle"
        case .cookies: return "person.badge.key"
        case .session: return "rectangle.stack.badge.play"
        }
    }

    func title(_ loc: Localized) -> String {
        switch self {
        case .bookmarks: return loc.importOptionBookmarks
        case .openTabs: return loc.importOptionOpenTabs
        case .cookies: return loc.importOptionCookies
        case .session: return loc.importOptionSession
        }
    }

    func detail(_ loc: Localized) -> String {
        switch self {
        case .bookmarks: return loc.importOptionBookmarksHint
        case .openTabs: return loc.importOptionOpenTabsHint
        case .cookies: return loc.importOptionCookiesHint
        case .session: return loc.importOptionSessionHint
        }
    }
}

/// A browser Peekr can import from. The supported data types are fixed per
/// browser because each importer is backed by a browser-specific source
/// (on-disk bookmark files, AppleScript tabs, Chrome's cookie/session stores).
enum BrowserImportSource: String, CaseIterable, Identifiable, Hashable {
    case chrome
    case safari
    case edge
    case brave

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chrome: return "Chrome"
        case .safari: return "Safari"
        case .edge: return "Edge"
        case .brave: return "Brave"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .chrome: return "com.google.Chrome"
        case .safari: return "com.apple.Safari"
        case .edge: return "com.microsoft.edgemac"
        case .brave: return "com.brave.Browser"
        }
    }

    /// Categories funded by an existing importer for this browser. Chrome
    /// additionally owns the cookie and session stores; the other browsers
    /// currently only expose on-disk bookmarks and scriptable open tabs.
    var supportedTypes: Set<BrowserImportDataType> {
        switch self {
        case .chrome: return [.bookmarks, .openTabs, .cookies, .session]
        case .safari, .edge, .brave: return [.bookmarks, .openTabs]
        }
    }

    /// Browsers that are installed or already have importable on-disk data.
    /// Safari and the Chromium family are the only writers Peekr understands.
    static func availableSources() -> [BrowserImportSource] {
        let workspace = NSWorkspace.shared
        let bookmarkNames = Set(BookmarkImporter.availableSources().map(\.name))
        return allCases.filter { source in
            workspace.urlForApplication(withBundleIdentifier: source.bundleIdentifier) != nil
                || bookmarkNames.contains(source.displayName)
        }
    }
}

/// A single row of import feedback so successes and failures from several
/// selected categories can be shown together.
private struct BrowserImportOutcome: Identifiable {
    let id = UUID()
    let message: String
    let success: Bool
}

/// One explicit, user-driven entry for browser data. The user picks a browser,
/// chooses which categories to pull (all available ones are checked by
/// default), and imports once. Browser access never happens on appearance:
/// Apple Events, keychain reads and Chrome profile access only occur after the
/// import button is pressed.
struct BrowserImportSheet: View {
    let model: AppModel
    let bookmarks: BookmarksModel
    let settings: Settings
    let icons: IconStore
    var onClose: () -> Void

    @State private var sources: [BrowserImportSource] = []
    @State private var source: BrowserImportSource = .chrome
    @State private var selectedTypes: Set<BrowserImportDataType> = []
    @State private var profiles: [ChromeProfile] = []
    @State private var selectedProfileID = ""
    @State private var running = false
    @State private var outcomes: [BrowserImportOutcome] = []
    @State private var showCookieConfirmation = false
    @State private var finished = false
    @State private var accessDenied = false

    private var loc: Localized { settings.strings }
    private var selectedProfile: ChromeProfile? {
        profiles.first { $0.id == selectedProfileID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(loc.importTitle)
                .font(.system(size: 17, weight: .bold, design: .rounded))

            if sources.isEmpty {
                noBrowsersState
            } else {
                picker
                if accessDenied { accessDeniedBanner }
                if source == .chrome { chromeProfileSection }
                typeList
            }

            if !outcomes.isEmpty || running { resultSection }

            Spacer(minLength: 0)

            HStack {
                if !finished {
                    Button(loc.cancel, role: .cancel) { onClose() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(loc.importButton) { requestImport() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .tint(.primary)
                        .foregroundStyle(.background)
                        .disabled(running || selectedTypes.isEmpty)
                } else {
                    Spacer()
                    Button(loc.done) { onClose() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .tint(.primary)
                        .foregroundStyle(.background)
                }
            }
        }
        .padding(22)
        .frame(width: 480, height: 540)
        .onAppear { reload() }
        .onChange(of: source) { _, _ in resetSelection() }
        .onChange(of: selectedProfileID) { _, _ in
            // Cookies/session become available once a profile is resolved.
            applyAvailableDefaults()
        }
        .alert(loc.cookieConfirmTitle, isPresented: $showCookieConfirmation) {
            Button(loc.cancel, role: .cancel) {}
            Button(loc.importOptionCookies) { runImport() }
        } message: {
            Text(loc.cookieConfirmMessage(selectedProfile?.name ?? source.displayName))
        }
    }

    // MARK: - Sections

    private var picker: some View {
        Picker(loc.importBrowserLabel, selection: $source) {
            ForEach(sources) { browser in
                Text(browser.displayName).tag(browser)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    @ViewBuilder
    private var chromeProfileSection: some View {
        if profiles.isEmpty {
            Label(loc.chromeProfilesEmpty, systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Picker(loc.chromeProfile, selection: $selectedProfileID) {
                ForEach(profiles) { profile in
                    Text("\(profile.name) — \(profile.id)").tag(profile.id)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var accessDeniedBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(loc.importAccessDeniedTitle, systemImage: "lock.trianglebadge.exclamationmark")
                .font(.callout.weight(.semibold))
            Text(loc.importAccessDeniedMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(loc.importOpenPrivacySettings) { openPrivacySettings() }
                .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var typeList: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(BrowserImportDataType.allCases) { type in
                typeRow(type)
            }
        }
    }

    private func typeRow(_ type: BrowserImportDataType) -> some View {
        let supported = availableTypes.contains(type)
        return Toggle(
            isOn: Binding(
                get: { selectedTypes.contains(type) },
                set: { isOn in
                    if isOn { selectedTypes.insert(type) } else { selectedTypes.remove(type) }
                }
            )
        ) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Image(systemName: type.symbolName).frame(width: 16)
                    Text(type.title(loc))
                    if !supported {
                        Text(loc.importUnsupported)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(type.detail(loc))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .contentShape(Rectangle())
        }
        .toggleStyle(.checkbox)
        .disabled(!supported || running)
    }

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if running {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(loc.importRunning)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(outcomes) { outcome in
                Label(
                    outcome.message,
                    systemImage: outcome.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(outcome.success ? .green : .orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var noBrowsersState: some View {
        VStack(spacing: 12) {
            Image(systemName: "safari")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(loc.importNoBrowsers)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Availability

    /// Data types the current browser can contribute right now. Chrome's
    /// cookie and session stores only exist once a profile is resolvable.
    private var availableTypes: Set<BrowserImportDataType> {
        var types = source.supportedTypes
        if source == .chrome, selectedProfile == nil {
            types.remove(.cookies)
            types.remove(.session)
        }
        return types
    }

    private func applyAvailableDefaults() {
        selectedTypes = availableTypes
    }

    private func resetSelection() {
        outcomes = []
        finished = false
        applyAvailableDefaults()
    }

    private func reload() {
        sources = BrowserImportSource.availableSources()
        if !sources.contains(source) {
            source = sources.first ?? .chrome
        }
        profiles = ChromeCookieImporter.discoverProfiles()
        if !profiles.contains(where: { $0.id == selectedProfileID }) {
            selectedProfileID = profiles.first?.id ?? ""
        }
        accessDenied = Self.dataAccessDenied()
        outcomes = []
        finished = false
        applyAvailableDefaults()
    }

    /// macOS gates other apps' data behind the App Data / Full Disk Access TCC
    /// policy; surface that as the real reason when reads are blocked.
    private static func dataAccessDenied() -> Bool {
        if ChromeCookieImporter.chromeDataAccessDenied() { return true }
        return BookmarkImporter.availableSources().contains {
            BookmarkImporter.accessDenied(for: $0)
        }
    }

    private func openPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Import

    private func requestImport() {
        // Cookies touch the login keychain; keep a single explicit confirmation
        // before any keychain access, matching the standalone import flow.
        if selectedTypes.contains(.cookies) {
            showCookieConfirmation = true
        } else {
            runImport()
        }
    }

    private func runImport() {
        let browser = source
        let types = selectedTypes
        let profile = selectedProfile
        running = true
        finished = false
        outcomes = []

        Task {
            if types.contains(.bookmarks) {
                outcomes.append(importBookmarks(from: browser, profile: profile))
            }
            if types.contains(.openTabs) {
                outcomes.append(await importOpenTabs(from: browser))
            }
            if types.contains(.cookies), let profile {
                outcomes.append(await importCookies(from: profile))
            }
            if types.contains(.session), let profile {
                outcomes.append(await importSession(from: profile))
            }
            running = false
            finished = true
        }
    }

    private func importBookmarks(
        from browser: BrowserImportSource,
        profile: ChromeProfile?
    ) -> BrowserImportOutcome {
        let source: BookmarkImporter.Source?
        if browser == .chrome, let profile {
            let url = profile.directoryURL.appendingPathComponent("Bookmarks")
            source = FileManager.default.fileExists(atPath: url.path)
                ? BookmarkImporter.Source(name: "Chrome", fileURL: url, isSafari: false)
                : BookmarkImporter.availableSources().first { $0.name == "Chrome" }
        } else {
            source = BookmarkImporter.availableSources().first { $0.name == browser.displayName }
        }

        guard let source else {
            return BrowserImportOutcome(
                message: loc.importBookmarksUnavailable(browser.displayName),
                success: false
            )
        }
        let nodes = BookmarkImporter.importBookmarks(from: source)
        guard !nodes.isEmpty else {
            if BookmarkImporter.accessDenied(for: source) {
                return BrowserImportOutcome(
                    message: loc.importBookmarksDenied(browser.displayName),
                    success: false
                )
            }
            return BrowserImportOutcome(
                message: loc.importBookmarksEmpty(browser.displayName),
                success: false
            )
        }
        let folderName: String
        if browser == .chrome, let profile, profile.id != "Default" {
            folderName = "Chrome — \(profile.name)"
        } else {
            folderName = browser.displayName
        }
        bookmarks.importOrRefreshNodes(nodes, as: folderName)
        return BrowserImportOutcome(
            message: loc.importBookmarksDone(count: Self.bookmarkCount(nodes), browser: browser.displayName),
            success: true
        )
    }

    private func importOpenTabs(from browser: BrowserImportSource) async -> BrowserImportOutcome {
        let tabs = await Task.detached { OpenTabsImporter.readOpenTabs(only: [browser.displayName]) }.value
        guard !tabs.isEmpty else {
            return BrowserImportOutcome(
                message: loc.importOpenTabsEmpty(browser.displayName),
                success: false
            )
        }
        for tab in tabs {
            let title = tab.title.isEmpty
                ? (URL(string: tab.urlString)?.displayHost ?? tab.urlString)
                : tab.title
            let app = model.addApp(title: title, urlString: tab.urlString)
            icons.load(app)
        }
        return BrowserImportOutcome(
            message: loc.importOpenTabsDone(count: tabs.count, browser: browser.displayName),
            success: true
        )
    }

    private func importCookies(from profile: ChromeProfile) async -> BrowserImportOutcome {
        do {
            let source = try await Task.detached(priority: .userInitiated) {
                try ChromeCookieImporter.readCookies(from: profile)
            }.value
            let result = try CEFCookieWriter.write(source)
            return BrowserImportOutcome(
                message: loc.cookieImportResult(imported: result.imported, skipped: result.skipped),
                success: true
            )
        } catch {
            return BrowserImportOutcome(
                message: loc.cookieImportFailed(error.localizedDescription),
                success: false
            )
        }
    }

    private func importSession(from profile: ChromeProfile) async -> BrowserImportOutcome {
        do {
            let snapshot = try await Task.detached(priority: .userInitiated) {
                try ChromeSessionImporter.readSession(from: profile)
            }.value
            guard !snapshot.windows.isEmpty else {
                return BrowserImportOutcome(message: loc.importSessionEmpty, success: false)
            }
            let result = model.importChromeSession(snapshot)
            for id in result.importedTabIDs {
                if let app = model.tab(id) { icons.load(app) }
            }
            return BrowserImportOutcome(
                message: loc.importChromeSessionResult(
                    windows: result.importedWindowCount,
                    tabs: result.importedTabIDs.count,
                    groups: result.importedGroupCount
                ),
                success: true
            )
        } catch {
            return BrowserImportOutcome(
                message: loc.cookieImportFailed(error.localizedDescription),
                success: false
            )
        }
    }

    private static func bookmarkCount(_ nodes: [BookmarkNode]) -> Int {
        nodes.reduce(0) { total, node in
            total + (node.urlString == nil ? 0 : 1) + bookmarkCount(node.children ?? [])
        }
    }
}
