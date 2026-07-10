import AppKit
import SwiftUI

struct AppIconView: View {
    let appName: String
    let bundleURL: URL?
    let bundleIdentifier: String?
    var size: CGFloat = 24
    var isElevated = false

    var body: some View {
        Group {
            if let iconImage {
                Image(nsImage: iconImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                fallbackIcon
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .shadow(color: .black.opacity(isElevated ? 0.18 : 0), radius: isElevated ? 10 : 0, y: isElevated ? 5 : 0)
        .shadow(color: iconColor.opacity(isElevated ? 0.18 : 0), radius: isElevated ? 18 : 0, y: isElevated ? 8 : 0)
    }

    private var iconImage: NSImage? {
        AppIconCache.icon(appName: appName, bundleURL: bundleURL, bundleIdentifier: bundleIdentifier)
    }

    private var fallbackIcon: some View {
        Image(systemName: symbolName)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(iconColor.gradient)
    }

    private var symbolName: String {
        switch appName.lowercased() {
        case let name where name.contains("terminal"): "terminal"
        case let name where name.contains("safari") || name.contains("chrome"): "globe"
        case let name where name.contains("xcode") || name.contains("code"): "chevron.left.forwardslash.chevron.right"
        case let name where name.contains("simulator"): "iphone"
        default: "macwindow"
        }
    }

    private var iconColor: Color {
        switch appName.lowercased() {
        case let name where name.contains("terminal"): .black
        case let name where name.contains("safari") || name.contains("chrome"): .blue
        case let name where name.contains("xcode") || name.contains("code"): .blue
        case let name where name.contains("simulator"): .gray
        default: .accentColor
        }
    }
}

private enum AppIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(appName: String, bundleURL: URL?, bundleIdentifier: String?) -> NSImage? {
        let key = bundleIdentifier ?? bundleURL?.absoluteString ?? appName
        if let cachedIcon = cache[key] { return cachedIcon }
        guard let resolvedIcon = resolvedIcon(bundleURL: bundleURL, bundleIdentifier: bundleIdentifier) else { return nil }
        cache[key] = resolvedIcon
        return resolvedIcon
    }

    private static func resolvedIcon(bundleURL: URL?, bundleIdentifier: String?) -> NSImage? {
        if let bundleURL { return NSWorkspace.shared.icon(forFile: bundleURL.path) }
        if let bundleIdentifier,
           let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: applicationURL.path)
        }
        return nil
    }
}

enum AppIconPalette {
    private static var cache: [String: NSColor] = [:]

    static func accentColor(appName: String, bundleURL: URL?, bundleIdentifier: String?) -> NSColor {
        let key = bundleIdentifier ?? bundleURL?.absoluteString ?? appName
        if let cached = cache[key] { return cached }
        let resolved = resolvedIcon(bundleURL: bundleURL, bundleIdentifier: bundleIdentifier)
            .flatMap(dominantColor(from:)) ?? fallbackColor(appName: appName)
        cache[key] = resolved
        return resolved
    }

    private static func resolvedIcon(bundleURL: URL?, bundleIdentifier: String?) -> NSImage? {
        if let bundleURL { return NSWorkspace.shared.icon(forFile: bundleURL.path) }
        if let bundleIdentifier,
           let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: applicationURL.path)
        }
        return nil
    }

    private static func dominantColor(from image: NSImage) -> NSColor? {
        let targetSize = NSSize(width: 24, height: 24)
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(targetSize.width), pixelsHigh: Int(targetSize.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )
        guard let bitmap else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: targetSize))
        NSGraphicsContext.restoreGraphicsState()

        var redTotal: CGFloat = 0
        var greenTotal: CGFloat = 0
        var blueTotal: CGFloat = 0
        var weightTotal: CGFloat = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.2 else { continue }
                let maxComponent = max(color.redComponent, color.greenComponent, color.blueComponent)
                let minComponent = min(color.redComponent, color.greenComponent, color.blueComponent)
                let saturation = maxComponent - minComponent
                guard saturation > 0.08, maxComponent > 0.16, maxComponent < 0.96 else { continue }
                let weight = saturation * color.alphaComponent
                redTotal += color.redComponent * weight
                greenTotal += color.greenComponent * weight
                blueTotal += color.blueComponent * weight
                weightTotal += weight
            }
        }
        guard weightTotal > 0 else { return nil }
        return NSColor(calibratedRed: redTotal / weightTotal, green: greenTotal / weightTotal, blue: blueTotal / weightTotal, alpha: 1)
    }

    private static func fallbackColor(appName: String) -> NSColor {
        switch appName.lowercased() {
        case let name where name.contains("terminal"): .darkGray
        case let name where name.contains("safari") || name.contains("chrome"): .systemBlue
        case let name where name.contains("xcode") || name.contains("code"): .systemBlue
        case let name where name.contains("simulator"): .systemGray
        default: .controlAccentColor
        }
    }
}
