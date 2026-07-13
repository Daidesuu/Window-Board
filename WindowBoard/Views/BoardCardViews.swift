import AppKit
import SwiftUI

struct PinnedWindowCardGrid: View {
    let attachedWindows: [AttachedWindow]
    let stateForWindow: (AttachedWindow) -> AttachedWindowDisplayState
    let recoveryIssue: (AttachedWindow.ID) -> AttachedWindowRecoveryIssue?
    let canAttachFrontmost: Bool
    let attachFromAddCard: () -> Void
    let recentlyAddedWindowID: AttachedWindow.ID?
    let clearRecentlyAddedWindowID: () -> Void
    let workspaceTransitionToken: UUID?
    let detachingAttachedWindowIDs: Set<AttachedWindow.ID>
    let recover: (AttachedWindow) -> Void
    let useFrontWindow: (AttachedWindow) -> Void
    let update: (AttachedWindow.ID) -> Void
    let detach: (AttachedWindow.ID) -> Void
    let bringForward: (AttachedWindow) -> Void
    let bringAndMoveBelowCard: (AttachedWindow, CGPoint) -> Void
    let sourceBoard: (AttachedWindow.ID) -> BoardCardSource?
    let includeBoard: (SavedWorkspace.ID) -> Void
    let rejectDrop: () -> Void
    let showsAddCard: Bool
    @State private var isDropTargeted = false

    private let columns = [
        GridItem(.adaptive(minimum: 200, maximum: 240), spacing: 18, alignment: .top)
    ]

    var body: some View {
        let entranceToken = shouldAnimateWorkspaceEntrance ? workspaceTransitionToken : nil

        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
            if attachedWindows.isEmpty && showsAddCard {
                AddPinnedWindowCard(
                    canAttachFrontmost: canAttachFrontmost,
                    attachFrontmost: attachFromAddCard,
                    isEmptyState: true,
                    appearanceGeneration: attachedWindows.count,
                    workspaceTransitionToken: entranceToken,
                    workspaceTransitionIndex: 0
                )
            } else {
                ForEach(Array(attachedWindows.enumerated()), id: \.element.id) { index, attachedWindow in
                    let isPinningIn = attachedWindow.id == recentlyAddedWindowID
                    let isDetaching = detachingAttachedWindowIDs.contains(attachedWindow.id)
                    let state = stateForWindow(attachedWindow)
                    PinnedWindowCard(
                        attachedWindow: attachedWindow,
                        state: state,
                        recoveryIssue: recoveryIssue(attachedWindow.id),
                        isPinningIn: isPinningIn,
                        isDetaching: isDetaching,
                        workspaceTransitionToken: entranceToken,
                        workspaceTransitionIndex: index,
                        onPinInComplete: isPinningIn ? clearRecentlyAddedWindowID : {},
                        bringForward: { bringForward(attachedWindow) },
                        recover: { recover(attachedWindow) },
                        useFrontWindow: { useFrontWindow(attachedWindow) },
                        update: { update(attachedWindow.id) },
                        detach: { detach(attachedWindow.id) },
                        sourceBoard: sourceBoard(attachedWindow.id),
                        bringAndMoveBelowCard: { cursorScreenLocation in
                            bringAndMoveBelowCard(attachedWindow, cursorScreenLocation)
                        }
                    )
                }

                if showsAddCard {
                    AddPinnedWindowCard(
                        canAttachFrontmost: canAttachFrontmost,
                        attachFrontmost: attachFromAddCard,
                        isEmptyState: false,
                        appearanceGeneration: attachedWindows.count,
                        workspaceTransitionToken: entranceToken,
                        workspaceTransitionIndex: attachedWindows.count
                    )
                }
            }
        }
        .animation(
            .spring(response: 0.32, dampingFraction: 0.88, blendDuration: 0.06),
            value: attachedWindows.map(\.id)
        )
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.10) : Color.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    isDropTargeted ? Color.accentColor.opacity(0.45) : Color.clear,
                    style: StrokeStyle(lineWidth: 1.2, dash: [6, 5])
                )
        }
        .dropDestination(for: String.self) { items, _ in
            handleDrop(items)
        } isTargeted: { isTargeted in
            isDropTargeted = isTargeted
        }
    }

    private var shouldAnimateWorkspaceEntrance: Bool {
        attachedWindows.count < 4
    }

    private func handleDrop(_ items: [String]) -> Bool {
        guard let item = items.first else {
            rejectDrop()
            return false
        }

        if let boardID = DragPayload.boardID(from: item) {
            includeBoard(boardID)
            return true
        }

        rejectDrop()
        return false
    }
}

