import Foundation
import Observation

/// What makes the open panel auto-hide (when not pinned).
enum AutoHideMode: String, Codable, CaseIterable, Identifiable {
    /// Hide once the panel loses keyboard focus — i.e. you click another app or
    /// window. The default: lets you read the panel freely until you move on.
    case focusLoss
    /// Hide as soon as the cursor leaves the panel's frame.
    case mouseLeave
    var id: String { rawValue }
}

/// User-facing auto-hide policy. This intentionally adapts the existing
/// `autoHide` + `autoHideMode` persistence fields so upgrades keep their saved
/// behavior without a settings-file migration.
enum AutoHidePolicy: String, CaseIterable, Identifiable {
    case off
    case focusLoss
    case mouseLeave

    var id: String { rawValue }

    init(autoHide: Bool, mode: AutoHideMode) {
        guard autoHide else {
            self = .off
            return
        }
        self = mode == .focusLoss ? .focusLoss : .mouseLeave
    }

    var storedValues: (autoHide: Bool, mode: AutoHideMode) {
        switch self {
        case .off:
            return (false, .focusLoss)
        case .focusLoss:
            return (true, .focusLoss)
        case .mouseLeave:
            return (true, .mouseLeave)
        }
    }
}

/// How often to re-import bookmarks from the browsers already imported.
enum BookmarkSyncInterval: String, Codable, CaseIterable, Identifiable {
    case off, hourly, daily
    var id: String { rawValue }

    /// Repeat interval in seconds, or nil when disabled.
    var seconds: TimeInterval? {
        switch self {
        case .off: return nil
        case .hourly: return 3600
        case .daily: return 86_400
        }
    }
}

/// Codable snapshot of all preferences — drives persistence + change detection.
/// `panelWidth`/`panelHeight` of 0 mean "auto" (a ratio of the screen).
struct SettingsData: Codable, Equatable {
    var anchor: PanelAnchor = .right
    var panelWidth: Double = 0
    var panelHeight: Double = 0
    var hoverDelay: Double = 0.12
    var edgeThreshold: Double = 3
    var hotKey: HotKeyConfig = .default
    var launchAtLogin: Bool = false
    var followCursor: Bool = true
    var lastScreenNumber: Int? = nil
    var autoHide: Bool = true
    var autoHideMode: AutoHideMode = .focusLoss
    var language: AppLanguage = .system
    var bookmarkSync: BookmarkSyncInterval = .off
    var webEngine: WebEngineKind = .system

    init() {}

    // Decode tolerantly so the schema can evolve without losing the file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) .flatMap { $0 } ?? fallback
        }
        anchor = v(.anchor, .right)
        panelWidth = v(.panelWidth, 0)
        panelHeight = v(.panelHeight, 0)
        hoverDelay = v(.hoverDelay, 0.12)
        edgeThreshold = v(.edgeThreshold, 3)
        hotKey = v(.hotKey, .default)
        launchAtLogin = v(.launchAtLogin, false)
        followCursor = v(.followCursor, true)
        lastScreenNumber = (try? c.decodeIfPresent(Int.self, forKey: .lastScreenNumber)) ?? nil
        autoHide = v(.autoHide, true)
        autoHideMode = v(.autoHideMode, .focusLoss)
        language = v(.language, .system)
        bookmarkSync = v(.bookmarkSync, .off)
        webEngine = v(.webEngine, .system)
    }
}

/// Observable, persisted preferences. UI binds to the fields; `snapshot`
/// gives a single Equatable value to watch with `.onChange` for saving.
@MainActor
@Observable
final class Settings {
    var anchor: PanelAnchor
    var panelWidth: Double
    var panelHeight: Double
    var hoverDelay: Double
    var edgeThreshold: Double
    var hotKey: HotKeyConfig
    var launchAtLogin: Bool
    var followCursor: Bool
    var lastScreenNumber: Int?
    var autoHide: Bool
    var autoHideMode: AutoHideMode
    var language: AppLanguage
    var bookmarkSync: BookmarkSyncInterval
    var webEngine: WebEngineKind

    private let store: SettingsStore

    init(store: SettingsStore) {
        self.store = store
        let d = store.load()
        anchor = d.anchor
        panelWidth = d.panelWidth
        panelHeight = d.panelHeight
        hoverDelay = d.hoverDelay
        edgeThreshold = d.edgeThreshold
        hotKey = d.hotKey
        launchAtLogin = d.launchAtLogin
        followCursor = d.followCursor
        lastScreenNumber = d.lastScreenNumber
        autoHide = d.autoHide
        autoHideMode = d.autoHideMode
        language = d.language
        bookmarkSync = d.bookmarkSync
        webEngine = d.webEngine
    }

    var snapshot: SettingsData {
        var s = SettingsData()
        s.anchor = anchor; s.panelWidth = panelWidth; s.panelHeight = panelHeight
        s.hoverDelay = hoverDelay; s.edgeThreshold = edgeThreshold; s.hotKey = hotKey
        s.launchAtLogin = launchAtLogin; s.followCursor = followCursor
        s.lastScreenNumber = lastScreenNumber; s.autoHide = autoHide
        s.autoHideMode = autoHideMode; s.language = language
        s.bookmarkSync = bookmarkSync; s.webEngine = webEngine
        return s
    }

    /// Two-language string table reflecting the current language preference.
    var strings: Localized { Localized(isChinese: language.resolved == .chinese) }

    var autoHidePolicy: AutoHidePolicy {
        get { AutoHidePolicy(autoHide: autoHide, mode: autoHideMode) }
        set {
            let stored = newValue.storedValues
            autoHide = stored.autoHide
            autoHideMode = stored.mode
        }
    }

    func persist() {
        store.save(snapshot)
    }
}
