import AppKit
import OSLog
import SwiftUI

#if DEBUG
private let prototypeDragLogger = Logger(subsystem: "com.local.WindowBoard.prototype", category: "drag")
#endif

/// Native lifecycle only. The SwiftUI view and pure fixture model own every mutation.
@MainActor
final class PrototypeDragPresentation: ObservableObject {
    @Published var payload: PrototypeDragPayload?
    @Published var target: PrototypeDropTarget?
    @Published var feedback = ""
    @Published var rejected = false

    func clear() {
        payload = nil
        target = nil
        feedback = ""
        rejected = false
    }
}

struct PrototypeDragSurface: NSViewRepresentable {
    static let boardType = NSPasteboard.PasteboardType("com.windowboard.prototype.board.v1")
    static let cardType = NSPasteboard.PasteboardType("com.windowboard.prototype.card.v1")
    let presentation: PrototypeDragPresentation
    var source: PrototypeDragKind?
    var title = ""
    var excludesCardButtons = false
    var click: () -> Void = {}
    var begin: (PrototypeDragKind) -> PrototypeDragPayload? = { _ in nil }
    var ended: () -> Void = {}
    var sourceEnded: (UUID) -> Void = { _ in }
    var destination: (CGPoint) -> PrototypeDropTarget? = { _ in nil }
    var accepts: (PrototypeDragPayload, PrototypeDropTarget) -> PrototypeDragResult = { _, _ in .rejected("Unsupported") }
    var feedback: (PrototypeDropTarget) -> String = { _ in "" }
    var commit: (PrototypeDragPayload, PrototypeDropTarget) -> PrototypeDragResult = { _, _ in .rejected("Unsupported") }
    var scrolls = false
    var reduceMotion = false

    func makeNSView(context: Context) -> NativeSurface { NativeSurface(configuration: self) }
    func updateNSView(_ view: NativeSurface, context: Context) {
        view.configuration = self
        view.setAccessibilityElement(source != nil)
        view.setAccessibilityLabel(title)
        if source != nil { view.setAccessibilityRole(.button) }
        if presentation.payload == nil { view.stopScrolling() }
        view.refreshOutline()
    }
    static func dismantleNSView(_ view: NativeSurface, coordinator: ()) { view.stopScrolling() }

    final class NativeSurface: NSView, NSDraggingSource {
        var configuration: PrototypeDragSurface
        private var downEvent: NSEvent?
        private var started = false
        private var timer: Timer?
        private var scrollDirection: CGFloat = 0
        private var enteredEdgeAt = Date.distantPast
        private var latestLocation = CGPoint.zero
        private var currentTarget: PrototypeDropTarget?
        private var sourceSessionToken: UUID?
        private let outline = CAShapeLayer()
        override var isFlipped: Bool { true }

