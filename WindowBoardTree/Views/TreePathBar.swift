import SwiftUI

struct TreePathBar: View {
    let boards: [SavedWorkspace]
    let currentBoardID: SavedWorkspace.ID
    let onOpenBoard: (SavedWorkspace.ID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(Array(boards.enumerated()), id: \.element.id) { index, board in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }

                    Button(board.name) {
                        onOpenBoard(board.id)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(board.id == currentBoardID ? .primary : .secondary)
                    .fontWeight(board.id == currentBoardID ? .semibold : .regular)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityLabel("Board path")
    }
}
