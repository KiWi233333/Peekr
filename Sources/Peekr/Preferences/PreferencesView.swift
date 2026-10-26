import SwiftUI

enum PreferenceEffect {
    case layout
    case hotKey
    case launchAtLogin
    case language
    case bookmarkSync
    case browser
}

struct PreferencesView: View {
    let model: AppModel
    let bookmarks: BookmarksModel
    @Bindable var settings: Settings
    let icons: IconStore
    var onApply: (PreferenceEffect) -> Void
    var onImportBrowserData: () -> Void
    var onInstallAgentCLI: () -> Void

    @State private var persistTask: Task<Void, Never>?

    private var loc: Localized { settings.strings }

    var body: some View {
        TabView {
            GeneralTab(settings: settings)
                .tabItem { Label(loc.general, systemImage: "gearshape") }
            BrowserTab(
                settings: settings,
                onImportBrowserData: onImportBrowserData,
                onInstallAgentCLI: onInstallAgentCLI
            )
            .tabItem { Label(loc.browser, systemImage: "globe") }
            PrivacyTab(settings: settings)
                .tabItem { Label(loc.privacy, systemImage: "hand.raised") }
            AppsTab(model: model, bookmarks: bookmarks, settings: settings, icons: icons)
                .tabItem { Label(loc.apps, systemImage: "square.grid.2x2") }
            AboutTab(settings: settings)
                .tabItem { Label(loc.about, systemImage: "info.circle") }
        }
        .frame(width: 500, height: 560)
        .onChange(of: settings.snapshot) { _, _ in
            schedulePersist()
        }
        .onChange(of: settings.anchor) { _, _ in onApply(.layout) }
        .onChange(of: settings.panelWidth) { _, _ in onApply(.layout) }
        .onChange(of: settings.panelHeight) { _, _ in onApply(.layout) }
        .onChange(of: settings.hotKey) { _, _ in onApply(.hotKey) }
        .onChange(of: settings.launchAtLogin) { _, _ in
            onApply(.launchAtLogin)
        }
        .onChange(of: settings.language) { _, _ in onApply(.language) }
        .onChange(of: settings.bookmarkSync) { _, _ in onApply(.bookmarkSync) }
        .onChange(of: settings.defaultZoom) { _, _ in onApply(.browser) }
        .onChange(of: settings.historyRetentionDays) { _, _ in onApply(.browser) }
        .onDisappear {
            persistTask?.cancel()
            settings.persist()
        }
    }

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            settings.persist()
        }
    }
}

// MARK: - General

private struct GeneralTab: View {
    @Bindable var settings: Settings

    private var loc: Localized { settings.strings }
    private var defaultSize: NSSize { PanelGeometry.defaultSize(for: NSScreen.main ?? NSScreen.screens[0]) }

    private var widthBinding: Binding<Double> {
        Binding(get: { settings.panelWidth > 0 ? settings.panelWidth : Double(defaultSize.width) },
                set: { settings.panelWidth = $0 })
    }
    private var heightBinding: Binding<Double> {
        Binding(get: { settings.panelHeight > 0 ? settings.panelHeight : Double(defaultSize.height) },
                set: { settings.panelHeight = $0 })
    }
    private var autoHideBinding: Binding<AutoHidePolicy> {
        Binding(
            get: { settings.autoHidePolicy },
            set: { settings.autoHidePolicy = $0 }
        )
    }

