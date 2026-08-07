import AppKit
import SwiftUI

struct QuickLauncherView: View {
    @ObservedObject var viewModel: QuickLauncherViewModel

    var body: some View {
        VStack(spacing: 0) {
            searchField
            currentBoardIndicator
            Divider()
            resultContent
        }
        .frame(width: 640, height: 430)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick Launcher")
    }

    private var currentBoardIndicator: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.accentColor)
            Text("Current Board:")
                .foregroundStyle(.secondary)
            Text(viewModel.currentBoardTitle ?? "None")
                .fontWeight(.semibold)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Current Board: \(viewModel.currentBoardTitle ?? "None")")
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(.secondary)
            QuickLauncherSearchField(
                text: viewModel.query,
                focusRequestRevision: viewModel.focusRequestRevision,
                updateText: viewModel.updateQuery,
                submit: viewModel.executeSelected,
                moveSelection: viewModel.moveSelection,
                dismiss: viewModel.dismiss
            )
            .frame(height: 30)
            if !viewModel.query.isEmpty {
                Button {
                    viewModel.clearQuery()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear Search")
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
    }

    @ViewBuilder
    private var resultContent: some View {
        if let errorMessage = viewModel.errorMessage {
            VStack(spacing: 10) {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Button("Try Again") { viewModel.executeSelected() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.results.isEmpty {
            ContentUnavailableView(
                "No results found",
                systemImage: "magnifyingglass",
                description: Text("Try a Board, app, window, or action name.")
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(QuickLauncherItemKind.allCases, id: \.self) { kind in
                            let items = viewModel.results.filter { $0.kind == kind }
                            if !items.isEmpty {
                                Text(kind.displayName)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 14)
                                    .padding(.top, 10)
                                ForEach(items) { item in
                                    QuickLauncherResultRow(
                                        item: item,
                                        query: viewModel.query,
                                        isSelected: item.id == viewModel.selectedItemID,
                                        select: { viewModel.select(item.id) },
                                        execute: { viewModel.executeSelected() },
                                        executeSecondary: { target in viewModel.execute(item, target: target) }
                                    )
                                    .id(item.id)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .onChange(of: viewModel.keyboardSelectionScrollRevision) { _, _ in
                    let selectedID = viewModel.selectedItemID
                    guard let selectedID else { return }
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(selectedID, anchor: .center)
                    }
                }
            }
        }
    }
}

private struct QuickLauncherSearchField: NSViewRepresentable {
    let text: String
    let focusRequestRevision: Int
    let updateText: (String) -> Void
    let submit: () -> Void
    let moveSelection: (Int) -> Void
    let dismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .preferredFont(forTextStyle: .title3)
        field.placeholderString = "Search Boards, windows, and actions"
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Quick Launcher search")
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
        guard context.coordinator.lastFocusRequestRevision != focusRequestRevision else { return }
        context.coordinator.lastFocusRequestRevision = focusRequestRevision
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: QuickLauncherSearchField
        var lastFocusRequestRevision = -1

        init(_ parent: QuickLauncherSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.updateText(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                // An Enter that commits an active Japanese IME conversion must not execute a result.
                guard !textView.hasMarkedText() else { return false }
                parent.submit()
                return true
            }
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                parent.moveSelection(-1)
                return true
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                parent.moveSelection(1)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.dismiss()
                return true
            }
            return false
        }
    }
}

private struct QuickLauncherResultRow: View {
    let item: QuickLauncherItem
    let query: String
    let isSelected: Bool
    let select: () -> Void
    let execute: () -> Void
    let executeSecondary: (QuickLauncherTarget) -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 11) {
            if item.kind == .board, item.isSelectedBoardRelated {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
            icon
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                QuickLauncherHighlightedText(text: item.title, query: query)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if let badge = item.badge {
                Text(badge)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
            if let secondaryAction = item.secondaryAction {
                Button {
                    executeSecondary(secondaryAction.target)
                } label: {
                    Label(secondaryAction.title, systemImage: secondaryAction.systemImage)
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)
                .help("Detach this window from its Board")
                .accessibilityLabel(secondaryAction.title + " window from Board")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .contentShape(Rectangle())
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .opacity(item.isEnabled ? 1 : 0.5)
        .onHover { hovering in
            isHovered = hovering
            if hovering && item.isEnabled { select() }
        }
        .onTapGesture(count: 2) {
            guard item.isEnabled else { return }
            select()
            execute()
        }
        .onTapGesture(count: 1) {
            guard item.isEnabled else { return }
            select()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var icon: some View {
        switch item.icon {
        case let .system(name):
            Image(systemName: name)
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
        case let .application(appName, bundleURL, bundleIdentifier):
            AppIconView(
                appName: appName,
                bundleURL: bundleURL,
                bundleIdentifier: bundleIdentifier,
                size: 28
            )
        }
    }

    private var rowBackground: some ShapeStyle {
        if isSelected { return AnyShapeStyle(Color.accentColor.opacity(0.18)) }
        if isHovered { return AnyShapeStyle(Color.primary.opacity(0.06)) }
        return AnyShapeStyle(Color.clear)
    }

    private var accessibilityLabel: String {
        [item.title, item.subtitle, item.kind.rawValue, item.badge, isSelected ? "Selected" : nil]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

private struct QuickLauncherHighlightedText: View {
    let text: String
    let query: String

    var body: some View {
        let searchText = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .drop { $0 == ">" || $0 == "@" || $0 == "#" || $0.isWhitespace }
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init) ?? ""
        guard !searchText.isEmpty,
              let range = text.range(
                of: searchText,
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
              ) else {
            return Text(text)
        }
        return Text(text[..<range.lowerBound])
            + Text(text[range]).bold().foregroundStyle(Color.accentColor)
            + Text(text[range.upperBound...])
    }
}
