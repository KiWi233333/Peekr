import Foundation
import Observation

/// Observable navigation state for the currently active web view, kept in sync
/// by `WebViewManager` via KVO. The nav bar binds to this.
@MainActor
@Observable
final class BrowserState {
    var currentID: UUID?
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var progress: Double = 0
    var urlString = ""
    var title = ""
    /// The active tab's last main-frame navigation failure, if any.
    var loadError: WebLoadFailure?
    /// The active tab's renderer terminated and needs a reload.
    var rendererFailure: WebRendererFailure?
    /// Runtime-only lifecycle state for the selected page.
    var pageLifecycle: WebPageLifecycle = .closed
    /// Bumped to ask the nav bar to focus its omnibox (⌘L).
    var focusOmniboxToken = 0

    /// Compact label for the omnibox when it isn't being edited.
    var displayURL: String {
        URL(string: urlString)?.displayHost ?? urlString
    }
}

/// Find-in-page bar state (⌘F). Owned by `WebViewManager`; the bar overlays
/// the web card and drives the active engine's find session.
@MainActor
@Observable
final class FindBarState {
    var isVisible = false
    var query = ""
    /// Bumped by ⌘F to refocus the field even when the bar is already open.
    var focusToken = 0
}
