import SwiftUI

/// Floating glass omnibox: drag grip, back/forward/reload, address field.
struct NavigationBar: View {
    let state: BrowserState
    let manager: WebViewManager
    let settings: Settings

    var onMoveBegan: () -> Void
    var onMoveChanged: (CGSize) -> Void
    var onMoveEnded: () -> Void

    @State private var text = ""
    @State private var isDragging = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            grip
            navButton("chevron.backward", enabled: state.canGoBack) { manager.goBack() }
            navButton("chevron.forward", enabled: state.canGoForward) { manager.goForward() }
            navButton(state.isLoading ? "xmark" : "arrow.clockwise", enabled: true) { manager.reloadOrStop() }
            omnibox
            navButton("safari", enabled: !state.urlString.isEmpty) { openExternally() }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .liquidGlass(in: Capsule(style: .continuous), interactive: true)
        .overlay(alignment: .bottom) { progressLine }
        .onAppear { syncText() }
        .onChange(of: focused) { _, isFocused in
            text = isFocused ? state.urlString : state.displayURL
        }
        .onChange(of: state.urlString) { _, _ in if !focused { syncText() } }
        .onChange(of: state.focusOmniboxToken) { _, _ in focused = true }
    }

    // MARK: - Pieces

    private var grip: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.tertiary)
            .frame(width: 22, height: 28)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if !isDragging { isDragging = true; onMoveBegan() }
                        onMoveChanged(value.translation)
                    }
                    .onEnded { _ in isDragging = false; onMoveEnded() }
            )
            .help(settings.strings.dragHint)
    }

    private func navButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        .disabled(!enabled)
    }

    private var omnibox: some View {
        TextField(settings.strings.omniboxPlaceholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .lineLimit(1)
            .focused($focused)
            .onSubmit {
                manager.loadAddress(text)
                focused = false
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .frame(maxWidth: .infinity)
            .background(.black.opacity(0.06), in: Capsule())
    }

    @ViewBuilder
    private var progressLine: some View {
        if state.isLoading && state.progress > 0.01 && state.progress < 1 {
            GeometryReader { geo in
                Capsule()
                    .fill(Theme.accentGradient)
                    .frame(width: geo.size.width * state.progress, height: 2)
            }
            .frame(height: 2)
            .padding(.horizontal, 14)
            .offset(y: 1)
        }
    }

    // MARK: - Helpers

    private func syncText() {
        text = focused ? state.urlString : state.displayURL
    }

    private func openExternally() {
        guard let url = URL(string: state.urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
