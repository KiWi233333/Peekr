import SwiftUI

/// Native `peekr://clear-data` page. Time-range filters only apply to data
/// Peekr owns; CEF can only delete every cookie and clear the whole cache, so
/// those two options are presented as all-or-nothing.
struct ClearDataPageView: View {
    let cleaner: BrowsingDataCleaner
    let settings: Settings
    let onClose: () -> Void

    @State private var selection = BrowsingDataSelection()
    @State private var isClearing = false
    @State private var didClear = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var loc: Localized { settings.strings }

    private enum Layout {
        static let horizontalPadding: CGFloat = 20
        static let contentMaxWidth: CGFloat = 760
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
                .overlay(Theme.hairline)
                .padding(.horizontal, Layout.horizontalPadding)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(loc.clearDataDescription)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    optionsCard

                    Text(loc.clearDataCookiesAlways)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    footer
                        .padding(.top, 2)
                }
                .frame(maxWidth: Layout.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Layout.horizontalPadding)
                .padding(.vertical, 16)
            }
        }
        .frame(maxWidth: Layout.contentMaxWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: Theme.webCardCorner, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.webCardCorner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.webCardCorner, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
        .onChange(of: selection) { _, _ in didClear = false }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(loc.clearBrowsingData)
                .font(.system(size: 20, weight: .semibold))
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 8)

            Button(action: onClose) {
                Label(loc.close, systemImage: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.primary.opacity(0.06), in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.8))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .help(loc.close)
            .accessibilityLabel(loc.close)
            .fixedSize()
        }
        .frame(maxWidth: Layout.contentMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Layout.horizontalPadding)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    // MARK: - Options

    private var optionsCard: some View {
        VStack(spacing: 0) {
            optionRow(
                loc.clearHistoryOption,
                symbol: "clock",
                isOn: binding(\.history)
            )
            optionDivider
            optionRow(
                loc.clearDownloadsOption,
                symbol: "arrow.down.circle",
                isOn: binding(\.downloads)
            )
            optionDivider
            optionRow(
                loc.clearCookiesOption,
                symbol: "circle.grid.cross",
                isOn: binding(\.cookies)
            )
            optionDivider
            optionRow(
                loc.clearCacheOption,
                symbol: "externaldrive",
                isOn: binding(\.cache)
            )
            optionDivider
            optionRow(
                loc.clearPermissionsOption,
                symbol: "hand.raised",
                isOn: binding(\.permissions)
            )
            optionDivider
            optionRow(
                loc.clearZoomOption,
                symbol: "textformat.size",
                isOn: binding(\.zoom)
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(
            .primary.opacity(0.055),
            in: RoundedRectangle(cornerRadius: Theme.popoverRowCorner, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.popoverRowCorner, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.8)
        )
        .disabled(isClearing)
    }

    private var optionDivider: some View {
        Divider()
            .overlay(Theme.hairline.opacity(0.7))
            .padding(.leading, 25)
    }

    private func optionRow(
        _ title: String,
        symbol: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 12.5))
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(.vertical, 8)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Group {
                if isClearing {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text(loc.clearDataWorking)
                    }
                } else if didClear {
                    Label(loc.clearDataDone, systemImage: "checkmark.circle.fill")
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .transition(reduceMotion ? .identity : .opacity)

            Spacer(minLength: 12)

            Button(action: clear) {
                Text(loc.clearDataButton)
                    .font(.system(size: 12.5, weight: .medium))
                    .padding(.horizontal, 14)
                    .frame(height: 28)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(selection.isEmpty || isClearing)
            .help(loc.clearDataButton)
            .accessibilityLabel(loc.clearDataButton)
        }
        .animation(reduceMotion ? nil : Motion.controlFeedback, value: isClearing)
        .animation(reduceMotion ? nil : Motion.controlFeedback, value: didClear)
    }

    // MARK: - Actions

    private func binding(_ keyPath: WritableKeyPath<BrowsingDataSelection, Bool>) -> Binding<Bool> {
        Binding(
            get: { selection[keyPath: keyPath] },
            set: { selection[keyPath: keyPath] = $0 }
        )
    }

    private func clear() {
        guard !selection.isEmpty, !isClearing else { return }
        isClearing = true
        didClear = false
        cleaner.clear(selection) {
            isClearing = false
            didClear = true
        }
    }
}
