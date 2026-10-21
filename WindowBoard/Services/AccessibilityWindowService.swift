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

protocol WorkspaceWindowOperating: AnyObject {
    func listWindows() -> [WindowInfo]
    func listWindowsReport() -> WindowEnumerationReport
    func windows(matching window: WindowInfo) -> [WindowInfo]
    func position(of window: WindowInfo) throws -> CGPoint
    func size(of window: WindowInfo) throws -> CGSize
    func setPosition(_ position: CGPoint, for window: WindowInfo) throws
    func setSize(_ size: CGSize, for window: WindowInfo) throws
    func isMinimized(_ window: WindowInfo) -> Bool
    func minimizedObservation(of window: WindowInfo) -> MinimizedObservation
    func setMinimized(_ minimized: Bool, for window: WindowInfo) throws
    func raise(_ window: WindowInfo)
    func openSavedWindowReference(_ reference: SavedWindowReference) -> Bool
    func activateSavedApplication(_ reference: SavedWindowReference) -> Bool
}

extension WorkspaceWindowOperating {
    /// Compatibility only: the legacy array cannot establish enumeration coverage.
    func listWindowsReport() -> WindowEnumerationReport {
        WindowEnumerationReport(
            windows: listWindows(),
            coverage: .unverifiedLegacy,
            issues: [],
            failedPIDs: []
        )
    }

    /// Preserve the old Bool without claiming that read failures were diagnosed.
    func minimizedObservation(of window: WindowInfo) -> MinimizedObservation {
        MinimizedObservation(state: .success(isMinimized(window)), quality: .legacy)
    }
}

protocol ContentWindowOperating: WorkspaceWindowOperating, Sendable {
    func isTrusted() -> Bool
    func requestAccessPrompt()
    func openAccessibilitySettings()
    func frontmostWindow(for application: NSRunningApplication) -> WindowInfo?
    func frontmostVisibleExternalWindow(
        excludingProcessID excludedPID: pid_t
    ) -> WindowInfo?
    func windows(for application: NSRunningApplication) -> [WindowInfo]
    func title(of window: WindowInfo) -> String?
    func raiseWindowOnly(_ window: WindowInfo)
    func activateApplication(for window: WindowInfo)
    @discardableResult func activateApplication(pid: pid_t) -> Bool
    func openDocument(for window: WindowInfo) -> Bool
    func activateOrOpenApplication(for window: WindowInfo) -> Bool
    func focusWindow(_ window: WindowInfo)
}

extension ContentWindowOperating {
    func frontmostVisibleExternalWindow() -> WindowInfo? {
        frontmostVisibleExternalWindow(excludingProcessID: ProcessInfo.processInfo.processIdentifier)
    }
}

final class AccessibilityWindowService: ContentWindowOperating, @unchecked Sendable {
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

    struct ApplicationInspection {
        let pid: pid_t
        let windows: [WindowInfo]
        let issues: [WindowInspectionIssue]
        let hasSuccessfulScope: Bool
    }

    static func aggregateInspections(_ inspections: [ApplicationInspection], permissionGranted: Bool = true) -> WindowEnumerationReport {
        let windows = inspections.flatMap(\.windows).sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        let failedPIDs = Set(inspections.filter { !$0.issues.isEmpty }.map(\.pid))
        let issues = inspections.flatMap(\.issues)
        guard permissionGranted else {
            return WindowEnumerationReport(windows: windows, coverage: .failed, issues: issues + [
                WindowInspectionIssue(stage: .accessibilityPermission, pid: nil, windowID: nil, failure: .ax(.apiDisabled))
            ], failedPIDs: failedPIDs)
        }
        let coverage: WindowEnumerationReport.Coverage = issues.isEmpty ? .complete
            : (inspections.contains(where: \.hasSuccessfulScope) ? .partial : .failed)
        return WindowEnumerationReport(
            windows: windows, coverage: coverage, issues: issues, failedPIDs: failedPIDs
        )
    }

    static func minimizedObservation(rawValue: CFTypeRef?, error: AXError, pid: pid_t, windowID: String?) -> MinimizedObservation {
        let failure: WindowInspectionIssue.Failure
        if error != .success {
            failure = .ax(error)
        } else if let rawValue, CFGetTypeID(rawValue) == CFBooleanGetTypeID() {
            return MinimizedObservation(state: .success(CFEqual(rawValue, kCFBooleanTrue)), quality: .diagnostic)
        } else {
            failure = .invalidValue
        }
        return MinimizedObservation(state: .failure(WindowInspectionIssue(
            stage: .readMinimized, pid: pid, windowID: windowID, failure: failure
        )), quality: .diagnostic)
    }

