import AppKit
import SwiftUI

enum ProfileAvatarStore {
    static func image(
        for profile: BrowserProfile,
        chromeRoot: URL = ChromeCookieImporter.chromeRoot
    ) -> NSImage? {
        guard !profile.isIncognito else { return nil }
        let candidates = ChromeCookieImporter.discoverProfiles(in: chromeRoot)
        let match = candidates.first { candidate in
            if profile.isDefault { return candidate.id == "Default" }
            return candidate.name.caseInsensitiveCompare(profile.name) == .orderedSame
        } ?? (profile.isDefault ? candidates.first : nil)
        guard let match else { return nil }
        for name in ["Google Profile Picture.png", "Profile Picture.png"] {
            let url = match.directoryURL.appendingPathComponent(name)
            if let image = NSImage(contentsOf: url) { return image }
        }
        return nil
    }

    static func thumbnail(from source: NSImage, size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let scale = max(rect.width / source.size.width, rect.height / source.size.height)
            let scaledSize = NSSize(
                width: source.size.width * scale,
                height: source.size.height * scale
            )
            let drawRect = NSRect(
                x: rect.midX - scaledSize.width / 2,
                y: rect.midY - scaledSize.height / 2,
                width: scaledSize.width,
                height: scaledSize.height
            )
            NSGraphicsContext.current?.imageInterpolation = .high
            NSBezierPath(ovalIn: rect).addClip()
            source.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
    }
}

struct ProfileAvatarView: View {
    let profile: BrowserProfile
    let size: CGFloat

    @State private var image: NSImage?

    private var fallback: String {
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "P" : String(name.prefix(1)).uppercased()
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
            } else {
                Text(fallback)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.primary.opacity(0.08))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.primary.opacity(0.1), lineWidth: 0.7))
        .accessibilityLabel(profile.name)
        .task(id: profile.id) {
            image = ProfileAvatarStore.image(for: profile)
                .map { ProfileAvatarStore.thumbnail(from: $0, size: size) }
        }
    }
}
