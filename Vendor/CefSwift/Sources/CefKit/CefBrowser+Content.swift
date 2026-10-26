import CCef
import Foundation

extension CefBrowser {
    /// Prints the current page using Chromium's print flow.
    public func print() {
        withHostInternal { $0.pointee.print?($0) }
    }

    /// Downloads a URL through the browser's request context and download handler.
    public func startDownload(_ url: URL) {
        withHostInternal { host in
            CefStringUtil.withCefString(url.absoluteString) { value in
                host.pointee.start_download?(host, value)
            }
        }
    }

    /// Resolves an image through the browser's cache and request context, then
    /// returns a lossless PNG suitable for the native clipboard.
    public func downloadImage(_ url: URL, completion: @escaping (Data?) -> Void) {
        let callback = CefImageDownloadCallback(completion: completion)
        var hasHost = false
        withHostInternal { host in
            hasHost = true
            CefStringUtil.withCefString(url.absoluteString) { value in
                host.pointee.download_image?(host, value, 0, 0, 0, callback.makeCallback())
            }
        }
        if !hasHost { completion(nil) }
    }
}

@MainActor
private final class CefImageDownloadCallback {
    private let completion: (Data?) -> Void

    init(completion: @escaping (Data?) -> Void) {
        self.completion = completion
    }

    func makeCallback() -> UnsafeMutablePointer<cef_download_image_callback_t> {
        let callback = cefAllocate(cef_download_image_callback_t.self, owner: self)
        callback.pointee.on_download_image_finished = { callbackSelf, _, _, image in
            guard let owner = cefOwner(CefImageDownloadCallback.self, callbackSelf.map(UnsafeMutableRawPointer.init)) else {
                cefRelease(image.map(UnsafeMutableRawPointer.init))
                return
            }
            let data = image.flatMap(CefImageDownloadCallback.pngData(from:))
            cefRelease(image.map(UnsafeMutableRawPointer.init))
            MainActor.assumeIsolated { owner.completion(data) }
        }
        return callback
    }

    private static func pngData(from image: UnsafeMutablePointer<cef_image_t>) -> Data? {
        var width: Int32 = 0
        var height: Int32 = 0
        guard let binary = image.pointee.get_as_png?(image, 1, 1, &width, &height) else { return nil }
        defer { cefRelease(UnsafeMutableRawPointer(binary)) }
        let size = binary.pointee.get_size?(binary) ?? 0
        guard size > 0, let bytes = binary.pointee.get_raw_data?(binary) else { return nil }
        return Data(bytes: bytes, count: size)
    }
}
