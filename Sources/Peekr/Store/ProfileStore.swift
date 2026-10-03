import Foundation

/// Persists the Profile registry independently from Workspace/tab facts.
/// Profile IDs remain stable even when a display name changes.
struct ProfileStore {
    let fileURL: URL

    init(fileURL: URL = AppPaths.supportDirectory.appendingPathComponent("profiles.json")) {
        self.fileURL = fileURL
    }

    func load() -> ProfileRegistry {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(ProfileRegistry.self, from: data) else {
            let defaults = ProfileRegistry()
            save(defaults)
            return defaults
        }

        let repaired = decoded.normalized()
        if repaired != decoded { save(repaired) }
        return repaired
    }

    func save(_ registry: ProfileRegistry) {
        let normalized = registry.normalized()
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoded = try JSONEncoder().encode(normalized)
            try encoded.write(to: fileURL, options: .atomic)
        } catch {
            // Persistence failures are handled like the existing AppStore: the
            // in-memory model remains usable and the next load retries repair.
        }
    }

    @discardableResult
    func create(name: String, at date: Date = Date()) -> BrowserProfile? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var registry = load()
        guard !registry.profiles.contains(where: {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame && !$0.isArchived
        }) else { return nil }

        let profile = BrowserProfile(name: trimmed, createdAt: date, updatedAt: date)
        registry.profiles.append(profile)
        save(registry)
        return profile
    }

    @discardableResult
    func rename(_ id: BrowserProfile.ID, to name: String, at date: Date = Date())
        -> BrowserProfile?
    {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var registry = load()
        guard let index = registry.profiles.firstIndex(where: { $0.id == id }),
              !registry.profiles[index].isDefault,
              !registry.profiles.contains(where: {
                  $0.id != id && !$0.isArchived
                      && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
              }) else { return nil }

        let renamed = registry.profiles[index].renamed(to: trimmed, at: date)
        registry.profiles[index] = renamed
        save(registry)
        return renamed
    }

    @discardableResult
    func archive(_ id: BrowserProfile.ID, at date: Date = Date()) -> Bool {
        var registry = load()
        guard let index = registry.profiles.firstIndex(where: { $0.id == id }),
              !registry.profiles[index].isDefault else { return false }
        registry.profiles[index] = registry.profiles[index].archived(at: date)
        save(registry)
        return true
    }

    /// A Profile cannot be deleted while a Workspace still points at it.
    @discardableResult
    func delete(
        _ id: BrowserProfile.ID,
        boundWorkspaceIDs: Set<Workspace.ID>
    ) -> Bool {
        var registry = load()
        guard let index = registry.profiles.firstIndex(where: { $0.id == id }),
              !registry.profiles[index].isDefault,
              boundWorkspaceIDs.isEmpty else {
            return false
        }
        // Archived Profiles are still deletable once no Workspace references them.
        registry.profiles.remove(at: index)
        save(registry)
        return true
    }
}
