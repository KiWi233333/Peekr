import AppKit
import SwiftUI

/// Routes a `peekr://` route to its native page and wires the page's actions to
/// the shared stores and the active web manager. Each page owns its layout while
/// the host fills the web area.
struct InternalPageHost: View {
    let page: InternalPage
    let model: AppModel
    let settings: Settings
    let manager: WebViewManager
    let icons: IconStore
    let bookmarks: BookmarksModel

    private var loc: Localized { settings.strings }

    var body: some View {
        Group {
            switch page {
            case .newTab:
                NewTabPageView(
                    history: manager.history,
                    bookmarks: bookmarks,
                    settings: settings,
                    icons: icons,
                    onSearch: { manager.loadAddress($0) },
                    onOpen: open,
                    onManageBookmarks: { manager.openInternalPage(.bookmarks) }
                )

            case .history:
                HistoryPageView(
                    history: manager.history,
                    settings: settings,
                    icons: icons,
                    onOpen: open
                )

            case .downloads:
                DownloadsPageView(
                    downloads: manager.downloads,
                    settings: settings,
                    onPause: manager.pauseDownload,
                    onResume: manager.resumeDownload,
                    onCancel: manager.cancelDownload,
                    onRetry: manager.retryDownload,
                    onReveal: reveal,
                    onOpen: { NSWorkspace.shared.open($0) },
                    onClearFinished: manager.downloads.clearFinished
                )

            case .bookmarks:
                BookmarksPageView(
                    bookmarks: bookmarks,
                    settings: settings,
                    icons: icons,
                    currentPage: nil,
                    onOpen: open
                )

            case .shortcuts:
                ShortcutsPageView(settings: settings)

            case .settings:
                placeholderCard

            case .clearData:
                ClearDataPageView(
                    cleaner: manager.browsingData,
                    settings: settings,
                    onClose: { manager.closeInternalPage() }
                )

            case .siteSettings(let origin):
                SiteSettingsPageView(
                    permissions: SitePermissionStore.shared,
                    settings: settings,
                    filterOrigin: origin.isEmpty ? nil : origin,
                    onClose: {
                        if origin.isEmpty {
                            manager.closeInternalPage()
                        } else {
                            manager.openInternalPage(.siteSettings(""))
                        }
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Placeholder

    private var placeholderCard: some View {
        VStack(spacing: 12) {
            Image(systemName: placeholderSymbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(loc.title(for: page))
                .font(.system(size: 18, weight: .semibold))
                .accessibilityAddTraits(.isHeader)

            Text(loc.internalPagePlaceholder)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(32)
        .frame(maxWidth: 460)
        .background {
            RoundedRectangle(cornerRadius: Theme.webCardCorner, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.webCardCorner, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(loc.title(for: page)). \(loc.internalPagePlaceholder)")
    }

    private var placeholderSymbol: String {
        switch page {
        case .settings: return "gearshape"
        case .shortcuts: return "keyboard"
        default: return "doc.text"
        }
    }

    // MARK: - Actions

    private func open(_ url: URL) {
        manager.loadAddress(url.absoluteString)
    }

    private func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