struct CardDetachExitModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isActive ? 0 : 1)
            .scaleEffect(reduceMotion || !isActive ? 1 : 0.96)
            .offset(y: reduceMotion || !isActive ? 0 : -8)
            .rotationEffect(.degrees(reduceMotion || !isActive ? 0 : -1.5))
            .animation(.easeInOut(duration: reduceMotion ? 0.16 : 0.24), value: isActive)
            .allowsHitTesting(!isActive)
            .accessibilityHidden(isActive)
    }
}

struct WorkspaceCardEntranceModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = true
    @State private var lastToken: UUID?

    let token: UUID?
    let index: Int
    let isEnabled: Bool

    private var delayNanoseconds: UInt64 {
        UInt64(min(Double(index) * 0.035, 0.18) * 1_000_000_000)
    }

    private var entranceAnimation: Animation {
        if reduceMotion {
            return .easeOut(duration: 0.16)
        }

        return .spring(response: 0.34, dampingFraction: 0.86, blendDuration: 0.06)
    }

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .scaleEffect(reduceMotion || visible ? 1 : 0.985)
            .offset(y: reduceMotion || visible ? 0 : 10)
            .onAppear {
                let shouldRunInitialEntrance = lastToken == nil && token != nil
                lastToken = token
                if shouldRunInitialEntrance {
                    scheduleEntrance()
                }
            }
            .onChange(of: token) { _, newToken in
                runEntranceIfNeeded(for: newToken)
            }
    }

    private func runEntranceIfNeeded(for newToken: UUID?) {
        guard isEnabled,
              let newToken,
              newToken != lastToken else {
            lastToken = newToken
            return
        }

        lastToken = newToken
        scheduleEntrance()
    }

    private func scheduleEntrance() {
        guard isEnabled else {
            visible = true
            return
        }

        visible = false

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            withAnimation(entranceAnimation) {
                visible = true
            }
        }
    }
}

struct CardPinInModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = true
    @State private var hasAnimated = false

    let isActive: Bool
    let onComplete: () -> Void

    func body(content: Content) -> some View {
        let shouldShowStartState = isActive && !hasAnimated
        let isVisible = shouldShowStartState ? false : visible

        content
            .opacity(isVisible ? 1 : 0)
            .scaleEffect(reduceMotion || isVisible ? 1 : 0.96)
            .offset(y: reduceMotion || isVisible ? 0 : -8)
            .rotationEffect(.degrees(reduceMotion || isVisible ? 0 : 1.5))
            .onAppear(perform: startIfNeeded)
            .onChange(of: isActive) { _, _ in
                startIfNeeded()
            }
    }

    private func startIfNeeded() {
        guard isActive, !hasAnimated else {
            return
        }

        hasAnimated = true
        visible = false

        Task { @MainActor in
            await Task.yield()
            withAnimation(pinAnimation) {
                visible = true
            }
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 180 : 520))
            onComplete()
        }
    }

    private var pinAnimation: Animation {
        if reduceMotion {
            .easeOut(duration: 0.16)
        } else {
            .spring(response: 0.30, dampingFraction: 0.86, blendDuration: 0.06)
        }
    }
}

