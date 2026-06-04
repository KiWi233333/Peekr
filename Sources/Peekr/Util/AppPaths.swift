import Foundation

/// Single source of truth for Peekr's on-disk locations under
/// `~/Library/Application Support/Peekr/`. The stores and the icon cache all
/// route through here instead of re-deriving the path, so relocating the data
/// directory is a one-line change.
enum AppPaths {
    /// `~/Library/Application Support/Peekr` (created on first access).
    static let supportDirectory: URL = {
        let fm = FileManager.default
        let base = (fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser)
            .appendingPathComponent("Peekr", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// `…/Peekr/icons` for the per-app favicon cache (created on first access).
    static let iconsDirectory: URL = {
        let dir = supportDirectory.appendingPathComponent("icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}
