import AppKit
import SwiftUI

/// Native `peekr://downloads` page: live search by file name or source host,
/// per-record pause/resume/cancel/retry, and open/reveal for finished files.
struct DownloadsPageView: View {
    let downloads: DownloadStore
    let settings: Settings
    let onPause: (UInt32) -> Void
    let onResume: (UInt32) -> Void
    let onCancel: (UInt32) -> Void
    let onRetry: (DownloadRecord) -> Void
    let onReveal: (URL) -> Void
    let onOpen: (URL) -> Void
    let onClearFinished: () -> Void

    @State private var query = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var loc: Localized { settings.strings }

    private enum Layout {
        static let horizontalPadding: CGFloat = 18
        static let topPadding: CGFloat = 16
        static let bottomPadding: CGFloat = 12
        static let contentMaxWidth: CGFloat = 880
        static let rowSpacing: CGFloat = 6
        static let searchHeight: CGFloat = 30
    }

    var body: some View {
        pageColumn
            .padding(.horizontal, Layout.horizontalPadding)
            .padding(.top, Layout.topPadding)
            .padding(.bottom, Layout.bottomPadding)
            .frame(maxWidth: Layout.contentMaxWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background {
                RoundedRectangle(cornerRadius: Theme.webCardCorner, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.webCardCorner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.webCardCorner, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            }
    }

    private var pageColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            searchField
                .padding(.top, 12)
                .padding(.bottom, 10)

            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)

            content
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(loc.downloads)
                .font(.system(size: 20, weight: .semibold))
                .accessibilityAddTraits(.isHeader)

            activeCountBadge

            Spacer(minLength: 8)

            clearFinishedButton
        }
    }

    private var activeCountBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 10, weight: .semibold))
                .accessibilityHidden(true)

            Text(loc.activeDownloadCount(downloads.activeCount))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
        }
        .foregroundStyle(downloads.activeCount > 0 ? Color.primary : Color.secondary)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background {
            Capsule(style: .continuous)
                .fill(.primary.opacity(downloads.activeCount > 0 ? 0.07 : 0.04))
        }
        .animation(reduceMotion ? nil : Motion.controlFeedback, value: downloads.activeCount)
    }

    private var clearFinishedButton: some View {
        Button(action: clearFinished) {
            HStack(spacing: 5) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityHidden(true)

                Text(loc.clearCompletedDownloads)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background {
                RoundedRectangle(cornerRadius: Theme.controlCorner, style: .continuous)
                    .fill(.primary.opacity(0.06))
            }
            .contentShape(
                RoundedRectangle(cornerRadius: Theme.controlCorner, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(!downloads.hasFinishedDownloads)
        .opacity(downloads.hasFinishedDownloads ? 1 : 0.4)
        .help(loc.clearCompletedDownloads)
        .accessibilityLabel(loc.clearCompletedDownloads)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(loc.searchDownloads, text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .accessibilityLabel(loc.searchDownloads)

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(loc.clearDownloadSearch)
                .accessibilityLabel(loc.clearDownloadSearch)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Layout.searchHeight)
        .background {
            RoundedRectangle(cornerRadius: Theme.controlCorner, style: .continuous)
                .fill(.primary.opacity(0.06))
        }
        .animation(reduceMotion ? nil : Motion.controlFeedback, value: query.isEmpty)
    }

    @ViewBuilder
    private var content: some View {
        if visibleDownloads.isEmpty {
            statusState(
                symbol: trimmedQuery.isEmpty ? "arrow.down.circle" : "magnifyingglass",
                title: trimmedQuery.isEmpty ? loc.noDownloads : loc.noMatchingDownloads
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Layout.rowSpacing) {
                    ForEach(visibleDownloads) { download in
                        DownloadsPageRow(
                            download: download,
                            strings: loc,
                            isPaused: downloads.isPaused(download.id),
                            onPause: { onPause(download.id) },
                            onResume: { onResume(download.id) },
                            onCancel: { onCancel(download.id) },
                            onRetry: { retry(download) },
                            onOpen: onOpen,
                            onReveal: onReveal,
                            onRemove: { remove(download.id) }
                        )
                        .transition(rowTransition)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 1)
                .animation(
                    reduceMotion ? nil : Motion.sidebarReorder,
                    value: visibleDownloads.map(\.id)
                )
            }
            .scrollIndicators(.automatic)
        }
    }

    private func statusState(symbol: String, title: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleDownloads: [WebDownload] {
        let trimmed = trimmedQuery
        guard !trimmed.isEmpty else { return downloads.records }

        return downloads.records.filter { download in
            if download.fileName.localizedCaseInsensitiveContains(trimmed) {
                return true
            }
            guard let url = download.url else { return false }
            if let host = url.displayHost, host.localizedCaseInsensitiveContains(trimmed) {
                return true
            }
            if let host = url.host, host.localizedCaseInsensitiveContains(trimmed) {
                return true
            }
            return false
        }
    }

    private var rowTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        return .asymmetric(
            insertion: .opacity.combined(with: .move(edge: .top)),
            removal: .opacity.combined(with: .scale(scale: 0.97, anchor: .center))
        )
    }

    private func retry(_ download: WebDownload) {
        let record = downloads.record(for: download.id) ?? DownloadRecord(
            id: download.id,
            url: download.url,
            fileName: download.fileName,
            receivedBytes: download.receivedBytes,
            totalBytes: download.totalBytes,
            state: DownloadRecord.State(download.state),
            location: download.location,
            startedAt: Date(),
            endedAt: Date(),
            isPaused: false
        )

        onRetry(record)

        withAnimation(reduceMotion ? nil : Motion.sidebarReorder) {
            downloads.remove(id: download.id)
        }
    }

    private func remove(_ id: UInt32) {
        withAnimation(reduceMotion ? nil : Motion.sidebarReorder) {
            downloads.remove(id: id)
        }
    }

    private func clearFinished() {
        withAnimation(reduceMotion ? nil : Motion.sidebarReorder) {
            onClearFinished()
        }
    }
}

private struct DownloadsPageRow: View {
    let download: WebDownload
    let strings: Localized
    let isPaused: Bool
    let onPause: () -> Void
    let onResume: () -> Void
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onOpen: (URL) -> Void
    let onReveal: (URL) -> Void
    let onRemove: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            fileIcon

            VStack(alignment: .leading, spacing: 5) {
                Text(displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                metadata

                if download.state == .downloading {
                    progress
                        .padding(.top, 1)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            actions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: Theme.popoverRowCorner, style: .continuous)
                .fill(.primary.opacity(hovering ? 0.065 : 0.04))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.popoverRowCorner, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.8)
        }
        .contentShape(
            RoundedRectangle(cornerRadius: Theme.popoverRowCorner, style: .continuous)
        )
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : Motion.controlFeedback, value: hovering)
    }

    private var fileIcon: some View {
        Image(systemName: fileKind.symbolName)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(download.state == .canceled ? Color.secondary : Color.primary)
            .frame(width: 34, height: 34)
            .background {
                RoundedRectangle(cornerRadius: Theme.iconCorner, style: .continuous)
                    .fill(.primary.opacity(0.06))
            }
            .accessibilityHidden(true)
    }

    private var metadata: some View {
        HStack(spacing: 6) {
            if let sourceHost {
                Text(sourceHost)
                    .lineLimit(1)
                    .truncationMode(.middle)

                separator
            }

            Text(sizeText)
                .monospacedDigit()
                .fixedSize(horizontal: true, vertical: false)

            separator

            Text(statusText)
                .fixedSize(horizontal: true, vertical: false)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var separator: some View {
        Text("·")
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var progress: some View {
        if let value = download.progress {
            DownloadProgressBar(value: value)
        } else {
            ProgressView()
                .progressViewStyle(.linear)
                .controlSize(.mini)
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 2) {
            switch download.state {
            case .downloading:
                if isPaused {
                    actionButton("play.fill", label: strings.resume, action: onResume)
                } else {
                    actionButton("pause.fill", label: strings.pause, action: onPause)
                }
                actionButton("xmark", label: strings.cancelDownload, action: onCancel)

            case .completed:
                if let location = download.location {
                    actionButton("arrow.up.forward.square", label: strings.openDownloadedFile) {
                        onOpen(location)
                    }
                    actionButton("folder", label: strings.revealInFinder) {
                        onReveal(location)
                    }
                }
                actionButton("trash", label: strings.removeDownload, action: onRemove)

            case .failed, .canceled:
                actionButton("arrow.clockwise", label: strings.retry, action: onRetry)
                actionButton("trash", label: strings.removeDownload, action: onRemove)
            }
        }
    }

    private func actionButton(
        _ symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(IconButtonStyle())
        .foregroundStyle(.primary)
        .help(label)
        .accessibilityLabel(label)
    }

    private var displayName: String {
        let trimmed = download.fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let lastPathComponent = download.url?.lastPathComponent, !lastPathComponent.isEmpty {
            return lastPathComponent
        }
        return strings.downloads
    }

    private var sourceHost: String? {
        guard let url = download.url else { return nil }
        guard let host = url.displayHost ?? url.host, !host.isEmpty else { return nil }
        return host
    }

    private var fileKind: DownloadFileKind {
        DownloadFileKind(fileName: displayName)
    }

    private var sizeText: String {
        let received = formattedBytes(download.receivedBytes)
        guard download.totalBytes > 0 else { return received }
        return "\(received) / \(formattedBytes(download.totalBytes))"
    }

    private var statusText: String {
        switch download.state {
        case .downloading:
            return isPaused ? strings.downloadPaused : strings.downloadInProgress
        case .completed:
            return strings.downloadComplete
        case .canceled:
            return strings.downloadCanceled
        case .failed:
            return strings.downloadFailed
        }
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct DownloadProgressBar: View {
    let value: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let fraction = min(max(value, 0), 1)
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(.primary.opacity(0.10))

                Capsule(style: .continuous)
                    .fill(Theme.accent)
                    .frame(width: max(proxy.size.width * fraction, fraction > 0 ? 2 : 0))
            }
        }
        .frame(height: 3)
        .animation(reduceMotion ? nil : Motion.controlFeedback, value: value)
        .accessibilityHidden(true)
    }
}

private enum DownloadFileKind {
    case archive
    case image
    case document
    case audio
    case video
    case generic

    init(fileName: String) {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "sit", "sitx", "lzh":
            self = .archive
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp",
             "svg", "avif", "raw", "icns", "ico":
            self = .image
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "md", "csv",
             "pages", "numbers", "key", "epub", "json", "xml", "html", "htm", "yml", "yaml",
             "swift", "py", "js", "tsx":
            self = .document
        case "mp3", "m4a", "aac", "wav", "flac", "ogg", "opus", "aiff", "alac", "wma":
            self = .audio
        case "mp4", "mov", "m4v", "avi", "mkv", "webm", "wmv", "flv", "mpeg", "mpg", "3gp":
            self = .video
        default:
            self = .generic
        }
    }

    var symbolName: String {
        switch self {
        case .archive: return "archivebox"
        case .image: return "photo"
        case .document: return "doc.text"
        case .audio: return "music.note"
        case .video: return "film"
        case .generic: return "doc"
        }
    }
}

/// Keys this page needs that are not yet in `Localized`. Move these into
/// `Localization.swift` and delete this extension when the shell wave lands.
