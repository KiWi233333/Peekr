import CCef

/// A refcounted wrapper around `cef_cookie_manager_t`.
///
/// Delete/flush callbacks run on the main actor after CEF finishes the
/// operation. Both methods return CEF's result flag; `false` means the
/// operation was rejected and the completion will never run.
@MainActor
public final class CefCookieManager {
    /// Owned +1 `cef_cookie_manager_t` reference. `nonisolated(unsafe)` so the
    /// nonisolated deinit can release it.
    nonisolated(unsafe) private let raw: UnsafeMutablePointer<cef_cookie_manager_t>

    /// Takes ownership of a +1 CEF cookie manager reference.
    init(raw: UnsafeMutablePointer<cef_cookie_manager_t>) {
        self.raw = raw
    }

    deinit {
        cefRelease(UnsafeMutableRawPointer(raw))
    }

    /// The runtime-wide cookie manager used by the global request context.
    /// Requires an initialized ``CefRuntime``.
    ///
    /// Reached through the global request context because CEF's own C API
    /// documents the two as equivalent and CefSwift's loader has no trampoline
    /// for `cef_cookie_manager_get_global_manager`.
    public static func global() -> CefCookieManager? {
        guard let context = cef_request_context_get_global_context() else { return nil }
        defer { cefRelease(UnsafeMutableRawPointer(context)) }
        guard let manager = context.pointee.get_cookie_manager?(context, nil) else { return nil }
        return CefCookieManager(raw: manager)
    }

    /// Deletes every cookie. `completion` receives the number of cookies CEF
    /// removed.
    public func deleteAllCookies(completion: @escaping (Int) -> Void) -> Bool {
        guard let delete = raw.pointee.delete_cookies else { return false }
        let callback = CefDeleteCookiesCallback(completion)
        return delete(raw, nil, nil, callback.makeCallback()) != 0
    }

    /// Flushes the cookie store to disk.
    public func flush(completion: @escaping () -> Void) -> Bool {
        guard let flush = raw.pointee.flush_store else { return false }
        let callback = CefCompletionCallback(completion)
        return flush(raw, callback.makeCallback()) != 0
    }
}
