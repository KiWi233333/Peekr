import Foundation

/// Shared test vectors for the Chromium runtime suites, converged here so the
/// well-known digest lives in exactly one place (was duplicated per file).
enum ChromiumTestVectors {
    /// SHA-1 of empty input — a fixed, well-known digest, so a `fetch` returning
    /// `Data()` passes checksum verification.
    static let emptySHA1 = "da39a3ee5e6b4b0d3255bfef95601890afd80709"
}
