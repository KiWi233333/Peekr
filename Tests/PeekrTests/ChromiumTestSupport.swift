import Foundation

/// Shared test vectors for the Chromium runtime suites, converged here so the
/// well-known digest lives in exactly one place (was duplicated per file).
enum ChromiumTestVectors {
    /// SHA-256 of empty input — a fixed, well-known digest, so a `fetch` returning
    /// `Data()` passes checksum verification.
    static let emptySHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
}
