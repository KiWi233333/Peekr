import AppKit
import CryptoKit
import Observation

/// Loads, caches and persists website icons. Automatic favicons are shared by
/// normalized domain in memory and on disk; user overrides remain per app.
@MainActor
@Observable
final class IconStore {
    typealias DomainIconResolver = (_ host: String, _ declaredLinks: [URL]) async -> NSImage?

    /// Per-app images are reserved for user overrides and legacy cache migration.
    private var images: [UUID: NSImage] = [:]
    private var domainImages: [String: NSImage] = [:]
    /// Runtime host currently shown by each tab. The configured `WebApp.host`
    /// remains its launch URL; this map lets the rail follow live navigation
    /// without persisting transient redirects or OAuth callback URLs.
    private var pageHosts: [UUID: String] = [:]
    /// One generation token per domain coalesces concurrent loads. A forced
    /// refresh replaces the token, so an older request can never overwrite it.
    private var domainLoadTokens: [String: UUID] = [:]
    /// The first live-DOM settle upgrades the add-time icon once per domain.
    private var liveIconHosts = Set<String>()
    private let dir: URL
    private let domainDir: URL
    private let domainResolver: DomainIconResolver

    init(
        directory: URL = AppPaths.iconsDirectory,
        resolver: DomainIconResolver? = nil
    ) {
        dir = directory
        domainDir = directory.appendingPathComponent("domains", isDirectory: true)
        domainResolver = resolver ?? { host, links in
            await IconStore.bestIcon(host: host, declaredLinks: links)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: domainDir, withIntermediateDirectories: true)
    }

    /// Reading this in a SwiftUI body registers observation, so tiles update
    /// the moment an icon finishes loading.
    func image(for app: WebApp) -> NSImage? {
        if app.usesCustomIcon, let custom = images[app.id] { return custom }
        let host = pageHosts[app.id] ?? Self.normalizedHost(app.host)
        return host.flatMap { domainImages[$0] }
    }

    /// Shared entry point for URL-bearing UI that has no `WebApp`, such as
    /// omnibox suggestions.
    func image(forHost host: String) -> NSImage? {
        Self.normalizedHost(host).flatMap { domainImages[$0] }
    }

    func warm(_ apps: [WebApp]) {
        for app in apps { load(app) }
    }

    func load(_ app: WebApp) {
        if app.usesCustomIcon {
            if images[app.id] != nil { return }
            if let custom = NSImage(contentsOf: fileURL(app.id)) {
                images[app.id] = custom
                return
            }
        }
        guard let host = Self.normalizedHost(app.host),
              !loadDomainFromDisk(host, legacyID: app.id) else { return }
        fetchFavicon(app)
    }

    func load(host rawHost: String) {
        guard let host = Self.normalizedHost(rawHost),
              !loadDomainFromDisk(host) else { return }
        resolveIcon(host: host, force: false) { [] }
    }

    /// Force a fresh favicon fetch (e.g. after the URL changes).
    func refreshFavicon(_ app: WebApp) {
        guard !app.usesCustomIcon else { return }
        fetchFavicon(app, force: true)
    }

    /// Point the rail at the host the engine is displaying as soon as its URL
    /// changes. Only an existing memory/disk entry is loaded here: the settled
    /// live-DOM pass below performs the network refresh, so redirect chains do
    /// not fan out favicon requests.
    func followNavigation(_ app: WebApp, pageURL: URL?) {
        guard !app.usesCustomIcon,
              let host = Self.normalizedHost(pageURL?.displayHost ?? app.host)
        else { return }
        if pageHosts[app.id] != host { pageHosts[app.id] = host }
        _ = loadDomainFromDisk(host)
    }

    func discardNavigation(for id: WebApp.ID) {
        pageHosts[id] = nil
    }

