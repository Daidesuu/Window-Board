import AppKit
import SwiftUI

struct BoardWindowObserver: NSViewRepresentable {
    var onWindowAvailable: (NSWindow) -> Void
    var onOriginChanged: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onWindowAvailable: onWindowAvailable, onOriginChanged: onOriginChanged)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.attach(to: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.attach(to: nsView.window)
        }
    }

    final class Coordinator {
        private let onWindowAvailable: (NSWindow) -> Void
        private let onOriginChanged: (CGPoint) -> Void
        private weak var observedWindow: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private var lastReportedOrigin: CGPoint?
        private var lastReportDate = Date.distantPast
        private let minimumReportInterval: TimeInterval = 1.0 / 20.0

        init(onWindowAvailable: @escaping (NSWindow) -> Void, onOriginChanged: @escaping (CGPoint) -> Void) {
            self.onWindowAvailable = onWindowAvailable
            self.onOriginChanged = onOriginChanged
        }

        deinit {
            clearObservers()
        }

        func attach(to window: NSWindow?) {
            guard let window, observedWindow !== window else {
                return
            }

            clearObservers()
            observedWindow = window
            window.title = "Window Board"
            onWindowAvailable(window)
            reportOriginIfNeeded(window.frame.origin, force: true)

            let center = NotificationCenter.default
            let moved = center.addObserver(
                forName: NSWindow.didMoveNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                guard let window else { return }
                self?.reportOriginIfNeeded(window.frame.origin)
            }

            let resized = center.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                guard let window else { return }
                self?.reportOriginIfNeeded(window.frame.origin)
            }

            observers = [moved, resized]
        }

        private func clearObservers() {
            lastReportedOrigin = nil
            lastReportDate = .distantPast

            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers.removeAll()
        }

        private func reportOriginIfNeeded(_ origin: CGPoint, force: Bool = false) {
            let now = Date()
            if !force, now.timeIntervalSince(lastReportDate) < minimumReportInterval {
                return
            }

            if !force,
               let lastReportedOrigin,
               abs(lastReportedOrigin.x - origin.x) < 0.5,
               abs(lastReportedOrigin.y - origin.y) < 0.5 {
                return
            }

            lastReportedOrigin = origin
            lastReportDate = now
            onOriginChanged(origin)
        }

    }
}
