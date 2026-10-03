import AppKit
import XCTest
@testable import Peekr

@MainActor
final class IconStoreTests: XCTestCase {
    func testDomainCacheCoalescesConcurrentLoadsAndPersistsAcrossApps() async throws {
        URLProtocol.registerClass(IconDocumentProtocol.self)
        defer { URLProtocol.unregisterClass(IconDocumentProtocol.self) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeekrIconStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(IconStore.normalizedHost(" WWW.Example.COM. "), "example.com")

        let resolvedIcon = makeImage(color: .systemBlue)
        let counter = ResolverCounter()
        let store = IconStore(directory: directory) { _, _ in
            await counter.resolve(resolvedIcon)
        }
        let first = WebApp(title: "First", urlString: "https://www.icons.peekr-icon.test/one")
        let second = WebApp(title: "Second", urlString: "https://icons.peekr-icon.test/two")

        store.load(first)
        store.load(second)

        let loaded = await waitUntil {
            store.image(for: first) != nil && store.image(for: second) != nil
        }
        XCTAssertTrue(loaded)
        XCTAssertTrue(store.image(for: first) === store.image(for: second))
        let initialResolveCount = await counter.count
        XCTAssertEqual(initialResolveCount, 1)

        let diskCounter = ResolverCounter()
        let relaunchedStore = IconStore(directory: directory) { _, _ in
            await diskCounter.resolve(resolvedIcon)
        }
        let relaunchedTab = WebApp(title: "Relaunched", urlString: "https://icons.peekr-icon.test/three")
        relaunchedStore.load(relaunchedTab)

        XCTAssertNotNil(relaunchedStore.image(for: relaunchedTab))
        let diskResolveCount = await diskCounter.count
        XCTAssertEqual(diskResolveCount, 0)

        let customIcon = makeImage(color: .systemPink)
        let customTab = WebApp(
            title: "Custom",
            urlString: "https://icons.peekr-icon.test/custom",
            usesCustomIcon: true
        )
        XCTAssertTrue(store.setCustomIcon(customTab, image: customIcon))
        XCTAssertTrue(store.image(for: customTab) === customIcon)
        XCTAssertTrue(store.image(for: first) === resolvedIcon)

        store.clearCustomIcon(customTab)
        XCTAssertTrue(store.image(for: customTab) === resolvedIcon)
    }

    func testRailIconFollowsLiveNavigationHostWithoutShowingPreviousSite() async throws {
        URLProtocol.registerClass(IconDocumentProtocol.self)
        defer { URLProtocol.unregisterClass(IconDocumentProtocol.self) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeekrIconStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let googleIcon = makeImage(color: .systemBlue)
        let xIcon = makeImage(color: .black)
        let store = IconStore(directory: directory) { host, _ in
            host == "x.peekr-icon.test" ? xIcon : googleIcon
        }
        let tab = WebApp(title: "Google", urlString: "https://google.peekr-icon.test")

        store.load(tab)
        let loadedGoogle = await waitUntil { store.image(for: tab) === googleIcon }
        XCTAssertTrue(loadedGoogle)

        let destination = try XCTUnwrap(URL(string: "https://x.peekr-icon.test/home"))
        store.followNavigation(tab, pageURL: destination)

        XCTAssertNil(store.image(for: tab), "The previous host's icon must disappear immediately")

        store.syncFavicon(tab, pageURL: destination, domLinks: [])
        let loadedX = await waitUntil { store.image(for: tab) === xIcon }
        XCTAssertTrue(loadedX)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    private func makeImage(color: NSColor) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }
}

private actor ResolverCounter {
    private(set) var count = 0

    func resolve(_ image: NSImage) async -> NSImage {
        count += 1
        try? await Task.sleep(nanoseconds: 40_000_000)
        return image
    }
}

/// Keep the real load/coalescing path while making its page HTML deterministic.
/// Only this suite's reserved hosts are intercepted; no production network code changes.
private final class IconDocumentProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".peekr-icon.test") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200,
                                             httpVersion: nil, headerFields: ["Content-Type": "text/html"])
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("<html><head></head><body></body></html>".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
