import CCef
import Foundation
import Testing

@testable import CefKit

/// Fake backing for a `cef_cookie_manager_t` allocated with `cefAllocate`;
/// the C function pointers below recover it from the CEF `self` pointer.
private final class FakeCookieManager {
    var deleteCalls = 0
    var flushCalls = 0
    var deleteResult: Int32 = 1
    var flushResult: Int32 = 1
    var deletedCount: Int32 = 0
}

private func fakeDeleteCookies(
    _ manager: UnsafeMutablePointer<cef_cookie_manager_t>?,
    _ url: UnsafePointer<cef_string_t>?,
    _ cookieName: UnsafePointer<cef_string_t>?,
    _ callback: UnsafeMutablePointer<cef_delete_cookies_callback_t>?
) -> Int32 {
    guard
        let manager,
        let fake = cefOwner(FakeCookieManager.self, UnsafeMutableRawPointer(manager))
    else { return 0 }
    fake.deleteCalls += 1
    if let callback {
        if fake.deleteResult != 0 {
            callback.pointee.on_complete?(callback, fake.deletedCount)
        }
        cefRelease(UnsafeMutableRawPointer(callback))
    }
    return fake.deleteResult
}

private func fakeFlushStore(
    _ manager: UnsafeMutablePointer<cef_cookie_manager_t>?,
    _ callback: UnsafeMutablePointer<cef_completion_callback_t>?
) -> Int32 {
    guard
        let manager,
        let fake = cefOwner(FakeCookieManager.self, UnsafeMutableRawPointer(manager))
    else { return 0 }
    fake.flushCalls += 1
    if let callback {
        if fake.flushResult != 0 {
            callback.pointee.on_complete?(callback)
        }
        cefRelease(UnsafeMutableRawPointer(callback))
    }
    return fake.flushResult
}

private final class FakeRequestContext {
    var clearCalls = 0
}

private func fakeClearHTTPCache(
    _ context: UnsafeMutablePointer<cef_request_context_t>?,
    _ callback: UnsafeMutablePointer<cef_completion_callback_t>?
) {
    guard
        let context,
        let fake = cefOwner(FakeRequestContext.self, UnsafeMutableRawPointer(context))
    else { return }
    fake.clearCalls += 1
    if let callback {
        callback.pointee.on_complete?(callback)
        cefRelease(UnsafeMutableRawPointer(callback))
    }
}

// MARK: - Completion callbacks

struct CefCompletionCallbackTests {
    @Test func ownerIsReleasedWhenCEFNeverInvokes() {
        weak var weakOwner: CefCompletionCallback?
        do {
            let owner = CefCompletionCallback { Issue.record("completion must not run") }
            weakOwner = owner
            let callback = owner.makeCallback()
            // CEF abandons the operation without invoking on_complete and
            // releases the transferred reference.
            cefRelease(UnsafeMutableRawPointer(callback))
        }
        #expect(weakOwner == nil)
    }

    @MainActor
    @Test func completionRunsOnMainActorAndOwnerIsReleased() {
        weak var weakOwner: CefCompletionCallback?
        var ran = false
        do {
            let owner = CefCompletionCallback { ran = true }
            weakOwner = owner
            let callback = owner.makeCallback()
            callback.pointee.on_complete?(callback)
            cefRelease(UnsafeMutableRawPointer(callback))
        }
        #expect(ran)
        #expect(weakOwner == nil)
    }

    @MainActor
    @Test func deleteCookiesCallbackDeliversCount() {
        weak var weakOwner: CefDeleteCookiesCallback?
        var deleted: Int?
        do {
            let owner = CefDeleteCookiesCallback { deleted = $0 }
            weakOwner = owner
            let callback = owner.makeCallback()
            callback.pointee.on_complete?(callback, 12)
            cefRelease(UnsafeMutableRawPointer(callback))
        }
        #expect(deleted == 12)
        #expect(weakOwner == nil)
    }
}

// MARK: - Cookie manager

@MainActor
struct CefCookieManagerTests {
    private func makeManager(_ fake: FakeCookieManager) -> CefCookieManager {
        let raw = cefAllocate(cef_cookie_manager_t.self, owner: fake)
        raw.pointee.delete_cookies = fakeDeleteCookies
        raw.pointee.flush_store = fakeFlushStore
        return CefCookieManager(raw: raw)
    }

    @Test func deleteAllCookiesForwardsAndReportsCount() {
        let fake = FakeCookieManager()
        fake.deletedCount = 7
        let manager = makeManager(fake)

        var deleted: Int?
        #expect(manager.deleteAllCookies { deleted = $0 })
        #expect(fake.deleteCalls == 1)
        #expect(deleted == 7)
    }

    @Test func deleteAllCookiesReportsCEFFailure() {
        let fake = FakeCookieManager()
        fake.deleteResult = 0
        let manager = makeManager(fake)

        var completed = false
        #expect(!manager.deleteAllCookies { _ in completed = true })
        #expect(fake.deleteCalls == 1)
        #expect(!completed)
    }

    @Test func flushForwardsAndCompletes() {
        let fake = FakeCookieManager()
        let manager = makeManager(fake)

        var completed = false
        #expect(manager.flush { completed = true })
        #expect(fake.flushCalls == 1)
        #expect(completed)
    }

    @Test func flushReportsCEFFailure() {
        let fake = FakeCookieManager()
        fake.flushResult = 0
        let manager = makeManager(fake)

        var completed = false
        #expect(!manager.flush { completed = true })
        #expect(!completed)
    }

    @Test func managerReleasesItsReferenceOnDeinit() {
        weak var weakFake: FakeCookieManager?
        do {
            let fake = FakeCookieManager()
            weakFake = fake
            _ = makeManager(fake)
        }
        #expect(weakFake == nil)
    }
}

// MARK: - Request context cache

@MainActor
struct CefRequestContextCacheTests {
    @Test func clearHTTPCacheForwardsAndCompletes() {
        let fake = FakeRequestContext()
        let context = cefAllocate(cef_request_context_t.self, owner: fake)
        defer { cefRelease(UnsafeMutableRawPointer(context)) }
        context.pointee.clear_http_cache = fakeClearHTTPCache

        var completed = false
        context.clearHTTPCache { completed = true }
        #expect(fake.clearCalls == 1)
        #expect(completed)
    }

    @Test func clearHTTPCacheCompletesWhenCEFLacksTheFunction() {
        let context = cefAllocate(cef_request_context_t.self, owner: FakeRequestContext())
        defer { cefRelease(UnsafeMutableRawPointer(context)) }
        #expect(context.pointee.clear_http_cache == nil)

        var completed = false
        context.clearHTTPCache { completed = true }
        #expect(completed)
    }
}
