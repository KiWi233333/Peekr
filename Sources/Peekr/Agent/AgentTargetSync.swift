import Foundation

/// The native registry is authoritative: only targets created through this bridge
/// belong to an agent. UI selection, URLs and target-list ordering never imply ownership.
@MainActor
final class AgentTargetSync {
    private struct Binding {
        let workspaceID: UUID
        let tabID: UUID
    }
    private let model: AppModel
    private let transport: any AgentTargetTransport
    private var tracked: [String: Binding] = [:]
    private var timer: Timer?
    private var tickTask: Task<Void, Never>?
    private var busy = false
    private var operationRevision: UInt = 0
    private var stopped = false
    let tabLimit: Int
    var prepareNativeTab: ((UUID) -> Void)?
    var loadNativeTab: ((UUID, URL) -> Void)?
    var activateNativeTab: ((UUID, UUID) -> Void)?

    init(model: AppModel, port: Int, transport: (any AgentTargetTransport)? = nil, tabLimit: Int = 8) {
        self.model = model
        self.transport = transport ?? AgentCDPClient(port: port)
        self.tabLimit = max(1, tabLimit)
    }

    func start() {
        guard timer == nil else { return }
        stopped = false
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.tickTask == nil else { return }
                self.tickTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.tick()
                    self.tickTask = nil
                }
            }
        }
    }

    func stop() {
        stopped = true
        operationRevision &+= 1
        timer?.invalidate()
        timer = nil
        tickTask?.cancel()
        tickTask = nil
        tracked.removeAll()
    }

    func assertControl(_ id: UUID) throws {
        try Task.checkCancellation()
        guard !stopped else {
            throw AgentBridgeError(code: "PEEKR_SPACE_INACTIVE", message: "The native bridge stopped.")
        }
        guard let space = model.workspaces.first(where: { $0.id == id }) else {
            throw AgentBridgeError(code: "PEEKR_SPACE_INACTIVE", message: "Space no longer exists.")
        }
        guard space.ownership == .agent else {
            throw AgentBridgeError(code: "PEEKR_SPACE_USER_IN_CONTROL", message: "The user controls this space.")
        }
    }

    private func enter(_ id: UUID) throws {
        try assertControl(id)
        guard !busy else {
            throw AgentBridgeError(code: "PEEKR_BROWSER_BUSY", message: "A target operation is in flight.")
        }
        busy = true
        operationRevision &+= 1
    }

    private func isCurrent(_ binding: Binding) -> Bool {
        model.workspaces.first(where: { $0.id == binding.workspaceID })?
            .tabs.contains(where: { $0.id == binding.tabID }) == true
    }

    private func pruneTransferredTargets() {
        tracked = tracked.filter { isCurrent($0.value) || model.tab($0.value.tabID) == nil }
    }

    func tabs(in id: UUID) async throws -> [[String: Any]] {
        try enter(id)
        defer { busy = false }
        let targets = try await transport.targets()
        try assertControl(id)
        return targets.compactMap { target in
            guard let targetID = target["id"] as? String,
                let binding = tracked[targetID], binding.workspaceID == id,
                isCurrent(binding)
            else { return nil }
            return [
                "targetId": targetID, "tabId": binding.tabID.uuidString,
                "origin": "agent", "url": target["url"] as? String ?? "",
                "title": target["title"] as? String ?? "",
            ]
        }
    }

    func createTab(in id: UUID, url: String) async throws -> [String: Any] {
        try enter(id)
        defer { busy = false }
        pruneTransferredTargets()
        guard tracked.values.filter({ $0.workspaceID == id }).count < tabLimit else {
            throw AgentBridgeError(
                code: "PEEKR_TAB_LIMIT",
                message: "This space allows \(tabLimit) managed pages. Close a scratch page first.")
        }
        guard let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
            parsed.host != nil
        else {
            throw AgentBridgeError(code: "PEEKR_INVALID_ARGUMENT", message: "Tabs require an HTTP(S) URL.")
        }
        if prepareNativeTab != nil { return try await createNativeTab(in: id, url: parsed) }
        let result = try await transport.command("Target.createTarget", ["url": url])
        guard let targetID = result["targetId"] as? String else {
            throw AgentBridgeError(
                code: "PEEKR_ACTION_FAILED", message: "Creation returned no target ID; do not replay.")
        }
        do { try assertControl(id) } catch {
            _ = try? await transport.command("Target.closeTarget", ["targetId": targetID])
            throw error
        }
        guard let tab = model.addApp(title: url, urlString: url, toWorkspace: id) else {
            _ = try? await transport.command("Target.closeTarget", ["targetId": targetID])
            throw AgentBridgeError(code: "PEEKR_SPACE_INACTIVE", message: "Space closed during creation.")
        }
        tracked[targetID] = Binding(workspaceID: id, tabID: tab.id)
        return ["targetId": targetID, "tabId": tab.id.uuidString, "origin": "agent", "url": url, "title": ""]
    }

    private func createNativeTab(in id: UUID, url: URL) async throws -> [String: Any] {
        let markerID = "peekr-\(UUID().uuidString)"
        let marker = "data:text/html,%3Ctitle%3E\(markerID)%3C/title%3E"
        guard let tab = model.addApp(title: "", urlString: marker, toWorkspace: id) else {
            throw AgentBridgeError(code: "PEEKR_SPACE_INACTIVE", message: "Space closed.")
        }
        prepareNativeTab?(tab.id)
        do {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                let targets = try await transport.targets()
                try assertControl(id)
                guard isCurrent(Binding(workspaceID: id, tabID: tab.id)) else {
                    throw AgentBridgeError(
                        code: "PEEKR_TARGET_NOT_OWNED", message: "Native tab left the space during creation.")
                }
                if let targetID = targets.first(where: { $0["title"] as? String == markerID })?["id"] as? String {
                    tracked[targetID] = Binding(workspaceID: id, tabID: tab.id)
                    loadNativeTab?(tab.id, url)
                    return [
                        "targetId": targetID, "tabId": tab.id.uuidString, "origin": "agent", "url": url.absoluteString,
                        "title": "",
                    ]
                }
                try await Task.sleep(for: .milliseconds(50))
            } while Date() < deadline
            throw AgentBridgeError(code: "PEEKR_CDP_UNAVAILABLE", message: "Native page target did not become ready.")
        } catch {
            if isCurrent(Binding(workspaceID: id, tabID: tab.id)) { model.removeApp(tab.id) }
            throw error
        }
    }

    func closeTab(in id: UUID, targetID: String) async throws {
        try enter(id)
        defer { busy = false }
        try await closeManagedTarget(in: id, targetID: targetID)
    }

    private func closeManagedTarget(in id: UUID, targetID: String) async throws {
        try assertControl(id)
        guard let binding = tracked[targetID], binding.workspaceID == id, isCurrent(binding) else {
            throw AgentBridgeError(code: "PEEKR_TARGET_NOT_OWNED", message: "Target does not belong to this space.")
        }
        let result = try await transport.command("Target.closeTarget", ["targetId": targetID])
        guard result["success"] as? Bool == true else {
            throw AgentBridgeError(code: "PEEKR_ACTION_FAILED", message: "Target did not confirm close.")
        }
        tracked.removeValue(forKey: targetID)
        if isCurrent(binding) { model.removeApp(binding.tabID) }
    }

    func activateTab(in id: UUID, targetID: String) async throws {
        try enter(id)
        defer { busy = false }
        guard let binding = tracked[targetID], binding.workspaceID == id, isCurrent(binding) else {
            throw AgentBridgeError(code: "PEEKR_TARGET_NOT_OWNED", message: "Target does not belong to this space.")
        }
        _ = try await transport.command("Target.activateTarget", ["targetId": targetID])
        try assertControl(id)
        guard isCurrent(binding) else {
            throw AgentBridgeError(code: "PEEKR_TARGET_NOT_OWNED", message: "Tab left this space during activation.")
        }
        activateNativeTab?(id, binding.tabID)
    }

    /// Completion preserves every user/unmanaged tab. Kept agent tabs become user-owned.
    func finish(_ id: UUID, keep: [String]) async throws -> Bool {
        try enter(id)
        defer { busy = false }
        pruneTransferredTargets()
        let owned = Set(tracked.filter { $0.value.workspaceID == id }.map(\.key))
        guard Set(keep).isSubset(of: owned) else {
            throw AgentBridgeError(code: "PEEKR_TARGET_NOT_OWNED", message: "Unknown retained target.")
        }
        for target in owned.subtracting(keep).sorted() { try await closeManagedTarget(in: id, targetID: target) }
        try assertControl(id)
        let empty = model.workspaces.first(where: { $0.id == id })?.tabs.isEmpty == true
        if empty { model.removeWorkspace(id) } else { model.takeOverWorkspace(id) }
        for target in owned { tracked.removeValue(forKey: target) }
        return empty
    }

    /// A failed discovery request is not an empty browser: preserve tabs on transport failures.
    private func tick() async {
        guard !busy, !stopped else { return }
        let revision = operationRevision
        guard let targets = try? await transport.targets(), !Task.isCancelled,
            !busy, revision == operationRevision
        else { return }
        busy = true
        defer { busy = false }
        let liveIDs = Set(targets.compactMap { $0["id"] as? String })
        for (targetID, binding) in tracked {
            guard !stopped, !Task.isCancelled else { return }
            if model.tab(binding.tabID) != nil, !isCurrent(binding) {
                tracked.removeValue(forKey: targetID)
                continue
            }
            if model.tab(binding.tabID) == nil {
                if (try? await transport.command("Target.closeTarget", ["targetId": targetID])) != nil {
                    tracked.removeValue(forKey: targetID)
                }
            } else if !liveIDs.contains(targetID) {
                tracked.removeValue(forKey: targetID)
                model.removeApp(binding.tabID)
            }
        }
        for target in targets {
            guard let targetID = target["id"] as? String, let binding = tracked[targetID],
                isCurrent(binding), var app = model.tab(binding.tabID)
            else { continue }
            let previous = app
            if let url = target["url"] as? String, !url.isEmpty, url != "about:blank" { app.urlString = url }
            if let title = target["title"] as? String, !title.isEmpty {
                app.title = BadgeParser.strippingCount(fromTitle: title)
            }
            if app != previous { model.update(app) }
        }
    }

}