    /// Live favicon sync once a tab settles, driven by the icon `<link>`s the
    /// engine read from the rendered DOM (so JS-injected icons are caught).
    /// Runs once per domain — within-site navigation, sibling tabs and progress
    /// ticks never refetch — while the first real settle can still replace the
    /// add-time placeholder. Custom icons are left untouched.
    func syncFavicon(_ app: WebApp, pageURL: URL?, domLinks: [URL]) {
        followNavigation(app, pageURL: pageURL)
        guard !app.usesCustomIcon,
              let host = Self.normalizedHost(pageURL?.displayHost ?? app.host),
              liveIconHosts.insert(host).inserted else { return }
        resolveIcon(host: host, force: true) { domLinks }
    }

    /// Re-fetches both the favicon and the page `<title>` from one page load.
    /// `onTitle` fires on the main actor only when a non-empty title is found;
    /// the icon is skipped for apps using a custom image.
    func refresh(_ app: WebApp, onTitle: @escaping (String) -> Void) {
        guard let host = Self.normalizedHost(app.host) else { return }
        let pageURL = app.url ?? URL(string: "https://\(host)")
        let skipIcon = app.usesCustomIcon
        let token = skipIcon ? nil : reserveDomainLoad(host: host, force: true)
        let resolver = domainResolver
        Task { [weak self] in
            let doc = await Self.pageDocument(pageURL)
            if let doc, let title = Self.pageTitle(in: doc.html) { onTitle(title) }
            guard let self, let token else { return }
            let links = doc.map { Self.iconLinks(in: $0.html, base: $0.base) } ?? []
            let image = await resolver(host, links)
            self.writeIcon(host: host, image: image, token: token)
        }
    }

    func setCustomIcon(_ app: WebApp, from url: URL) -> Bool {
        guard let image = NSImage(contentsOf: url),
              let data = image.pngData() else { return false }
        try? data.write(to: fileURL(app.id), options: .atomic)
        images[app.id] = image
        return true
    }

    /// Persist an already-loaded image (e.g. one fetched from the icon library)
    /// as this app's custom icon.
    @discardableResult
    func setCustomIcon(_ app: WebApp, image: NSImage) -> Bool {
        guard let data = image.pngData() else { return false }
        try? data.write(to: fileURL(app.id), options: .atomic)
        images[app.id] = image
        return true
    }

