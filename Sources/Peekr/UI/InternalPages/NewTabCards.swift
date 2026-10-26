import SwiftUI

struct NewTabBookmarkCard: View {
    let node: BookmarkNode
    let icons: IconStore
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if node.isFolder {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Color(red: 0.35, green: 0.61, blue: 0.91))
                        .frame(width: 24, height: 24)
                } else {
                    NewTabFavicon(
                        icons: icons,
                        host: Self.host(for: node.urlString),
                        title: node.title,
                        size: 23
                    )
                }
                Text(node.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.86))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .liquidGlass(
                in: RoundedRectangle(cornerRadius: 14, style: .continuous),
                interactive: true
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .scaleEffect(hovering ? 1.01 : 1)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : Motion.controlFeedback, value: hovering)
        .help(node.title)
        .accessibilityLabel(node.title)
        .accessibilityHint(node.isFolder ? node.title : (node.urlString ?? ""))
    }

    private static func host(for urlString: String?) -> String? {
        guard let urlString else { return nil }
        return URL(string: urlString)?.displayHost
    }
}

struct NewTabRecentCard: View {
    let entry: HistoryEntry
    let icons: IconStore
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var host: String { URL(string: entry.urlString)?.displayHost ?? entry.urlString }
    private var title: String {
        let value = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? host : value
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 9) {
                    NewTabFavicon(icons: icons, host: host, title: title, size: 24)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(host)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text(title)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)

                Text(host)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .liquidGlass(
                in: RoundedRectangle(cornerRadius: 18, style: .continuous),
                interactive: true
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .offset(y: hovering ? -2 : 0)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : Motion.controlFeedback, value: hovering)
        .help(title)
        .accessibilityLabel("\(title), \(host)")
    }
}

struct NewTabFavicon: View {
    let icons: IconStore
    let host: String?
    let title: String
    let size: CGFloat

    private var corner: CGFloat { max(4, size * 0.26) }
    private var monogram: String {
        if let first = title.trimmingCharacters(in: .whitespacesAndNewlines).first {
            return String(first).uppercased()
        }
        if let first = host?.first { return String(first).uppercased() }
        return "•"
    }

    var body: some View {
        Group {
            if let host, let image = icons.image(forHost: host) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Text(monogram)
                    .font(.system(size: size * 0.42, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.7))
                    .frame(width: size, height: size)
                    .background(
                        .primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: corner, style: .continuous)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .accessibilityHidden(true)
        .task(id: host) {
            guard let host else { return }
            icons.load(host: host)
        }
    }
}
