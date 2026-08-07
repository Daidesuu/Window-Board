import Carbon
import Foundation
import OSLog

private let quickLauncherHotKeyLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "WindowBoard",
    category: "QuickLauncherHotKey"
)
private let quickLauncherHotKeySignature: OSType = 0x57424C52 // WBLR

private func quickLauncherHotKeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else {
        return OSStatus(eventNotHandledErr)
    }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == quickLauncherHotKeySignature else {
        return OSStatus(eventNotHandledErr)
    }

    let controller = Unmanaged<GlobalHotKeyController>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async {
        controller.performAction()
    }
    return noErr
}

@MainActor
final class GlobalHotKeyController {
    private let action: () -> Void
    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?

    init(action: @escaping () -> Void) {
        self.action = action
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    @discardableResult
    func registerDefaultShortcut() -> Bool {
        unregister()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            quickLauncherHotKeyEventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        guard handlerStatus == noErr else {
            quickLauncherHotKeyLogger.error("event handler registration failed status=\(handlerStatus, privacy: .public)")
            return false
        }

        let identifier = EventHotKeyID(signature: quickLauncherHotKeySignature, id: 1)
        let registrationStatus = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(cmdKey | shiftKey),
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registrationStatus == noErr else {
            quickLauncherHotKeyLogger.error("shortcut registration failed status=\(registrationStatus, privacy: .public)")
            if let eventHandlerRef {
                RemoveEventHandler(eventHandlerRef)
                self.eventHandlerRef = nil
            }
            return false
        }

        quickLauncherHotKeyLogger.debug("registered Command-Shift-Space")
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    fileprivate func performAction() {
        action()
    }
}
