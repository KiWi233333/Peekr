import AppKit
import SwiftUI

/// Installs an AppKit cursor rect over a SwiftUI control without changing its
/// hit testing. Cursor rects are preferable to `onHover` push/pop pairs here:
/// AppKit owns their lifetime and restores the previous cursor when the pointer
/// leaves the region or the window resigns key status.
struct PointerCursorRegion: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> PointerCursorNSView {
        PointerCursorNSView(cursor: cursor)
    }

    func updateNSView(_ nsView: PointerCursorNSView, context: Context) {
        nsView.cursor = cursor
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

final class PointerCursorNSView: NSView {
    var cursor: NSCursor

    init(cursor: NSCursor) {
        self.cursor = cursor
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Cursor-only regions must never intercept the SwiftUI control below.
        nil
    }
}

extension View {
    /// Shows a semantic AppKit cursor while preserving the view's normal input.
    func pointerCursor(_ cursor: NSCursor) -> some View {
        overlay {
            PointerCursorRegion(cursor: cursor)
                .allowsHitTesting(false)
        }
    }
}
