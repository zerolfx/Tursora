import Foundation

/// Geometry shared by the tab strip and its regression checks. Tab frames use
/// document coordinates; controls and the viewport use strip coordinates.
struct TabStripLayout {
    static let minimumTabWidth: CGFloat = 120
    /// The width a tab settles at when the strip has room to spare. Browsers
    /// stop growing tabs well before the window edge; so do we (D79).
    static let preferredTabWidth: CGFloat = 240
    /// The soft cap: a tab may pass `preferredTabWidth` when its own title
    /// needs the room and the strip can spare it, but never this.
    static let maximumTabWidth: CGFloat = 480
    static let horizontalInset: CGFloat = 8
    static let controlWidth: CGFloat = 28
    static let controlGap: CGFloat = 4

    let tabCount: Int
    let tabWidth: CGFloat
    let contentWidth: CGFloat
    let viewportFrame: CGRect
    let addButtonFrame: CGRect
    let overflowButtonFrame: CGRect?
    /// True when the tabs do not fill the strip and New Tab sits right after
    /// them instead of at the trailing edge.
    let addButtonFollowsTabs: Bool

    /// `naturalTabWidth` is the width the widest title would need with nothing
    /// truncated, measured by the view. Zero means "unmeasured", which settles
    /// every tab at `preferredTabWidth` or below.
    init(width: CGFloat, height: CGFloat = 36, tabCount: Int, naturalTabWidth: CGFloat = 0) {
        self.tabCount = max(0, tabCount)
        let width = max(0, width), height = max(0, height)
        let inset = min(Self.horizontalInset, width / 2)
        let buttonWidth = min(Self.controlWidth, max(0, width - inset * 2))
        let buttonY = max(0, (height - 28) / 2)
        let buttonHeight = min(28, height)
        // Widest the tab area could be: New Tab pinned to the trailing edge.
        let pinnedX = max(inset, width - inset - buttonWidth)
        let pinnedViewport = max(0, pinnedX - Self.controlGap - inset)
        let overflowing = CGFloat(self.tabCount) * Self.minimumTabWidth > pinnedViewport
        if overflowing {
            let overflowWidth = min(Self.controlWidth, pinnedViewport)
            overflowButtonFrame = CGRect(x: pinnedX - Self.controlGap - overflowWidth,
                                         y: buttonY, width: overflowWidth, height: buttonHeight)
        } else {
            overflowButtonFrame = nil
        }
        let available = max(0, (overflowButtonFrame?.minX ?? pinnedX) - Self.controlGap - inset)
        if self.tabCount == 0 {
            tabWidth = 0
        } else {
            // Share the strip equally, but stop at the preferred width unless
            // the title itself needs more, and never past the hard ceiling.
            let fairShare = available / CGFloat(self.tabCount)
            let wanted = min(Self.maximumTabWidth, max(Self.preferredTabWidth, max(0, naturalTabWidth)))
            tabWidth = max(Self.minimumTabWidth, min(fairShare, wanted))
        }
        let tabsWidth = tabWidth * CGFloat(self.tabCount)
        // Pinning New Tab to the far edge of a half-empty strip puts it nowhere
        // near the tabs it adds to, so it follows them instead (D79).
        addButtonFollowsTabs = self.tabCount > 0 && !overflowing && tabsWidth < available
        let viewportWidth = addButtonFollowsTabs ? tabsWidth : available
        addButtonFrame = CGRect(x: addButtonFollowsTabs ? inset + tabsWidth + Self.controlGap : pinnedX,
                                y: buttonY, width: buttonWidth, height: buttonHeight)
        viewportFrame = CGRect(x: inset, y: 0, width: viewportWidth, height: height)
        contentWidth = max(viewportWidth, tabsWidth)
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
