import CCef
import Foundation

extension CefBrowser {
    /// Captures the browser's visible viewport without a remote debugging port.
    /// The result is the CDP method's JSON payload; callers should decode it off
    /// the CEF UI thread. Each request has its own observer and a short timeout.
    public func captureViewport(completion: @escaping (Data?) -> Void) {
        let request = CefViewportRequest(completion: completion)
        var hasHost = false
        withHostInternal { host in
            hasHost = true
            request.start(on: host)
        }
        if !hasHost { completion(nil) }
    }
}

@MainActor
private final class CefViewportRequest {
    private static var nextID = 10_000
    private let messageID: Int
    private var completion: ((Data?) -> Void)?
    private var registration: UnsafeMutablePointer<cef_registration_t>?
    private var timeout: Task<Void, Never>?

    init(completion: @escaping (Data?) -> Void) {
        self.completion = completion
        Self.nextID &+= 1
        messageID = Self.nextID
    }

    func start(on host: UnsafeMutablePointer<cef_browser_host_t>) {
        let observer = cefAllocate(cef_dev_tools_message_observer_t.self, owner: self)
        observer.pointee.on_dev_tools_message = { _, browser, _, _ in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            return 0
        }
        observer.pointee.on_dev_tools_method_result = { observerSelf, browser, id, success, result, size in
            defer { cefRelease(browser.map(UnsafeMutableRawPointer.init)) }
            guard let request = cefOwner(CefViewportRequest.self, observerSelf.map(UnsafeMutableRawPointer.init)) else { return }
            MainActor.assumeIsolated {
                guard id == request.messageID else { return }
                let data = success != 0 ? result.map { Data(bytes: $0, count: size) } : nil
                request.finish(data)
            }
        }
        observer.pointee.on_dev_tools_agent_detached = { observerSelf, browser in
            defer { cefRelease(browser.map(UnsafeMutableRawPointer.init)) }
            guard let request = cefOwner(CefViewportRequest.self, observerSelf.map(UnsafeMutableRawPointer.init)) else { return }
            MainActor.assumeIsolated { request.finish(nil) }
        }
        observer.pointee.on_dev_tools_event = { _, browser, _, _, _ in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
        }
        observer.pointee.on_dev_tools_agent_attached = { _, browser in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
        }
        registration = host.pointee.add_dev_tools_message_observer?(host, observer)
        // CEF takes the allocator's +1 reference when registration succeeds.
        // Releasing it here would leave the observer callbacks dangling.
        guard registration != nil else {
            cefRelease(UnsafeMutableRawPointer(observer))
            finish(nil)
            return
        }

        let message = Data(#"{"id":\#(messageID),"method":"Page.captureScreenshot","params":{"format":"jpeg","quality":55,"captureBeyondViewport":false}}"#.utf8)
        let sent = message.withUnsafeBytes { bytes in
            host.pointee.send_dev_tools_message?(host, bytes.baseAddress, bytes.count) ?? 0
        }
        guard sent != 0 else { finish(nil); return }
        timeout = Task { @MainActor [self] in
            try? await Task.sleep(for: .seconds(2))
            finish(nil)
        }
    }

    private func finish(_ data: Data?) {
        guard let completion else { return }
        self.completion = nil
        timeout?.cancel()
        timeout = nil
        let oldRegistration = registration
        registration = nil
        // Release registration after the observer callback has unwound.
        if let oldRegistration {
            DispatchQueue.main.async { cefRelease(UnsafeMutableRawPointer(oldRegistration)) }
        }
        completion(data)
    }
}
