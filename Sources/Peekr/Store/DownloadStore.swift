import Foundation
import Observation

/// In-memory download history for Peekr's compact download center. Chromium
/// owns the files; this store only mirrors their current state for the UI.
@MainActor
@Observable
final class DownloadStore {
    private(set) var records: [WebDownload] = []

    var activeCount: Int {
        records.filter { $0.state == .downloading }.count
    }

    var hasFinishedDownloads: Bool {
        records.contains { $0.state != .downloading }
    }

    func update(_ download: WebDownload) {
        if let index = records.firstIndex(where: { $0.id == download.id }) {
            records[index] = download
        } else {
            records.insert(download, at: 0)
        }

        // Keep the center useful without letting a long-lived browser session
        // grow an unbounded list. Active items are always retained.
        let active = records.filter { $0.state == .downloading }
        let finished = records.filter { $0.state != .downloading }.prefix(49)
        records = active + Array(finished)
    }

    func clearFinished() {
        records.removeAll { $0.state != .downloading }
    }
}
