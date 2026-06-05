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
    let settings: Settings
    let icons: IconStore
    var onClose: () -> Void

    @State private var title: String
    @State private var alias: String
    @State private var urlString: String
    @State private var pendingIconURL: URL?
    @State private var pendingLibraryImage: NSImage?
    @State private var previewImage: NSImage?
    @State private var librarySlug = ""
    @State private var libraryLoading = false

    init(target: EditTarget, model: AppModel, settings: Settings, icons: IconStore, onClose: @escaping () -> Void) {
        self.target = target
        self.model = model
        self.settings = settings
        self.icons = icons
        self.onClose = onClose
        _title = State(initialValue: target.app?.title ?? "")
        _alias = State(initialValue: target.app?.alias ?? "")
        _urlString = State(initialValue: target.app?.urlString ?? "")
        _previewImage = State(initialValue: target.app.flatMap { icons.image(for: $0) })
    }

    private var loc: Localized { settings.strings }
    private var isEditing: Bool { target.app != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isEditing ? loc.editWebApp : loc.addWebApp)
                .font(.system(size: 17, weight: .bold, design: .rounded))

            HStack(spacing: 16) {
                iconWell
                VStack(alignment: .leading, spacing: 10) {
                    field(loc.title, text: $title, placeholder: "GitHub")
                    field(loc.address, text: $urlString, placeholder: "https://github.com")
                }
            }

            field(loc.alias, text: $alias, placeholder: loc.aliasHint)

            libraryRow

            HStack {
                Button(loc.cancel, role: .cancel) { onClose() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isEditing ? loc.save : loc.add) { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.primary)
                    .disabled(urlString.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 420)
    }

    private var iconWell: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.quaternary)
                if let previewImage {
                    Image(nsImage: previewImage)
                        .resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                } else {
                    Text(title.first.map { String($0).uppercased() } ?? "?")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 68, height: 68)

            Button(loc.chooseIcon) { chooseIcon() }
                .controlSize(.small)
            if pendingIconURL != nil || pendingLibraryImage != nil || (target.app?.usesCustomIcon ?? false) {
                Button(loc.useFavicon) { resetIcon() }
                    .controlSize(.small)
            }
        }
    }

    /// Pick a monochrome brand glyph from the simple-icons library by slug.
    private var libraryRow: some View {
        HStack(spacing: 8) {
            Text(loc.iconLibrary)
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            TextField(loc.iconLibraryHint, text: $librarySlug)
                .textFieldStyle(.roundedBorder)
                .onSubmit(fetchLibraryIcon)
            Button(action: fetchLibraryIcon) {
                if libraryLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "magnifyingglass")
                }
            }
            .disabled(libraryLoading)
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
        pendingLibraryImage = nil
        if let app = target.app { icons.clearCustomIcon(app) }
        previewImage = nil
    }

    private func fetchLibraryIcon() {
        var slug = librarySlug.trimmingCharacters(in: .whitespaces)
        if slug.isEmpty { slug = guessedSlug(); librarySlug = slug }
        guard !slug.isEmpty, !libraryLoading else { return }
        libraryLoading = true
        Task {
            let image = await IconStore.libraryIcon(slug: slug)
            libraryLoading = false
            if let image {
                previewImage = image
                pendingLibraryImage = image
                pendingIconURL = nil
            }
        }
    }

    /// Best-guess simple-icons slug from the URL host's main label, else title.
    private func guessedSlug() -> String {
        if let host = URL(string: resolvedURLString())?.displayHost {
            return (host.split(separator: ".").first.map(String.init) ?? host).lowercased()
        }
        return title.lowercased().replacingOccurrences(of: " ", with: "")
    }

    /// The URL with an `https://` scheme prepended when the user omitted one.
    private func resolvedURLString() -> String {
        let raw = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.lowercased().hasPrefix("http") ? raw : "https://" + raw
    }

    private func save() {
        let resolved = resolvedURLString()
        let resolvedTitle = title.trimmingCharacters(in: .whitespaces).isEmpty
            ? (URL(string: resolved)?.displayHost ?? resolved)
            : title
        let resolvedAlias = alias.trimmingCharacters(in: .whitespaces)

        var app: WebApp
        if let existing = target.app {
            app = existing
            let urlChanged = existing.urlString != resolved
            app.title = resolvedTitle
            app.alias = resolvedAlias
            app.urlString = resolved
            if let libImage = pendingLibraryImage {
                app.usesCustomIcon = icons.setCustomIcon(app, image: libImage)
            } else if let iconURL = pendingIconURL {
                app.usesCustomIcon = icons.setCustomIcon(app, from: iconURL)
            } else if urlChanged && !app.usesCustomIcon {
                icons.refreshFavicon(app)
            }
            model.update(app)
        } else {
            app = model.addApp(title: resolvedTitle, urlString: resolved, alias: resolvedAlias)
            if let libImage = pendingLibraryImage, icons.setCustomIcon(app, image: libImage) {
                app.usesCustomIcon = true
                model.update(app)
            } else if let iconURL = pendingIconURL, icons.setCustomIcon(app, from: iconURL) {
                app.usesCustomIcon = true
                model.update(app)
            } else {
                icons.load(app)
            }
        }
        onClose()
    }
}