        init(configuration: PrototypeDragSurface) {
            self.configuration = configuration
            super.init(frame: .zero)
            wantsLayer = true
            outline.fillColor = NSColor.clear.cgColor
            outline.lineWidth = 2
            outline.opacity = 0
            layer?.addSublayer(outline)
            registerForDraggedTypes([PrototypeDragSurface.boardType, PrototypeDragSurface.cardType])
        }
        required init?(coder: NSCoder) { return nil }
        override func accessibilityPerformPress() -> Bool {
            guard configuration.source != nil else { return false }
            configuration.click()
            return true
        }
        override func hitTest(_ point: NSPoint) -> NSView? {
            if NSApp.currentEvent?.type == .rightMouseDown || NSApp.currentEvent?.type == .rightMouseUp { return nil }
            let local = convert(point, from: superview)
            guard bounds.contains(local) else { return nil }
            if configuration.presentation.payload != nil { return self }
            guard configuration.source != nil else { return nil }
            if configuration.excludesCardButtons {
                let scale = bounds.width / 220
                // Keep the native menu and footer action clickable; the icon is deliberately draggable.
                if CGRect(x: 174 * scale, y: 0, width: 46 * scale, height: 38 * scale).contains(local)
                    || CGRect(x: 10 * scale, y: 270 * scale, width: 200 * scale, height: 38 * scale).contains(local) { return nil }
            }
            return self
        }
        override func mouseDown(with event: NSEvent) {
            downEvent = event
            started = false
        }
        override func mouseUp(with event: NSEvent) {
            if !started { configuration.click() }
            downEvent = nil
        }
        override func mouseDragged(with event: NSEvent) {
            guard !started, let downEvent, let kind = configuration.source,
                  hypot(event.locationInWindow.x - downEvent.locationInWindow.x,
                        event.locationInWindow.y - downEvent.locationInWindow.y) >= 4,
                  let payload = configuration.begin(kind), let data = try? JSONEncoder().encode(payload) else { return }
            started = true
#if DEBUG
            let kindLabel: String
            switch kind { case .board: kindLabel = "board"; case .card: kindLabel = "card" }
            prototypeDragLogger.debug("dragStarted kind=\(kindLabel, privacy: .public)")
#endif
            sourceSessionToken = payload.sessionToken
            configuration.presentation.payload = payload
            let item = NSPasteboardItem()
            let type: NSPasteboard.PasteboardType
            switch kind { case .board: type = PrototypeDragSurface.boardType; case .card: type = PrototypeDragSurface.cardType }
            item.setData(data, forType: type)
            let draggingItem = NSDraggingItem(pasteboardWriter: item)
            let image = NSImage(size: NSSize(width: 200, height: 42), flipped: false) { rect in
                NSColor.controlBackgroundColor.withAlphaComponent(0.85).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
                (self.configuration.title as NSString).draw(in: rect.insetBy(dx: 10, dy: 10), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor
                ])
                return true
            }
            let point = convert(event.locationInWindow, from: nil)
            draggingItem.setDraggingFrame(CGRect(x: point.x - 20, y: point.y - 20, width: 200, height: 42), contents: image)
            beginDraggingSession(with: [draggingItem], event: event, source: self)
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            return context == .withinApplication ? .move : []
        }
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
#if DEBUG
            prototypeDragLogger.debug("ended operation=\(operation.rawValue)")
#endif
            if let token = sourceSessionToken { finishSourceDrag(sessionToken: token) }
        }
        func finishSourceDrag(sessionToken: UUID) {
            guard configuration.presentation.payload?.sessionToken == sessionToken else { return }
            configuration.sourceEnded(sessionToken)
            configuration.ended()
            configuration.presentation.clear()
            sourceSessionToken = nil
            downEvent = nil
            currentTarget = nil
            refreshOutline()
            stopScrolling()
        }
        private func payload(_ sender: NSDraggingInfo) -> PrototypeDragPayload? {
            guard sender.draggingSource is NativeSurface,
                  sender.draggingPasteboard.pasteboardItems?.count == 1 else { return nil }
            for type in [PrototypeDragSurface.boardType, PrototypeDragSurface.cardType] {
                if let data = sender.draggingPasteboard.data(forType: type),
                   let value = try? JSONDecoder().decode(PrototypeDragPayload.self, from: data),
                   value == configuration.presentation.payload { return value }
            }
            return nil
        }
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
        override func draggingExited(_ sender: NSDraggingInfo?) {
            configuration.presentation.target = nil
            configuration.presentation.feedback = ""
            configuration.presentation.rejected = false
            currentTarget = nil
            refreshOutline()
            stopScrolling()
        }
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            outline.frame = bounds
            outline.path = CGPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 7, cornerHeight: 7, transform: nil)
            CATransaction.commit()
        }
        func refreshOutline() {
            let visible: Bool
            if let target = currentTarget, configuration.presentation.payload != nil,
               target == configuration.presentation.target {
                if case .card = target { visible = false } else { visible = true }
            } else { visible = false }
            let opacity: Float = visible ? 1 : 0
            let previous = outline.opacity
            let from = outline.presentation()?.opacity ?? previous
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            outline.strokeColor = (configuration.presentation.rejected ? NSColor.systemRed : NSColor.controlAccentColor).cgColor
            outline.opacity = opacity
            CATransaction.commit()
            if abs(previous - opacity) > 0.001 {
                let animation = CABasicAnimation(keyPath: "opacity")
                animation.fromValue = from
                animation.toValue = opacity
                animation.duration = PrototypeMotionEvent.dropHint.duration(reduceMotion: configuration.reduceMotion)
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                outline.add(animation, forKey: "dropHint")
            }
        }
        private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
            latestLocation = convert(sender.draggingLocation, from: nil)
            guard let payload = payload(sender), let target = configuration.destination(latestLocation) else {
                configuration.presentation.target = nil
                configuration.presentation.feedback = ""
                configuration.presentation.rejected = false
                currentTarget = nil
                refreshOutline()
                stopScrolling()
                return []
            }
            let result = configuration.accepts(payload, target)
            configuration.presentation.target = target
            currentTarget = target
            refreshOutline()
            switch result {
            case .rejected(let reason):
                configuration.presentation.feedback = reason
                configuration.presentation.rejected = true
            case .applied:
                configuration.presentation.feedback = configuration.feedback(target)
                configuration.presentation.rejected = false
            case .noChange:
                if case .board = payload.kind { configuration.presentation.feedback = "既に同じBoard / グループです。変更はありません。" }
                else { configuration.presentation.feedback = "同じ位置です。変更はありません。" }
                configuration.presentation.rejected = false
            }
            if configuration.scrolls { updateScrolling() }
            return configuration.presentation.rejected ? [] : .move
        }
        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { payload(sender) != nil }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            stopScrolling()
            guard let payload = payload(sender), let target = configuration.destination(convert(sender.draggingLocation, from: nil)) else {
#if DEBUG
                prototypeDragLogger.debug("performDrop result=rejected")
#endif
                return false
            }
            let result = configuration.commit(payload, target)
