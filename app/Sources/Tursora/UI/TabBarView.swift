import AppKit

/// Dolphin-style tab strip: compact tabs with a close button, a `+` at the
/// end, middle-click to close, and drag to reorder. Draws itself; the
/// controller only feeds it titles and a selected index.
final class TabBarView: NSView {

    static let height: CGFloat = 30

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onAdd: (() -> Void)?
    var onMove: ((Int, Int) -> Void)?
    var menuForTab: ((Int) -> NSMenu?)?
    /// A tab is being dragged below the strip, over the content (window
    /// point), or came back (nil). Index is the tab's original position.
    var onDragOutside: ((Int, NSPoint?) -> Void)?
    /// A tab was dropped below the strip.
    var onDropOutside: ((Int, NSPoint) -> Void)?

    // Files dragged over the strip (Dolphin semantics): hovering a tab for
    // 800 ms activates it; dropping on a tab lands in its folder; dropping on
    // empty strip space opens folders as new tabs.
    var onFilesDroppedOnTab: ((Int?, [URL], NSDragOperation) -> Void)?
    var onAutoActivateTab: ((Int) -> Void)?
    /// Asked while hovering so the cursor badge matches what a drop would do.
    var dropOperationForTab: ((Int?, [URL], NSDragOperation) -> NSDragOperation)?
    static let autoActivationDelay: TimeInterval = 0.8

    private(set) var titles: [String] = []
    private(set) var selectedIndex = 0
    private(set) var toolTips: [String] = []
    private var items: [TabItemView] = []
    private let addButton = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addButton.bezelStyle = .accessoryBarAction
        addButton.showsBorderOnlyWhileMouseInside = true
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")
        addButton.toolTip = "New Tab (⌘T)"
        addButton.target = self
        addButton.action = #selector(addClicked)
        addSubview(addButton)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    func reload(titles: [String], selected: Int, toolTips: [String]? = nil) {
        self.titles = titles
        self.toolTips = toolTips ?? titles
        self.selectedIndex = selected
        while items.count < titles.count {
            let v = TabItemView(bar: self)
            addSubview(v)
            items.append(v)
        }
        while items.count > titles.count {
            items.removeLast().removeFromSuperview()
        }
        for (i, v) in items.enumerated() {
            v.index = i
            v.title = titles[i]
            v.toolTip = self.toolTips.indices.contains(i) ? self.toolTips[i] : titles[i]
            v.isSelected = i == selected
        }
        needsLayout = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let index = tabIndex(at: convert(event.locationInWindow, from: nil)) else { return nil }
        return menuForTab?(index)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    // MARK: - Layout

    private let addWidth: CGFloat = 28
    private let pad: CGFloat = 6

    var tabWidth: CGFloat {
        guard !items.isEmpty else { return 0 }
        let avail = bounds.width - addWidth - pad * 3
        return min(220, max(80, avail / CGFloat(items.count)))
    }

    override func layout() {
        super.layout()
        let w = tabWidth
        var x = pad
        for (i, v) in items.enumerated() {
            if v === dragging { x += w; continue }         // dragged item follows the mouse
            v.frame = NSRect(x: x, y: 3, width: w - 2, height: bounds.height - 4)
            _ = i; x += w
        }
        addButton.frame = NSRect(x: min(x + 2, bounds.width - addWidth - pad), y: (bounds.height - 22) / 2, width: addWidth, height: 22)
    }

    // MARK: - Files dragged over the strip

    private var hoverTabIndex: Int? { didSet { if hoverTabIndex != oldValue { updateDropHighlight() } } }
    private var autoActivation: DispatchWorkItem?

    func tabIndex(at point: NSPoint) -> Int? {
        items.first { $0.frame.contains(point) && !$0.isHidden }?.index
    }

    private func droppedFileURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        // A tab being reordered is our own drag, handled by TabItemView, not a file drop.
        guard sender.draggingSource as? TabBarView !== self else { return [] }
        let urls = droppedFileURLs(sender)
        guard !urls.isEmpty else { return [] }
        let index = tabIndex(at: convert(sender.draggingLocation, from: nil))
        if index != hoverTabIndex { beginAutoActivation(index) }
        hoverTabIndex = index
        return dropOperationForTab?(index, urls, sender.draggingSourceOperationMask) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { endHover() }
    override func draggingEnded(_ sender: NSDraggingInfo) { endHover() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedFileURLs(sender)
        let index = tabIndex(at: convert(sender.draggingLocation, from: nil))
        endHover()
        return performDrop(urls: urls, sourceMask: sender.draggingSourceOperationMask, onTabAt: index)
    }

    /// The drop itself, separated from the session so it can be exercised directly.
    @discardableResult
    func performDrop(urls: [URL], sourceMask: NSDragOperation, onTabAt index: Int?) -> Bool {
        guard !urls.isEmpty, let op = dropOperationForTab?(index, urls, sourceMask), !op.isEmpty else { return false }
        onFilesDroppedOnTab?(index, urls, op)
        return true
    }

    /// Dolphin: hovering a tab with a drag switches to it after 800 ms, so the
    /// drop can then go anywhere in that tab's content.
    func beginAutoActivation(_ index: Int?) {
        autoActivation?.cancel()
        guard let index, index != selectedIndex else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hoverTabIndex == index else { return }
            self.onAutoActivateTab?(index)
        }
        autoActivation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoActivationDelay, execute: work)
    }

    var hasPendingAutoActivation: Bool { autoActivation != nil && !(autoActivation?.isCancelled ?? true) }
    var hoverTabIndexForTesting: Int? {
        get { hoverTabIndex }
        set { hoverTabIndex = newValue }
    }
    func tabFrameForTesting(_ index: Int) -> NSRect { items.indices.contains(index) ? items[index].frame : .zero }

    private func endHover() {
        autoActivation?.cancel(); autoActivation = nil
        hoverTabIndex = nil
    }

    private func updateDropHighlight() {
        for v in items { v.isDropTarget = v.index == hoverTabIndex }
    }

    // MARK: - Interaction (called by TabItemView)

    fileprivate func select(_ item: TabItemView) { onSelect?(item.index) }
    fileprivate func close(_ item: TabItemView) { onClose?(item.index) }
    @objc private func addClicked() { onAdd?() }

    private var dragging: TabItemView?
    private var dragOffset: CGFloat = 0
    private var dragOrigin = 0
    private var draggingOutside = false

    fileprivate func beginDrag(_ item: TabItemView, at point: NSPoint) {
        dragging = item
        dragOrigin = item.index
        dragOffset = point.x - item.frame.minX
        addSubview(item)  // bring to front
    }

    fileprivate func drag(to point: NSPoint, windowPoint: NSPoint) {
        guard let d = dragging else { return }
        // Below the strip (the view is not flipped, so "below" is negative y):
        // the drag is over the content area — a split-view drop, not a reorder.
        let outside = point.y < -8
        if outside != draggingOutside {
            draggingOutside = outside
            if !outside { onDragOutside?(dragOrigin, nil) }
        }
        if outside { onDragOutside?(dragOrigin, windowPoint); return }
        var f = d.frame
        f.origin.x = max(pad, min(point.x - dragOffset, bounds.width - addWidth - pad * 2 - f.width))
        d.frame = f
        // Reorder when the dragged tab's centre crosses into a neighbour's slot.
        let slot = Int((f.midX - pad) / tabWidth)
        let target = max(0, min(items.count - 1, slot))
        if target != d.index {
            items.remove(at: d.index)
            items.insert(d, at: target)
            for (i, v) in items.enumerated() { v.index = i }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                needsLayout = true
                layoutSubtreeIfNeeded()
            }
        }
    }

    fileprivate func endDrag(windowPoint: NSPoint) {
        guard let d = dragging else { return }
        dragging = nil
        let wasOutside = draggingOutside
        draggingOutside = false
        needsLayout = true
        if wasOutside { onDropOutside?(dragOrigin, windowPoint); return }
        let from = dragOrigin, to = d.index
        if from != to { onMove?(from, to) }
    }
}

