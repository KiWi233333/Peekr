import Foundation

/// JSON persistence for `SettingsData` under Application Support/Peekr.
struct SettingsStore {
    let fileURL: URL

    init() {
        let fm = FileManager.default
        let base = (fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser)
            .appendingPathComponent("Peekr", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("settings.json")
    }

    func load() -> SettingsData {
        guard
            let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode(SettingsData.self, from: data)
        else { return SettingsData() }
        return decoded
    }

    func save(_ data: SettingsData) {
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        try? encoded.write(to: fileURL, options: .atomic)
    }
}
