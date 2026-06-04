import SwiftUI

/// Lists the tabs currently open in the user's running browsers and lets the
/// user pick which to add as Peekr web apps. Scanning is an explicit button
/// press (not on-appear) so the system Automation consent prompt fires in a
/// clean user-gesture context.
struct ImportTabsSheet: View {
    let model: AppModel
    let settings: Settings
    let icons: IconStore
    var onClose: () -> Void

    @State private var tabs: [ImportedTab] = []
    @State private var selected: Set<ImportedTab.ID> = []
    @State private var scanned = false
    @State private var scanning = false

    private var loc: Localized { settings.strings }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(loc.importTitle)
                .font(.system(size: 17, weight: .bold, design: .rounded))

            if scanning {
                scanningState
            } else if !scanned {
                scanPrompt
            } else if tabs.isEmpty {
                emptyState
            } else {
                tabList
            }

            HStack {
                Button(loc.cancel, role: .cancel) { onClose() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if scanned && !tabs.isEmpty {
                    Button(loc.selectAll) { toggleAll() }
                        .controlSize(.small)
                    Button(loc.importAdd(selected.count)) { addSelected() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .tint(.primary)
                        .disabled(selected.isEmpty)
                }
            }
        }
        .padding(22)
        .frame(width: 460, height: 460)
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
