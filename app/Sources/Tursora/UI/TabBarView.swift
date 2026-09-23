import AppKit

/// A quiet, appearance-aware tab strip. The document scrolls independently of
/// the trailing controls; the controller owns tab identity and all actions.
final class TabBarView: NSView {
    static let height: CGFloat = 36
    /// The rule drawn between the two halves of a split tab's name, and the air
    /// on either side of it (D78).
    static let titleDividerWidth: CGFloat = 1
    static let titleDividerGap: CGFloat = 7
    static var titleDividerSpan: CGFloat { titleDividerGap * 2 + titleDividerWidth }

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onAdd: (() -> Void)?
    var onMove: ((Int, Int) -> Void)?
    var menuForTab: ((Int) -> NSMenu?)?
    /// Points are in window coordinates; the index is the original position.
    var onDragOutside: ((Int, NSPoint?) -> Void)?
    var onDropOutside: ((Int, NSPoint) -> Void)?
    var onFilesDroppedOnTab: ((Int?, [URL], NSDragOperation) -> Void)?
    var onAutoActivateTab: ((Int) -> Void)?
    var dropOperationForTab: ((Int?, [URL], NSDragOperation) -> NSDragOperation)?
    static let autoActivationDelay: TimeInterval = 0.8

    private(set) var tabTitles: [TabTitle] = []
    /// The single-string form of each tab's name, for checks and menus.
    var titles: [String] { tabTitles.map(\.plain) }
    private(set) var selectedIndex = 0
    private(set) var toolTips: [String] = []
    private var items: [TabItemView] = []
    private let scrollView = TabScrollView()
    private let documentView = NSView()
    private let addButton = NSButton()
    private let overflowButton = NSButton()
    private var windowObservers: [NSObjectProtocol] = []
    private var shortcutObserver: NSObjectProtocol?
    private var revealSelection = true
    private var previousViewportWidth: CGFloat = -1
    private var reloadGeneration = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Tabs")
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = documentView
        scrollView.onScroll = { [weak self] delta in self?.scroll(by: delta) }
        addSubview(scrollView)
        configure(addButton, symbol: "plus", description: "New Tab", action: #selector(addClicked))
        refreshShortcutHint()
        shortcutObserver = NotificationCenter.default.addObserver(forName: .tursoraShortcutsChanged,
            object: AppPreferences.shared.shortcuts, queue: .main) { [weak self] _ in self?.refreshShortcutHint() }
        configure(overflowButton, symbol: "chevron.down", description: "All Tabs", action: #selector(showOverflow))
        overflowButton.toolTip = "All Tabs"
        overflowButton.isHidden = true
        registerForDraggedTypes([.fileURL, ArchiveEntryPromiseProvider.internalType])
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        if let shortcutObserver { NotificationCenter.default.removeObserver(shortcutObserver) }
        dragScrollTimer?.invalidate()
        autoActivation?.cancel()
    }

    var newTabToolTipForTesting: String? { addButton.toolTip }

    private func refreshShortcutHint() {
        let key = AppPreferences.shared.shortcuts.shortcut(for: "menu.newTab")?.displayString
        addButton.toolTip = "New Tab" + (key.map { " (" + $0 + ")" } ?? "")
    }

    private func configure(_ button: NSButton, symbol: String, description: String, action: Selector) {
        button.bezelStyle = .circular
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        button.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        button.setAccessibilityLabel(description)
        button.target = self
        button.action = action
        addSubview(button)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    func reload(titles: [String], selected: Int, toolTips: [String]? = nil) {
        reload(titles: titles.map(TabTitle.init), selected: selected, toolTips: toolTips)
    }

    func reload(titles: [TabTitle], selected: Int, toolTips: [String]? = nil) {
        // Directory notifications can reload the strip during mouse tracking.
        // Stop the provisional reorder before rebinding views to model indices.
        cancelDrag()
        endHover()
        reloadGeneration += 1
        revealSelection = revealSelection || selected != selectedIndex || titles.count != tabTitles.count
        tabTitles = titles
        naturalTabWidth = titles.reduce(0) { max($0, TabItemView.naturalWidth(for: $1)) }
        self.toolTips = toolTips ?? titles.map(\.plain)
        selectedIndex = selected
        while items.count < titles.count {
            let item = TabItemView(bar: self)
            documentView.addSubview(item)
            items.append(item)
        }
        while items.count > titles.count { items.removeLast().removeFromSuperview() }
        for (index, item) in items.enumerated() {
            item.index = index
            item.title = titles[index]
            item.toolTip = self.toolTips.indices.contains(index) ? self.toolTips[index] : titles[index].plain
            item.isSelected = index == selected
        }
        needsLayout = true
        needsDisplay = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let index = tabIndex(at: convert(event.locationInWindow, from: nil)) else { return nil }
        return menuForTab?(index)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification] {
                windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.refreshAppearance()
                })
            }
        }
        refreshAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    private func refreshAppearance() {
        needsDisplay = true
        for item in items {
            if window?.isKeyWindow == false { item.hovered = false }
            item.refreshAppearance()
        }
        addButton.contentTintColor = colors.selectedText
        overflowButton.contentTintColor = colors.selectedText
    }

    fileprivate var colors: TabStripColors {
        Self.palette(appearance: effectiveAppearance, active: window?.isKeyWindow ?? true)
    }

    func resolvedColorsForTesting(appearance: NSAppearance, active: Bool) -> (background: NSColor, rail: NSColor, selected: NSColor, text: NSColor, secondaryText: NSColor) {
        let palette = Self.palette(appearance: appearance, active: active)
        return (palette.background, palette.rail, palette.selectedFill, palette.selectedText, palette.inactiveText)
    }

    func titleDividerColorsForTesting(appearance: NSAppearance, active: Bool) -> (selected: NSColor, inactive: NSColor) {
        let palette = Self.palette(appearance: appearance, active: active)
        return (palette.titleDivider, palette.inactiveTitleDivider)
    }

    private static func palette(appearance: NSAppearance, active: Bool) -> TabStripColors {
        var result: TabStripColors!
        appearance.performAsCurrentDrawingAppearance {
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            // Resolve semantic colors while the requested appearance is current.
            // Never retain a CGColor that becomes stale when the theme changes.
            func resolved(_ color: NSColor) -> NSColor { color.usingColorSpace(.sRGB) ?? color }
            let base = resolved(.windowBackgroundColor)
            let label = resolved(.labelColor)
            let opaqueLabel = label.withAlphaComponent(1)
            let raisedTarget = dark ? opaqueLabel : resolved(.textBackgroundColor).withAlphaComponent(1)
            result = TabStripColors(
                background: base,
                rail: base.blended(withFraction: dark ? 0.025 : 0.035, of: opaqueLabel) ?? base,
                selectedFill: base.blended(withFraction: dark ? (active ? 0.13 : 0.075) : (active ? 0.88 : 0.45), of: raisedTarget) ?? base,
                selectedBorder: label.withAlphaComponent(active ? 0.12 : 0.075),
                selectedText: label,
                inactiveText: resolved(.secondaryLabelColor),
                hoverFill: label.withAlphaComponent(dark ? 0.07 : 0.045),
                divider: label.withAlphaComponent(0.1),
                titleDivider: label.withAlphaComponent(0.18),
                inactiveTitleDivider: label.withAlphaComponent(0.12))
        }
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = colors
        palette.background.setFill()
        bounds.fill()
        let geometry = layoutForTesting
        palette.rail.setFill()
        let railFrame = geometry.viewportFrame.insetBy(dx: 0, dy: 3)
        NSBezierPath(roundedRect: railFrame, xRadius: railFrame.height / 2, yRadius: railFrame.height / 2).fill()
        for frame in [geometry.addButtonFrame, geometry.overflowButtonFrame].compactMap({ $0 }) {
            palette.rail.setFill()
            NSBezierPath(ovalIn: frame.insetBy(dx: 1, dy: 1)).fill()
        }
        NSColor.separatorColor.withAlphaComponent(0.35).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 0.5).fill()
    }

    // MARK: - Layout and overflow

    var tabWidth: CGFloat { layoutForTesting.tabWidth }
    var layoutForTesting: TabStripLayout {
        TabStripLayout(width: bounds.width, height: bounds.height, tabCount: items.count,
                       naturalTabWidth: naturalTabWidth)
    }

    /// The width the widest current title needs with nothing truncated. Lets a
    /// tab pass the preferred width when the strip can spare the room (D79).
    /// Recomputed when the titles change, because `layout()`, `draw()` and the
    /// drag handlers all read the geometry and measuring text is not free.
    private var naturalTabWidth: CGFloat = 0

    override func layout() {
        super.layout()
        let geometry = layoutForTesting
        let resized = previousViewportWidth != geometry.viewportFrame.width
        previousViewportWidth = geometry.viewportFrame.width
        scrollView.frame = geometry.viewportFrame
        documentView.frame = NSRect(x: 0, y: 0, width: geometry.contentWidth, height: bounds.height)
        for (index, item) in items.enumerated() where item !== dragging {
            item.frame = geometry.frameForTab(index)
        }
        addButton.frame = geometry.addButtonFrame
        overflowButton.isHidden = !geometry.isOverflowing
        overflowButton.frame = geometry.overflowButtonFrame ?? .zero
        scroll(to: scrollView.contentView.bounds.minX)
        if dragging == nil, revealSelection || resized {
            revealSelectedTab()
            revealSelection = false
        }
    }

    private func revealSelectedTab() {
        guard items.indices.contains(selectedIndex) else { return }
        let frame = items[selectedIndex].frame.insetBy(dx: -2, dy: 0)
        let visible = scrollView.contentView.bounds
        if frame.minX < visible.minX { scroll(to: frame.minX) }
        else if frame.maxX > visible.maxX { scroll(to: frame.maxX - visible.width) }
    }

    private func scroll(to offset: CGFloat) {
        let maximum = max(0, documentView.bounds.width - scrollView.contentView.bounds.width)
        scrollView.contentView.scroll(to: NSPoint(x: max(0, min(maximum, offset)), y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func scroll(by delta: CGFloat) { scroll(to: scrollView.contentView.bounds.minX + delta) }

    private func overflowMenu() -> NSMenu {
        let menu = NSMenu(title: "All Tabs")
        for (index, title) in titles.enumerated() {
            let item = NSMenuItem(title: title, action: #selector(selectFromOverflow(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.representedObject = NSNumber(value: reloadGeneration)
            item.state = index == selectedIndex ? .on : .off
            item.toolTip = toolTips.indices.contains(index) ? toolTips[index] : title
            menu.addItem(item)
        }
        return menu
    }

    @objc private func showOverflow() {
        overflowMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: overflowButton.bounds.minY), in: overflowButton)
    }
    @objc private func selectFromOverflow(_ sender: NSMenuItem) {
        guard (sender.representedObject as? NSNumber)?.intValue == reloadGeneration,
              titles.indices.contains(sender.tag) else { return }
        revealSelection = true
        needsLayout = true
        onSelect?(sender.tag)
    }

    // MARK: - Files dragged over the strip

    private var hoverTabIndex: Int? { didSet { if hoverTabIndex != oldValue { updateDropHighlight() } } }
    private var autoActivation: DispatchWorkItem?

    func tabIndex(at point: NSPoint) -> Int? {
        guard scrollView.frame.contains(point) else { return nil }
        let documentPoint = documentView.convert(point, from: self)
        return items.first { $0.frame.contains(documentPoint) && !$0.isHidden }?.index
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func wantsPeriodicDraggingUpdates() -> Bool { true }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSource as? TabBarView !== self else { return [] }
        let urls = sender.fileURLs
        guard !urls.isEmpty else { return [] }
        let point = convert(sender.draggingLocation, from: nil)
        scrollAtEdge(point)
        let index = tabIndex(at: point)
        if index != hoverTabIndex { beginAutoActivation(index) }
        hoverTabIndex = index
        return dropOperationForTab?(index, urls, sender.draggingSourceOperationMask) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { endHover() }
    override func draggingEnded(_ sender: NSDraggingInfo) { endHover() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.fileURLs
        let index = tabIndex(at: convert(sender.draggingLocation, from: nil))
        endHover()
        return performDrop(urls: urls, sourceMask: sender.draggingSourceOperationMask, onTabAt: index)
    }

    @discardableResult
    func performDrop(urls: [URL], sourceMask: NSDragOperation, onTabAt index: Int?) -> Bool {
        guard !urls.isEmpty, let op = dropOperationForTab?(index, urls, sourceMask), !op.isEmpty else { return false }
        onFilesDroppedOnTab?(index, urls, op)
        return true
    }

    func beginAutoActivation(_ index: Int?) {
        autoActivation?.cancel()
        autoActivation = nil
        guard let index, titles.indices.contains(index), index != selectedIndex else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hoverTabIndex == index else { return }
            self.autoActivation = nil
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
    func tabFrameForTesting(_ index: Int) -> NSRect {
        guard items.indices.contains(index) else { return .zero }
        return convert(items[index].frame, from: documentView)
    }
    /// Both of these convert to the strip's own coordinates, like the leading
    /// title and the close button, so a check can compare all four directly.
    func trailingTitleFrameForTesting(_ index: Int) -> NSRect? {
        guard items.indices.contains(index), let frame = items[index].trailingLabelFrame else { return nil }
        return convert(frame, from: items[index])
    }

    func titleDividerFrameForTesting(_ index: Int) -> NSRect? {
        guard items.indices.contains(index), let frame = items[index].dividerFrame else { return nil }
        return convert(frame, from: items[index])
    }

    func titleFrameForTesting(_ index: Int) -> NSRect {
        guard items.indices.contains(index) else { return .zero }
        return convert(items[index].labelFrame, from: items[index])
    }
    func closeFrameForTesting(_ index: Int) -> NSRect {
        guard items.indices.contains(index) else { return .zero }
        return convert(items[index].closeFrame, from: items[index])
    }
    /// Whether the label renders its whole string. Asks the cell, which is the
    /// only authority on where AppKit actually clips.
    func isTitleFullyShownForTesting(_ index: Int) -> Bool? {
        items.indices.contains(index) ? items[index].isLeadingTitleFullyShown : nil
    }

    func isTrailingTitleFullyShownForTesting(_ index: Int) -> Bool? {
        items.indices.contains(index) ? items[index].isTrailingTitleFullyShown : nil
    }

    func trailingRenderedTitleColorForTesting(_ index: Int) -> NSColor? {
        items.indices.contains(index) ? items[index].trailingTitleColor : nil
    }

    func actualRenderedTitleColorForTesting(_ index: Int) -> NSColor? {
        guard items.indices.contains(index) else { return nil }
        return items[index].titleColor
    }
    func isCloseVisibleForTesting(_ index: Int) -> Bool { items.indices.contains(index) && items[index].isCloseVisible }
    func setHoveredTabForTesting(_ index: Int?) {
        for item in items { item.hovered = item.index == index }
    }
    var scrollOffsetForTesting: CGFloat { scrollView.contentView.bounds.minX }
    func scrollForTesting(to offset: CGFloat) { scroll(to: offset) }
    func overflowMenuForTesting() -> NSMenu { overflowMenu() }

    private func endHover() {
        autoActivation?.cancel(); autoActivation = nil
        hoverTabIndex = nil
    }

    private func updateDropHighlight() {
        for item in items { item.isDropTarget = item.index == hoverTabIndex }
    }

    // MARK: - Interaction (called by TabItemView)

    fileprivate func select(_ item: TabItemView) {
        revealSelection = true
        needsLayout = true
        onSelect?(item.index)
    }
    fileprivate func close(_ item: TabItemView) { onClose?(item.index) }
    @objc private func addClicked() { onAdd?() }

    private var dragging: TabItemView?
    private var dragOffset: CGFloat = 0
    private var dragOrigin = 0
    private var draggingOutside = false
    private var dragPoint = NSPoint.zero
    private var dragScrollTimer: Timer?

    private func cancelDrag() {
        guard dragging != nil else { return }
        dragScrollTimer?.invalidate(); dragScrollTimer = nil
        dragging = nil
        if draggingOutside { onDragOutside?(dragOrigin, nil) }
        draggingOutside = false
        needsLayout = true
    }

    fileprivate func beginDrag(_ item: TabItemView, at point: NSPoint) {
        dragging = item
        dragOrigin = item.index
        dragOffset = documentView.convert(point, from: self).x - item.frame.minX
        documentView.addSubview(item)
        dragScrollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, self.dragging != nil, !self.draggingOutside else { return }
            self.scrollAtEdge(self.dragPoint)
            self.updateDraggedFrame(at: self.dragPoint)
        }
        dragScrollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    fileprivate func drag(to point: NSPoint, windowPoint: NSPoint) {
        guard dragging != nil else { return }
        dragPoint = point
        let outside = point.y < -8
        if outside != draggingOutside {
            draggingOutside = outside
            if !outside { onDragOutside?(dragOrigin, nil) }
        }
        if outside { onDragOutside?(dragOrigin, windowPoint); return }
        updateDraggedFrame(at: point)
    }

    private func scrollAtEdge(_ point: NSPoint) {
        guard layoutForTesting.isOverflowing, scrollView.frame.contains(point) else { return }
        if point.x < scrollView.frame.minX + 24 { scroll(by: -16) }
        else if point.x > scrollView.frame.maxX - 24 { scroll(by: 16) }
    }

    private func updateDraggedFrame(at point: NSPoint) {
        guard let item = dragging else { return }
        let documentPoint = documentView.convert(point, from: self)
        var frame = item.frame
        frame.origin.x = max(2, min(documentPoint.x - dragOffset, documentView.bounds.width - frame.width - 2))
        item.frame = frame
        guard let target = layoutForTesting.targetIndex(atDocumentX: frame.midX), target != item.index else { return }
        items.remove(at: item.index)
        items.insert(item, at: target)
        for (index, item) in items.enumerated() { item.index = index }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    fileprivate func endDrag(windowPoint: NSPoint) {
        guard let item = dragging else { return }
        dragScrollTimer?.invalidate(); dragScrollTimer = nil
        dragging = nil
        let wasOutside = draggingOutside
        draggingOutside = false
        needsLayout = true
        if wasOutside { onDropOutside?(dragOrigin, windowPoint); return }
        let from = dragOrigin, to = item.index
        if from != to { onMove?(from, to) }
    }
}

struct TabStripColors {
    let background: NSColor
    let rail: NSColor
    let selectedFill: NSColor
    let selectedBorder: NSColor
    let selectedText: NSColor
    let inactiveText: NSColor
    let hoverFill: NSColor
    let divider: NSColor
    /// The rule drawn between the two halves of a split tab's name.
    let titleDivider: NSColor
    let inactiveTitleDivider: NSColor
}

private final class TabScrollView: NSScrollView {
    var onScroll: ((CGFloat) -> Void)?
    override func scrollWheel(with event: NSEvent) {
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        onScroll?(-delta * (event.hasPreciseScrollingDeltas ? 1 : 12))
    }
}

private final class TabItemView: NSView {
    unowned let bar: TabBarView
    var index = 0
    var title = TabTitle("") {
        didSet {
            label.stringValue = title.left
            trailingLabel.stringValue = title.right ?? ""
            trailingLabel.isHidden = !title.isSplit
            setAccessibilityLabel(title.accessibilityLabel)
            needsLayout = true
            needsDisplay = true
        }
    }
    /// Text height, the close button's reserved width on both sides, and the
    /// room the drawn divider takes between the two halves of a split name.
    static let titleHeight: CGFloat = 16
    static let titleInset: CGFloat = 28
    static let titlePadding: CGFloat = 6
    private static let titleFont = NSFont.systemFont(ofSize: 12)

    /// Every title label is built here, so the field a measurement is taken
    /// from cannot drift from the fields that actually render.
    private static func makeTitleField() -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = titleFont
        field.lineBreakMode = .byTruncatingMiddle
        field.alignment = .center
        field.setAccessibilityElement(false)
        return field
    }

    /// A truncating cell clips before its text reaches the frame edge, so a
    /// label framed at the raw glyph width renders an ellipsis even in a tab
    /// with room to spare. `intrinsicContentSize` does not cover it either: it
    /// reports only half the shortfall. Rather than hardcode the 8 pt this
    /// machine wants, ask a real cell where it stops offering to expand — which
    /// on measurement is exactly the width at which the whole string renders.
    private static let labelInset: CGFloat = {
        let probe = makeTitleField()
        probe.stringValue = "Mwq"
        let glyphs = ceil(("Mwq" as NSString).size(withAttributes: [.font: titleFont]).width)
        for extra in stride(from: CGFloat(0), through: 24, by: 1) {
            probe.frame = NSRect(x: 0, y: 0, width: glyphs + extra, height: titleHeight)
            if probe.cell?.expansionFrame(withFrame: probe.bounds, in: probe).isEmpty ?? true { return extra }
        }
        return 8
    }()

    /// The width this title needs with nothing truncated, including the room
    /// the drawn rule takes between the two halves of a split name.
    static func naturalWidth(for title: TabTitle) -> CGFloat {
        var content = textWidth(title.left)
        if let right = title.right { content += textWidth(right) + TabBarView.titleDividerSpan }
        return content + (titleInset + titlePadding) * 2
    }
    var isSelected = false {
        didSet { refreshAppearance(); setAccessibilityValue(isSelected ? 1 : 0) }
    }
    var isDropTarget = false { didSet { needsDisplay = true } }
    private let label = TabItemView.makeTitleField()
    private let trailingLabel = TabItemView.makeTitleField()
    /// Set by `layout()`; nil for a tab that is not split.
    private(set) var dividerFrame: NSRect?
    private let closeButton = NSButton()
    fileprivate var hovered = false {
        didSet { needsDisplay = true; closeButton.isHidden = !hovered }
    }
    private var tracking: NSTrackingArea?
    private var dragStart: NSPoint?
    private var didDrag = false
    var labelFrame: NSRect { label.frame }
    var trailingLabelFrame: NSRect? { title.isSplit ? trailingLabel.frame : nil }
    var closeFrame: NSRect { closeButton.frame }
    var titleColor: NSColor? { label.textColor }
    var trailingTitleColor: NSColor? { trailingLabel.textColor }
    /// A cell offers an expansion frame exactly when it judges its own text
    /// clipped, so this is AppKit's answer rather than our arithmetic's.
    private func isFullyShown(_ field: NSTextField) -> Bool {
        guard let cell = field.cell, !field.stringValue.isEmpty else { return true }
        return cell.expansionFrame(withFrame: field.bounds, in: field).isEmpty
    }
    var isLeadingTitleFullyShown: Bool { isFullyShown(label) }
    var isTrailingTitleFullyShown: Bool { !title.isSplit || isFullyShown(trailingLabel) }
    var isCloseVisible: Bool { !closeButton.isHidden }

    init(bar: TabBarView) {
        self.bar = bar
        super.init(frame: .zero)
        wantsLayer = true
        for field in [label, trailingLabel] { addSubview(field) }
        trailingLabel.isHidden = true
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")
        closeButton.symbolConfiguration = .init(pointSize: 9, weight: .medium)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.isHidden = true
        closeButton.toolTip = "Close Tab"
        addSubview(closeButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Close Tab", target: self, selector: #selector(accessibilityCloseTab))])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        closeButton.frame = NSRect(x: 4, y: (bounds.height - 20) / 2, width: 20, height: 20)
        let content = NSRect(x: Self.titleInset, y: (bounds.height - Self.titleHeight) / 2,
                             width: max(0, bounds.width - Self.titleInset * 2), height: Self.titleHeight)
        guard let right = title.right else {
            label.frame = content
            trailingLabel.frame = .zero
            dividerFrame = nil
            return
        }
        let text = max(0, content.width - TabBarView.titleDividerSpan)
        let leftNatural = Self.textWidth(title.left), rightNatural = Self.textWidth(right)
        // Each half keeps its natural width while both fit. When they do not, a
        // half that needs less than its share keeps all of it and the other
        // takes the rest, so a short name is never truncated next to a long one.
        let half = text / 2
        var leftWidth = leftNatural, rightWidth = rightNatural
        if leftNatural + rightNatural > text {
            if leftNatural <= half { rightWidth = text - leftNatural }
            else if rightNatural <= half { leftWidth = text - rightNatural }
            else { leftWidth = half; rightWidth = text - half }
        }
        let originX = content.minX + max(0, (content.width - leftWidth - rightWidth - TabBarView.titleDividerSpan) / 2)
        label.frame = NSRect(x: originX, y: content.minY, width: leftWidth, height: content.height)
        let dividerX = originX + leftWidth + TabBarView.titleDividerGap
        // The rule runs the whole height of the tab, flush with the selected
        // pill's outline, so it cannot be mistaken for a letterform.
        dividerFrame = NSRect(x: dividerX, y: 0.5, width: TabBarView.titleDividerWidth, height: max(0, bounds.height - 1))
        trailingLabel.frame = NSRect(x: dividerX + TabBarView.titleDividerWidth + TabBarView.titleDividerGap, y: content.minY,
                                     width: rightWidth, height: content.height)
    }

    /// What a label needs to render `value` whole: its glyphs plus the inset a
    /// truncating cell keeps. Framing a field at the glyph width alone
    /// truncates it, which is the ellipsis D78 exists to remove.
    static func textWidth(_ value: String) -> CGFloat {
        ceil((value as NSString).size(withAttributes: [.font: titleFont]).width) + labelInset
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    func refreshAppearance() {
        needsDisplay = true
        label.textColor = isSelected ? bar.colors.selectedText : bar.colors.inactiveText
        trailingLabel.textColor = label.textColor
        closeButton.contentTintColor = bar.colors.selectedText
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = bar.colors
        let surface = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: surface, xRadius: surface.height / 2, yRadius: surface.height / 2)
        if isSelected {
            palette.selectedFill.setFill(); path.fill()
            palette.selectedBorder.setStroke(); path.lineWidth = 0.5; path.stroke()
        } else if hovered {
            palette.hoverFill.setFill(); path.fill()
        } else if index > 0 && index - 1 != bar.selectedIndex {
            palette.divider.setFill()
            NSRect(x: 0, y: 8, width: 0.5, height: max(0, bounds.height - 16)).fill()
        }
        if let dividerFrame {
            (isSelected ? palette.titleDivider : palette.inactiveTitleDivider).setFill()
            dividerFrame.fill()
        }
        if isDropTarget {
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill(); path.fill()
            NSColor.controlAccentColor.setStroke(); path.lineWidth = 2; path.stroke()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? { bar.menuForTab?(index) }
    @objc private func closeClicked() { bar.close(self) }
    @objc private func accessibilityCloseTab() -> Bool { bar.close(self); return true }
    override func accessibilityPerformPress() -> Bool { bar.select(self); return true }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let menu = menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        dragStart = bar.convert(event.locationInWindow, from: nil)
        didDrag = false
    }
    override func mouseDragged(with event: NSEvent) {
        let point = bar.convert(event.locationInWindow, from: nil)
        if !didDrag, let start = dragStart, hypot(point.x - start.x, point.y - start.y) > 4 {
            didDrag = true
            bar.beginDrag(self, at: start)
        }
        if didDrag { bar.drag(to: point, windowPoint: event.locationInWindow) }
    }
    override func mouseUp(with event: NSEvent) {
        if didDrag { bar.endDrag(windowPoint: event.locationInWindow) }
        else if dragStart != nil { bar.select(self) }
        dragStart = nil; didDrag = false
    }
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { bar.close(self) } else { super.otherMouseDown(with: event) }
    }
}
