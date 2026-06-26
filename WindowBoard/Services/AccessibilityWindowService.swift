import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum WindowBoardAXError: LocalizedError {
    case missingPosition
    case missingSize
    case operationFailed(String, AXError)

    var errorDescription: String? {
        switch self {
        case .missingPosition:
            return "Window position is not available."
        case .missingSize:
            return "Window size is not available."
        case let .operationFailed(operation, error):
            return "\(operation) failed: \(error)"
        }
    }
}

final class AccessibilityWindowService {
    func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    func requestAccessPrompt() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        if let url {
            NSWorkspace.shared.open(url)
        }
    }

    func listWindows() -> [WindowInfo] {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let applications = NSWorkspace.shared.runningApplications
            .filter { $0.processIdentifier != currentPID }
            .filter { $0.activationPolicy == .regular || $0.activationPolicy == .accessory }

        return applications.flatMap { application -> [WindowInfo] in
            guard let appName = application.localizedName else {
                return []
            }

            return windows(for: application, appName: appName)
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func windows(matching window: WindowInfo) -> [WindowInfo] {
        matchingApplications(for: window).flatMap { application -> [WindowInfo] in
            guard let appName = application.localizedName else {
                return []
            }

            return windows(for: application, appName: appName)
        }
    }

    func matchingApplications(for window: WindowInfo) -> [NSRunningApplication] {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let applications = NSWorkspace.shared.runningApplications
            .filter { $0.processIdentifier != currentPID }
            .filter { $0.activationPolicy == .regular || $0.activationPolicy == .accessory }

        if let application = applications.first(where: { $0.processIdentifier == window.pid }) {
            return [application]
        }

        if let bundleIdentifier = window.bundleIdentifier {
            let bundleMatches = applications.filter { $0.bundleIdentifier == bundleIdentifier }
            if !bundleMatches.isEmpty {
                return bundleMatches
            }
        }

        return applications.filter { $0.localizedName == window.appName }
    }

    func frontmostWindow(for application: NSRunningApplication) -> WindowInfo? {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        guard application.processIdentifier != currentPID,
              let appName = application.localizedName else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var focusedValue: CFTypeRef?
        let focusedError = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedValue)
        if focusedError == .success,
           let focusedWindow = focusedValue,
           CFGetTypeID(focusedWindow) == AXUIElementGetTypeID(),
           let windowInfo = windowInfo(for: focusedWindow as! AXUIElement, application: application, appName: appName) {
            return windowInfo
        }

        return windows(for: application, appName: appName).first
    }

    func windows(for application: NSRunningApplication) -> [WindowInfo] {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        guard application.processIdentifier != currentPID,
              application.activationPolicy == .regular || application.activationPolicy == .accessory,
              let appName = application.localizedName else {
            return []
        }

        return windows(for: application, appName: appName)
    }

    func position(of window: WindowInfo) throws -> CGPoint {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(window.axWindow, kAXPositionAttribute as CFString, &value)
        guard error == .success else {
            throw WindowBoardAXError.operationFailed("Read window position", error)
        }
        guard let axValue = value, CFGetTypeID(axValue) == AXValueGetTypeID() else {
            throw WindowBoardAXError.missingPosition
        }

        var point = CGPoint.zero
        guard AXValueGetValue(axValue as! AXValue, .cgPoint, &point) else {
            throw WindowBoardAXError.missingPosition
        }
        return point
    }

    func setPosition(_ position: CGPoint, for window: WindowInfo) throws {
        var mutablePosition = CGPoint(x: round(position.x), y: round(position.y))
        guard let value = AXValueCreate(.cgPoint, &mutablePosition) else {
            throw WindowBoardAXError.missingPosition
        }

        let error = AXUIElementSetAttributeValue(window.axWindow, kAXPositionAttribute as CFString, value)
        guard error == .success else {
            throw WindowBoardAXError.operationFailed("Move window", error)
        }
    }

    func isMinimized(_ window: WindowInfo) -> Bool {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(window.axWindow, kAXMinimizedAttribute as CFString, &value)
        guard error == .success else {
            return false
        }

        return value as? Bool ?? false
    }

    func setMinimized(_ minimized: Bool, for window: WindowInfo) throws {
        let error = AXUIElementSetAttributeValue(
            window.axWindow,
            kAXMinimizedAttribute as CFString,
            minimized as CFBoolean
        )
        guard error == .success else {
            throw WindowBoardAXError.operationFailed(minimized ? "Minimize window" : "Restore window", error)
        }
    }

    func raise(_ window: WindowInfo) {
        activateApplication(for: window)
        raiseWindowOnly(window)
    }

    func raiseWindowOnly(_ window: WindowInfo) {
        AXUIElementPerformAction(window.axWindow, kAXRaiseAction as CFString)
    }

    func activateApplication(for window: WindowInfo) {
        if !activateApplication(pid: window.pid),
           let bundleURL = window.bundleURL {
            openApplication(at: bundleURL)
        }
    }

    @discardableResult
    func activateApplication(pid: pid_t) -> Bool {
        if let application = NSRunningApplication(processIdentifier: pid) {
            return activateApplication(application)
        }

        return false
    }

    @discardableResult
    func activateApplication(_ application: NSRunningApplication) -> Bool {
        application.activate(options: [.activateAllWindows])
    }

    func openApplication(at bundleURL: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration)
    }

    func openDocument(for window: WindowInfo) -> Bool {
        guard !SavedWindowReference.isVisualStudioCode(bundleIdentifier: window.bundleIdentifier) else {
            return false
        }

        guard let documentURL = window.documentURL else {
            return false
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        if let bundleURL = window.bundleURL {
            NSWorkspace.shared.open([documentURL], withApplicationAt: bundleURL, configuration: configuration)
        } else {
            NSWorkspace.shared.open(documentURL, configuration: configuration)
        }

        return true
    }

    func reopenApplication(for window: WindowInfo) {
        if openDocument(for: window) {
            return
        }

        _ = activateOrOpenApplication(for: window)
    }

    @discardableResult
    func activateOrOpenApplication(for window: WindowInfo) -> Bool {
        var didActivateOrOpen = false

        if activateApplication(pid: window.pid) {
            didActivateOrOpen = true
        }

        if let bundleIdentifier = window.bundleIdentifier,
           let application = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
            didActivateOrOpen = activateApplication(application) || didActivateOrOpen
        }

        if let bundleURL = window.bundleURL {
            openApplication(at: bundleURL)
            didActivateOrOpen = true
        }

        return didActivateOrOpen
    }

    @discardableResult
    func openNewWindow(for window: WindowInfo) -> Bool {
        if openDocument(for: window) {
            return true
        }

        guard window.bundleIdentifier == "com.apple.Terminal",
              let bundleURL = window.bundleURL else {
            return false
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [FileManager.default.homeDirectoryForCurrentUser],
            withApplicationAt: bundleURL,
            configuration: configuration
        )
        return true
    }

    @discardableResult
    func openSavedWindowReference(_ reference: SavedWindowReference) -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        if reference.isVisualStudioCode {
            return false
        }

        if let documentURL = reference.documentURL {
            if let bundleURL = reference.bundleURL {
                NSWorkspace.shared.open([documentURL], withApplicationAt: bundleURL, configuration: configuration)
            } else {
                NSWorkspace.shared.open(documentURL, configuration: configuration)
            }
            return true
        }

        guard reference.bundleIdentifier == "com.apple.Terminal",
              let bundleURL = reference.bundleURL else {
            return false
        }

        NSWorkspace.shared.open(
            [FileManager.default.homeDirectoryForCurrentUser],
            withApplicationAt: bundleURL,
            configuration: configuration
        )
        return true
    }

    @discardableResult
    func activateSavedApplication(_ reference: SavedWindowReference) -> Bool {
        var didActivateOrOpen = false

        if let bundleIdentifier = reference.bundleIdentifier,
           let application = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
            didActivateOrOpen = activateApplication(application)
        }

        if let bundleURL = reference.bundleURL {
            openApplication(at: bundleURL)
            didActivateOrOpen = true
        }

        return didActivateOrOpen
    }

    func focusWindow(_ window: WindowInfo) {
        let appElement = AXUIElementCreateApplication(window.pid)
        AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, window.axWindow)
    }

    private func isUsableWindow(_ window: AXUIElement) -> Bool {
        guard stringAttribute(kAXRoleAttribute, from: window) == kAXWindowRole as String else {
            return false
        }

        var positionValue: CFTypeRef?
        let positionError = AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue)
        guard positionError == .success else {
            return false
        }

        var sizeValue: CFTypeRef?
        let sizeError = AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue)
        guard sizeError == .success else {
            return false
        }

        return true
    }

    private func windows(for application: NSRunningApplication, appName: String) -> [WindowInfo] {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        guard error == .success, let windows = value as? [AXUIElement] else {
            return []
        }

        return windows.compactMap { axWindow in
            windowInfo(for: axWindow, application: application, appName: appName)
        }
    }

    private func windowInfo(
        for axWindow: AXUIElement,
        application: NSRunningApplication,
        appName: String
    ) -> WindowInfo? {
        guard isUsableWindow(axWindow) else {
            return nil
        }

        let title = stringAttribute(kAXTitleAttribute, from: axWindow) ?? ""
        let windowNumber = windowNumberAttribute(from: axWindow)
        let documentURL = documentURLAttribute(from: axWindow)
        let position = positionAttribute(from: axWindow)
        let id = if let windowNumber {
            "\(application.processIdentifier)-window-\(windowNumber)"
        } else {
            "\(application.processIdentifier)-element-\(stableWindowAddress(axWindow))"
        }

        return WindowInfo(
            id: id,
            appName: appName,
            title: title,
            pid: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            bundleURL: application.bundleURL,
            documentURL: documentURL,
            axWindow: axWindow,
            windowNumber: windowNumber,
            position: position
        )
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else {
            return nil
        }

        return value as? String
    }

    private func windowNumberAttribute(from element: AXUIElement) -> CGWindowID? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, "AXWindowNumber" as CFString, &value)
        guard error == .success, let number = value as? NSNumber else {
            return nil
        }

        return CGWindowID(number.uint32Value)
    }

    private func documentURLAttribute(from element: AXUIElement) -> URL? {
        guard let rawDocument = stringAttribute("AXDocument", from: element),
              !rawDocument.isEmpty else {
            return nil
        }

        if let url = URL(string: rawDocument), url.scheme != nil {
            return url
        }

        return URL(fileURLWithPath: rawDocument)
    }

    private func positionAttribute(from element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value)
        guard error == .success,
              let axValue = value,
              CFGetTypeID(axValue) == AXValueGetTypeID() else {
            return nil
        }

        var point = CGPoint.zero
        guard AXValueGetValue(axValue as! AXValue, .cgPoint, &point) else {
            return nil
        }

        return point
    }

    private func stableWindowAddress(_ window: AXUIElement) -> UInt {
        UInt(bitPattern: Unmanaged.passUnretained(window).toOpaque())
    }
}
