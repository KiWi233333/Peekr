import Foundation
import Observation

/// Codable snapshot of all preferences — drives persistence + change detection.
struct SettingsData: Codable, Equatable {
    var anchor: PanelAnchor = .right
    var panelWidth: Double = 440
    var hoverDelay: Double = 0.12
    var edgeThreshold: Double = 3
    var hotKey: HotKeyConfig = .default
    var launchAtLogin: Bool = false
    var followCursor: Bool = true
    var lastScreenNumber: Int? = nil
    var autoHide: Bool = true
}

/// Observable, persisted preferences. UI binds to the fields; `snapshot`
/// gives a single Equatable value to watch with `.onChange` for saving.
@MainActor
@Observable
final class Settings {
    var anchor: PanelAnchor
    var panelWidth: Double
    var hoverDelay: Double
    var edgeThreshold: Double
    var hotKey: HotKeyConfig
    var launchAtLogin: Bool
    var followCursor: Bool
    var lastScreenNumber: Int?
    var autoHide: Bool

    private let store: SettingsStore

    init(store: SettingsStore) {
        self.store = store
        let d = store.load()
        anchor = d.anchor
        panelWidth = d.panelWidth
        hoverDelay = d.hoverDelay
        edgeThreshold = d.edgeThreshold
        hotKey = d.hotKey
        launchAtLogin = d.launchAtLogin
        followCursor = d.followCursor
        lastScreenNumber = d.lastScreenNumber
        autoHide = d.autoHide
    }

    var snapshot: SettingsData {
        SettingsData(
            anchor: anchor, panelWidth: panelWidth, hoverDelay: hoverDelay,
            edgeThreshold: edgeThreshold, hotKey: hotKey, launchAtLogin: launchAtLogin,
            followCursor: followCursor, lastScreenNumber: lastScreenNumber, autoHide: autoHide
        )
    }

    func persist() {
        store.save(snapshot)
    }
}