    var body: some View {
        Form {
            Section(loc.docking) {
                HStack(alignment: .top, spacing: 20) {
                    AnchorGrid(selection: $settings.anchor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(loc.anchorName(settings.anchor))
                            .font(.system(size: 13, weight: .semibold))
                        Text(loc.dockingHint)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Toggle(loc.followCursor, isOn: $settings.followCursor)
            }

            Section(loc.panel) {
                slider(loc.defaultWidth, value: widthBinding, range: Double(PanelGeometry.minSize.width)...1400, unit: "pt")
                slider(loc.defaultHeight, value: heightBinding, range: Double(PanelGeometry.minSize.height)...1600, unit: "pt")
                HStack {
                    Text(loc.panelSizeHint)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(loc.defaultSize) {
                        settings.panelWidth = 0
                        settings.panelHeight = 0
                    }
                    .controlSize(.small)
                }
                slider(loc.hoverDelay, value: $settings.hoverDelay, range: 0...0.6, unit: "s", decimals: 2)
                slider(loc.edgeSensitivity, value: $settings.edgeThreshold, range: 1...14, unit: "pt")
            }

            Section(loc.panelBehavior) {
                Picker(loc.autoHide, selection: autoHideBinding) {
                    ForEach(AutoHidePolicy.allCases) { policy in
                        Text(loc.autoHidePolicyName(policy)).tag(policy)
                    }
                }
                .pickerStyle(.menu)
            }

            Section(loc.shortcutStartup) {
                HStack {
                    Text(loc.toggleShortcut)
                    Spacer()
                    HotKeyRecorder(settings: settings)
                }
                Toggle(loc.launchAtLogin, isOn: $settings.launchAtLogin)
                Picker(loc.language, selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.nativeName).tag(lang)
                    }
                }
                .pickerStyle(.menu)
                Picker(loc.startup, selection: $settings.startupBehavior) {
                    ForEach(StartupBehavior.allCases) { behavior in
                        Text(startupName(behavior)).tag(behavior)
                    }
                }
                .pickerStyle(.menu)
                if settings.startupBehavior == .homePage {
                    TextField(loc.homePage, text: $settings.homePage, prompt: Text(loc.homePage))
                        .textFieldStyle(.roundedBorder)
                    Text(loc.omniboxPlaceholder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func startupName(_ behavior: StartupBehavior) -> String {
        switch behavior {
        case .newTab: return loc.startupNewTab
        case .continueWhereLeftOff: return loc.startupContinue
        case .homePage: return loc.startupHomePage
        }
    }

    private func slider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String, decimals: Int = 0) -> some View {
        HStack {
            Text(label)
            Slider(value: value, in: range)
            Text(String(format: "%.\(decimals)f", value.wrappedValue) + unit)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
    }
}

/// 3×3 grid of dock positions (centre is inert). Monochrome selection.
private struct AnchorGrid: View {
    @Binding var selection: PanelAnchor

    private let layout: [[PanelAnchor?]] = [
        [.topLeft, nil, .topRight],
        [.left, nil, .right],
        [.bottomLeft, nil, .bottomRight]
    ]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { col in
                        cell(layout[row][col])
                    }
                }
            }
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func cell(_ anchor: PanelAnchor?) -> some View {
        if let anchor {
            Button {
                selection = anchor
            } label: {
                Image(systemName: anchor.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(selection == anchor ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selection == anchor ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color.clear))
                    )
            }
            .buttonStyle(.plain)
        } else {
            Circle().fill(.tertiary).frame(width: 6, height: 6).frame(width: 34, height: 34)
        }
    }
}

/// Captures the next key-press as the global shortcut.
private struct HotKeyRecorder: View {
    @Bindable var settings: Settings

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? settings.strings.pressKeys : settings.hotKey.displayString)
                .font(.system(.body, design: .rounded).weight(.medium))
                .frame(minWidth: 92)
                .padding(.vertical, 3)
        }
        .buttonStyle(.bordered)
        .tint(recording ? .primary : nil)
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let mods = carbonModifiers(from: event.modifierFlags)
            guard mods != 0 else { return event }
            settings.hotKey = HotKeyConfig(keyCode: UInt32(event.keyCode), modifiers: mods)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - Browser

private struct BrowserTab: View {
    @Bindable var settings: Settings
    var onImportBrowserData: () -> Void
    var onInstallAgentCLI: () -> Void

    private var loc: Localized { settings.strings }

