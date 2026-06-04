import Foundation

extension URL {
    /// Host with a leading `www.` stripped, for compact display in the rail,
    /// omnibox and edit sheet. `nil` when the URL has no host.
    var displayHost: String? {
        host?.replacingOccurrences(of: "www.", with: "")
    }
}
