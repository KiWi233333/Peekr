import SwiftUI

enum PreferenceEffect {
    case layout
    case hotKey
    case launchAtLogin
    case language
    case bookmarkSync
    case webEngine
}

struct PreferencesView: View {
    let model: AppModel
    @Bindable var settings: Settings
    let icons: IconStore
    var onApply: (PreferenceEffect) -> Void
    var onImportCookies: () -> Void
    var onImportBookmarks: () -> Void

    @State private var persistTask: Task<Void, Never>?

    private var loc: Localized { settings.strings }

    var body: some View {
        TabView {
            GeneralTab(settings: settings)
                .tabItem { Label(loc.general, systemImage: "gearshape") }
            BrowserTab(
                settings: settings,
                onImportCookies: onImportCookies,
                onImportBookmarks: onImportBookmarks
            )
            .tabItem { Label(loc.browser, systemImage: "globe") }
            AppsTab(model: model, settings: settings, icons: icons)
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
        .onChange(of: settings.webEngine) { _, _ in onApply(.webEngine) }
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
            }
        }
        .formStyle(.grouped)
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
    var onImportCookies: () -> Void
    var onImportBookmarks: () -> Void

    @State private var pendingEngine: WebEngineKind?

    private var loc: Localized { settings.strings }
    private var engineSelection: Binding<WebEngineKind> {
        Binding(
            get: { settings.webEngine },
            set: { newValue in
                guard newValue != settings.webEngine else { return }
                pendingEngine = newValue
            }
        )
    }
    private var showsEngineConfirmation: Binding<Bool> {
        Binding(
            get: { pendingEngine != nil },
            set: { if !$0 { pendingEngine = nil } }
        )
    }

    var body: some View {
        Form {
            Section(loc.webEngineSection) {
                Picker("", selection: engineSelection) {
                    ForEach(WebEngineKind.allCases) { kind in
                        Text(loc.engineName(kind)).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)

                Text(loc.engineDetail(settings.webEngine))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(loc.webEngineHint)
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
                    Label(loc.importChromeCookies, systemImage: "person.badge.key")
                    Spacer()
                    Button(loc.importAction, action: onImportCookies)
                }
                HStack {
                    Label(loc.importChromeBookmarks, systemImage: "book.closed")
                    Spacer()
                    Button(loc.importAction, action: onImportBookmarks)
                }
            }

            Section(loc.bookmarks) {
                Picker(loc.bookmarkSync, selection: $settings.bookmarkSync) {
                    ForEach(BookmarkSyncInterval.allCases) { interval in
                        Text(loc.syncIntervalName(interval)).tag(interval)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .alert(
            loc.switchEngineTitle,
            isPresented: showsEngineConfirmation,
            presenting: pendingEngine
        ) { engine in
            Button(loc.cancel, role: .cancel) {
                pendingEngine = nil
            }
            Button(loc.switchEngine) {
                settings.webEngine = engine
                pendingEngine = nil
            }
        } message: { engine in
            Text(loc.switchEngineMessage(loc.engineName(engine)))
        }
    }
}

// MARK: - Apps

private struct AppsTab: View {
    let model: AppModel
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
            ImportTabsSheet(model: model, settings: settings, icons: icons) { importing = false }
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
