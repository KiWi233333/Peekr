import SwiftUI
import UniformTypeIdentifiers

/// Identifies what the add/edit sheet is editing. A nil `app` means "add new".
struct EditTarget: Identifiable {
    let id = UUID()
    let app: WebApp?
}

/// Add or edit a web app: title, URL, and a custom icon override.
struct EditAppSheet: View {
    let target: EditTarget
    let model: AppModel
    let icons: IconStore
    var onClose: () -> Void

    @State private var title: String
    @State private var urlString: String
    @State private var pendingIconURL: URL?
    @State private var previewImage: NSImage?

    init(target: EditTarget, model: AppModel, icons: IconStore, onClose: @escaping () -> Void) {
        self.target = target
        self.model = model
        self.icons = icons
        self.onClose = onClose
        _title = State(initialValue: target.app?.title ?? "")
        _urlString = State(initialValue: target.app?.urlString ?? "")
        _previewImage = State(initialValue: target.app.flatMap { icons.image(for: $0) })
    }

    private var isEditing: Bool { target.app != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isEditing ? "Edit Web App" : "Add Web App")
                .font(.system(size: 17, weight: .bold, design: .rounded))

            HStack(spacing: 16) {
                iconWell
                VStack(alignment: .leading, spacing: 10) {
                    field("Title", text: $title, placeholder: "GitHub")
                    field("Address", text: $urlString, placeholder: "https://github.com")
                }
            }

            HStack {
                Button("Cancel", role: .cancel) { onClose() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isEditing ? "Save" : "Add") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accentDeep)
                    .disabled(urlString.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 420)
    }

    private var iconWell: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.quaternary)
                if let previewImage {
                    Image(nsImage: previewImage)
                        .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .frame(width: 40, height: 40)
                } else {
                    Text(title.first.map { String($0).uppercased() } ?? "?")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 68, height: 68)

            Button("Choose…") { chooseIcon() }
                .controlSize(.small)
            if pendingIconURL != nil || (target.app?.usesCustomIcon ?? false) {
                Button("Use favicon") { resetIcon() }
                    .controlSize(.small)
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Actions

    private func chooseIcon() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            pendingIconURL = url
            previewImage = NSImage(contentsOf: url)
        }
    }

    private func resetIcon() {
        pendingIconURL = nil
        if let app = target.app {
            icons.clearCustomIcon(app)
            previewImage = nil
        }
    }

    private func save() {
        var resolved = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !resolved.lowercased().hasPrefix("http") { resolved = "https://" + resolved }
        let resolvedTitle = title.trimmingCharacters(in: .whitespaces).isEmpty
            ? (URL(string: resolved)?.host?.replacingOccurrences(of: "www.", with: "") ?? resolved)
            : title

        var app: WebApp
        if let existing = target.app {
            app = existing
            let urlChanged = existing.urlString != resolved
            app.title = resolvedTitle
            app.urlString = resolved
            if let iconURL = pendingIconURL {
                app.usesCustomIcon = icons.setCustomIcon(app, from: iconURL)
            } else if urlChanged && !app.usesCustomIcon {
                icons.refreshFavicon(app)
            }
            model.update(app)
        } else {
            app = model.addApp(title: resolvedTitle, urlString: resolved)
            if let iconURL = pendingIconURL, icons.setCustomIcon(app, from: iconURL) {
                app.usesCustomIcon = true
                model.update(app)
            } else {
                icons.load(app)
            }
        }
        onClose()
    }
}
