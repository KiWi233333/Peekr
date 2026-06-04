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

    /// Compact label for the omnibox when it isn't being edited.
    var displayURL: String {
        guard let host = URL(string: urlString)?.host else { return urlString }
        return host.replacingOccurrences(of: "www.", with: "")
    }
}
