import Foundation

/// Mirrors agent-created Chromium pages into Peekr's model so the rail shows
/// what the agent is doing — the ego-lite property that the agent's tabs are
/// first-class browser citizens. While an agent space is active, page targets
/// appearing on the CDP endpoint that nobody tracks yet get bound to (or added
/// as) tabs of that space; targets that disappear remove their rail tab, and
/// rail tabs the user deleted close their Chromium target. Both layers stay
/// one browser.
///
/// Identity is CDP `targetId` ↔ `WebApp.id`, kept in memory only: target ids
/// do not survive a relaunch, and every launch re-seeds the mapping from the
/// first `/json/list` snapshot (everything already on screen at tick one is
/// treated as app-owned).
extension Notification.Name {
    /// Posted by `WebViewManager` when it builds an engine for a tab — the one
    /// moment a CDP target is guaranteed to appear for that known tab.
    static let peekrTabEngineActivated = Notification.Name("peekrTabEngineActivated")
}

@MainActor
final class AgentTargetSync {
    private let model: AppModel
    private let port: Int
    private var timer: Timer?
    private var tracked: [String: UUID] = [:]
    private var seen: Set<String> = []
    /// Rail tabs whose engine (and therefore CDP target) is about to appear,
    /// in creation order — the deterministic binding queue.
    private var pendingBindings: [UUID] = []
    private var engineObserver: NSObjectProtocol?
    private var tickTask: Task<Void, Never>?

    init(model: AppModel, port: Int) {
        self.model = model
        self.port = port
    }

    func start() {
        guard timer == nil else { return }
        engineObserver = NotificationCenter.default.addObserver(
            forName: .peekrTabEngineActivated, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let tabID = note.userInfo?["tabID"] as? UUID else { return }
            MainActor.assumeIsolated { self.pendingBindings.append(tabID) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.tickTask?.cancel()
            self.tickTask = Task { @MainActor [weak self] in
                await self?.tick()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        tickTask?.cancel()
        tickTask = nil
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = nil
        pendingBindings.removeAll()
        tracked.removeAll()
        seen.removeAll()
    }

    // MARK: - Tick

    private func tick() async {
        let targets = (try? await fetchTargets()) ?? []
        let liveIDs = Set(targets.map(\.targetId))

        // Rail tabs the user deleted → close their Chromium target.
        for (targetId, tabID) in tracked where model.tab(tabID) == nil {
            tracked.removeValue(forKey: targetId)
            closeTarget(targetId)
        }
        // Chromium targets that disappeared → remove their rail tab.
        for (targetId, tabID) in tracked where !liveIDs.contains(targetId) {
            tracked.removeValue(forKey: targetId)
            if model.tab(tabID) != nil { model.removeApp(tabID) }
        }
        // New targets: while an agent space is active they belong to it —
        // bind to an existing untracked tab when one matches, else add.
        let agentActive = model.activeWorkspace.isAgentOwned
        for target in targets where !seen.contains(target.targetId) {
            seen.insert(target.targetId)
            if agentActive { bindOrAdd(target) }
        }
        // Tracked tabs follow the agent's navigation (title + URL).
        for target in targets {
            guard let tabID = tracked[target.targetId], var app = model.tab(tabID) else { continue }
            var changed = false
            let title = target.title ?? ""
            if !title.isEmpty, title != app.title {
                app.title = BadgeParser.strippingCount(fromTitle: title)
                changed = true
            }
            if let url = target.url, url != "about:blank", url != app.urlString {
                app.urlString = url
                changed = true
            }
            if changed { model.update(app) }
        }
    }

    private func bindOrAdd(_ target: TargetSnapshot) {
        let workspace = model.activeWorkspace
        let trackedTabIDs = Set(tracked.values)

        // 1) The app just created this tab's engine — bind by expectation.
        while !pendingBindings.isEmpty {
            let pendingID = pendingBindings.removeFirst()
            guard model.tab(pendingID) != nil,
                  !trackedTabIDs.contains(pendingID),
                  workspace.tabs.contains(where: { $0.id == pendingID }) else { continue }
            tracked[target.targetId] = pendingID
            adopt(target, into: pendingID)
            return
        }
        // 2) Engine recreation (backend switch): same page, fresh target id.
        if let match = workspace.tabs.first(where: {
            !trackedTabIDs.contains($0.id) && Self.samePage($0.urlString, target.url ?? "")
        }) {
            tracked[target.targetId] = match.id
            adopt(target, into: match.id)
            return
        }
        // 3) A genuinely new agent page → mirror it into the rail.
        if let app = model.addApp(
            title: target.title ?? target.url ?? "New Tab",
            urlString: target.url ?? "about:blank",
            toWorkspace: workspace.id
        ) {
            tracked[target.targetId] = app.id
        }
    }

    private func adopt(_ target: TargetSnapshot, into tabID: UUID) {
        guard var app = model.tab(tabID) else { return }
        var changed = false
        if let title = target.title, !title.isEmpty, title != app.title {
            app.title = BadgeParser.strippingCount(fromTitle: title)
            changed = true
        }
        if let url = target.url, url != "about:blank", url != app.urlString {
            app.urlString = url
            changed = true
        }
        if changed { model.update(app) }
    }

    /// Page identity: exact URL, tolerating a trailing slash. Redirected
    /// start pages are absorbed by the single-untracked-tab fallback instead
    /// of URL heuristics, which would mis-bind sibling tabs on one site.
    static func samePage(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a == b + "/" || b == a + "/"
    }

    // MARK: - CDP access

    private struct TargetSnapshot: Decodable {
        let targetId: String
        let type: String
        let title: String?
        let url: String?

        init(targetId: String, type: String, title: String?, url: String?) {
            self.targetId = targetId
            self.type = type
            self.title = title
            self.url = url
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // The HTTP endpoint names the id field `id` (CLI cdp.ts normalizes
            // the same quirk).
            targetId = try container.decode(String.self, forKey: .id)
            type = try container.decode(String.self, forKey: .type)
            title = try? container.decodeIfPresent(String.self, forKey: .title)
            url = try? container.decodeIfPresent(String.self, forKey: .url)
        }

        enum CodingKeys: String, CodingKey { case id, type, title, url }
    }

    private func fetchTargets() async throws -> [TargetSnapshot] {
        let url = URL(string: "http://127.0.0.1:\(port)/json/list")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let all = try JSONDecoder().decode([TargetSnapshot].self, from: data)
        return all.filter { target in
            guard target.type == "page" else { return false }
            guard let raw = target.url else { return false }
            return !raw.hasPrefix("devtools://") && !raw.hasPrefix("chrome://")
        }
    }

    /// Close one Chromium target. Close is rare, so each call opens a short
    /// browser-level socket instead of keeping one alive for the app lifetime.
    private func closeTarget(_ targetId: String) {
        Task { [port] in
            guard
                let versionURL = URL(string: "http://127.0.0.1:\(port)/json/version"),
                let (data, _) = try? await URLSession.shared.data(from: versionURL),
                let version = try? JSONDecoder().decode(BrowserVersion.self, from: data),
                let wsURL = URL(string: version.webSocketDebuggerUrl)
            else { return }
            let socket = URLSession.shared.webSocketTask(with: wsURL)
            socket.resume()
            let payload = """
            {"id":1,"method":"Target.closeTarget","params":{"targetId":"\(targetId)"}}
            """
            try? await socket.send(.string(payload))
            try? await Task.sleep(for: .milliseconds(300))
            socket.cancel(with: .normalClosure, reason: nil)
        }
    }

    private struct BrowserVersion: Decodable {
        let webSocketDebuggerUrl: String
    }
}
