import CCef

/// Swift owner behind a `cef_delete_cookies_callback_t`.
///
/// Ownership follows ``CefCompletionCallback``: the struct carries one
/// reference from ``makeCallback()``, that reference transfers to CEF at the
/// `delete_cookies` call, and CEF releases the struct after `on_complete` (or
/// when the operation is abandoned).
final class CefDeleteCookiesCallback: @unchecked Sendable {
    private let completion: (Int) -> Void

    init(_ completion: @escaping (Int) -> Void) {
        self.completion = completion
    }

    func makeCallback() -> UnsafeMutablePointer<cef_delete_cookies_callback_t> {
        let callback = cefAllocate(cef_delete_cookies_callback_t.self, owner: self)
        callback.pointee.on_complete = { callbackSelf, numDeleted in
            guard
                let owner = cefOwner(
                    CefDeleteCookiesCallback.self,
                    callbackSelf.map(UnsafeMutableRawPointer.init))
            else { return }
            let completion = owner.completion
            MainActor.assumeIsolated { completion(Int(numDeleted)) }
        }
        return callback
    }
}
