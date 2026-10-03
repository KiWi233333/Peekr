import Foundation

/// A persistent browsing identity shared by one or more Workspaces.
///
/// The UUID is the public identity, while `storageKey` is an immutable,
/// filesystem-safe implementation detail. Display names are intentionally not
/// used to derive storage paths, so renaming a Profile never moves its data.
struct BrowserProfile: Identifiable, Codable, Hashable {
    static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let defaultStorageKey = "Default"
    static let defaultName = "Default"

    let id: UUID
    var name: String
    let storageKey: String
    var isArchived: Bool
    let createdAt: Date
    var updatedAt: Date

    var isDefault: Bool { id == Self.defaultID }

    init(
        id: UUID = UUID(),
        name: String,
        storageKey: String? = nil,
        isArchived: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = Self.normalizedName(name)
        self.storageKey = Self.validatedStorageKey(storageKey)
            ?? Self.storageKey(for: id)
        self.isArchived = id == Self.defaultID ? false : isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static var defaultProfile: BrowserProfile {
        BrowserProfile(
            id: defaultID,
            name: defaultName,
            storageKey: defaultStorageKey
        )
    }

    static func storageKey(for id: UUID) -> String {
        if id == defaultID { return defaultStorageKey }
        return "Profile-" + id.uuidString.replacingOccurrences(of: "-", with: "")
    }

    /// Returns nil for values that could escape the Profile directory or are
    /// not stable filesystem components.
    static func validatedStorageKey(_ value: String?) -> String? {
        guard let value else { return nil }
        guard !value.isEmpty, value != ".", value != ".." else { return nil }
        guard value.unicodeScalars.allSatisfy({ scalar in
            scalar == "-" || scalar == "_" || scalar == "."
                || scalar.value == 0x2D
                || scalar.value == 0x5F
                || scalar.value == 0x2E
                || (scalar.value >= 0x30 && scalar.value <= 0x39)
                || (scalar.value >= 0x41 && scalar.value <= 0x5A)
                || (scalar.value >= 0x61 && scalar.value <= 0x7A)
        }) else { return nil }
        guard !value.hasPrefix(".") else { return nil }
        return value
    }

    static func normalizedName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Profile" : trimmed
    }

    func renamed(to value: String, at date: Date = Date()) -> BrowserProfile {
        var copy = self
        copy.name = Self.normalizedName(value)
        copy.updatedAt = date
        return copy
    }

    func archived(at date: Date = Date()) -> BrowserProfile {
        var copy = self
        copy.isArchived = true
        copy.updatedAt = date
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, storageKey, isArchived, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Profile"
        let storageKey = try container.decodeIfPresent(String.self, forKey: .storageKey)
        let isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        let createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        let updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        self.init(
            id: id,
            name: name,
            storageKey: storageKey,
            isArchived: isArchived,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

struct ProfileRegistry: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var profiles: [BrowserProfile]

    init(
        schemaVersion: Int = ProfileRegistry.currentSchemaVersion,
        profiles: [BrowserProfile] = [.defaultProfile]
    ) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        profiles = try container.decodeIfPresent([BrowserProfile].self, forKey: .profiles) ?? []
    }

    /// Repairs missing/duplicate profiles and guarantees one usable default.
    func normalized() -> ProfileRegistry {
        var seen = Set<BrowserProfile.ID>()
        var normalized: [BrowserProfile] = []
        normalized.append(.defaultProfile)
        seen.insert(BrowserProfile.defaultID)

        for profile in profiles where !seen.contains(profile.id) {
            var repaired = profile
            if repaired.id == BrowserProfile.defaultID { continue }
            if BrowserProfile.validatedStorageKey(repaired.storageKey) == nil {
                repaired = BrowserProfile(
                    id: repaired.id,
                    name: repaired.name,
                    storageKey: BrowserProfile.storageKey(for: repaired.id),
                    isArchived: repaired.isArchived,
                    createdAt: repaired.createdAt,
                    updatedAt: repaired.updatedAt
                )
            }
            normalized.append(repaired)
            seen.insert(repaired.id)
        }

        return ProfileRegistry(profiles: normalized)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, profiles
    }
}
