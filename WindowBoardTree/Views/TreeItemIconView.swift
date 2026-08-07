import AppKit
import SwiftUI

struct TreeItemIconView: View {
    let item: TreeBrowserItem
    var size: CGFloat = 56

    var body: some View {
        Group {
            switch item {
            case .board:
                Image(systemName: "folder.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color.accentColor)
                    .padding(size * 0.06)

            case let .window(row):
                if let icon = TreeAppIconCache.icon(for: row.reference) {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                } else {
                    Image(systemName: "macwindow")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                        .padding(size * 0.16)
                }
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            stateIndicator
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var stateIndicator: some View {
        if case let .window(row) = item, row.state != .available {
            Image(systemName: row.state.systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(row.state == .unavailable ? .orange : .secondary)
                .padding(4)
                .background(.regularMaterial, in: Circle())
        }
    }
}

private enum TreeAppIconCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for reference: SavedWindowReference) -> NSImage? {
        let key = reference.bundleIdentifier
            ?? reference.bundleURLString
            ?? reference.appName
        let cacheKey = key as NSString

        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }
        if missingKeys.contains(key) {
            return nil
        }

        let applicationURL: URL?
        if let bundleURL = reference.bundleURL {
            applicationURL = bundleURL
        } else if let bundleIdentifier = reference.bundleIdentifier {
            applicationURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleIdentifier
            )
        } else {
            applicationURL = nil
        }

        guard let applicationURL else {
            missingKeys.insert(key)
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: applicationURL.path)
        cache.setObject(icon, forKey: cacheKey)
        return icon
    }

    private static var missingKeys: Set<String> = []
}
