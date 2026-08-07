import Foundation

struct QuickLauncherUsage: Codable, Equatable {
    var useCount: Int
    var lastUsedAt: Date
}

protocol QuickLauncherUsageProviding {
    func usage(for itemID: QuickLauncherItem.ID) -> QuickLauncherUsage?
}

final class QuickLauncherUsageStore: QuickLauncherUsageProviding {
    private let defaults: UserDefaults
    private let storageKey: String
    private let now: () -> Date
    private var records: [QuickLauncherItem.ID: QuickLauncherUsage]

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "quickLauncherUsage",
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.now = now
        records = defaults.data(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode([QuickLauncherItem.ID: QuickLauncherUsage].self, from: $0) }
            ?? [:]
    }

    func usage(for itemID: QuickLauncherItem.ID) -> QuickLauncherUsage? {
        records[itemID]
    }

    func recordUse(of itemID: QuickLauncherItem.ID) {
        let prior = records[itemID]
        records[itemID] = QuickLauncherUsage(
            useCount: (prior?.useCount ?? 0) + 1,
            lastUsedAt: now()
        )

        guard let data = try? JSONEncoder().encode(records) else {
            return
        }
        defaults.set(data, forKey: storageKey)
    }
}

struct EmptyQuickLauncherUsage: QuickLauncherUsageProviding {
    func usage(for itemID: QuickLauncherItem.ID) -> QuickLauncherUsage? { nil }
}
