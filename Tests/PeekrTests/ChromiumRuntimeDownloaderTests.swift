import XCTest
@testable import Peekr

/// The async first-use download driver: fetch → verify SHA-256 → install → mark.
/// Network and filesystem are injected, so the orchestration is tested without
/// real I/O. The load-bearing guarantee is the security gate: bytes that fail the
/// checksum are NEVER handed to `install`.
@MainActor
final class ChromiumRuntimeDownloaderTests: XCTestCase {
    /// SHA-1 of empty input — so a `fetch` returning `Data()` passes verification.
    private static let emptyHash = ChromiumTestVectors.emptySHA1
    private let url = URL(string: "https://dl.example.com/chromium-120.1.zip")!

    private func installer(installed: Bool) -> ChromiumRuntimeInstaller {
        ChromiumRuntimeInstaller(
            layout: ChromiumRuntimeLayout(root: URL(fileURLWithPath: "/tmp/peekr-x")),
            requiredVersion: "120.1",
            fileExists: { _ in installed }
        )
    }

    private func manifest(sha1: String) -> ChromiumRuntimeManifest {
        ChromiumRuntimeManifest(version: "120.1", url: url, sha1: sha1, sizeBytes: 0)
    }

    func testSkipsDownloadWhenAlreadyInstalled() async {
        var fetched = false
        let d = ChromiumRuntimeDownloader(
            installer: installer(installed: true),
            fetch: { _, _ in fetched = true; return Data() },
            install: { _ in }
        )
        await d.ensureInstalled(manifest(sha1: Self.emptyHash))
        XCTAssertFalse(fetched)
        XCTAssertEqual(d.status, .installed(version: "120.1"))
    }

    func testHappyPathVerifiesThenInstalls() async {
        var installed = false
        let d = ChromiumRuntimeDownloader(
            installer: installer(installed: false),
            fetch: { _, _ in Data() },
            install: { _ in installed = true }
        )
        await d.ensureInstalled(manifest(sha1: Self.emptyHash))
        XCTAssertTrue(installed)
        XCTAssertEqual(d.status, .installed(version: "120.1"))
    }

    /// Security gate: a checksum mismatch must abort BEFORE install runs, so a
    /// tampered/corrupt download is never unpacked or executed.
    func testChecksumMismatchNeverInstalls() async {
        var installed = false
        let d = ChromiumRuntimeDownloader(
            installer: installer(installed: false),
            fetch: { _, _ in Data([0x01]) },
            install: { _ in installed = true }
        )
        await d.ensureInstalled(manifest(sha1: Self.emptyHash))
        XCTAssertFalse(installed)
        guard case .failed = d.status else { return XCTFail("expected .failed, got \(d.status)") }
    }

    /// Verification passes but the unpack/install step fails — must surface as
    /// `.failed`, not silently report installed.
    func testInstallFailureSurfacesAsFailed() async {
        struct InstallError: Error {}
        let d = ChromiumRuntimeDownloader(
            installer: installer(installed: false),
            fetch: { _, _ in Data() },
            install: { _ in throw InstallError() }
        )
        await d.ensureInstalled(manifest(sha1: Self.emptyHash))
        guard case .failed = d.status else { return XCTFail("install failure must surface as .failed, got \(d.status)") }
    }

    func testFetchFailureSurfacesAsFailed() async {
        struct DownloadError: Error {}
        let d = ChromiumRuntimeDownloader(
            installer: installer(installed: false),
            fetch: { _, _ in throw DownloadError() },
            install: { _ in }
        )
        await d.ensureInstalled(manifest(sha1: Self.emptyHash))
        guard case .failed = d.status else { return XCTFail("expected .failed, got \(d.status)") }
    }

    /// An OLD version is installed but the manifest asks for a NEWER one — the
    /// download must NOT be skipped. Guards against gating on the installer's
    /// `requiredVersion` instead of the manifest's version (the single source for
    /// "what do we need now").
    func testUpgradeNotSkippedWhenOnlyOldVersionInstalled() async {
        let layout = ChromiumRuntimeLayout(root: URL(fileURLWithPath: "/tmp/peekr-x"))
        let oldMarker = layout.completionMarker("119.0")
        let installer = ChromiumRuntimeInstaller(
            layout: layout, requiredVersion: "119.0", fileExists: { $0 == oldMarker })
        var fetched = false
        let d = ChromiumRuntimeDownloader(
            installer: installer,
            fetch: { _, _ in fetched = true; return Data() },
            install: { _ in }
        )
        await d.ensureInstalled(manifest(sha1: Self.emptyHash)) // manifest version 120.1
        XCTAssertTrue(fetched, "a newer manifest version must download, not skip on an old install")
        XCTAssertEqual(d.status, .installed(version: "120.1"))
    }

    func testProgressIsPublishedDuringDownload() async {
        var observed: Double?
        var downloader: ChromiumRuntimeDownloader!
        downloader = ChromiumRuntimeDownloader(
            installer: installer(installed: false),
            fetch: { _, report in
                report(45, 90)
                if case let .downloading(p) = downloader.status { observed = p }
                return Data()
            },
            install: { _ in }
        )
        await downloader.ensureInstalled(manifest(sha1: Self.emptyHash))
        XCTAssertEqual(observed, 0.5)
    }
}
