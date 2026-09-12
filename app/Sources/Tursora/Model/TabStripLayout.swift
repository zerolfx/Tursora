import Foundation

/// Geometry shared by the tab strip and its regression checks. Tab frames use
/// document coordinates; controls and the viewport use strip coordinates.
struct TabStripLayout {
    static let minimumTabWidth: CGFloat = 120
    static let maximumTabWidth: CGFloat = 320
    static let horizontalInset: CGFloat = 8
    static let controlWidth: CGFloat = 28
    static let controlGap: CGFloat = 4

    let tabCount: Int
    let tabWidth: CGFloat
    let contentWidth: CGFloat
    let viewportFrame: CGRect
    let addButtonFrame: CGRect
    let overflowButtonFrame: CGRect?

    init(width: CGFloat, height: CGFloat = 36, tabCount: Int) {
        self.tabCount = max(0, tabCount)
        let width = max(0, width), height = max(0, height)
        let inset = min(Self.horizontalInset, width / 2)
        let buttonWidth = min(Self.controlWidth, max(0, width - inset * 2))
        addButtonFrame = CGRect(x: max(inset, width - inset - buttonWidth),
                                y: max(0, (height - 28) / 2), width: buttonWidth, height: min(28, height))
        let available = max(0, addButtonFrame.minX - Self.controlGap - inset)
        let overflowing = CGFloat(self.tabCount) * Self.minimumTabWidth > available
        if overflowing {
            let overflowWidth = min(Self.controlWidth, available)
            overflowButtonFrame = CGRect(x: addButtonFrame.minX - Self.controlGap - overflowWidth,
                                         y: addButtonFrame.minY, width: overflowWidth, height: addButtonFrame.height)
        } else {
            overflowButtonFrame = nil
        }
        let viewportWidth = max(0, (overflowButtonFrame?.minX ?? addButtonFrame.minX) - Self.controlGap - inset)
        viewportFrame = CGRect(x: inset, y: 0, width: viewportWidth, height: height)
        if self.tabCount == 0 {
            tabWidth = 0
        } else {
            let equalWidth = max(Self.minimumTabWidth, viewportWidth / CGFloat(self.tabCount))
            tabWidth = self.tabCount == 1 ? min(Self.maximumTabWidth, equalWidth) : equalWidth
        }
        contentWidth = max(viewportWidth, tabWidth * CGFloat(self.tabCount))
    }

    var isOverflowing: Bool { overflowButtonFrame != nil }

    func frameForTab(_ index: Int) -> CGRect {
        guard (0..<tabCount).contains(index) else { return .zero }
        return CGRect(x: CGFloat(index) * tabWidth + 2, y: 4,
                      width: max(0, tabWidth - 4), height: max(0, viewportFrame.height - 8))
    }

    func targetIndex(atDocumentX x: CGFloat) -> Int? {
        guard tabCount > 0, tabWidth > 0 else { return nil }
        return max(0, min(tabCount - 1, Int(max(0, x) / tabWidth)))
    }
}
