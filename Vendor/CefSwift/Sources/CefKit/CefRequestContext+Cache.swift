import CCef

extension UnsafeMutablePointer where Pointee == cef_request_context_t {
    /// Clears this context's HTTP cache. The context reference stays owned by
    /// the caller; the completion callback transfers to CEF.
    func clearHTTPCache(completion: @escaping () -> Void) {
        guard let clear = pointee.clear_http_cache else {
            completion()
            return
        }
        clear(self, CefCompletionCallback(completion).makeCallback())
    }
}
