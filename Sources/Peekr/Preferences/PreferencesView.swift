import SwiftUI

struct PreferencesView: View {
    let model: AppModel
    @Bindable var settings: Settings
    let icons: IconStore
    var onApply: () -> Void

    var body: some View {
        TabView {
            GeneralTab(settings: settings, onApply: onApply)
                .tabItem { Label("General", systemImage: "gearshape") }
            AppsTab(model: model, icons: icons)
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 540)
        .onChange(of: settings.snapshot) { _, _ in
            settings.persist()
            onApply()
        }
        .onChange(of: settings.launchAtLogin) { _, enabled in
            LaunchAtLogin.set(enabled)
        }
    }
}

// MARK: - General

private struct GeneralTab: View {
    @Bindable var settings: Settings
    var onApply: () -> Void

    var body: some View {
        Form {
            Section("Docking") {
                HStack(alignment: .top, spacing: 20) {
                    AnchorGrid(selection: $settings.anchor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(settings.anchor.label)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                        Text("Hover this edge or corner — or drag the panel by its grip and release near any edge/corner to re-snap.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Toggle("Follow cursor across displays", isOn: $settings.followCursor)
            }

            Section("Panel") {
                slider("Width", value: $settings.panelWidth, range: 320...760, unit: "pt")
                slider("Hover delay", value: $settings.hoverDelay, range: 0...0.6, unit: "s", decimals: 2)
                slider("Edge sensitivity", value: $settings.edgeThreshold, range: 1...14, unit: "px")
                Toggle("Auto-hide when the cursor leaves", isOn: $settings.autoHide)
            }

            Section("Shortcut & Startup") {
                HStack {
                    Text("Toggle shortcut")
                    Spacer()
                    HotKeyRecorder(settings: settings, onApply: onApply)
                }
                Toggle("Launch Peekr at login", isOn: $settings.launchAtLogin)
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

/// 3×3 grid of dock positions (centre is inert).
private struct AnchorGrid: View {
    @Binding var selection: PanelAnchor

    private let layout: [[PanelAnchor?]] = [
        [.topLeft, .top, .topRight],
        [.left, nil, .right],
        [.bottomLeft, .bottom, .bottomRight]
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
                withAnimation(.snappy) { selection = anchor }
            } label: {
                Image(systemName: anchor.symbol)
                    .font(.system(size: 15))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(selection == anchor ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(.secondary))
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selection == anchor ? Theme.accent.opacity(0.18) : .clear)
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
    var onApply: () -> Void

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "Press keys…" : settings.hotKey.displayString)
                .font(.system(.body, design: .rounded).weight(.medium))
                .frame(minWidth: 92)
                .padding(.vertical, 3)
        }
        .buttonStyle(.bordered)
        .tint(recording ? Theme.accentDeep : nil)
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let mods = carbonModifiers(from: event.modifierFlags)
            guard mods != 0 else { return event } // require at least one modifier
            settings.hotKey = HotKeyConfig(keyCode: UInt32(event.keyCode), modifiers: mods)
            settings.persist()
            onApply()
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

// MARK: - Apps

private struct AppsTab: View {
    let model: AppModel
    let icons: IconStore
    @State private var editTarget: EditTarget?

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(model.apps) { app in
                    HStack(spacing: 12) {
                        AppTile(app: app, selected: false, icon: icons.image(for: app))
                            .frame(width: 34, height: 34)
                            .scaleEffect(0.74)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.title).font(.system(size: 13, weight: .medium))
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
                .onMove { from, to in
                    model.moveApps(fromOffsets: from, toOffset: to)
                }
                .onDelete { offsets in
                    offsets.map { model.apps[$0].id }.forEach { model.removeApp($0) }
                }
            }

            HStack {
                Button { editTarget = EditTarget(app: nil) } label: {
                    Label("Add Web App", systemImage: "plus")
                }
                Spacer()
                Text("\(model.apps.count) apps")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .sheet(item: $editTarget) { target in
            EditAppSheet(target: target, model: model, icons: icons) { editTarget = nil }
        }
    }
}

// MARK: - About

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "sidebar.trailing")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(Theme.accentGradient)
            Text("Peekr")
                .font(.system(size: 26, weight: .bold, design: .rounded))
            Text("A liquid-glass slide-over browser for macOS.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Version 0.2.0")
                .font(.caption).foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