private final class TabItemView: NSView {
    unowned let bar: TabBarView
    var index = 0
    var title: String = "" { didSet { label.stringValue = title; toolTip = title } }
    var isSelected = false { didSet { needsDisplay = true; closeButton.isHidden = !(isSelected || hovered) } }
    var isDropTarget = false { didSet { needsDisplay = true } }

    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var hovered = false { didSet { needsDisplay = true; closeButton.isHidden = !(isSelected || hovered) } }
    private var tracking: NSTrackingArea?
    private var dragStart: NSPoint?
    private var didDrag = false

    init(bar: TabBarView) {
        self.bar = bar
        super.init(frame: .zero)
        wantsLayer = true
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.lineBreakMode = .byTruncatingMiddle
        label.alignment = .center
        addSubview(label)
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")
        closeButton.symbolConfiguration = .init(pointSize: 9, weight: .bold)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.isHidden = true
        closeButton.toolTip = "Close Tab"
        addSubview(closeButton)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        closeButton.frame = NSRect(x: 4, y: (bounds.height - 16) / 2, width: 16, height: 16)
        label.frame = NSRect(x: 22, y: (bounds.height - 16) / 2, width: bounds.width - 30, height: 16)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        if isSelected {
            NSColor.controlBackgroundColor.setFill(); path.fill()
            NSColor.separatorColor.setStroke(); path.lineWidth = 1; path.stroke()
        } else if hovered {
            NSColor.labelColor.withAlphaComponent(0.06).setFill(); path.fill()
        }
        if isDropTarget {
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill(); path.fill()
            NSColor.controlAccentColor.setStroke(); path.lineWidth = 2; path.stroke()
        }
        label.textColor = isSelected ? .labelColor : .secondaryLabelColor
    }

    override func menu(for event: NSEvent) -> NSMenu? { bar.menuForTab?(index) }

    @objc private func closeClicked() { bar.close(self) }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let menu = menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        dragStart = convert(event.locationInWindow, from: nil)
        didDrag = false
        bar.select(self)
    }
    override func mouseDragged(with event: NSEvent) {
        let p = superview!.convert(event.locationInWindow, from: nil)
        if !didDrag, let s = dragStart, abs(convert(event.locationInWindow, from: nil).x - s.x) > 4 {
            didDrag = true
            bar.beginDrag(self, at: p)
        }
        if didDrag { bar.drag(to: p, windowPoint: event.locationInWindow) }
    }
    override func mouseUp(with event: NSEvent) {
        if didDrag { bar.endDrag(windowPoint: event.locationInWindow) }
        dragStart = nil; didDrag = false
    }
    /// Middle click closes, as in Dolphin and every browser.
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { bar.close(self) } else { super.otherMouseDown(with: event) }
    }
}