struct InteractiveCardMotion: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    let cornerRadius: CGFloat
    let isEnabled: Bool
    let highlightOpacity: Double

    private let spring = Animation.interactiveSpring(
        response: 0.24,
        dampingFraction: 0.86,
        blendDuration: 0.06
    )

    private var motionEnabled: Bool {
        isEnabled && !reduceMotion
    }

    private var hoverScale: CGFloat {
        motionEnabled && isHovering ? 1.012 : 1
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(hoverScale)
            .shadow(
                color: .black.opacity(motionEnabled && isHovering ? 0.12 : 0),
                radius: motionEnabled && isHovering ? 16 : 0,
                y: motionEnabled && isHovering ? 9 : 0
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        .white.opacity(motionEnabled && isHovering ? highlightOpacity : 0),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onHover { hovering in
                guard motionEnabled else {
                    isHovering = false
                    return
                }
                withAnimation(spring) {
                    isHovering = hovering
                }
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled {
                    isHovering = false
                }
            }
    }
}

private struct AddPinnedWindowCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let canAttachFrontmost: Bool
    let attachFrontmost: () -> Void
    let isEmptyState: Bool
    let appearanceGeneration: Int
    let workspaceTransitionToken: UUID?
    let workspaceTransitionIndex: Int
    @State private var isPresenting = true
    @State private var lastAppearanceGeneration = 0

    private let baseCardSize = CGSize(width: 220, height: 308)
    private var presentationOpacity: Double {
        (canAttachFrontmost ? 1 : 0.55) * (isPresenting ? 1 : 0)
    }

    var body: some View {
        GeometryReader { proxy in
            let scale = proxy.size.width / baseCardSize.width

            Button(action: attachFrontmost) {
                addCardContent
                    .frame(width: baseCardSize.width, height: baseCardSize.height)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
            .buttonStyle(.plain)
            .disabled(!canAttachFrontmost)
        }
        .aspectRatio(baseCardSize.width / baseCardSize.height, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.18),
                                    .white.opacity(0.04),
                                    .black.opacity(0.025)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
        }
        .overlay(addCardSurfaceOverlay)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.10), radius: 10, y: 3)
        .shadow(color: .black.opacity(0.08), radius: 22, y: 10)
        .opacity(presentationOpacity)
        .scaleEffect(reduceMotion || isPresenting ? 1 : 0.96)
        .offset(y: reduceMotion || isPresenting ? 0 : 8)
        .interactiveCardMotion(
            isEnabled: canAttachFrontmost,
            highlightOpacity: 0.10
        )
        .workspaceCardEntrance(
            token: workspaceTransitionToken,
            index: workspaceTransitionIndex
        )
        .onAppear {
            lastAppearanceGeneration = appearanceGeneration
            if !isEmptyState, appearanceGeneration > 0 {
                isPresenting = false
                presentAfterDelay(milliseconds: 150)
            } else {
                isPresenting = true
            }
        }
        .onChange(of: appearanceGeneration) { _, newGeneration in
            animateNewAddCardIfNeeded(newGeneration)
        }
    }

    private func animateNewAddCardIfNeeded(_ newGeneration: Int) {
        guard newGeneration > lastAppearanceGeneration else {
            lastAppearanceGeneration = newGeneration
            return
        }

        lastAppearanceGeneration = newGeneration
        isPresenting = false
        presentAfterDelay(milliseconds: 150)
    }

    private func presentAfterDelay(milliseconds: UInt64) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(milliseconds))
            withAnimation(.easeOut(duration: 0.24)) {
                isPresenting = true
            }
        }
    }

    private var addCardContent: some View {
        VStack(spacing: 12) {
            Image(systemName: "plus")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 58, height: 58)
                .background {
                    Circle()
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.36))
                        .overlay(
                            Circle()
                                .stroke(.white.opacity(0.24), lineWidth: 1)
                        )
                }
                .shadow(color: .black.opacity(0.12), radius: 9, y: 4)

            Text(isEmptyState ? "Pin Frontmost Window" : "Add Window")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if isEmptyState {
                Text("Attach the frontmost app window to make it part of this board.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var addCardSurfaceOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    Color(nsColor: .separatorColor).opacity(0.46),
                    style: StrokeStyle(lineWidth: 1, dash: [7, 6])
                )

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .inset(by: 0.7)
                .stroke(.white.opacity(0.24), lineWidth: 1)
                .blendMode(.plusLighter)

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .inset(by: 1.2)
                .stroke(.black.opacity(0.025), lineWidth: 1)
        }
    }
}

