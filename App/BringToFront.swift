import AppKit
import SwiftUI

extension View {
    /// Brings this view's window in front of other apps' windows when it first appears.
    /// A menu-bar-only app isn't activated on launch, so a window it opens by itself (setup on
    /// first run) would otherwise sit behind Finder.
    func bringsWindowToFrontOnAppear() -> some View {
        background(WindowFronter())
    }
}

private struct WindowFronter: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { FronterView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class FronterView: NSView {
        private var done = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !done else { return }
            done = true
            bringToFront(window)
            // SwiftUI finishes presenting the window after this; repeat once it has.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.bringToFront(window) }
        }

        private func bringToFront(_ window: NSWindow) {
            NSApp.activate()
            // Unlike activation, this isn't up to macOS: it orders the window above other
            // apps' windows even while this app isn't active.
            window.orderFrontRegardless()
            window.makeKey()
        }
    }
}
