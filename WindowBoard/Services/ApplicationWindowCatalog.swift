import AppKit
import Foundation

final class ApplicationWindowCatalog: @unchecked Sendable {
    private let serviceFactory: @Sendable () -> any ContentWindowOperating

    init(
        serviceFactory: @escaping @Sendable () -> any ContentWindowOperating = { AccessibilityWindowService() }
    ) {
        self.serviceFactory = serviceFactory
    }

    func allWindows() -> [WindowInfo] {
        serviceFactory().listWindows()
    }

    func windows(
        for application: NSRunningApplication,
        attempts: Int,
        retryDelay: Duration
    ) async -> [WindowInfo] {
        let service = serviceFactory()
        var result: [WindowInfo] = []

        for attempt in 0..<max(attempts, 1) {
            guard !Task.isCancelled else {
                return result
            }

            if attempt > 0 {
                try? await Task.sleep(for: retryDelay)
            }

            result = service.windows(for: application)
            if !result.isEmpty {
                break
            }
        }

        return result
    }

    func merging(_ newWindows: [WindowInfo], into cachedWindows: [WindowInfo]) -> [WindowInfo] {
        var mergedWindows = cachedWindows
        for window in newWindows where !mergedWindows.contains(where: { $0.id == window.id }) {
            mergedWindows.append(window)
        }
        return sorted(mergedWindows)
    }

    func removingWindows(
        for application: NSRunningApplication,
        from cachedWindows: [WindowInfo]
    ) -> [WindowInfo] {
        cachedWindows.filter { !isWindow($0, from: application) }
    }

    private func sorted(_ windows: [WindowInfo]) -> [WindowInfo] {
        windows.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private func isWindow(_ window: WindowInfo, from application: NSRunningApplication) -> Bool {
        if let bundleIdentifier = application.bundleIdentifier,
           let windowBundleIdentifier = window.bundleIdentifier {
            return bundleIdentifier == windowBundleIdentifier
        }

        if window.pid == application.processIdentifier {
            return true
        }

        return application.localizedName == window.appName
    }
}
