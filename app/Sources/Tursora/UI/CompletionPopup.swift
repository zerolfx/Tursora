import AppKit

/// The candidate list under the address bar's text field. A borderless,
/// non-activating child panel: it never takes key focus, so typing keeps
/// going into the field while ↑/↓ and clicks pick from the list.
final class CompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    var onChoose: ((String) -> Void)?

    private(set) var candidates: [String] = []
    private let panel: NSPanel
    private let table = ClickTableView()
    private let scroll = NSScrollView()
    private weak var parent: NSWindow?
    private let rowHeight: CGFloat = 22
    private let maxRows = 8

    final class NonKeyPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// A clip view that anchors its document at the top. The default clip
    /// view is not flipped, so a table that is shorter than (or exactly as
    /// tall as) the clip sits at the *bottom* — rows got cut off by the
    /// panel's edge.
    private final class FlippedClipView: NSClipView {
        override var isFlipped: Bool { true }
    }

    /// Table that reports clicks without wanting focus.
    private final class ClickTableView: NSTableView {
        var onClickRow: ((Int) -> Void)?
        override var acceptsFirstResponder: Bool { false }
        override func mouseDown(with event: NSEvent) {
            let row = self.row(at: convert(event.locationInWindow, from: nil))
            if row >= 0 { onClickRow?(row) }
        }
    }

    override init() {
        panel = NonKeyPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true

        let content = NSView()
        content.wantsLayer = true
        content.layer?.cornerRadius = 8
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        content.layer?.borderColor = NSColor.separatorColor.cgColor
        content.layer?.borderWidth = 1
        panel.contentView = content

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain                 // .inset (the default) pads 5pt top and bottom
        table.rowSizeStyle = .custom         // honour rowHeight
        table.rowHeight = rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.selectionHighlightStyle = .regular
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.onClickRow = { [weak self] row in
            guard let self, self.candidates.indices.contains(row) else { return }
            self.onChoose?(self.candidates[row])
        }
        scroll.contentView = FlippedClipView()          // before documentView
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets()
        content.pinToEdges(scroll, insets: NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0))
    }

    var isVisible: Bool { panel.isVisible }
    var selectedCandidate: String? { candidates.indices.contains(table.selectedRow) ? candidates[table.selectedRow] : nil }

    /// Show `candidates` in a list anchored under `fieldRectOnScreen`.
    func show(_ candidates: [String], below fieldRectOnScreen: NSRect, in window: NSWindow) {
        self.candidates = candidates
        table.reloadData()
        table.deselectAll(nil)
        guard !candidates.isEmpty else { hide(); return }
        let rows = min(candidates.count, maxRows)
        let height = CGFloat(rows) * rowHeight + 8
        let frame = NSRect(x: fieldRectOnScreen.minX, y: fieldRectOnScreen.minY - height - 2,
                           width: max(fieldRectOnScreen.width, 160), height: height)
        panel.setFrame(frame, display: false)
        // Settle geometry now, then pin the list to its top: the clip view
        // may still be scrolled from a previous, longer list.
        panel.contentView?.layoutSubtreeIfNeeded()
        table.tile()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        if parent !== window {
            parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
            parent = window
        }
        panel.orderFront(nil)
    }

    /// For the smoke test: where the first row sits inside the panel's content
    /// view (non-flipped coordinates, y up) and the panel/clip/table heights.
    var geometryForTesting: (panelHeight: CGFloat, clipHeight: CGFloat, tableHeight: CGFloat, firstRow: NSRect) {
        let first = table.numberOfRows > 0 ? table.convert(table.rect(ofRow: 0), to: panel.contentView) : .zero
        return (panel.frame.height, scroll.contentView.bounds.height, table.frame.height, first)
    }

    func hide() {
        guard panel.isVisible else { return }
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        parent = nil
    }

    /// ↑/↓ — wraps around; from no selection, ↓ picks the first and ↑ the last.
    func moveSelection(by delta: Int) {
        let n = candidates.count
        guard n > 0 else { return }
        let current = table.selectedRow
        let next = current < 0 ? (delta > 0 ? 0 : n - 1) : (current + delta + n) % n
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { candidates.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("candidate")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView)
            ?? NSTableCellView.make(identifier: id, withIcon: true)
        let name = candidates[row]
        cell.textField?.stringValue = name.hasSuffix("/") ? String(name.dropLast()) : name
        cell.imageView?.image = NSWorkspace.shared.icon(for: .folder)
        return cell
    }
}
