import SwiftUI

/// One layout host for every prototype composition and viewport size.
/// The caller supplies the full viewport and applies 24pt padding outside this layout.
/// Keep a direct, Board-ID-keyed ForEach here so a Board keeps its canvas and scroll view
/// when its slot changes or the layout changes between tiled and stacked presentation.
struct PrototypeBoardLayout: Layout {
    var viewport: CGSize

    static let outerPadding: CGFloat = 24
    static let spacing: CGFloat = 12
    static let minimumCanvasSize = CGSize(width: 280, height: 240)

    struct Metrics: Equatable {
        let isStacked: Bool
        let columns: Int
        let rows: Int
        /// Excludes the caller's outer padding.
        let contentSize: CGSize
        let canvasSize: CGSize
    }

    /// Pure sizing contract, shared by layout placement and the caller's scroll policy.
    static func metrics(viewport: CGSize, count: Int) -> Metrics {
        let count = max(0, count)
        guard count > 0 else {
            return Metrics(isStacked: false, columns: 0, rows: 0, contentSize: .zero, canvasSize: .zero)
        }
        let width = available(viewport.width)
        let height = available(viewport.height)
        let columns = count == 1 ? 1 : 2
        let rows = count <= 2 ? 1 : 2
        let requiredWidth = CGFloat(columns) * minimumCanvasSize.width + CGFloat(columns - 1) * spacing
        let requiredHeight = CGFloat(rows) * minimumCanvasSize.height + CGFloat(rows - 1) * spacing
        let isStacked = count > 4 || width < requiredWidth || height < requiredHeight
        if isStacked {
            let canvasHeight = max(minimumCanvasSize.height, height)
            return Metrics(
                isStacked: true, columns: 1, rows: count,
                contentSize: CGSize(width: width, height: CGFloat(count) * canvasHeight + CGFloat(count - 1) * spacing),
                canvasSize: CGSize(width: width, height: canvasHeight)
            )
        }
        return Metrics(
            isStacked: false, columns: columns, rows: rows,
            contentSize: CGSize(width: width, height: height),
            canvasSize: CGSize(
                width: (width - CGFloat(columns - 1) * spacing) / CGFloat(columns),
                height: (height - CGFloat(rows - 1) * spacing) / CGFloat(rows)
            )
        )
    }

    /// Local content coordinates: the caller's padding is deliberately not included.
    /// With three Boards only three frames exist; the fourth grid slot stays empty.
    static func frames(viewport: CGSize, count: Int) -> [CGRect] {
        let metrics = metrics(viewport: viewport, count: count)
        guard metrics.columns > 0 else { return [] }
        return (0..<max(0, count)).map { index in
            CGRect(
                x: CGFloat(index % metrics.columns) * (metrics.canvasSize.width + spacing),
                y: CGFloat(index / metrics.columns) * (metrics.canvasSize.height + spacing),
                width: metrics.canvasSize.width,
                height: metrics.canvasSize.height
            )
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        Self.metrics(viewport: viewport, count: subviews.count).contentSize
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = Self.frames(viewport: viewport, count: subviews.count)
        for (index, subview) in subviews.enumerated() {
            let frame = frames[index]
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private static func available(_ extent: CGFloat) -> CGFloat {
        guard extent.isFinite else { return 0 }
        return max(0, extent - outerPadding * 2)
    }
}
