import Foundation
import CryptoKit

/// Install state of the optional Chromium runtime, surfaced to Preferences so it
/// can show a download button, live progress, or an "installed" badge. The
/// runtime is heavy (~180 MB) and downloads on first use, so it's never bundled.
enum ChromiumRuntimeStatus: Equatable {
    case notInstalled
    case downloading(progress: Double) // 0...1
    case installed(version: String)
    case failed(reason: String)
}

/// On-disk layout of the optional Chromium runtime under
/// `~/Library/Application Support/Peekr/engines/chromium`. Pure path math — no
/// I/O — so it's the single, testable source for where each part lives.
struct ChromiumRuntimeLayout {
    let root: URL

    func versionDir(_ version: String) -> URL {
        root.appendingPathComponent(version, isDirectory: true)
    }

    /// Sentinel written LAST, after a successful unpack, so an interrupted or
    /// half-extracted download never looks installed.
    func completionMarker(_ version: String) -> URL {
        versionDir(version).appendingPathComponent(".installed", isDirectory: false)
    }
}

/// Decides whether the *required* Chromium runtime is present and derives
/// download progress. Filesystem access is injected so the rule is unit-testable;
/// the async download driver wraps this over a real `FileManager`/`URLSession`.
/// Binding-agnostic on purpose: whatever concrete Chromium backend ships, "is the
/// runtime downloaded and which version" stays the same question.
struct ChromiumRuntimeInstaller {
    let layout: ChromiumRuntimeLayout
    /// The exact runtime version this build needs. An older installed version
    /// doesn't satisfy it, so upgrades re-download rather than run stale bits.
    let requiredVersion: String
    var fileExists: (URL) -> Bool

    /// Whether a specific version's completion marker is present. The version is
    /// a parameter so the download path can gate on the *manifest's* version (the
    /// single source for "what's needed now") rather than the launch-time default.
    func isInstalled(version: String) -> Bool { fileExists(layout.completionMarker(version)) }

    func isInstalled() -> Bool { isInstalled(version: requiredVersion) }

    func status() -> ChromiumRuntimeStatus {
        isInstalled() ? .installed(version: requiredVersion) : .notInstalled
    }

    /// Fraction downloaded, clamped to 0...1. Returns 0 while the total length is
    /// unknown (some servers omit Content-Length), avoiding a divide-by-zero NaN.
    static func progress(bytesWritten: Int64, totalBytes: Int64) -> Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(0, Double(bytesWritten) / Double(totalBytes)), 1)
    }
}

/// Describes one downloadable Chromium runtime build, fetched as JSON from the
/// update endpoint. Unlike the local user files, a malformed *remote* manifest
/// should fail loudly (treated as "no download available") rather than decode to
/// defaults — so this stays a plain Codable, not a tolerant one.
struct ChromiumRuntimeManifest: Codable, Equatable {
    let version: String
    let url: URL
    /// Lowercase hex SHA-1 of the archive — verified before the bytes are ever
    /// unpacked or executed. SHA-1 because that's the digest the upstream CEF
    /// builds index publishes per file; integrity only (the transport is HTTPS).
    let sha1: String
    let sizeBytes: Int64
}

/// Integrity gate for the downloaded runtime. A 180 MB blob that gets executed
/// MUST be verified against the manifest's hash first; skipping this is a
/// supply-chain hole, so the download driver calls `verify` before unpacking.
enum ChromiumChecksum {
    static func verify(_ data: Data, expected: String) -> Bool {
        let hex = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return hex == expected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Promotes a fully-prepared staging directory into the runtime's version dir.
/// The completion marker is written LAST, so an interrupted install is seen as
/// *not installed* (→ re-download), never as a half-extracted runtime.
///
/// The replace itself is NOT failure-atomic: a same-version re-install clears the
/// prior dir first, so a move that fails mid-way leaves neither. That's tolerable
/// because the runtime is freely re-downloadable — but switch to
/// `FileManager.replaceItemAt` (same-volume atomic swap, preserves the old item on
/// failure) when the real download path is wired up.
struct ChromiumRuntimeFileInstaller {
    let layout: ChromiumRuntimeLayout
    let version: String
    let fileManager: FileManager

    func install(stagedAt staging: URL) throws {
        let dest = layout.versionDir(version)
        if fileManager.fileExists(atPath: dest.path) {
            try fileManager.removeItem(at: dest)
        }
        try fileManager.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: staging, to: dest)
        try Data().write(to: layout.completionMarker(version))
    }
}
