import SwiftUI

enum BrowserImportMode: Hashable {
    case tabs
    case cookies
}

/// Imports open tabs or Chrome cookies through one explicit, user-driven entry.
/// Browser access never happens on appearance: Apple Events and keychain access
/// are only requested after the corresponding import button is pressed.
struct ImportTabsSheet: View {
    let model: AppModel
    let settings: Settings
    let icons: IconStore
    var onClose: () -> Void

    @State private var mode: BrowserImportMode
    @State private var tabs: [ImportedTab] = []
    @State private var selected: Set<ImportedTab.ID> = []
    @State private var scanned = false
    @State private var scanning = false
    @State private var profiles: [ChromeProfile] = []
    @State private var selectedProfileID = ""
    @State private var cookieImporting = false
    @State private var cookieMessage: String?
    @State private var cookieImportSucceeded = false
    @State private var showCookieConfirmation = false

    private var loc: Localized { settings.strings }

    init(
        model: AppModel,
        settings: Settings,
        icons: IconStore,
        initialMode: BrowserImportMode = .tabs,
        onClose: @escaping () -> Void
    ) {
        self.model = model
        self.settings = settings
        self.icons = icons
        self.onClose = onClose
        _mode = State(initialValue: initialMode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(loc.importTitle)
                .font(.system(size: 17, weight: .bold, design: .rounded))

            Picker("", selection: $mode) {
                Text(loc.importTabsMode).tag(BrowserImportMode.tabs)
                Text(loc.importCookiesMode).tag(BrowserImportMode.cookies)
            }
            .pickerStyle(.segmented)

            Group {
                switch mode {
                case .tabs:
                    if scanning {
                        scanningState
                    } else if !scanned {
                        scanPrompt
                    } else if tabs.isEmpty {
                        emptyState
                    } else {
                        tabList
                    }
                case .cookies:
                    cookieImportPane
                }
            }

            HStack {
                Button(loc.cancel, role: .cancel) { onClose() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if mode == .tabs, scanned, !tabs.isEmpty {
                    Button(loc.selectAll) { toggleAll() }
                        .controlSize(.small)
                    Button(loc.importAdd(selected.count)) { addSelected() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .tint(.primary)
                        .disabled(selected.isEmpty)
                } else if mode == .cookies {
                    Button(loc.importChromeCookies) {
                        showCookieConfirmation = true
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.primary)
                    .disabled(
                        cookieImporting
                        || selectedProfile?.cookieDatabaseURL == nil
                    )
                }
            }
        }
        .padding(22)
        .frame(width: 480, height: 500)
        .onAppear { reloadProfiles() }
        .alert(loc.cookieConfirmTitle, isPresented: $showCookieConfirmation) {
            Button(loc.cancel, role: .cancel) {}
            Button(loc.importChromeCookies) { importCookies() }
        } message: {
            Text(loc.cookieConfirmMessage(selectedProfile?.name ?? "Chrome"))
        }
    }

    private var scanPrompt: some View {
        VStack(spacing: 12) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
            Text(loc.importScanHint)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(loc.importScan) { scan() }
                .buttonStyle(.borderedProminent).tint(.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scanningState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(loc.importScanning)
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
            Text(loc.importEmpty)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(loc.importRescan) { scan() }
                Button(loc.openAutomationSettings) { openAutomationSettings() }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var tabList: some View {
        List {
            ForEach(browsers, id: \.self) { browser in
                Section(browser) {
                    ForEach(tabs.filter { $0.browser == browser }) { tab in
                        row(tab)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var cookieImportPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            if profiles.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(loc.chromeProfilesEmpty)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(loc.reloadChromeProfiles) { reloadProfiles() }
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker(loc.chromeProfile, selection: $selectedProfileID) {
                            ForEach(profiles) { profile in
                                Text("\(profile.name) — \(profile.id)")
                                    .tag(profile.id)
                            }
                        }

                        if selectedProfile?.cookieDatabaseURL == nil {
                            Label(loc.chromeCookieDatabaseMissing, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        } else {
                            Label(loc.chromeCookieDatabaseReady, systemImage: "checkmark.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                    .padding(4)
                } label: {
                    Label(loc.chromeProfile, systemImage: "person.crop.circle")
                }

                Label(loc.cookiePrivacyHint, systemImage: "lock.shield")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if cookieImporting {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(loc.importingChromeCookies)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else if let cookieMessage {
                    Label(
                        cookieMessage,
                        systemImage: cookieImportSucceeded
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(cookieImportSucceeded ? .green : .red)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ tab: ImportedTab) -> some View {
        Button { toggle(tab.id) } label: {
            HStack(spacing: 10) {
                Image(systemName: selected.contains(tab.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected.contains(tab.id) ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                VStack(alignment: .leading, spacing: 1) {
                    Text(tab.title.isEmpty ? tab.urlString : tab.title)
                        .font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(tab.urlString)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Distinct browsers in discovery order (preserves grouping).
    private var browsers: [String] {
        var seen: [String] = []
        for tab in tabs where !seen.contains(tab.browser) { seen.append(tab.browser) }
        return seen
    }

    private var selectedProfile: ChromeProfile? {
        profiles.first { $0.id == selectedProfileID }
    }

    private func scan() {
        scanning = true
        Task {
            // Run AppleScript off the main thread so the Automation consent
            // prompt can draw (a synchronous call on main would block it).
            let found = await Task.detached { OpenTabsImporter.readOpenTabs() }.value
            tabs = found
            selected = Set(found.map(\.id)) // default: everything selected
            scanned = true
            scanning = false
        }
    }

    private func openAutomationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
        NSWorkspace.shared.open(url)
    }

    private func reloadProfiles() {
        profiles = ChromeCookieImporter.discoverProfiles()
        if !profiles.contains(where: { $0.id == selectedProfileID }) {
            selectedProfileID = profiles.first?.id ?? ""
        }
        cookieMessage = nil
    }

    private func importCookies() {
        guard let profile = selectedProfile else { return }
        cookieImporting = true
        cookieMessage = nil
        cookieImportSucceeded = false

        Task {
            do {
                let source = try await Task.detached(priority: .userInitiated) {
                    try ChromeCookieImporter.readCookies(from: profile)
                }.value
                let result = try CEFCookieWriter.write(source)
                cookieMessage = loc.cookieImportResult(
                    imported: result.imported,
                    skipped: result.skipped
                )
                cookieImportSucceeded = true
            } catch {
                cookieMessage = loc.cookieImportFailed(error.localizedDescription)
            }
            cookieImporting = false
        }
    }

    private func toggle(_ id: ImportedTab.ID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func toggleAll() {
        selected = selected.count == tabs.count ? [] : Set(tabs.map(\.id))
    }

    private func addSelected() {
        for tab in tabs where selected.contains(tab.id) {
            let title = tab.title.isEmpty ? (URL(string: tab.urlString)?.displayHost ?? tab.urlString) : tab.title
            let app = model.addApp(title: title, urlString: tab.urlString)
            icons.load(app)
        }
        onClose()
    }
}
