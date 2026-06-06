import Foundation
import Observation

/// Drives the on-first-use download of the optional Chromium runtime:
/// fetch → verify SHA-256 → install → mark installed, publishing `status` so the
/// Preferences UI can show a live progress bar. `@Observable` so SwiftUI tracks
/// the status.
///
/// The network (`fetch`) and filesystem (`install`) are injected as closures so
/// the orchestration is unit-testable without real I/O — and so the production
/// driver can wrap `URLSession` + unzip without this type knowing either. The
/// load-bearing invariant: verified-before-installed — bytes that fail the
/// manifest checksum are never handed to `install`.
@MainActor
@Observable
final class ChromiumRuntimeDownloader {
    private(set) var status: ChromiumRuntimeStatus

    private let installer: ChromiumRuntimeInstaller
    /// Download `url` to in-memory bytes, reporting `(bytesWritten, totalBytes)`.
    private let fetch: (URL, @escaping (Int64, Int64) -> Void) async throws -> Data
    /// Unpack the verified archive and write the completion marker; throws on failure.
    private let install: (Data) throws -> Void

    init(
        installer: ChromiumRuntimeInstaller,
        fetch: @escaping (URL, @escaping (Int64, Int64) -> Void) async throws -> Data,
        install: @escaping (Data) throws -> Void
    ) {
        self.installer = installer
        self.fetch = fetch
        self.install = install
        self.status = installer.status()
    }

    /// Ensure the runtime described by `manifest` is installed. Idempotent: a
    /// no-op when the required version is already present on disk.
    func ensureInstalled(_ manifest: ChromiumRuntimeManifest) async {
        // Gate on the manifest's version, not the installer's launch-time default,
        // so a newer manifest still downloads when only an older version is present.
        if installer.isInstalled(version: manifest.version) {
            status = .installed(version: manifest.version)
            return
        }
        status = .downloading(progress: 0)
        do {
            let data = try await fetch(manifest.url) { [weak self] written, total in
                self?.status = .downloading(
                    progress: ChromiumRuntimeInstaller.progress(bytesWritten: written, totalBytes: total))
            }
            guard ChromiumChecksum.verify(data, expected: manifest.sha256) else {
                status = .failed(reason: "checksum mismatch")
                return
            }
            try install(data)
            status = .installed(version: manifest.version)
        } catch {
            status = .failed(reason: error.localizedDescription)
        }
    }
}
