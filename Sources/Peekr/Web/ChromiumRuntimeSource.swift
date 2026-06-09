import Foundation

/// Resolves the optional Chromium runtime against the upstream open-source CEF
/// builds CDN (the official "CEF Automated Builds" Spotify mirrors). Keeps the
/// download free of any Peekr-hosted artifact: the URL + SHA-1 always come from
/// CEF's own published index, so there's nothing to re-host or keep in sync.
///
/// Pure orchestration with the network injected as a closure, so it's testable
/// without real I/O and the production path wires `URLSession`.
enum ChromiumRuntimeSource {
    /// Apple-silicon only — Peekr ships an arm64 shim, and the framework ABI is
    /// architecture-specific.
    static let platform = "macosarm64"
    static let indexURL = URL(string: "https://cef-builds.spotifycdn.com/index.json")!
    private static let downloadBase = "https://cef-builds.spotifycdn.com/"

    // The slice of CEF's index.json this resolver reads. The file is keyed by
    // platform at the top level; each version lists its downloadable files.
    private struct Index: Decodable {
        let platforms: [String: Platform]
        init(from decoder: Decoder) throws {
            platforms = try decoder.singleValueContainer().decode([String: Platform].self)
        }
        struct Platform: Decodable { let versions: [Version] }
        struct Version: Decodable { let cef_version: String; let files: [File] }
        struct File: Decodable { let name: String; let sha1: String; let size: Int64; let type: String }
    }

    /// Resolve the upstream "minimal" build whose CEF release matches the bundled
    /// shim's `requiredVersion` (the ABI-locked match). Returns a manifest stamped
    /// with the SHORT version id so the on-disk layout aligns with
    /// `CEFRuntime.frameworkDir` (which keys off `requiredVersion`, not the long
    /// `…+g…+chromium-…` build string). nil when the index is unreachable or has no
    /// matching build.
    static func resolveManifest(
        requiredVersion: String,
        fetch: (URL) async throws -> Data
    ) async -> ChromiumRuntimeManifest? {
        guard let data = try? await fetch(indexURL),
              let index = try? JSONDecoder().decode(Index.self, from: data),
              let platform = index.platforms[platform] else { return nil }
        for version in platform.versions
        where version.cef_version == requiredVersion
            || version.cef_version.hasPrefix(requiredVersion + "+") {
            guard let file = version.files.first(where: { $0.type == "minimal" }),
                  // The CDN serves files by their literal name; the `+` in the build
                  // string must be percent-encoded or the request 404s.
                  let url = URL(string: downloadBase + file.name.replacingOccurrences(of: "+", with: "%2B"))
            else { continue }
            return ChromiumRuntimeManifest(
                version: requiredVersion, url: url, sha1: file.sha1, sizeBytes: file.size)
        }
        return nil
    }
}

/// Production network + filesystem for `ChromiumRuntimeDownloader`. Split from the
/// orchestrator so the latter stays unit-testable with fakes; this side wraps the
/// real `URLSession` download and the `tar` unpack the tests deliberately avoid.
enum ChromiumRuntimeInstall {
    /// Streamed download reporting `(bytesWritten, totalBytes)`. Uses the async
    /// byte stream and accumulates in MB-sized chunks so progress ticks without
    /// the per-byte overhead of appending one element at a time.
    static func fetch(_ url: URL, progress: @escaping (Int64, Int64) -> Void) async throws -> Data {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        let total = response.expectedContentLength
        var data = Data()
        if total > 0 { data.reserveCapacity(Int(total)) }
        var chunk = Data()
        chunk.reserveCapacity(1 << 20)
        var written: Int64 = 0
        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count >= (1 << 20) {
                data.append(chunk); written += Int64(chunk.count); chunk.removeAll(keepingCapacity: true)
                progress(written, total)
            }
        }
        if !chunk.isEmpty { data.append(chunk); written += Int64(chunk.count) }
        progress(written, total)
        return data
    }

    /// Unpack the verified `.tar.bz2` and promote just the framework into the
    /// runtime's version dir. The CEF "minimal" archive nests the framework under
    /// `…/Release/Chromium Embedded Framework.framework`; the helper subprocess
    /// bundle ships inside the app, so only the framework is kept here.
    static func install(_ archive: Data, version: String, layout: ChromiumRuntimeLayout) throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("peekr-cef-\(version)", isDirectory: true)
        try? fm.removeItem(at: scratch)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        let archiveURL = scratch.appendingPathComponent("cef.tar.bz2")
        try archive.write(to: archiveURL)

        let extractDir = scratch.appendingPathComponent("unpacked", isDirectory: true)
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        try runTar(archive: archiveURL, into: extractDir)

        guard let framework = locateFramework(in: extractDir, fileManager: fm) else {
            throw InstallError.frameworkNotFound
        }
        // Stage a dir holding only the framework, then hand it to the shared
        // installer, which writes the completion marker LAST (interrupted → not
        // installed → re-download).
        let staging = scratch.appendingPathComponent("staged", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try fm.moveItem(at: framework,
                        to: staging.appendingPathComponent(framework.lastPathComponent))
        try ChromiumRuntimeFileInstaller(
            layout: layout, version: version, fileManager: fm
        ).install(stagedAt: staging)
    }

    enum InstallError: Error { case extractFailed(Int32), frameworkNotFound }

    private static func runTar(archive: URL, into dir: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-xjf", archive.path, "-C", dir.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw InstallError.extractFailed(p.terminationStatus) }
    }

    private static func locateFramework(in root: URL, fileManager fm: FileManager) -> URL? {
        let name = "Chromium Embedded Framework.framework"
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in walker where url.lastPathComponent == name {
            return url
        }
        return nil
    }
}