private struct PinnedWindowCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPrimaryActionPressed = false
    @State private var isPrimaryActionPopping = false

    let attachedWindow: AttachedWindow
    let state: AttachedWindowDisplayState
    let recoveryIssue: AttachedWindowRecoveryIssue?
    let isPinningIn: Bool
    let isDetaching: Bool
    let workspaceTransitionToken: UUID?
    let workspaceTransitionIndex: Int
    let onPinInComplete: () -> Void
    let bringForward: () -> Void
    let recover: () -> Void
    let useFrontWindow: () -> Void
    let update: () -> Void
    let detach: () -> Void
    let sourceBoard: BoardCardSource?
    let bringAndMoveBelowCard: (CGPoint) -> Void

    private let baseCardSize = CGSize(width: 220, height: 308)

    var body: some View {
        GeometryReader { proxy in
            let scale = proxy.size.width / baseCardSize.width

            cardContent
                .frame(width: baseCardSize.width, height: baseCardSize.height)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .clipped()
        }
        .aspectRatio(baseCardSize.width / baseCardSize.height, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(cardBackground)
        .overlay(cardSurfaceOverlay)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(state.needsAttention ? 0.16 : 0.12), radius: 11, y: 4)
        .shadow(color: .black.opacity(state.needsAttention ? 0.10 : 0.08), radius: 24, y: 11)
        .shadow(color: appAccentColor.opacity(state == .available ? 0.12 : 0.05), radius: 20, y: 9)
        .scaleEffect(primaryActionCardScale)
        .animation(.spring(response: 0.20, dampingFraction: 0.82), value: primaryActionCardScale)
        .interactiveCardMotion(
            isEnabled: !isPinningIn && !isDetaching,
            highlightOpacity: state.needsAttention ? 0.08 : 0.12
        )
        .cardPinIn(
            isActive: isPinningIn && !isDetaching,
            onComplete: onPinInComplete
        )
        .workspaceCardEntrance(
            token: workspaceTransitionToken,
            index: workspaceTransitionIndex,
            isEnabled: !isPinningIn && !isDetaching
        )
        .cardDetachExit(isActive: isDetaching)
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(attachedWindow.window.appName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                actionsMenu
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            iconField
                .padding(.horizontal, 16)

            Divider()
                .padding(.horizontal, 16)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 6) {
                Text(windowSubtitle)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(minHeight: 30, alignment: .topLeading)

                if let sourceBoard {
                    Label(
                        sourceBoard.name,
                        systemImage: sourceBoard.isPermanent ? "pin.fill" : "rectangle.stack.fill"
                    )
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help("Included from \(sourceBoard.name)")
                }

                StatusBadge(state: state)

                Text(statusDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if shouldShowUseFrontWindow {
                    Button("Use Front Window", action: useFrontWindow)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .minimumScaleFactor(0.82)
                }

                Button(primaryActionTitle, action: primaryAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(state == .reconnecting || state == .resolving)
                    .controlSize(.small)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .minimumScaleFactor(0.82)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
    }

    private var isPrimaryActionEnabled: Bool {
        state != .reconnecting && state != .resolving && !isDetaching
    }

    private var iconField: some View {
        IconPrimaryActionField(
            appName: attachedWindow.window.appName,
            bundleURL: attachedWindow.window.bundleURL,
            bundleIdentifier: attachedWindow.window.bundleIdentifier,
            state: state,
            background: iconFieldBackground,
            strokeColor: iconFieldStroke,
            isEnabled: isPrimaryActionEnabled,
            doubleClickAction: bringAndMoveBelowCard,
            onPressChanged: setPrimaryActionPressed,
            onActionFeedback: runPrimaryActionFeedback,
            action: primaryAction
        )
    }

    private var actionsMenu: some View {
        Menu {
            Button("Save Layout", action: update)
            Button("Find or Reopen", action: recover)
                .disabled(state == .reconnecting || state == .resolving)
            if shouldShowUseFrontWindow {
                Button("Use Front Window", action: useFrontWindow)
            }
            Divider()
            Button("Detach from Board", action: detach)
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("More window actions")
    }

    private var windowSubtitle: String {
        let title = attachedWindow.window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "No window title" : title
    }

    private var statusDetail: String {
        if let recoveryIssue, state == .unavailable || state == .reconnecting {
            return recoveryIssue.detail
        }

        return switch state {
        case .available:
            "Ready"
        case .resolving:
            "Restoring saved window"
        case .minimized:
            "Minimized"
        case .unavailable:
            "Last seen window is missing"
        case .reconnecting:
            "Finding matching window"
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(state == .unavailable ? Color.red.opacity(0.085) : appAccentColor.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.22),
                                .white.opacity(0.04),
                                .black.opacity(0.035)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
    }

    private var cardSurfaceOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(cardStroke, lineWidth: strokeWidth)

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .inset(by: 0.7)
                .stroke(.white.opacity(0.30), lineWidth: 1)
                .blendMode(.plusLighter)

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .inset(by: 1.2)
                .stroke(.black.opacity(0.035), lineWidth: 1)
        }
    }

    private var iconFieldBackground: LinearGradient {
        if state == .unavailable {
            return LinearGradient(
                colors: [
                    Color(nsColor: .controlBackgroundColor).opacity(0.88),
                    Color.red.opacity(0.085),
                    Color(nsColor: .controlBackgroundColor).opacity(0.84)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        return LinearGradient(
            colors: [
                appAccentColor.opacity(0.26),
                appAccentColor.opacity(0.22),
                appAccentColor.opacity(0.18)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var iconFieldStroke: Color {
        state == .unavailable ? Color(nsColor: .separatorColor).opacity(0.42) : appAccentColor.opacity(0.32)
    }

    private var cardStroke: Color {
        switch state {
        case .available:
            appAccentColor.opacity(0.42)
        case .resolving:
            .blue.opacity(0.40)
        case .minimized:
            .orange.opacity(0.55)
        case .unavailable:
            .red.opacity(0.55)
        case .reconnecting:
            .blue.opacity(0.55)
        }
    }

    private var strokeWidth: CGFloat {
        state.needsAttention ? 1.15 : 0.8
    }

    private var primaryActionCardScale: CGFloat {
        if reduceMotion {
            1
        } else if isPrimaryActionPressed {
            0.992
        } else if isPrimaryActionPopping {
            1.012
        } else {
            1
        }
    }

    private var appAccentColor: Color {
        Color(nsColor: AppIconPalette.accentColor(
            appName: attachedWindow.window.appName,
            bundleURL: attachedWindow.window.bundleURL,
            bundleIdentifier: attachedWindow.window.bundleIdentifier
        ))
    }

    private var primaryActionTitle: String {
        switch state {
        case .available:
            "Bring Forward"
        case .resolving:
            "Restoring..."
        case .minimized:
            "Restore Window"
        case .unavailable:
            "Find or Reopen"
        case .reconnecting:
            "Finding..."
        }
    }

    private var shouldShowUseFrontWindow: Bool {
        (state == .unavailable || state == .reconnecting) && recoveryIssue?.canUseFrontWindow == true
    }

    private func primaryAction() {
        if state == .available {
            bringForward()
        } else if state != .resolving {
            recover()
        }
    }

    private func setPrimaryActionPressed(_ isPressed: Bool) {
        guard isPrimaryActionEnabled else { return }
        isPrimaryActionPressed = isPressed
    }

    private func runPrimaryActionFeedback() {
        guard isPrimaryActionEnabled, !reduceMotion else { return }

        isPrimaryActionPopping = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(115))
            withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                isPrimaryActionPopping = false
            }
        }
    }
}

struct IconPrimaryActionField: View {
    @State private var isCursorPushed = false

    let appName: String
    let bundleURL: URL?
    let bundleIdentifier: String?
    let state: AttachedWindowDisplayState
    let background: LinearGradient
    let strokeColor: Color
    let isEnabled: Bool
    var actionTitle: String? = nil
    var accessibilityLabel: String? = nil
    var doubleClickAction: ((CGPoint) -> Void)? = nil
    let onPressChanged: (Bool) -> Void
    let onActionFeedback: () -> Void
    let action: () -> Void

    var body: some View {
        Button {
            triggerAction()
        } label: {
            fieldContent
        }
        .buttonStyle(
            IconPrimaryActionButtonStyle(
                isEnabled: isEnabled,
                onPressChanged: onPressChanged
            )
        )
        .disabled(!isEnabled)
        .onHover { hovering in
            guard isEnabled else { return }

            if hovering, !isCursorPushed {
                NSCursor.pointingHand.push()
                isCursorPushed = true
            } else if !hovering, isCursorPushed {
                NSCursor.pop()
                isCursorPushed = false
            }
        }
        .onDisappear {
            if isCursorPushed {
                NSCursor.pop()
                isCursorPushed = false
            }
        }
        .help(resolvedActionTitle)
        .accessibilityLabel(Text(resolvedAccessibilityLabel))
        .accessibilityAddTraits(isEnabled ? .isButton : [])
        .frame(maxWidth: .infinity)
        .aspectRatio(188.0 / 118.0, contentMode: .fit)
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded {
                    guard isEnabled else { return }
                    doubleClickAction?(NSEvent.mouseLocation)
                }
        )
    }

    private var fieldContent: some View {
        GeometryReader { proxy in
            let iconSize = min(max(proxy.size.width * 0.52, 82), 120)

            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(background)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(strokeColor.opacity(0.82), lineWidth: 0.8)
                    )
                    .overlay(alignment: .top) {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(.white.opacity(0.34), lineWidth: 1)
                            .blendMode(.plusLighter)
                    }

                AppIconView(
                    appName: appName,
                    bundleURL: bundleURL,
                    bundleIdentifier: bundleIdentifier,
                    size: iconSize,
                    isElevated: true
                )
            }
        }
    }

    private func triggerAction() {
        guard isEnabled else { return }

        action()
        onActionFeedback()
    }

    private var primaryActionTitle: String {
        switch state {
        case .available:
            "Bring Forward"
        case .resolving:
            "Restoring..."
        case .minimized:
            "Restore Window"
        case .unavailable:
            "Find or Reopen"
        case .reconnecting:
            "Finding..."
        }
    }

    private var resolvedActionTitle: String {
        let title = actionTitle ?? primaryActionTitle
        guard doubleClickAction != nil, isEnabled, state == .available else {
            return title
        }
        return "\(title). Double-click to place below the cursor."
    }

    private var resolvedAccessibilityLabel: String {
        if let accessibilityLabel {
            return accessibilityLabel
        }

        switch state {
        case .available:
            return "Bring \(appName) forward"
        case .resolving:
            return "Restoring \(appName)"
        case .minimized:
            return "Restore \(appName) window"
        case .unavailable:
            return "Find or reopen \(appName)"
        case .reconnecting:
            return "Finding \(appName)"
        }
    }
}

private struct IconPrimaryActionButtonStyle: ButtonStyle {
    let isEnabled: Bool
    let onPressChanged: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, isPressed in
                onPressChanged(isEnabled && isPressed)
            }
            .onDisappear {
                onPressChanged(false)
            }
    }
}

