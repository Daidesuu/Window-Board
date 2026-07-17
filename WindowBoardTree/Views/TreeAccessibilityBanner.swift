import SwiftUI

struct TreeAccessibilityBanner: View {
    let requestAccess: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised")
                .foregroundStyle(.secondary)

            Text("Accessibility access is required for external window actions.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Request Access", action: requestAccess)
            Button("Open Settings", action: openSettings)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.yellow.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }
}
