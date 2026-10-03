import AppKit
import ImageIO
import Observation

/// Keeps one small, recent preview per workspace. Only the foreground CEF page
/// is captured; background pages retain their last usable image or tab metadata.
@MainActor
@Observable
final class WorkspacePreviewService {
    private(set) var previews: [UUID: NSImage] = [:]

    private struct PreviewSource: Equatable {
        let tabID: UUID
        let url: String
    }

    @ObservationIgnored private var previewSources: [UUID: PreviewSource] = [:]
    @ObservationIgnored private var captureTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    func start(model: AppModel, manager: WebViewManager) {
        stop()
        let previous = captureTask
        let validSources = Dictionary(uniqueKeysWithValues: model.workspaces.compactMap { workspace -> (UUID, PreviewSource)? in
            guard let tabID = workspace.selectedTabID ?? workspace.orderedTabIDs.first else { return nil }
            let liveURL = (manager.view(for: tabID) as? CefSwiftBrowserHostView)?
                .engine?.navState.url?.absoluteString
            let source = PreviewSource(tabID: tabID, url: liveURL ?? model.tab(tabID)?.urlString ?? "")
            return (workspace.id, source)
        })
        previews = previews.filter { id, _ in previewSources[id] == validSources[id] }
        previewSources = previewSources.filter { id, source in validSources[id] == source }
        let token = generation
        captureTask = Task { @MainActor [weak self] in
            // A rapid close/reopen waits for the former CEF request to settle;
            // the browser never has overlapping screenshot requests from us.
            await previous?.value
            await self?.captureCurrentWorkspace(model: model, manager: manager, token: token)
        }
    }

    func stop() {
        generation &+= 1
    }

    private func captureCurrentWorkspace(model: AppModel, manager: WebViewManager, token: Int) async {
        guard let workspace = model.workspaces.first(where: { $0.id == model.activeWorkspaceID }),
              let tabID = workspace.selectedTabID ?? workspace.orderedTabIDs.first,
              let host = manager.view(for: tabID) as? CefSwiftBrowserHostView,
              let engine = host.engine else { return }
        let source = PreviewSource(tabID: tabID, url: engine.navState.url?.absoluteString ?? "")

        // The first request runs before the overview hides the web layer.
        // Two bounded retries cover a page that has not painted yet, with no
        // permanent polling or background-browser wakeups.
        for attempt in 0..<3 {
            guard generation == token else { return }
            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(attempt == 1 ? 250 : 700))
            }
            guard generation == token else { return }
            guard let payload = await engine.captureViewport() else { continue }
            let thumbnail = await Task.detached(priority: .utility) {
                Self.thumbnail(from: payload)
            }.value
            guard generation == token else { return }
            guard let thumbnail else { continue }
            // A workspace can be switched while the CEF request is in flight.
            guard model.workspaces.first(where: { $0.id == workspace.id })?.selectedTabID == tabID,
                  (engine.navState.url?.absoluteString ?? "") == source.url else { return }
            previews[workspace.id] = NSImage(cgImage: thumbnail, size: CGSize(width: thumbnail.width, height: thumbnail.height))
            previewSources[workspace.id] = source
            return
        }
    }

    nonisolated private static func thumbnail(from payload: Data) -> CGImage? {
        guard let result = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let encoded = result["data"] as? String,
              let jpeg = Data(base64Encoded: encoded),
              let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 480,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary),
              image.width > 1, image.height > 1 else { return nil }
        let targetAspect = 440.0 / 224.0
        let cropWidth = min(image.width, Int(Double(image.height) * targetAspect))
        let cropHeight = min(image.height, Int(Double(image.width) / targetAspect))
        guard let cropped = image.cropping(to: CGRect(x: 0, y: 0, width: cropWidth, height: cropHeight)),
              isUsable(cropped) else { return nil }
        return cropped
    }

    /// Sampling the final thumbnail catches transparent/blank captures without
    /// decoding a second full-resolution image on the main thread.
    nonisolated private static func isUsable(_ image: CGImage) -> Bool {
        let width = 32, height = 18
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return false }
        var darkest = 1.0
        var brightest = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            guard pixels[index + 3] > 8 else { continue }
            let luminance = (0.2126 * Double(pixels[index])
                + 0.7152 * Double(pixels[index + 1])
                + 0.0722 * Double(pixels[index + 2])) / 255
            darkest = min(darkest, luminance)
            brightest = max(brightest, luminance)
        }
        return brightest - darkest >= 0.01 || darkest < 0.985
    }
}