private struct RecoveryPostingRow: View {
    let attachedWindow: AttachedWindow
    let state: AttachedWindowDisplayState
    let recover: () -> Void
    let detach: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(
                appName: attachedWindow.window.appName,
                bundleURL: attachedWindow.window.bundleURL,
                bundleIdentifier: attachedWindow.window.bundleIdentifier
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(attachedWindow.window.appName)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)

                Text(attachedWindow.window.title.isEmpty ? "Last saved window is not currently available." : attachedWindow.window.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            StatusBadge(state: state)

            if let title = state.recoveryActionTitle {
                Button(title, action: recover)
                    .disabled(state == .reconnecting || state == .resolving)
            }

            Button {
                detach()
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Detach from board")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.red.opacity(0.035))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.red.opacity(0.45), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct SnapshotComparisonView: View {
    let selectedWorkspace: SavedWorkspace?
    let attachedWindows: [AttachedWindow]
    let stateForWindow: (AttachedWindow) -> AttachedWindowDisplayState
    let restoreSnapshot: () -> Void
    let canRestoreSnapshot: Bool

    var body: some View {
        let savedReferences = selectedWorkspace?.windows ?? []

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                BoardSectionHeader(
                    title: "Snapshot Comparison",
                    count: savedReferences.isEmpty ? attachedWindows.count : savedReferences.count,
                    systemImage: "rectangle.stack"
                )

                Button("Restore Snapshot", action: restoreSnapshot)
                    .disabled(!canRestoreSnapshot)
            }

            VStack(spacing: 0) {
                if attachedWindows.isEmpty && savedReferences.isEmpty {
                    Text("No snapshot entries to compare.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                } else if attachedWindows.isEmpty {
                    ForEach(savedReferences) { savedReference in
                        SavedSnapshotReferenceRow(savedReference: savedReference)

                        if savedReference.id != savedReferences.last?.id {
                            Divider()
                                .padding(.leading, 14)
                        }
                    }
                } else {
                    ForEach(attachedWindows, id: \.id) { attachedWindow in
                        SnapshotComparisonRow(
                            attachedWindow: attachedWindow,
                            state: stateForWindow(attachedWindow)
                        )

                        if attachedWindow.id != attachedWindows.last?.id {
                            Divider()
                                .padding(.leading, 14)
                        }
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

private struct SavedSnapshotReferenceRow: View {
    let savedReference: SavedWindowReference

    var body: some View {
        HStack(spacing: 12) {
            Label("Saved", systemImage: "archivebox")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 112, alignment: .leading)

            AppIconView(
                appName: savedReference.appName,
                bundleURL: savedReference.bundleURL,
                bundleIdentifier: savedReference.bundleIdentifier,
                size: 18
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(savedReference.appName)
                    .lineLimit(1)

                if !savedReference.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(savedReference.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let savedOrigin = savedReference.savedOrigin {
                Text("\(Int(savedOrigin.x)), \(Int(savedOrigin.y))")
                    .foregroundStyle(.secondary)
            }

            if let savedSize = savedReference.savedSize {
                Text("\(Int(savedSize.width)) × \(Int(savedSize.height))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

private struct SnapshotComparisonRow: View {
    let attachedWindow: AttachedWindow
    let state: AttachedWindowDisplayState

    var body: some View {
        HStack(spacing: 12) {
            Label(statusTitle, systemImage: state.systemImage)
                .font(.caption.weight(.medium))
                .foregroundStyle(statusColor)
                .frame(width: 112, alignment: .leading)

            AppIconView(
                appName: attachedWindow.window.appName,
                bundleURL: attachedWindow.window.bundleURL,
                bundleIdentifier: attachedWindow.window.bundleIdentifier,
                size: 18
            )

            Text(attachedWindow.window.appName)
                .lineLimit(1)

            Spacer()

            if let savedOrigin = attachedWindow.savedReference?.savedOrigin {
                Text("\(Int(savedOrigin.x)), \(Int(savedOrigin.y))")
                    .foregroundStyle(.secondary)
            }

            if let savedSize = attachedWindow.savedReference?.savedSize {
                Text("\(Int(savedSize.width)) × \(Int(savedSize.height))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var statusTitle: String {
        switch state {
        case .available:
            "In Sync"
        case .resolving:
            "Restoring"
        case .minimized:
            "Minimized"
        case .unavailable:
            "Missing"
        case .reconnecting:
            "Finding"
        }
    }

    private var statusColor: Color {
        switch state {
        case .available:
            .green
        case .resolving:
            .blue
        case .minimized:
            .orange
        case .unavailable:
            .red
        case .reconnecting:
            .blue
        }
    }
}