    var body: some View {
        Form {
            Section(loc.searchEngineSection) {
                Picker(loc.defaultSearchEngine, selection: $settings.searchEngine) {
                    ForEach(SearchEngine.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .pickerStyle(.menu)

                Text(loc.searchEngineHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(loc.chromeDataSection) {
                Text(loc.chromeDataHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Label(loc.importOpenTabs, systemImage: "square.and.arrow.down.on.square")
                    Spacer()
                    Button(loc.importAction, action: onImportBrowserData)
                }
            }

            Section(loc.agentAccessSection) {
                Toggle(isOn: $settings.agentAccessEnabled) {
                    Text(loc.agentAccessToggle)
                }

                if settings.agentAccessEnabled {
                    HStack {
                        Text(loc.agentAccessPort)
                        Spacer()
                        TextField(
                            "",
                            value: $settings.agentDebugPort,
                            format: .number.grouping(.never)
                        )
                        .textFieldStyle(.roundedBorder)
                        .focusEffectDisabled()
                        .frame(width: 90)
                        .multilineTextAlignment(.trailing)
                    }
                    Text(loc.agentAccessRelaunchHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // Where agents look for the CDP/control endpoints. Shows
                    // the path the running app actually uses (smoke roots
                    // included), so it is always the actionable one.
                    HStack(alignment: .top) {
                        Text(loc.agentDiscoveryPath)
                        Spacer()
                        Text(AgentDiscovery.fileURL.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .frame(maxWidth: 280, alignment: .trailing)
                            .help(AgentDiscovery.fileURL.path)
                    }
                    HStack {
                        Label(loc.agentAccessInstallCLI, systemImage: "terminal")
                        Spacer()
                        Button(loc.installAction, action: onInstallAgentCLI)
                    }
                }

                Text(loc.agentAccessHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(loc.bookmarks) {
                Picker(loc.bookmarkSync, selection: $settings.bookmarkSync) {
                    ForEach(BookmarkSyncInterval.allCases) { interval in
                        Text(loc.syncIntervalName(interval)).tag(interval)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Privacy

private struct PrivacyTab: View {
    @Bindable var settings: Settings

    private var loc: Localized { settings.strings }

    var body: some View {
        Form {
            Section(loc.privacy) {
                Toggle(isOn: $settings.rememberPermissions) {
                    Text(loc.rememberPermissions)
                }
                Text(loc.rememberPermissionsHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(isOn: $settings.blockPopups) {
                    Text(loc.blockPopups)
                }
                Text(loc.blockPopupsHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(loc.historyRetention) {
                Picker(loc.historyRetention, selection: $settings.historyRetentionDays) {
                    ForEach(Self.retentionOptions, id: \.self) { days in
                        Text(loc.historyRetentionName(days)).tag(days)
                    }
                }
                .pickerStyle(.menu)
            }

            Section(loc.defaultZoom) {
                Picker(loc.defaultZoom, selection: $settings.defaultZoom) {
                    ForEach(Self.zoomOptions, id: \.self) { level in
                        Text(loc.zoomLevel(level)).tag(level)
                    }
                }
                .pickerStyle(.menu)
                Text(loc.defaultZoomHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private static let retentionOptions = [0, 30, 90, 365]
    private static let zoomOptions: [Double] = [-2, -1, 0, 1, 2, 3]
}

// MARK: - Apps

private struct AppsTab: View {
    let model: AppModel
    let bookmarks: BookmarksModel
    let settings: Settings
    let icons: IconStore
    @State private var editTarget: EditTarget?
    @State private var importing = false

    private var loc: Localized { settings.strings }

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(model.apps) { app in
                    HStack(spacing: 12) {
                        AppTile(app: app, selected: false, icon: icons.image(for: app))
                            .frame(width: 34, height: 34)
                            .scaleEffect(0.74)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.displayName).font(.system(size: 13, weight: .medium))
                            Text(app.urlString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button { editTarget = EditTarget(app: app) } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 2)
                }
                .onMove { from, to in model.moveApps(fromOffsets: from, toOffset: to) }
                .onDelete { offsets in
                    offsets.map { model.apps[$0].id }.forEach { model.removeApp($0) }
                }
            }

            HStack {
                Button { editTarget = EditTarget(app: nil) } label: {
                    Label(loc.addWebApp, systemImage: "plus")
                }
                Button { importing = true } label: {
                    Label(loc.importOpenTabs, systemImage: "square.and.arrow.down.on.square")
                }
                Spacer()
                Text(loc.appsCount(model.apps.count))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .sheet(item: $editTarget) { target in
            EditAppSheet(target: target, model: model, settings: settings, icons: icons) { editTarget = nil }
        }
        .sheet(isPresented: $importing) {
            BrowserImportSheet(
                model: model,
                bookmarks: bookmarks,
                settings: settings,
                icons: icons
            ) { importing = false }
        }
    }
}

// MARK: - About

private struct AboutTab: View {
    let settings: Settings

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0"
    }

    /// The real colored app icon (AppIcon.icns) in `.app` mode; the fallback
    /// keeps previews and tests usable when no bundle icon is available.
    private var appIcon: NSImage {
        let icon = NSApplication.shared.applicationIconImage
        if let icon, icon.isValid, icon.size.width > 0 { return icon }
        return BrandGlyph.image(size: 84)
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 84, height: 84)
            Text("Peekr")
                .font(.system(size: 26, weight: .bold, design: .rounded))
            Text(settings.strings.tagline)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Version \(appVersion)")
                .font(.caption).foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
