import AppKit
import SwiftUI

struct BoardClickObserver: NSViewRepresentable {
    var onClick: () -> Void

    func makeNSView(context: Context) -> ClickView {
        let view = ClickView(frame: .zero)
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: ClickView, context: Context) {
        nsView.onClick = onClick
    }

    final class ClickView: NSView {
        var onClick: (() -> Void)?

        override func mouseDown(with event: NSEvent) {
            onClick?()
            super.mouseDown(with: event)
        }
    }
}
