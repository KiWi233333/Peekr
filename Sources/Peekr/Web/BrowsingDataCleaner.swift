import Foundation

/// Which data sets a clear-browsing-data operation should remove.
struct BrowsingDataSelection: Equatable {
    var history = true
    var downloads = true
    var cookies = true
    var cache = true
    var permissions = true
    var zoom = true

    var isEmpty: Bool {
        !history && !downloads && !cookies && !cache && !permissions && !zoom
    }
}

/// Applies a browsing-data selection to Peekr's stores and, when cookies or
/// cache are selected, to CEF's whole-store cookie/cache deletion.
///
/// CEF has no time-range deletion; “the last hour” style filters can only apply
/// to Peekr-owned data. The CEF closure is injected by the composition root so
/// this type stays free of CefKit and engine-factory dependencies.
@MainActor
final class BrowsingDataCleaner {
    let history: HistoryStore
    let downloads: DownloadStore
    let permissions: SitePermissionStore
    /// Exposed so tests can seed/inspect the same copy the cleaner mutates.
    /// `ZoomStore` is a value type; `WebViewManager` reads this property so a
    /// clear is immediately visible to live zoom lookups.
    var zoom: ZoomStore

    /// Passed `(cookies, cache, completion)`. `nil` means no live CEF runtime;
    /// the operation then completes immediately after the local stores.
    var clearCEFData: ((_ cookies: Bool, _ cache: Bool, @escaping () -> Void) -> Void)?

    init(
        history: HistoryStore,
        downloads: DownloadStore,
        permissions: SitePermissionStore,
        zoom: ZoomStore = ZoomStore()
    ) {
        self.history = history
        self.downloads = downloads
        self.permissions = permissions
        self.zoom = zoom
    }

    func clear(_ selection: BrowsingDataSelection, completion: @escaping () -> Void) {
        guard !selection.isEmpty else {
            completion()
            return
        }

        var isFinished = false
        let finish = {
            guard !isFinished else { return }
            isFinished = true
            completion()
        }

        if selection.history { history.removeAll() }
        if selection.downloads { downloads.clearFinished() }
        if selection.permissions { permissions.forgetAll() }
        if selection.zoom { zoom.clear() }

        guard selection.cookies || selection.cache, let clearCEFData else {
            finish()
            return
        }
        clearCEFData(selection.cookies, selection.cache, finish)
    }
}