    /// Fetches a monochrome brand glyph from the simple-icons CDN and rasterizes
    /// it to a crisp 128px image. `slug` is the simple-icons brand slug
    /// (e.g. "github", "youtube"); returns nil when the brand isn't in the set.
    nonisolated static func libraryIcon(slug: String) async -> NSImage? {
        let clean = slug.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty,
              let url = URL(string: "https://cdn.simpleicons.org/\(clean)"),
              let data = await fetch(url),
              let svg = NSImage(data: data) else { return nil }
        let side = 128
        svg.size = NSSize(width: side, height: side)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        svg.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: NSSize(width: side, height: side))
        out.addRepresentation(rep)
        return out
    }

    func clearCustomIcon(_ app: WebApp) {
        try? FileManager.default.removeItem(at: fileURL(app.id))
        images[app.id] = nil
        load(app)
    }

    // MARK: - Private

    private func fileURL(_ id: UUID) -> URL {
        dir.appendingPathComponent("\(id.uuidString).png")
    }

    private func domainFileURL(_ host: String) -> URL {
        let digest = SHA256.hash(data: Data(host.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return domainDir.appendingPathComponent("\(digest).png")
    }

    @discardableResult
    private func loadDomainFromDisk(_ host: String, legacyID: UUID? = nil) -> Bool {
        if domainImages[host] != nil { return true }
        let destination = domainFileURL(host)
        if let disk = NSImage(contentsOf: destination) {
            domainImages[host] = disk
            return true
        }
        guard let legacyID else { return false }
        let legacy = fileURL(legacyID)
        guard let disk = NSImage(contentsOf: legacy) else { return false }
        domainImages[host] = disk
        try? FileManager.default.copyItem(at: legacy, to: destination)
        return true
    }

    private func fetchFavicon(_ app: WebApp, force: Bool = false) {
        guard let host = Self.normalizedHost(app.host) else { return }
        // Prefer the app's real URL (keeps scheme/path) so we can parse the
        // actual page; synthesize an https page URL when only a host is known.
        let pageURL = app.url ?? URL(string: "https://\(host)")
        resolveIcon(host: host, force: force) {
            await Self.pageDocument(pageURL)
                .map { Self.iconLinks(in: $0.html, base: $0.base) } ?? []
        }
    }

    private func resolveIcon(
        host: String,
        force: Bool,
        links: @escaping () async -> [URL]
    ) {
        guard let token = reserveDomainLoad(host: host, force: force) else { return }
        let resolver = domainResolver
        Task { [weak self] in
            let image = await resolver(host, await links())
            self?.writeIcon(host: host, image: image, token: token)
        }
    }

    private func reserveDomainLoad(host: String, force: Bool) -> UUID? {
        if !force, domainImages[host] != nil || domainLoadTokens[host] != nil { return nil }
        let token = UUID()
        domainLoadTokens[host] = token
        return token
    }

    /// Publishes only the newest request for a domain, then persists one shared
    /// PNG. Failed requests clear their token so a later appearance can retry.
    private func writeIcon(host: String, image: NSImage?, token: UUID) {
        guard domainLoadTokens[host] == token else { return }
        domainLoadTokens[host] = nil
        guard let image, let data = image.pngData() else { return }
        try? data.write(to: domainFileURL(host), options: .atomic)
        domainImages[host] = image
    }

    /// The favicon-service URL for a host — the same source the resolver falls
    /// back to. Kept as a normalized URL builder for integrations outside the
    /// shared cache.
    nonisolated static func faviconURL(host: String, size: Int = 64) -> URL? {
        guard let host = normalizedHost(host) else { return nil }
        return URL(string: "https://www.google.com/s2/favicons?sz=\(size)&domain=\(host)")
    }

    nonisolated static func normalizedHost(_ rawHost: String?) -> String? {
        guard var host = rawHost?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.isEmpty ? nil : host
    }

    // MARK: - Favicon resolution

    /// Resolution thresholds: stop early once we have something this crisp,
    /// and reject anything obviously too small to be a real icon.
    nonisolated private static let goodEnoughDimension: CGFloat = 128
    nonisolated private static let minDimension: CGFloat = 1

    /// Gathers icon candidates from the page's own `<link>` tags plus a set of
    /// well-known fallback endpoints, then returns the highest-resolution image
    /// that actually downloads and decodes. Runs off the main actor.
    nonisolated private static func bestIcon(host: String, declaredLinks: [URL]) async -> NSImage? {
        var candidates: [URL] = declaredLinks

        let origin = "https://\(host)"
        let fallbacks = [
            "\(origin)/apple-touch-icon.png",
            "\(origin)/apple-touch-icon-precomposed.png",
            "https://icons.duckduckgo.com/ip3/\(host).ico",
            "https://www.google.com/s2/favicons?sz=128&domain=\(host)",
            "\(origin)/favicon.ico",
        ].compactMap(URL.init(string:))
        candidates += fallbacks

        // De-dupe while preserving the (quality-ranked) order.
        var seen = Set<String>()
        candidates = candidates.filter { seen.insert($0.absoluteString).inserted }

        var best: NSImage?
        var bestDimension: CGFloat = 0
        for url in candidates {
            guard let data = await fetch(url),
                  let image = NSImage(data: data), image.size.width > minDimension
            else { continue }
            let dimension = max(image.size.width, image.size.height)
            if dimension > bestDimension {
                best = image
                bestDimension = dimension
            }
            if bestDimension >= goodEnoughDimension { break }
        }
        return best
    }

    /// Fetches and decodes a page's HTML once, so both icon links and the title
    /// can be parsed from a single request. `base` is used to resolve relative
    /// icon hrefs.
    nonisolated private static func pageDocument(_ url: URL?) async -> (html: String, base: URL)? {
        guard let url, let data = await fetch(url),
              let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        else { return nil }
        return (html, url)
    }

    /// Parses `<link rel="...icon...">` tags from the page `<head>`, resolving
    /// relative hrefs against `base` and ranking by declared `sizes`
    /// (apple-touch-icons, which are typically high-res, get a quality boost).
    nonisolated private static func iconLinks(in html: String, base: URL) -> [URL] {
        // Icons are declared in <head>; scanning only that keeps it cheap.
        let head: String
        if let end = html.range(of: "</head>", options: .caseInsensitive) {
            head = String(html[..<end.lowerBound])
        } else {
            head = html
        }

        guard let linkRegex = try? NSRegularExpression(
            pattern: "<link\\b[^>]*>", options: [.caseInsensitive]) else { return [] }
        let ns = head as NSString
        var ranked: [(url: URL, rank: Int)] = []
        for match in linkRegex.matches(in: head, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range)
            guard let rel = attribute("rel", in: tag)?.lowercased(), rel.contains("icon"),
                  let href = attribute("href", in: tag),
                  let url = URL(string: href, relativeTo: base)?.absoluteURL
            else { continue }
            let declared = attribute("sizes", in: tag)
                .flatMap { $0.lowercased().split(separator: "x").first }
                .flatMap { Int($0) } ?? 0
            // apple-touch-icons rarely declare sizes but are usually 180px+.
            let rank = max(declared, rel.contains("apple-touch") ? 180 : 0)
            ranked.append((url, rank))
        }
        return ranked.sorted { $0.rank > $1.rank }.map(\.url)
    }

    /// Extracts and cleans up the page `<title>`; nil when empty or absent.
    nonisolated private static func pageTitle(in html: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "<title[^>]*>([\\s\\S]*?)</title>", options: [.caseInsensitive]) else { return nil }
        let ns = html as NSString
        guard let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        let raw = ns.substring(with: match.range(at: 1))
        let collapsed = raw.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression)
        let title = decodeHTMLEntities(collapsed).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    /// Decodes the handful of HTML entities that show up in page titles
    /// (named common ones plus decimal/hex numeric references).
    nonisolated private static func decodeHTMLEntities(_ string: String) -> String {
        guard string.contains("&") else { return string }
        var result = string
        let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                     "&apos;": "'", "&#39;": "'", "&nbsp;": " ", "&mdash;": "—",
                     "&ndash;": "–", "&hellip;": "…"]
        for (entity, char) in named {
            result = result.replacingOccurrences(of: entity, with: char, options: .caseInsensitive)
        }
        guard result.contains("&#"),
              let regex = try? NSRegularExpression(pattern: "&#(x?[0-9a-fA-F]+);")
        else { return result }
        let ns = result as NSString
        for match in regex.matches(in: result, range: NSRange(location: 0, length: ns.length)).reversed() {
            let token = ns.substring(with: match.range(at: 1))
            let code = token.lowercased().hasPrefix("x")
                ? UInt32(token.dropFirst(), radix: 16)
                : UInt32(token, radix: 10)
            if let code, let scalar = Unicode.Scalar(code) {
                result = (result as NSString).replacingCharacters(in: match.range, with: String(scalar))
            }
        }
        return result
    }

    /// Extracts a quoted HTML attribute value from a single tag string.
    nonisolated private static func attribute(_ name: String, in tag: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "\\b\(name)\\s*=\\s*[\"']([^\"']*)[\"']", options: [.caseInsensitive])
        else { return nil }
        let ns = tag as NSString
        guard let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    /// Downloads `url` with a browser-like User-Agent (some servers 403 the
    /// default), returning the body only on a 2xx response.
    nonisolated private static func fetch(_ url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 Peekr",
            forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        return data
    }
}

private extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
