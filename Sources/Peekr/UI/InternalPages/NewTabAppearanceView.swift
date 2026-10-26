import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NewTabAppearanceView: View {
    let settings: Settings
    @Binding var isPresented: Bool

    @State private var wallpaperExpanded = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum WallpaperSource: String {
        case builtIn
        case custom
    }

    private enum Layout {
        static let width: CGFloat = 404
        static let maxHeight: CGFloat = 600
        static let gridSpacing: CGFloat = 8
    }

    private let wallpaperColumns = Array(
        repeating: GridItem(.flexible(), spacing: Layout.gridSpacing),
        count: 3
    )

    private var loc: Localized { settings.strings }

    private var wallpaperSource: Binding<WallpaperSource> {
        Binding(
            get: { settings.newTabUsesCustomWallpaper ? .custom : .builtIn },
            set: { source in
                settings.newTabUsesCustomWallpaper = source == .custom
                settings.persist()
            }
        )
    }

    private var customImage: NSImage? {
        guard !settings.newTabCustomWallpaperPath.isEmpty else { return nil }
        return NSImage(contentsOfFile: settings.newTabCustomWallpaperPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.hairline)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    wallpaperSection
                    displaySection
                }
                .padding(12)
            }
            .scrollIndicators(.automatic)
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(width: Layout.width)
        .frame(maxHeight: Layout.maxHeight)
        .liquidGlass(
            in: RoundedRectangle(cornerRadius: Theme.popoverCorner, style: .continuous),
            tint: .primary.opacity(0.025),
            interactive: true
        )
        .onExitCommand { isPresented = false }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(loc.newTabAppearanceTitle)
                .font(.system(size: 15, weight: .semibold))
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 8)

            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(IconButtonStyle())
            .help(loc.close)
            .accessibilityLabel(loc.close)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: Theme.popoverHeaderHeight)
    }

    private var wallpaperSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button(action: toggleWallpaperExpanded) {
                    HStack(spacing: 7) {
                        Image(systemName: wallpaperExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 12)
                            .contentTransition(.symbolEffect(.replace))
                        Text(loc.newTabWallpaper)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(wallpaperExpanded ? loc.collapseGroup : loc.expandGroup)

                Spacer(minLength: 8)

                Toggle(loc.newTabWallpaper, isOn: binding(\.newTabWallpaperEnabled))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            if wallpaperExpanded {
                wallpaperContent
                    .transition(.opacity)
            }
        }
        .padding(12)
        .background(
            .primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: Theme.popoverRowCorner, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Theme.popoverRowCorner, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.8)
        }
        .animation(reduceMotion ? nil : Motion.iconSwap, value: wallpaperExpanded)
    }

    @ViewBuilder
    private var wallpaperContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(loc.newTabWallpaper, selection: wallpaperSource) {
                Text(loc.newTabWallpaperBuiltIn).tag(WallpaperSource.builtIn)
                Text(loc.newTabWallpaperLocal).tag(WallpaperSource.custom)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if settings.newTabUsesCustomWallpaper {
                customWallpaperContent
            } else {
                builtInWallpaperGrid
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(loc.newTabWallpaperOverlay)
                        .font(.system(size: 12))
                    Spacer(minLength: 8)
                    Text("\(Int((settings.newTabWallpaperOverlay * 100).rounded()))%")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Slider(value: binding(\.newTabWallpaperOverlay), in: 0...0.85) {
                    Text(loc.newTabWallpaperOverlay)
                }
                .controlSize(.small)
            }
        }
    }

    private var builtInWallpaperGrid: some View {
        LazyVGrid(columns: wallpaperColumns, spacing: Layout.gridSpacing) {
            ForEach(NewTabWallpaperCatalog.items) { wallpaper in
                NewTabWallpaperThumbnail(
                    wallpaper: wallpaper,
                    selected: wallpaper.id == settings.newTabWallpaperID,
                    action: { selectBuiltInWallpaper(wallpaper) }
                )
            }
        }
    }

    @ViewBuilder
    private var customWallpaperContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let customImage {
                Image(nsImage: customImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 132)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.controlCorner, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.controlCorner, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 0.8)
                    }
            } else {
                VStack(spacing: 7) {
                    Image(systemName: "photo")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(loc.newTabCustomWallpaperEmpty)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 92)
                .background(
                    .primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: Theme.controlCorner, style: .continuous)
                )
            }

            HStack(spacing: 8) {
                Button(loc.newTabChooseWallpaper, action: chooseCustomWallpaper)
                    .controlSize(.small)

                if !settings.newTabCustomWallpaperPath.isEmpty {
                    Button(loc.newTabRemoveWallpaper, role: .destructive, action: removeCustomWallpaper)
                        .controlSize(.small)
                }

                Spacer(minLength: 0)
            }
        }
    }

    private var displaySection: some View {
        VStack(spacing: 0) {
            Toggle(loc.newTabShowBookmarks, isOn: binding(\.newTabShowBookmarks))
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(.vertical, 9)

            Divider().overlay(Theme.hairline)

            Toggle(loc.newTabShowRecent, isOn: binding(\.newTabShowRecent))
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(.vertical, 9)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 12)
        .background(
            .primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: Theme.popoverRowCorner, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Theme.popoverRowCorner, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.8)
        }
    }

    private func binding<Value>(_ keyPath: ReferenceWritableKeyPath<Settings, Value>) -> Binding<Value> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in
                settings[keyPath: keyPath] = value
                settings.persist()
            }
        )
    }

    private func toggleWallpaperExpanded() {
        withAnimation(reduceMotion ? nil : (wallpaperExpanded ? Motion.dropdownClose : Motion.dropdownOpen)) {
            wallpaperExpanded.toggle()
        }
    }

    private func selectBuiltInWallpaper(_ wallpaper: NewTabWallpaper) {
        settings.newTabWallpaperID = wallpaper.id
        settings.newTabUsesCustomWallpaper = false
        settings.persist()
    }

    private func chooseCustomWallpaper() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let importedPath = try NewTabWallpaperStorage.importImage(from: url)
            let previousPath = settings.newTabCustomWallpaperPath
            settings.newTabCustomWallpaperPath = importedPath
            settings.newTabUsesCustomWallpaper = true
            settings.newTabWallpaperEnabled = true
            settings.persist()
            if previousPath != importedPath {
                NewTabWallpaperStorage.removeCustomImage(atPath: previousPath)
            }
        } catch {
            return
        }
    }

    private func removeCustomWallpaper() {
        let path = settings.newTabCustomWallpaperPath
        NewTabWallpaperStorage.removeCustomImage(atPath: path)
        settings.newTabCustomWallpaperPath = ""
        settings.newTabUsesCustomWallpaper = false
        settings.persist()
    }
}