#if DEBUG
            let resultLabel: String
            switch result { case .applied: resultLabel = "applied"; case .noChange: resultLabel = "noChange"; case .rejected: resultLabel = "rejected" }
            prototypeDragLogger.debug("performDrop result=\(resultLabel, privacy: .public)")
#endif
            // The native source must remain mounted until AppKit ends its session.
            // Only the source callback releases the payload and the retained UI snapshot.
            configuration.presentation.target = nil
            configuration.presentation.feedback = ""
            configuration.presentation.rejected = false
            currentTarget = nil
            refreshOutline()
            if case .rejected = result { return false }
            return true
        }
        private func scrollCandidates() -> [NSScrollView] {
            guard let root = window?.contentView else { return [] }
            let pointer = convert(latestLocation, to: root)
            var candidates: [NSScrollView] = []
            func visit(_ view: NSView) {
                if let scroll = view as? NSScrollView, scroll.convert(scroll.bounds, to: root).contains(pointer) { candidates.append(scroll) }
                for child in view.subviews { visit(child) }
            }
            visit(root)
            return Array(candidates.reversed())
        }
        private func updateScrolling() {
            guard let scroll = scrollCandidates().first else { stopScrolling(); return }
            let clip = scroll.contentView
            let pointer = clip.convert(latestLocation, from: self)
            let direction: CGFloat = pointer.y < clip.bounds.minY + 32 ? -1 : (pointer.y > clip.bounds.maxY - 32 ? 1 : 0)
            if direction == 0 { stopScrolling(); return }
            if direction != scrollDirection { enteredEdgeAt = Date(); scrollDirection = direction }
            if timer == nil {
                let newTimer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scrollTick() }
                }
                timer = newTimer
                RunLoop.main.add(newTimer, forMode: .common)
            }
        }
        private func scrollTick() {
            guard let payload = configuration.presentation.payload, Date().timeIntervalSince(enteredEdgeAt) >= 0.3 else { return }
            for scroll in scrollCandidates() {
                guard let document = scroll.documentView else { continue }
                let clip = scroll.contentView
                let maxY = max(0, document.bounds.height - clip.bounds.height)
                let origin = clip.bounds.origin
                let nextY = min(maxY, max(0, origin.y + scrollDirection * 12))
                if abs(nextY - origin.y) < 0.1 { continue }
                clip.scroll(to: CGPoint(x: origin.x, y: nextY))
                scroll.reflectScrolledClipView(clip)
                break
            }
            // Scrolling updates SwiftUI geometry preferences; re-evaluate using the latest closure.
            if let target = configuration.destination(latestLocation) {
                currentTarget = target
                configuration.presentation.target = target
                let result = configuration.accepts(payload, target)
                if case let .rejected(reason) = result {
                    configuration.presentation.rejected = true
                    configuration.presentation.feedback = reason
                } else if result == .noChange {
                    configuration.presentation.rejected = false
                    configuration.presentation.feedback = "同じBoard / グループ / 位置です。変更はありません。"
                } else {
                    configuration.presentation.rejected = false
                    configuration.presentation.feedback = configuration.feedback(target)
                }
                refreshOutline()
            }
        }
        func stopScrolling() { timer?.invalidate(); timer = nil; scrollDirection = 0 }
    }
}

struct PrototypeCardFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}
