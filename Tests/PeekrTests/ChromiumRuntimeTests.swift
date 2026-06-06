import XCTest
@testable import Peekr

/// The optional Chromium runtime downloads on first use. These cover the
/// binding-agnostic core: where it lives on disk, whether the *required* version
/// is present (an older one must re-download), and download-progress math. The
/// filesystem is injected so nothing here touches a real disk or network.
final class ChromiumRuntimeTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/peekr-engines/chromium", isDirectory: true)
    private let version = "120.1"
    private func layout() -> ChromiumRuntimeLayout { ChromiumRuntimeLayout(root: root) }

    // MARK: - Progress math

    func testProgressIsFractionOfTotal() {
        XCTAssertEqual(ChromiumRuntimeInstaller.progress(bytesWritten: 90, totalBytes: 180), 0.5, accuracy: 0.0001)
    }

    /// Servers may not send Content-Length up front; until the total is known the
    /// fraction is 0 rather than a divide-by-zero NaN.
    func testProgressZeroWhenTotalUnknown() {
        XCTAssertEqual(ChromiumRuntimeInstaller.progress(bytesWritten: 50, totalBytes: 0), 0)
    }

    func testProgressClampsToOne() {
        XCTAssertEqual(ChromiumRuntimeInstaller.progress(bytesWritten: 200, totalBytes: 180), 1)
    }

    func testProgressClampsNegativeToZero() {
        XCTAssertEqual(ChromiumRuntimeInstaller.progress(bytesWritten: -5, totalBytes: 180), 0)
    }

    // MARK: - Layout

    func testCompletionMarkerLivesUnderVersionDir() {
        let l = layout()
        XCTAssertEqual(l.versionDir(version).lastPathComponent, version)
        XCTAssertEqual(l.completionMarker(version).lastPathComponent, ".installed")
        XCTAssertTrue(l.completionMarker(version).deletingLastPathComponent().path.hasSuffix("/\(version)"))
    }

    // MARK: - Install presence

    func testNotInstalledWhenMarkerMissing() {
        let installer = ChromiumRuntimeInstaller(layout: layout(), requiredVersion: version, fileExists: { _ in false })
        XCTAssertFalse(installer.isInstalled())
        XCTAssertEqual(installer.status(), .notInstalled)
    }

    func testInstalledWhenRequiredVersionMarkerPresent() {
        let marker = layout().completionMarker(version)
        let installer = ChromiumRuntimeInstaller(layout: layout(), requiredVersion: version, fileExists: { $0 == marker })
        XCTAssertTrue(installer.isInstalled())
        XCTAssertEqual(installer.status(), .installed(version: version))
    }

    /// A completion marker for an OLD version must NOT count as installed, so an
    /// upgrade re-downloads instead of running a stale runtime.
    func testOldVersionDoesNotCountAsInstalled() {
        let oldMarker = layout().completionMarker("119.0")
        let installer = ChromiumRuntimeInstaller(layout: layout(), requiredVersion: version, fileExists: { $0 == oldMarker })
        XCTAssertFalse(installer.isInstalled())
        XCTAssertEqual(installer.status(), .notInstalled)
    }

    // MARK: - Manifest

    func testManifestDecodesFromJSON() throws {
        let json = Data(#"{"version":"120.1","url":"https://dl.example.com/chromium-120.1.zip","sha256":"abc123","sizeBytes":188743680}"#.utf8)
        let m = try JSONDecoder().decode(ChromiumRuntimeManifest.self, from: json)
        XCTAssertEqual(m.version, "120.1")
        XCTAssertEqual(m.sizeBytes, 188_743_680)
        XCTAssertEqual(m.url.absoluteString, "https://dl.example.com/chromium-120.1.zip")
    }

    /// A malformed remote manifest must FAIL loudly (treated as "no download"),
    /// not decode to defaults — unlike the tolerant local-file decode. Pins that
    /// deliberate strict-decode choice.
    func testManifestDecodeFailsOnMissingField() {
        let json = Data(#"{"version":"120.1"}"#.utf8) // missing url / sha256 / sizeBytes
        XCTAssertThrowsError(try JSONDecoder().decode(ChromiumRuntimeManifest.self, from: json))
    }

    // MARK: - Checksum (SHA-256 of empty input is a well-known constant)

    private let emptySHA256 = ChromiumTestVectors.emptySHA256

    func testVerifyAcceptsMatchingSHA256() {
        XCTAssertTrue(ChromiumChecksum.verify(Data(), expected: emptySHA256))
    }

    func testVerifyIsCaseAndWhitespaceInsensitive() {
        XCTAssertTrue(ChromiumChecksum.verify(Data(), expected: "  \(emptySHA256.uppercased())\n"))
    }

    func testVerifyRejectsMismatch() {
        XCTAssertFalse(ChromiumChecksum.verify(Data([0x01]), expected: emptySHA256))
    }

    // MARK: - Atomic file install (real temp dir; marker written last)

    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("peekr-runtime-\(UUID().uuidString)")
    }

    func testInstallPromotesStagingAndWritesMarker() throws {
        let fm = FileManager.default
        let root = tempRoot()
        defer { try? fm.removeItem(at: root) }
        let l = ChromiumRuntimeLayout(root: root.appendingPathComponent("chromium"))

        let staging = root.appendingPathComponent("staging")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("lib".utf8).write(to: staging.appendingPathComponent("libcef.txt"))

        try ChromiumRuntimeFileInstaller(layout: l, version: version, fileManager: fm).install(stagedAt: staging)

        XCTAssertTrue(fm.fileExists(atPath: l.completionMarker(version).path))
        XCTAssertTrue(fm.fileExists(atPath: l.versionDir(version).appendingPathComponent("libcef.txt").path))
        let check = ChromiumRuntimeInstaller(layout: l, requiredVersion: version, fileExists: { fm.fileExists(atPath: $0.path) })
        XCTAssertTrue(check.isInstalled())
    }

    /// A previous interrupted attempt left a version dir with stale files and no
    /// marker; installing fresh must replace it wholesale, not merge into it.
    func testInstallReplacesPartialPriorAttempt() throws {
        let fm = FileManager.default
        let root = tempRoot()
        defer { try? fm.removeItem(at: root) }
        let l = ChromiumRuntimeLayout(root: root.appendingPathComponent("chromium"))

        let dest = l.versionDir(version)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: dest.appendingPathComponent("stale.txt"))

        let staging = root.appendingPathComponent("staging")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: staging.appendingPathComponent("fresh.txt"))

        try ChromiumRuntimeFileInstaller(layout: l, version: version, fileManager: fm).install(stagedAt: staging)

        XCTAssertFalse(fm.fileExists(atPath: dest.appendingPathComponent("stale.txt").path))
        XCTAssertTrue(fm.fileExists(atPath: dest.appendingPathComponent("fresh.txt").path))
        XCTAssertTrue(fm.fileExists(atPath: l.completionMarker(version).path))
    }

    /// Locks the marker-written-last invariant against the failure path: when the
    /// move throws (staging missing), install fails AND no completion marker is
    /// left, so the version stays correctly "not installed".
    func testInstallLeavesNoMarkerWhenStagingMissing() {
        let fm = FileManager.default
        let root = tempRoot()
        defer { try? fm.removeItem(at: root) }
        let l = ChromiumRuntimeLayout(root: root.appendingPathComponent("chromium"))
        let missing = root.appendingPathComponent("nonexistent-staging")

        XCTAssertThrowsError(
            try ChromiumRuntimeFileInstaller(layout: l, version: version, fileManager: fm).install(stagedAt: missing))
        XCTAssertFalse(fm.fileExists(atPath: l.completionMarker(version).path))
    }
}