private struct NewTabWallpaperThumbnail: View {
    let wallpaper: NewTabWallpaper
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.controlCorner, style: .continuous)
                        .fill(.primary.opacity(0.06))

                    if let image = NewTabWallpaperCatalog.image(
                        selectedID: wallpaper.id,
                        usesCustom: false,
                        customPath: "",
                        thumbnail: true
                    ) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 62)
                .clipShape(RoundedRectangle(cornerRadius: Theme.controlCorner, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.controlCorner, style: .continuous)
                        .strokeBorder(selected ? Color.primary : Theme.hairline, lineWidth: selected ? 1.5 : 0.8)
                }
                .overlay(alignment: .bottomTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .background(Circle().fill(Color(nsColor: .controlBackgroundColor)).padding(2))
                            .padding(5)
                            .transition(.opacity)
                    }
                }

                Text(wallpaper.title)
                    .font(.system(size: 10.5, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(4)
            .background {
                RoundedRectangle(cornerRadius: Theme.popoverRowCorner, style: .continuous)
                    .fill(.primary.opacity(hovering ? 0.055 : 0))
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.popoverRowCorner, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : Motion.controlFeedback, value: hovering)
        .animation(reduceMotion ? nil : Motion.controlFeedback, value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(wallpaper.title)
    }
}
