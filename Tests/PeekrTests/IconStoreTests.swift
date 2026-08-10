import AppKit
import XCTest
@testable import Peekr

@MainActor
final class IconStoreTests: XCTestCase {
    func testDomainCacheCoalescesConcurrentLoadsAndPersistsAcrossApps() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeekrIconStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(IconStore.normalizedHost(" WWW.Example.COM. "), "example.com")

        let resolvedIcon = makeImage(color: .systemBlue)
        let counter = ResolverCounter()
        let store = IconStore(directory: directory) { _, _ in
            await counter.resolve(resolvedIcon)
        }
        let first = WebApp(title: "First", urlString: "https://www.example.com/one")
        let second = WebApp(title: "Second", urlString: "https://example.com/two")

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
        let relaunchedTab = WebApp(title: "Relaunched", urlString: "https://example.com/three")
        relaunchedStore.load(relaunchedTab)

        XCTAssertNotNil(relaunchedStore.image(for: relaunchedTab))
        let diskResolveCount = await diskCounter.count
        XCTAssertEqual(diskResolveCount, 0)

        let customIcon = makeImage(color: .systemPink)
        let customTab = WebApp(
            title: "Custom",
            urlString: "https://example.com/custom",
            usesCustomIcon: true
        )
        XCTAssertTrue(store.setCustomIcon(customTab, image: customIcon))
        XCTAssertTrue(store.image(for: customTab) === customIcon)
        XCTAssertTrue(store.image(for: first) === resolvedIcon)

        store.clearCustomIcon(customTab)
        XCTAssertTrue(store.image(for: customTab) === resolvedIcon)
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
