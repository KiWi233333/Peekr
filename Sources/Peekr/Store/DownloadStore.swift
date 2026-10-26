import Foundation
import Observation

/// One row of the persisted download center. Chromium still owns the file; this
/// record keeps the list across launches and makes interrupted downloads
/// retryable.
struct DownloadRecord: Codable, Equatable, Identifiable {
    enum State: String, Codable, CaseIterable {
        case downloading, completed, canceled, failed
    }

    let id: UInt32
    var url: URL?
    var fileName: String
    var receivedBytes: Int64
    var totalBytes: Int64
    var state: State
    var location: URL?
    var startedAt: Date
    var endedAt: Date?
    var isPaused: Bool
}

/// Download history for Peekr's compact download center. Chromium owns the
/// files; this store mirrors their state and persists it when given a file.
@MainActor
@Observable
final class DownloadStore {
    private(set) var records: [WebDownload] = []
    private(set) var pausedIDs: Set<UInt32> = []

    private let fileURL: URL?
    private var savedRecords: [DownloadRecord] = []

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        savedRecords = Self.load(from: fileURL).map { record in
            guard record.state == .downloading else { return record }
            var interrupted = record
            interrupted.state = .failed
            interrupted.isPaused = false
            return interrupted
        }
        records = savedRecords.map(\.webDownload)
        pausedIDs = Set(
            savedRecords.lazy
                .filter { $0.isPaused && $0.state == .downloading }
                .map(\.id)
        )
    }

    var activeCount: Int {
        records.filter { $0.state == .downloading }.count
    }

    var hasFinishedDownloads: Bool {
        records.contains { $0.state != .downloading }
    }

    /// `persist` is false for downloads started in a private space: they stay
    /// visible for the current session but never enter `savedRecords` or
    /// `downloads.json`.
    func update(_ download: WebDownload, persist shouldPersist: Bool = true) {
        let now = Date()
        let isTerminal = download.state != .downloading

        guard shouldPersist else {
            updateInMemory(download, isTerminal: isTerminal)
            return
        }

        // CEF download ids restart with the process. If a fresh download reuses
        // the id of a persisted terminal row, move the historical row to a
        // synthetic id instead of overwriting it.
        if let index = savedRecords.firstIndex(where: { $0.id == download.id }),
           savedRecords[index].state != .downloading {
            let historical = savedRecords[index]
            let synthetic = nextSyntheticID()
            savedRecords[index] = historical.withID(synthetic)
            if let recordIndex = records.firstIndex(where: { $0.id == download.id }) {
                records[recordIndex] = historical.webDownload.withID(synthetic)
            }
        }

        if let index = savedRecords.firstIndex(where: { $0.id == download.id }) {
            var record = savedRecords[index]
            record.url = download.url ?? record.url
            record.fileName = download.fileName
            record.receivedBytes = download.receivedBytes
            record.totalBytes = download.totalBytes
            record.state = DownloadRecord.State(download.state)
            record.location = download.location ?? record.location
            if isTerminal {
                record.endedAt = record.endedAt ?? now
                record.isPaused = false
            } else {
                record.endedAt = nil
            }
            savedRecords[index] = record
        } else {
            savedRecords.insert(
                DownloadRecord(
                    id: download.id,
                    url: download.url,
                    fileName: download.fileName,
                    receivedBytes: download.receivedBytes,
                    totalBytes: download.totalBytes,
                    state: DownloadRecord.State(download.state),
                    location: download.location,
                    startedAt: now,
                    endedAt: isTerminal ? now : nil,
                    isPaused: false
                ),
                at: 0
            )
        }

        if let index = records.firstIndex(where: { $0.id == download.id }) {
            records[index] = download
        } else {
            records.insert(download, at: 0)
        }

        trimFinishedRecords()

        if isTerminal {
            pausedIDs.remove(download.id)
        }
        syncSavedRecords()
        persist()
    }

    private func updateInMemory(_ download: WebDownload, isTerminal: Bool) {
        if let index = records.firstIndex(where: { $0.id == download.id }) {
            records[index] = download
        } else {
            records.insert(download, at: 0)
        }
        trimFinishedRecords()
        if isTerminal {
            pausedIDs.remove(download.id)
        }
    }

    /// Keeps the center useful without letting a long-lived browser session
    /// grow an unbounded list. Active items are always retained.
    private func trimFinishedRecords() {
        let active = records.filter { $0.state == .downloading }
        let finished = records.filter { $0.state != .downloading }.prefix(49)
        records = active + Array(finished)
    }

    func clearFinished() {
        let count = records.count
        records.removeAll { $0.state != .downloading }
        guard records.count != count else { return }
        syncSavedRecords()
        persist()
    }

    func remove(id: UInt32) {
        records.removeAll { $0.id == id }
        savedRecords.removeAll { $0.id == id }
        pausedIDs.remove(id)
        persist()
    }

    func isPaused(_ id: UInt32) -> Bool {
        pausedIDs.contains(id)
    }

    func setPaused(_ id: UInt32, _ paused: Bool) {
        guard let index = savedRecords.firstIndex(where: { $0.id == id }) else {
            guard records.contains(where: { $0.id == id }) else {
                pausedIDs.remove(id)
                return
            }
            if paused {
                pausedIDs.insert(id)
            } else {
                pausedIDs.remove(id)
            }
            return
        }
        guard savedRecords[index].state == .downloading else {
            savedRecords[index].isPaused = false
            pausedIDs.remove(id)
            persist()
            return
        }
        savedRecords[index].isPaused = paused
        if paused {
            pausedIDs.insert(id)
        } else {
            pausedIDs.remove(id)
        }
        persist()
    }

    func record(for id: UInt32) -> DownloadRecord? {
        savedRecords.first { $0.id == id }
    }

    /// Persisted rows that no longer have a live CEF item get ids above the
    /// signed 31-bit range, which CEF download ids never reach in practice.
    private func nextSyntheticID() -> UInt32 {
        var candidate: UInt32 = 0x8000_0000
        while savedRecords.contains(where: { $0.id == candidate }) {
            candidate &+= 1
        }
        return candidate
    }

    private func syncSavedRecords() {
        let byID = Dictionary(savedRecords.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        savedRecords = records.compactMap { byID[$0.id] }
        let activeIDs = Set(records.lazy.filter { $0.state == .downloading }.map(\.id))
        pausedIDs.formIntersection(activeIDs)
    }

    private func persist() {
        guard let fileURL else { return }
        guard let data = try? JSONEncoder().encode(savedRecords) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func load(from fileURL: URL?) -> [DownloadRecord] {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([DownloadRecord].self, from: data)
        else { return [] }
        return decoded
    }
}

extension DownloadRecord {
    func withID(_ id: UInt32) -> DownloadRecord {
        DownloadRecord(
            id: id,
            url: url,
            fileName: fileName,
            receivedBytes: receivedBytes,
            totalBytes: totalBytes,
            state: state,
            location: location,
            startedAt: startedAt,
            endedAt: endedAt,
            isPaused: isPaused
        )
    }

    var webDownload: WebDownload {
        WebDownload(
            id: id,
            url: url,
            fileName: fileName,
            receivedBytes: receivedBytes,
            totalBytes: totalBytes,
            state: webState,
            location: location
        )
    }

    var webState: WebDownloadState {
        switch state {
        case .downloading: return .downloading
        case .completed: return .completed
        case .canceled: return .canceled
        case .failed: return .failed
        }
    }
}

extension WebDownload {
    func withID(_ id: UInt32) -> WebDownload {
        WebDownload(
            id: id,
            url: url,
            fileName: fileName,
            receivedBytes: receivedBytes,
            totalBytes: totalBytes,
            state: state,
            location: location
        )
    }
}

extension DownloadRecord.State {
    init(_ state: WebDownloadState) {
        switch state {
        case .downloading: self = .downloading
        case .completed: self = .completed
        case .canceled: self = .canceled
        case .failed: self = .failed
        }
    }
}
