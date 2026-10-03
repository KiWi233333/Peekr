import AppKit
import SwiftUI

/// A browser-style download surface aligned to the navigation bar's trailing edge.
/// It stays in the panel's view tree so Liquid Glass can sample the page behind it
/// without introducing the system popover arrow or a second detached window.
struct DownloadCenter: View {
    let downloads: DownloadStore
    let settings: Settings
    let onCancel: (UInt32) -> Void
    let onRemove: (UInt32) -> Void

    @State private var searchText = ""
    @State private var searchVisible = false

    private var loc: Localized { settings.strings }

    private var visibleDownloads: [WebDownload] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return downloads.records }
        return downloads.records.filter { $0.fileName.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if visibleDownloads.isEmpty {
                Text(searchText.isEmpty ? loc.noDownloads : loc.noMatchingDownloads)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 88)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(visibleDownloads) { download in
                            DownloadRow(
                                download: download,
                                settings: settings,
                                onCancel: { onCancel(download.id) },
                                onRemove: { onRemove(download.id) }
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: 330)
            }
        }
        .padding(6)
        .frame(width: 360)
        .liquidGlass(
            in: RoundedRectangle(cornerRadius: 22, style: .continuous),
            tint: .primary.opacity(0.025),
            interactive: true
        )
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            if searchVisible {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField(loc.searchDownloads, text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .transition(.opacity)
            } else {
                Text(loc.downloads)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            HStack(spacing: 2) {
                DownloadToolbarButton(
                    symbol: "folder",
                    label: loc.openDownloadsFolder,
                    action: openDownloadsFolder
                )
                DownloadToolbarButton(
                    symbol: searchVisible ? "xmark" : "magnifyingglass",
                    label: loc.searchDownloads,
                    action: toggleSearch
                )
                Menu {
                    Button(loc.openDownloadsFolder, action: openDownloadsFolder)
                    if downloads.hasFinishedDownloads {
                        Divider()
                        Button(loc.clearCompletedDownloads, action: clearFinished)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .buttonStyle(IconButtonStyle())
                .fixedSize()
                .foregroundStyle(.primary)
                .help(loc.moreActions)
                .accessibilityLabel(loc.moreActions)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, minHeight: 36)
    }

    private func toggleSearch() {
        withAnimation(Motion.dropdownOpen) {
            searchVisible.toggle()
        }
        if !searchVisible { searchText = "" }
    }

    private func openDownloadsFolder() {
        guard let downloadsURL = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first else { return }
        NSWorkspace.shared.open(downloadsURL)
    }

    private func clearFinished() {
        downloads.clearFinished()
    }
}

private struct DownloadToolbarButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(IconButtonStyle())
        .foregroundStyle(.primary)
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct DownloadRow: View {
    let download: WebDownload
    let settings: Settings
    let onCancel: () -> Void
    let onRemove: () -> Void

    private var loc: Localized { settings.strings }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            fileIcon

            VStack(alignment: .leading, spacing: 4) {
                Text(download.fileName)
                        .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)

                if download.state == .completed, download.location != nil {
                    Button(loc.openDownloadedFile, action: openFile)
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                } else {
                    HStack(spacing: 7) {
                        Text(statusText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        if download.state == .downloading {
                            Button(loc.cancelDownload, action: onCancel)
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let progress = download.progress, download.state == .downloading {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 132)
                }
            }

            Spacer(minLength: 4)
            actions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var fileIcon: some View {
        if let location = download.location, download.state == .completed {
            Image(nsImage: NSWorkspace.shared.icon(forFile: location.path))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: iconName)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(download.state == .canceled ? .secondary : .primary)
        }
    }

    @ViewBuilder
    private var actions: some View {
        if download.state == .completed, download.location != nil {
            HStack(spacing: 8) {
                DownloadRowButton(
                    symbol: "folder",
                    label: loc.showDownloadedFile,
                    action: showInFinder
                )
                DownloadRowButton(symbol: "trash", label: loc.delete, action: onRemove)
            }
        } else if download.state == .downloading {
            DownloadRowButton(symbol: "xmark", label: loc.cancelDownload, action: onCancel)
        } else {
            DownloadRowButton(symbol: "trash", label: loc.delete, action: onRemove)
        }
    }

    private var iconName: String {
        switch download.state {
        case .downloading: return "arrow.down.circle"
        case .completed: return "doc.text"
        case .canceled: return "xmark.circle"
        case .failed: return "exclamationmark.circle"
        }
    }

    private var statusText: String {
        switch download.state {
        case .downloading: return loc.downloadInProgress
        case .completed: return loc.downloadComplete
        case .canceled: return loc.downloadCanceled
        case .failed: return loc.downloadFailed
        }
    }

    private func openFile() {
        guard let location = download.location else { return }
        NSWorkspace.shared.open(location)
    }

    private func showInFinder() {
        guard let location = download.location else { return }
        NSWorkspace.shared.activateFileViewerSelecting([location])
    }
}

private struct DownloadRowButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(IconButtonStyle())
        .foregroundStyle(.primary)
        .help(label)
        .accessibilityLabel(label)
    }
}
