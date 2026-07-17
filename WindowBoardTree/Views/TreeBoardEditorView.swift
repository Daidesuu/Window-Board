import SwiftUI

struct TreeBoardEditorRequest: Identifiable {
    enum Kind {
        case create(parentID: SavedWorkspace.ID)
        case rename(boardID: SavedWorkspace.ID)
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let message: String
    let actionTitle: String
    let initialName: String

    static func create(parent: SavedWorkspace) -> TreeBoardEditorRequest {
        TreeBoardEditorRequest(
            kind: .create(parentID: parent.id),
            title: "New Board",
            message: "Create a child Board inside \(parent.name).",
            actionTitle: "Create",
            initialName: ""
        )
    }

    static func rename(board: SavedWorkspace) -> TreeBoardEditorRequest {
        TreeBoardEditorRequest(
            kind: .rename(boardID: board.id),
            title: "Rename Board",
            message: "Choose a new name for this Board.",
            actionTitle: "Rename",
            initialName: board.name
        )
    }
}

struct TreeBoardEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isNameFocused: Bool

    let request: TreeBoardEditorRequest
    let onCommit: (String) -> Bool

    @State private var name: String

    init(
        request: TreeBoardEditorRequest,
        onCommit: @escaping (String) -> Bool
    ) {
        self.request = request
        self.onCommit = onCommit
        _name = State(initialValue: request.initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(request.title)
                    .font(.title2.weight(.semibold))
                Text(request.message)
                    .foregroundStyle(.secondary)
            }

            TextField("Board Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isNameFocused)
                .onSubmit(commit)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(request.actionTitle) {
                    commit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
        .task {
            isNameFocused = true
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit() {
        guard !trimmedName.isEmpty, onCommit(trimmedName) else { return }
        dismiss()
    }
}
