import CCef

/// Swift owner behind a `cef_completion_callback_t` passed to CEF for
/// asynchronous operations (cookie flush, HTTP cache clear, …).
///
/// Ownership: ``makeCallback()`` returns a struct with one reference. Passing
/// it to a CEF API transfers that reference, and CEF releases the struct after
/// invoking `on_complete` (or when it abandons the operation), which releases
/// this owner and its closure — the callback must not release it again.
final class CefCompletionCallback: @unchecked Sendable {
    private let completion: () -> Void

    init(_ completion: @escaping () -> Void) {
        self.completion = completion
    }

    func makeCallback() -> UnsafeMutablePointer<cef_completion_callback_t> {
        let callback = cefAllocate(cef_completion_callback_t.self, owner: self)
        callback.pointee.on_complete = { callbackSelf in
            guard
                let owner = cefOwner(
                    CefCompletionCallback.self,
                    callbackSelf.map(UnsafeMutableRawPointer.init))
            else { return }
            let completion = owner.completion
            MainActor.assumeIsolated { completion() }
        }
        return callback
    }
}
