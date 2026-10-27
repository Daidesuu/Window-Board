import SwiftUI

/// A disposable UI study. All state is local; no workspace, persistence or AX services are used.
struct SplitBoardPrototypeView: View {
    @State private var stateModel: PrototypeBoardDragModel
    @StateObject private var motion: PrototypeMotionPresentation
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || demoReduceMotion }
    @State private var switchSnapshot: [PrototypeBoard]?
    @State private var detailOpacity = 1.0
    @State private var switchGeneration = UUID()
    @State private var switchTask: Task<Void, Never>?
    @State private var savedFeedbackID: UUID?
    @State private var savedFeedbackTask: Task<Void, Never>?
    @State private var scrollPositions: [String: String] = [:]
    @State private var interactionEpoch = 0
    @Namespace private var sidebarMotion
    @StateObject private var drag = PrototypeDragPresentation()
    @State private var cardFrames: [String: [String: CGRect]] = [:]
    @State private var isSettingsPresented = false
    @State private var settingsBoardID = "work"
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var sharedMinimized = false
    @State private var demoReduceMotion = false
    @State private var demoDarkAppearance = false
    @State private var lastAction = "作業・資料を同時に表示中。個人タブで単独表示と比較できます。"

    init() {
        let model = PrototypeBoardDragModel()
        _stateModel = State(initialValue: model)
        _motion = StateObject(wrappedValue: PrototypeMotionPresentation(model: model))
    }

    private var renderedModel: PrototypeBoardDragModel { motion.renderedModel }
    private var boards: [PrototypeBoard] { renderedModel.boards }
    private var displayedBoards: [PrototypeBoard] { renderedModel.displayedBoards }
    private var displayTitle: String { renderedModel.displayTitle }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List {
                Section("Boards") {
                    ForEach(sidebarBoards) { board in
                        if let group = renderedModel.group(containing: board.id) {
                            groupRow(group)
                                .listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
                        } else {
                            standaloneRow(board)
                                .listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .transaction(value: motion.settlementRevision) { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
            .animation(reduceMotion ? nil : PrototypeMotionEvent.sidebarComposition.animation(reduceMotion: false), value: renderedModel.groups)
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } detail: {
            GeometryReader { geometry in
                ZStack {
                    canvasLayout(displayedBoards, viewport: geometry.size, interactive: true)
                        .opacity(detailOpacity)
                    if let snapshot = switchSnapshot {
                        canvasLayout(snapshot, viewport: geometry.size, interactive: false)
                            .opacity(1 - detailOpacity)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .onChange(of: geometry.size) { _, _ in settleMotion() }
            }
            .overlay(alignment: .bottom) {
                ZStack {
                if let payload = drag.payload, case let .card(owner, reference) = payload.kind {
                    let name = boards.first { $0.id == owner }?.name ?? owner
                    let title = boards.first { $0.id == owner }?.cards.first { $0.id == reference }?.title ?? reference
                    Label("Remove from Board — \(name) / \(title)", systemImage: "pin.slash")
                        .font(.callout).lineLimit(1).frame(maxWidth: .infinity).frame(height: 48)
                        .background(drag.target == .detach ? Color.red.opacity(0.25) : Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(dropSurface { _ in .detach })
                        .padding(.horizontal, 24).padding(.bottom, 16)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
                }
                }.animation(PrototypeMotionEvent.detachZone.animation(reduceMotion: reduceMotion), value: drag.payload != nil)
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 5) {
                    if savedFeedbackID != nil && drag.feedback.isEmpty {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).transition(.opacity)
                    }
                    Text(drag.feedback.isEmpty ? lastAction : drag.feedback).lineLimit(1)
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 24).padding(.vertical, 6).allowsHitTesting(false)
                .animation(PrototypeMotionEvent.saveFeedback.animation(reduceMotion: reduceMotion), value: savedFeedbackID)
            }
            .navigationTitle("")
        }
        .toolbar { prototypeToolbar }
        .frame(minWidth: 620, minHeight: 420)
        .preferredColorScheme(demoDarkAppearance ? .dark : nil)
        .onChange(of: reduceMotion) { _, _ in settleMotion() }
        .onDisappear { switchTask?.cancel(); savedFeedbackTask?.cancel(); motion.reset(to: stateModel) }
    }

    private func canvasLayout(_ items: [PrototypeBoard], viewport: CGSize, interactive: Bool) -> some View {
        ScrollView(.vertical) {
            PrototypeBoardLayout(viewport: viewport) {
                ForEach(items) { board in
                    canvas(board, interactive: interactive)
                        .transition(.opacity)
                }
            }
            .padding(24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .transaction(value: motion.settlementRevision) { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    @ToolbarContentBuilder
    private var prototypeToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { createBoard() } label: {
                Label("New Board", systemImage: "square.and.pencil").labelStyle(.iconOnly)
            }.help("New Board")
            Text(displayTitle).font(.title3.weight(.semibold)).lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 4)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { recordGroup("Focus") } label: {
                Label("Focus Board", systemImage: "scope").labelStyle(.iconOnly)
            }.help("Focus displayed Boards (Demo)")
            Button { recordGroup("Minimize Others") } label: {
                Label("Minimize Others", systemImage: "minus.square").labelStyle(.iconOnly)
            }.help("Minimize Others (Demo)")
            Button { lastAction = "Restore Windows（仮操作）。" } label: {
                Label("Restore Windows", systemImage: "arrow.counterclockwise").labelStyle(.iconOnly)
            }.help("Restore Windows (Demo)")
            Menu {
                Button("Refresh Window List") { lastAction = "仮データを表示中です。" }
                Button("Restore Layout") { recordGroup("Restore Layout") }
                Divider()
                Menu("Board Settings") {
                    ForEach(displayedBoards) { board in
                        Button(board.name) { showSettings(board.id) }
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
            }
            .help("More board actions")
            .popover(isPresented: $isSettingsPresented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Board Settings — \(boards.first { $0.id == settingsBoardID }?.name ?? "")").font(.headline)
                    Text("仮データのみ。実データの保存・外部ウィンドウ操作は行いません。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Save Layout") { saveBoard(settingsBoardID) }
                    Button("Remove All Windows", role: .destructive) { removeAllCards(from: settingsBoardID) }
                    Button("Done") { isSettingsPresented = false }
                }.padding(20).frame(width: 300)
            }
        }
        ToolbarItem(placement: .automatic) {
            Menu {
                Text("仮データ / 実保存・外部操作なし")
                Button("Reset Demo", action: reset)
                Button("Fail Next Save (Demo)") { clearSaveFeedback(); stateModel.failNextSave = true }
                Divider()
                Toggle("Reduce Motion (Demo)", isOn: $demoReduceMotion)
                Toggle("Dark Appearance (Demo)", isOn: $demoDarkAppearance)
            } label: { Text("Prototype").font(.caption).foregroundStyle(.secondary) }
            .help("Isolated UI prototype")
        }
    }

    private func showSettings(_ boardID: String) {
        clearSaveFeedback()
        guard boards.contains(where: { $0.id == boardID }) else { return }
        settingsBoardID = boardID
        isSettingsPresented = true
    }

    private func removeAllCards(from boardID: String) {
        applyResult(stateModel.removeAll(boardID: boardID), event: .cardInsertRemove)
    }

    private func canvas(_ board: PrototypeBoard, interactive: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(board.name, systemImage: board.symbol).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Board Settings") { showSettings(board.id) }
                    Button("Save Layout") { saveBoard(board.id) }
                    Button("Focus") { lastAction = "\(board.name)だけに Focus（仮操作）。" }
                    Button("Restore Layout") { lastAction = "\(board.name)だけに Restore Layout（仮操作）。" }
                    Divider()
                    Button("Remove All Windows", role: .destructive) { removeAllCards(from: board.id) }
                    Divider()
                    boardMenu(board)
                } label: {
                    Image(systemName: "slider.horizontal.3").font(.caption).foregroundStyle(.secondary)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .help("\(board.name)のBoard Settings")
            }.padding(.horizontal, 8)
                .overlay { if interactive { dropSurface { _ in .board(board.id) } } }
            ScrollView(.vertical) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 240), spacing: 18)],
                          alignment: .leading, spacing: 18) {
                    ForEach(board.cards) { card in
                        cardView(card, owner: board, interactive: interactive)
                            .id(card.id)
                            .transition(reduceMotion ? .opacity.animation(PrototypeMotionEvent.cardInsertRemove.animation(reduceMotion: true)) : .opacity.combined(with: .scale(scale: 0.98)))
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: PrototypeCardFramesKey.self,
                                                       value: [card.id: geometry.frame(in: .named("canvas-\(board.id)"))])
                            })
                    }
                    addCardView(board)
                }.scrollTargetLayout().padding(8)
            }
            .scrollPosition(id: scrollPosition(board.id, interactive: interactive), anchor: .top)
            .coordinateSpace(name: "canvas-\(board.id)")
            .onPreferenceChange(PrototypeCardFramesKey.self) { if interactive { cardFrames[board.id] = $0 } }
            .overlay { if interactive { dropSurface(scrolls: true) { point in cardTarget(board: board, point: point) } } }
            .accessibilityLabel("\(board.name)の独立スクロール領域")
        }
        .disabled(!interactive)
        .allowsHitTesting(interactive)
        .accessibilityHidden(!interactive)
    }

    private func scrollPosition(_ boardID: String, interactive: Bool) -> Binding<String?> {
        Binding(get: { scrollPositions[boardID] }, set: { if interactive { scrollPositions[boardID] = $0 } })
    }

    private func addCardView(_ board: PrototypeBoard) -> some View {
        GeometryReader { proxy in
            let scale = proxy.size.width / 220
            Button { addCard(to: board.id) } label: {
                VStack(spacing: 12) {
                    Image(systemName: "plus")
                        .font(.system(size: 28, weight: .medium)).foregroundStyle(.secondary)
                        .frame(width: 58, height: 58)
                        .background(Color(nsColor: .windowBackgroundColor).opacity(0.36), in: Circle())
                        .shadow(color: .black.opacity(0.12), radius: 9, y: 4)
                    Text("Add Window").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                }
                .frame(width: 220, height: 308)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }.buttonStyle(.plain)
        }
        .aspectRatio(220.0 / 308.0, contentMode: .fit)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .stroke(Color(nsColor: .separatorColor).opacity(0.46), style: StrokeStyle(lineWidth: 1, dash: [7, 6])))
        .shadow(color: .black.opacity(0.10), radius: 12, y: 5)
    }

    private func cardView(_ card: PrototypeCard, owner: PrototypeBoard, interactive: Bool = true) -> some View {
        GeometryReader { proxy in
            let scale = proxy.size.width / 220
            cardContent(card, owner: owner)
                .frame(width: 220, height: 308)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .clipped()
        }
        .aspectRatio(220.0 / 308.0, contentMode: .fit)
        .background {
            RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 16).fill(cardColor(card).opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 16)
                    .fill(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.04), .black.opacity(0.035)],
                                         startPoint: .top, endPoint: .bottom)))
        }
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(cardColor(card).opacity(0.42), lineWidth: 0.8))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .modifier(PrototypeCardHoverMotion(reduceMotion: reduceMotion, enabled: interactive && drag.payload == nil, epoch: interactionEpoch))
        .opacity(interactive && isDraggedCard(card.id, ownerID: owner.id) ? 0.55 : 1)
        .animation(PrototypeMotionEvent.dragOpacity.animation(reduceMotion: reduceMotion), value: isDraggedCard(card.id, ownerID: owner.id))
        .overlay {
            ZStack {
                if interactive, case let .card(boardID, anchorID, before) = drag.target, boardID == owner.id, anchorID == card.id {
                    HStack { if !before { Spacer() }; Rectangle().fill(drag.rejected ? Color.red : Color.accentColor).frame(width: 3); if before { Spacer() } }
                        .allowsHitTesting(false).transition(.opacity)
                }
            }
            .animation(PrototypeMotionEvent.dropHint.animation(reduceMotion: reduceMotion), value: drag.target)
        }
        .overlay {
            if interactive {
                sourceSurface(.card(ownerID: owner.id, referenceID: card.id), title: card.title, cardButtons: true) {
                    clearSaveFeedback()
                    lastAction = "\(owner.name)のカード操作（仮操作）。"
                }
            }
        }
    }

    private func cardContent(_ card: PrototypeCard, owner: PrototypeBoard) -> some View {
        let status = card.shared ? (sharedMinimized ? "Minimized" : "Available") : card.status
        let primaryTitle = status == "Unavailable" ? "Find or Reopen" : (status == "Minimized" ? "Restore Window" : "Bring Forward")
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(card.application).font(.title3.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 8)
                Menu {
                    Button("Save Layout") { saveCard(card.id, ownerID: owner.id) }
                    Button("Find or Reopen") { lastAction = "\(owner.name)の Find or Reopen（仮操作）。" }
                    Divider()
                    ForEach(boards.filter { $0.id != owner.id }) { destination in
                        Button("Move to \(destination.name)") { move(card.id, from: owner.id, to: destination.id) }
                    }
                    Button("Detach from Board") { detach(card.id, ownerID: owner.id) }
                    Button("Move Earlier") { reorder(card.id, ownerID: owner.id, earlier: true) }
                    Button("Move Later") { reorder(card.id, ownerID: owner.id, earlier: false) }
                    if card.shared {
                        Divider()
                        Button("Toggle Shared Demo State") { withAnimation(PrototypeMotionEvent.status.animation(reduceMotion: reduceMotion)) { sharedMinimized.toggle() } }
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.body.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: 26, height: 22)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden)
            }.padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)
            Button { lastAction = "\(owner.name)の \(primaryTitle)（仮操作）。" } label: {
                AppIconView(appName: card.application, bundleURL: nil, bundleIdentifier: card.bundleIdentifier,
                            size: 98, isElevated: true)
                    .frame(width: 188, height: 118)
                    .background(cardColor(card).opacity(0.22), in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(cardColor(card).opacity(0.32), lineWidth: 0.8))
            }.buttonStyle(.plain).padding(.horizontal, 16)
            Divider().padding(.horizontal, 16).padding(.top, 8)
            VStack(alignment: .leading, spacing: 6) {
                Text(card.title).font(.callout.weight(.medium)).lineLimit(2).frame(minHeight: 30, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 6) {
                    StatusBadge(state: status == "Available" ? .available : (status == "Minimized" ? .minimized : .unavailable))
                    Text(card.saved ? "Layout saved" : (status == "Available" ? "Ready" : (status == "Minimized" ? "Minimized" : "Last seen window is missing")))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                .id("\(status)-\(card.saved)")
                .transition(.opacity)
                .animation(PrototypeMotionEvent.status.animation(reduceMotion: reduceMotion), value: status)
                .animation(PrototypeMotionEvent.status.animation(reduceMotion: reduceMotion), value: card.saved)
                Spacer(minLength: 0)
                Button(primaryTitle) { lastAction = "\(owner.name)の \(primaryTitle)（仮操作）。" }
                    .buttonStyle(.borderedProminent).controlSize(.small).frame(maxWidth: .infinity)
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
        }
    }

    private var sidebarBoards: [PrototypeBoard] {
        boards.filter { board in
            guard let group = renderedModel.group(containing: board.id) else { return true }
            return boards.first { group.memberIDs.contains($0.id) }?.id == board.id
        }
    }

    private func groupRow(_ group: PrototypeSplitGroup) -> some View {
        let members = group.memberIDs.compactMap { id in boards.first { $0.id == id } }
        return VStack(alignment: .leading, spacing: 4) {
            LazyVGrid(columns: [GridItem(.flexible(minimum: 60), spacing: 6), GridItem(.flexible(minimum: 60), spacing: 6)], spacing: 6) {
                ForEach(members) { board in
                    Label(board.name, systemImage: board.symbol).font(.callout).lineLimit(2)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                        .contentShape(Rectangle())
                        .matchedGeometryEffect(id: board.id, in: sidebarMotion, properties: .position)
                        .overlay(sourceSurface(.board(board.id), title: board.name) { select(board.id) })
                        .overlay(dropSurface(scrolls: true, allowsBoards: true) { _ in .board(board.id) })
                        .contextMenu { boardMenu(board) }
                }
            }
            .overlay {
                GeometryReader { geometry in
                    Rectangle().fill(Color.primary.opacity(0.06))
                        .frame(width: 1, height: max(0, geometry.size.height - 12))
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    if members.count > 2 {
                        Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
                            .padding(.horizontal, 8).position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    }
                }.allowsHitTesting(false).accessibilityHidden(true)
            }
            HStack {
                Text("\(members.reduce(0) { $0 + $1.cards.count }) windows · 並列").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if renderedModel.selectedTarget == .group(group.id) { Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(Color.accentColor) }
            }.padding(.horizontal, 8).frame(maxWidth: .infinity).contentShape(Rectangle())
                .onTapGesture { if let first = members.first { select(first.id) } }
                .overlay(dropSurface(scrolls: true, allowsBoards: true) { _ in .group(group.id) })
        }
        .padding(EdgeInsets(top: 4, leading: 8, bottom: 6, trailing: 8))
        .background { selectionBackground(selected: renderedModel.selectedTarget == .group(group.id)) }
        .overlay(alignment: .top) { Divider().padding(.horizontal, 16).allowsHitTesting(false) }
    }

    private func standaloneRow(_ board: PrototypeBoard) -> some View {
        HStack(spacing: 8) {
            Image(systemName: board.symbol).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(board.name).font(.callout)
                Text("\(board.cards.count) windows").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if renderedModel.selectedTarget == .standalone(board.id) { Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(Color.accentColor) }
        }
        .padding(.horizontal, 16).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        .matchedGeometryEffect(id: board.id, in: sidebarMotion, properties: .position)
        .background { selectionBackground(selected: renderedModel.selectedTarget == .standalone(board.id)) }
        .overlay(sourceSurface(.board(board.id), title: board.name) { select(board.id) })
        .overlay(dropSurface(scrolls: true, allowsBoards: true) { _ in .board(board.id) })
        .overlay(alignment: .top) { Divider().padding(.horizontal, 16).allowsHitTesting(false) }
        .contextMenu { boardMenu(board) }
    }

    private func selectionBackground(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(selected ? Color.accentColor.opacity(0.18) : Color.clear)
            .animation(PrototypeMotionEvent.selection.animation(reduceMotion: reduceMotion), value: selected)
    }

    @ViewBuilder private func boardMenu(_ board: PrototypeBoard) -> some View {
        Menu("並列グループへ追加 / 移動") {
            ForEach(boards.filter { $0.id != board.id }) { destination in
                Button(destination.name) { menuCommit(.board(board.id), target: .board(destination.id)) }
            }
        }
        if renderedModel.group(containing: board.id) != nil {
            Button("グループから解除") { applyResult(stateModel.separate(boardID: board.id), event: .composition) }
        }
    }

    private func sourceSurface(_ kind: PrototypeDragKind, title: String, cardButtons: Bool = false, click: @escaping () -> Void) -> some View {
        PrototypeDragSurface(presentation: drag, source: kind, title: title, excludesCardButtons: cardButtons,
                             click: click, begin: { kind in
                                 settleMotion()
                                 clearSaveFeedback()
                                 guard let payload = stateModel.beginDrag(kind: kind) else { return nil }
                                 motion.beginNativeDrag()
                                 return payload
                             }, sourceEnded: { token in
                                 guard drag.payload?.sessionToken == token else { return }
                                 stateModel.endDrag()
                                 motion.nativeDragEnded(reduceMotion: reduceMotion)
                             }, reduceMotion: reduceMotion)
    }

    private func dropSurface(scrolls: Bool = false, allowsBoards: Bool = false, destination: @escaping (CGPoint) -> PrototypeDropTarget?) -> some View {
        PrototypeDragSurface(presentation: drag, destination: { point in
            guard let target = destination(point), let payload = drag.payload else { return nil }
            switch payload.kind {
            case .board:
                guard allowsBoards else { return nil }
                switch target { case .board, .group: return target; default: return nil }
            case .card:
                if case .group = target { return nil }; return target
            }
        }, accepts: { stateModel.validate($0, to: $1) }, feedback: targetDescription,
                             commit: { payload, target in
                                 let result = stateModel.commit(payload, to: target)
                                 applyResult(result, event: motionEvent(payload.kind, target: target))
                                 return result
                             }, scrolls: scrolls, reduceMotion: reduceMotion)
    }

    private func targetDescription(_ target: PrototypeDropTarget) -> String {
        func name(_ id: String) -> String { boards.first { $0.id == id }?.name ?? id }
        switch target {
        case let .board(id): return "\(drag.payload.map { if case .board = $0.kind { return "並列化" }; return "Move to" } ?? "Move to") \(name(id))"
        case let .group(id): return "並列グループへ追加: \(stateModel.groups.first { $0.id == id }?.memberIDs.map(name).joined(separator: " + ") ?? id)"
        case let .card(id, _, before): return "\(name(id)): \(before ? "前へ挿入" : "後へ挿入")"
        case let .append(id): return "Move to \(name(id)) — 末尾"
        case .detach: return "元の所有Boardから参照を解除"
        }
    }

    private func cardTarget(board: PrototypeBoard, point: CGPoint) -> PrototypeDropTarget {
        let frames = cardFrames[board.id] ?? [:]
        let ordered = board.cards.compactMap { card -> (String, CGRect)? in frames[card.id].map { (card.id, $0) } }
        if let item = ordered.first(where: { $0.1.contains(point) }) {
            return .card(boardID: board.id, anchorID: item.0, before: point.x < item.1.midX)
        }
        var rows: [[(String, CGRect)]] = []
        for item in ordered {
            if let index = rows.firstIndex(where: { abs(($0.first?.1.minY ?? 0) - item.1.minY) < 2 }) { rows[index].append(item) }
            else { rows.append([item]) }
        }
        rows.sort { ($0.first?.1.minY ?? 0) < ($1.first?.1.minY ?? 0) }
        for row in rows {
            for index in 0..<max(0, row.count - 1) {
                let left = row[index], right = row[index + 1]
                let gutter = CGRect(x: left.1.maxX, y: max(left.1.minY, right.1.minY),
                                    width: max(0, right.1.minX - left.1.maxX), height: min(left.1.height, right.1.height))
                if gutter.contains(point) { return .card(boardID: board.id, anchorID: left.0, before: false) }
            }
        }
        for index in 0..<max(0, rows.count - 1) {
            let previous = rows[index], next = rows[index + 1]
            guard let previousLast = previous.last, let nextFirst = next.first else { continue }
            let bottom = previous.map { $0.1.maxY }.max() ?? 0
            let top = next.map { $0.1.minY }.min() ?? 0
            let left = (previous + next).map { $0.1.minX }.min() ?? 0
            let right = (previous + next).map { $0.1.maxX }.max() ?? 0
            let gutter = CGRect(x: left, y: bottom, width: right - left, height: max(0, top - bottom))
            if gutter.contains(point) {
                let _ = previousLast
                return .card(boardID: board.id, anchorID: nextFirst.0, before: true)
            }
        }
        return .append(board.id)
    }

    private func isDraggedCard(_ id: String, ownerID: String) -> Bool { drag.payload?.kind == .card(ownerID: ownerID, referenceID: id) }
    private func select(_ id: String) {
        let previous = renderedModel.displayedBoards
        let oldTarget = stateModel.selectedTarget
        stateModel.select(boardID: id)
        guard stateModel.selectedTarget != oldTarget else { return }
        clearTransientFeedback()
        switchSnapshot = previous
        detailOpacity = 0
        motion.receive(model: stateModel, event: .switchDisplay, result: .applied, reduceMotion: reduceMotion)
        let generation = switchGeneration
        switchTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled, switchGeneration == generation else { return }
            withAnimation(PrototypeMotionEvent.switchDisplay.animation(reduceMotion: reduceMotion)) { detailOpacity = 1 }
            try? await Task.sleep(for: .seconds(PrototypeMotionEvent.switchDisplay.duration(reduceMotion: reduceMotion)))
            guard !Task.isCancelled, switchGeneration == generation else { return }
            switchSnapshot = nil
        }
        lastAction = "\(displayTitle)を表示。"
    }
    private func addCard(to id: String) { applyResult(stateModel.addCard(to: id), event: .cardInsertRemove) }
    private func saveBoard(_ id: String) { saveResult(stateModel.saveLayout(boardID: id)) }
    private func saveCard(_ id: String, ownerID: String) { saveResult(stateModel.saveLayout(boardID: ownerID, referenceID: id)) }
    private func createBoard() {
        clearSaveFeedback()
        applyResult(stateModel.createBoard(name: "Board \(boards.count + 1)"), event: .composition)
    }
    private func motionEvent(_ kind: PrototypeDragKind, target: PrototypeDropTarget) -> PrototypeMotionEvent {
        if case .board = kind { return .composition }
        if case .detach = target { return .cardInsertRemove }
        return .cardMove
    }
    private func applyResult(_ result: PrototypeDragResult, event: PrototypeMotionEvent) {
        clearSaveFeedback()
        lastAction = result.message
        motion.receive(model: stateModel, event: event, result: result, reduceMotion: reduceMotion)
    }
    private func saveResult(_ result: PrototypeDragResult) {
        applyResult(result, event: .status)
        guard result == .applied else { return }
        let token = UUID()
        savedFeedbackID = token
        savedFeedbackTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, savedFeedbackID == token else { return }
            savedFeedbackID = nil
        }
    }
    private func clearSaveFeedback() {
        savedFeedbackTask?.cancel()
        savedFeedbackTask = nil
        savedFeedbackID = nil
    }
    private func clearTransientFeedback() {
        switchTask?.cancel()
        switchTask = nil
        switchGeneration = UUID()
        switchSnapshot = nil
        detailOpacity = 1
        clearSaveFeedback()
        interactionEpoch += 1
    }
    private func settleMotion() {
        clearTransientFeedback()
        // Geometry/accessibility changes during a live drag must not release its source.
        if !motion.isNativeDragActive { motion.settle() }
    }
    private func menuCommit(_ kind: PrototypeDragKind, target: PrototypeDropTarget) {
        guard let payload = stateModel.beginDrag(kind: kind) else { clearSaveFeedback(); lastAction = "処理中のため変更できません。"; return }
        applyResult(stateModel.commit(payload, to: target), event: motionEvent(kind, target: target))
        stateModel.endDrag()
    }
    private func detach(_ id: String, ownerID: String) { menuCommit(.card(ownerID: ownerID, referenceID: id), target: .detach) }
    private func move(_ id: String, from owner: String, to destination: String) { menuCommit(.card(ownerID: owner, referenceID: id), target: .append(destination)) }
    private func reorder(_ id: String, ownerID: String, earlier: Bool) {
        guard let cards = boards.first(where: { $0.id == ownerID })?.cards, let index = cards.firstIndex(where: { $0.id == id }) else { return }
        let other = index + (earlier ? -1 : 1)
        guard cards.indices.contains(other) else { return }
        menuCommit(.card(ownerID: ownerID, referenceID: id), target: .card(boardID: ownerID, anchorID: cards[other].id, before: earlier))
    }
    private func recordGroup(_ action: String) { clearSaveFeedback(); lastAction = "表示中のBoard（\(displayTitle)）に \(action)（仮操作）。" }
    private func reset() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            clearTransientFeedback()
            stateModel = PrototypeBoardDragModel()
            motion.reset(to: stateModel)
            drag.clear()
            sharedMinimized = false
            cardFrames = [:]
            scrollPositions = [:]
        }
    }
    private func cardColor(_ card: PrototypeCard) -> Color {
        switch card.tint { case "blue": .blue; case "cyan": .cyan; case "gray": .gray; case "orange": .orange; case "purple": .purple; default: .indigo }
    }
}


private struct PrototypeCardHoverMotion: ViewModifier {
    let reduceMotion: Bool
    let enabled: Bool
    let epoch: Int
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .shadow(color: .black.opacity(hovered && enabled && !reduceMotion ? 0.17 : 0.11),
                    radius: hovered && enabled && !reduceMotion ? 15 : 12, y: 5)
            .onHover { hovered = $0 && enabled }
            .onChange(of: enabled) { _, _ in hovered = false }
            .onChange(of: epoch) { _, _ in hovered = false }
            .animation(reduceMotion ? nil : PrototypeMotionEvent.hover.animation(reduceMotion: false), value: hovered)
    }
}