    static func roleObservation(rawValue: CFTypeRef?, error: AXError, pid: pid_t) -> Result<String, WindowInspectionIssue> {
        guard error == .success else {
            return .failure(WindowInspectionIssue(stage: .readRole, pid: pid, windowID: nil, failure: .ax(error)))
        }
        guard let rawValue, CFGetTypeID(rawValue) == CFStringGetTypeID(), let role = rawValue as? String else {
            return .failure(WindowInspectionIssue(stage: .readRole, pid: pid, windowID: nil, failure: .invalidValue))
        }
        return .success(role)
    }

    static func geometryIssue(rawValue: CFTypeRef?, error: AXError, stage: WindowInspectionIssue.Stage, pid: pid_t) -> WindowInspectionIssue? {
        if error != .success {
            return WindowInspectionIssue(stage: stage, pid: pid, windowID: nil, failure: .ax(error))
        }
        guard let rawValue, CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return WindowInspectionIssue(stage: stage, pid: pid, windowID: nil, failure: .invalidValue)
        }
        let value = unsafeBitCast(rawValue, to: AXValue.self)
        let expectedType: AXValueType = stage == .readPosition ? .cgPoint : .cgSize
        guard AXValueGetType(value) == expectedType else {
            return WindowInspectionIssue(stage: stage, pid: pid, windowID: nil, failure: .invalidValue)
        }
        return nil
    }

    func listWindows() -> [WindowInfo] {
        inspectWindows().windows
    }

    func listWindowsReport() -> WindowEnumerationReport {
        inspectWindows()
    }

    private func inspectWindows() -> WindowEnumerationReport {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let applications = NSWorkspace.shared.runningApplications
            .filter { $0.processIdentifier != currentPID }
            .filter { $0.activationPolicy == .regular || $0.activationPolicy == .accessory }
        let inspections = applications.compactMap { application -> ApplicationInspection? in
            guard let appName = application.localizedName else { return nil }
            return inspectWindows(for: application, appName: appName)
        }
        return Self.aggregateInspections(inspections, permissionGranted: isTrusted())
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

    func frontmostVisibleExternalWindow(excludingProcessID excludedPID: pid_t = ProcessInfo.processInfo.processIdentifier) -> WindowInfo? {
        guard let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, .zero) as? [[String: Any]] else {
            return nil
        }

        for windowInfo in windowList {
            guard let ownerPIDNumber = windowInfo[kCGWindowOwnerPID as String] as? NSNumber,
                  let layerNumber = windowInfo[kCGWindowLayer as String] as? NSNumber,
                  let windowNumberValue = windowInfo[kCGWindowNumber as String] as? NSNumber,
                  let ownerPID = pid_t(exactly: ownerPIDNumber),
                  ownerPID != excludedPID,
                  layerNumber.intValue == 0 else {
                continue
            }

            if let alphaNumber = windowInfo[kCGWindowAlpha as String] as? NSNumber,
               alphaNumber.doubleValue <= 0 {
                continue
            }

            if let boundsDictionary = windowInfo[kCGWindowBounds as String] as? [String: Any] {
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) ?? .zero
                guard bounds.width > 40, bounds.height > 40 else {
                    continue
                }
            }

            guard let application = NSRunningApplication(processIdentifier: ownerPID),
                  application.activationPolicy == .regular || application.activationPolicy == .accessory else {
                continue
            }

            let candidateWindows = windows(for: application)
            let windowNumber = CGWindowID(windowNumberValue.uint32Value)
            if let matchingWindow = candidateWindows.first(where: { $0.windowNumber == windowNumber }) {
                return matchingWindow
            }

            if let focusedWindow = frontmostWindow(for: application) {
                return focusedWindow
            }

            if candidateWindows.count == 1 {
                return candidateWindows[0]
            }
        }

        return nil
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

    func size(of window: WindowInfo) throws -> CGSize {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(window.axWindow, kAXSizeAttribute as CFString, &value)
        guard error == .success else {
            throw WindowBoardAXError.operationFailed("Read window size", error)
        }
        guard let axValue = value, CFGetTypeID(axValue) == AXValueGetTypeID() else {
            throw WindowBoardAXError.missingSize
        }

        var size = CGSize.zero
        guard AXValueGetValue(axValue as! AXValue, .cgSize, &size) else {
            throw WindowBoardAXError.missingSize
        }
        return size
    }

    func setSize(_ size: CGSize, for window: WindowInfo) throws {
        var mutableSize = CGSize(width: round(size.width), height: round(size.height))
        guard let value = AXValueCreate(.cgSize, &mutableSize) else {
            throw WindowBoardAXError.missingSize
        }

        let error = AXUIElementSetAttributeValue(window.axWindow, kAXSizeAttribute as CFString, value)
        guard error == .success else {
            throw WindowBoardAXError.operationFailed("Resize window", error)
        }
    }

    func isMinimized(_ window: WindowInfo) -> Bool {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(window.axWindow, kAXMinimizedAttribute as CFString, &value)
        guard error == .success else { return false }
        return value as? Bool ?? false
    }

    func minimizedObservation(of window: WindowInfo) -> MinimizedObservation {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(window.axWindow, kAXMinimizedAttribute as CFString, &value)
        return Self.minimizedObservation(rawValue: value, error: error, pid: window.pid, windowID: window.id)
    }

    func title(of window: WindowInfo) -> String? {
        stringAttribute(kAXTitleAttribute, from: window.axWindow)
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

        if !reference.isVisualStudioCode, let documentURL = reference.documentURL {
            if let bundleURL = reference.bundleURL {
                NSWorkspace.shared.open([documentURL], withApplicationAt: bundleURL, configuration: configuration)
            } else {
                NSWorkspace.shared.open(documentURL, configuration: configuration)
            }
            return true
        }

        if reference.bundleIdentifier == "com.apple.Terminal",
           let bundleURL = reference.bundleURL {
            NSWorkspace.shared.open(
                [FileManager.default.homeDirectoryForCurrentUser],
                withApplicationAt: bundleURL,
                configuration: configuration
            )
            return true
        }

        if let bundleURL = reference.bundleURL {
            openApplication(at: bundleURL)
            return true
        }

        if let bundleIdentifier = reference.bundleIdentifier {
            if let application = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
                return activateApplication(application)
            }

            if let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                openApplication(at: applicationURL)
                return true
            }
        }

        return false
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

        if minimizedAttribute(from: window) == true {
            return true
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

    private func minimizedAttribute(from element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &value)
        guard error == .success else {
            return nil
        }

        return value as? Bool
    }

    private func inspectWindows(for application: NSRunningApplication, appName: String) -> ApplicationInspection {
        let pid = application.processIdentifier
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value)
        guard error == .success, let value, CFGetTypeID(value) == CFArrayGetTypeID(),
              let elements = value as? [AnyObject] else {
            return ApplicationInspection(pid: pid, windows: [], issues: [WindowInspectionIssue(
                stage: .enumerateWindows, pid: pid, windowID: nil,
                failure: error == .success ? .invalidValue : .ax(error)
            )], hasSuccessfulScope: false)
        }
        var windows: [WindowInfo] = []
        var issues: [WindowInspectionIssue] = []
        var successfulScope = elements.isEmpty
        for element in elements {
            guard CFGetTypeID(element) == AXUIElementGetTypeID() else {
                issues.append(WindowInspectionIssue(stage: .enumerateWindows, pid: pid, windowID: nil, failure: .invalidValue))
                continue
            }
            let window = unsafeBitCast(element, to: AXUIElement.self)
            var role: CFTypeRef?
            let roleError = AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role)
            let roleString: String
            switch Self.roleObservation(rawValue: role, error: roleError, pid: pid) {
            case .success(let value): roleString = value
            case .failure(let issue):
                issues.append(issue)
                continue
            }
            guard roleString == kAXWindowRole as String else {
                successfulScope = true
                continue
            }
            var minimizedValue: CFTypeRef?
            let minimizedError = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue)
            let minimized = Self.minimizedObservation(rawValue: minimizedValue, error: minimizedError, pid: pid, windowID: nil)
            if case .failure(let issue) = minimized.state { issues.append(issue) }
            var usable = true
            // Keep the legacy filter's Bool bridging while reporting strict observation quality.
            let legacyMinimized = minimizedError == .success && (minimizedValue as? Bool) == true
            if !legacyMinimized {
                for (attribute, stage) in [(kAXPositionAttribute, WindowInspectionIssue.Stage.readPosition), (kAXSizeAttribute, .readSize)] {
                    var raw: CFTypeRef?
                    let readError = AXUIElementCopyAttributeValue(window, attribute as CFString, &raw)
                    if readError != .success {
                        issues.append(WindowInspectionIssue(stage: stage, pid: pid, windowID: nil, failure: .ax(readError)))
                        usable = false
                        break
                    }
                    // Successful geometry reads remain usable for existing array callers;
                    // malformed values still make diagnostic coverage incomplete.
                    if let issue = Self.geometryIssue(rawValue: raw, error: readError, stage: stage, pid: pid) {
                        issues.append(issue)
                    }
                }
            }
            if usable, let info = windowInfo(for: window, application: application, appName: appName, knownUsable: true) {
                windows.append(info)
                successfulScope = true
            }
        }
        return ApplicationInspection(pid: pid, windows: windows, issues: issues, hasSuccessfulScope: successfulScope)
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
        appName: String,
        knownUsable: Bool = false
    ) -> WindowInfo? {
        guard knownUsable || isUsableWindow(axWindow) else {
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
