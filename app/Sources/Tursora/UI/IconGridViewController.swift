import AppKit

/// Icon view: an NSCollectionView grid of the directory's top level, with
/// Dolphin-style zoom (icon size) and Quick Look thumbnails as previews.
final class IconGridViewController: NSViewController, FileViewing, NSCollectionViewDataSource,
                                    NSCollectionViewDelegateFlowLayout, NSTextFieldDelegate {

    let model: DirectoryModel
    let collectionView = FileCollectionView()
    let scrollView = NSScrollView()
    private let layout = NSCollectionViewFlowLayout()

    var viewController: NSViewController { self }
    var focusView: NSView { collectionView }

    var onOpen: ((FileItem) -> Void)?
    var onOpenInNewTab: ((FileItem) -> Void)?
    var onRenameCommitted: ((FileItem, String) -> Void)?
    var onSelectionChanged: (() -> Void)?
    var onFocus: (() -> Void)?
    var onQuickLook: (() -> Void)?
    var onDropFiles: (([URL], URL, NSDragOperation) -> Void)?
    var onZoomGesture: ((Int) -> Void)?

    var contextMenu: NSMenu? {
        get { collectionView.menu }
        set { collectionView.menu = newValue }
    }
    var cutURLs: Set<URL> = [] { didSet { collectionView.reloadData() } }

    private(set) var iconSize: CGFloat = 64
    private(set) var showPreviews = true
    private static let itemID = NSUserInterfaceItemIdentifier("file")
    private static let headerID = NSUserInterfaceItemIdentifier("groupHeader")

    init(model: DirectoryModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView()
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 12
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        applyItemSize()

        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.controlBackgroundColor]
        collectionView.register(FileCollectionItem.self, forItemWithIdentifier: Self.itemID)
        collectionView.register(GroupHeaderView.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader, withIdentifier: Self.headerID)
        layout.sectionHeadersPinToVisibleBounds = true
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.registerForDraggedTypes([.fileURL])
        collectionView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        collectionView.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: false)
        collectionView.onReturn = { [weak self] in
            guard let self, let item = self.selectedItems.first, self.selectedItems.count == 1 else { return }
            self.beginRename(item: item)
        }
        collectionView.onSpace = { [weak self] in self?.onQuickLook?() }
        collectionView.onZoom = { [weak self] step in self?.onZoomGesture?(step) }
        collectionView.onBecomeFirstResponder = { [weak self] in
            self?.onFocus?()
            self?.refreshSelectionEmphasis()
        }
        collectionView.onResignFirstResponder = { [weak self] in self?.refreshSelectionEmphasis() }

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        view.pinToEdges(scrollView)
    }

    // MARK: - Sections ↔ groups

    private func node(at ip: IndexPath) -> FileNode? {
        guard model.groups.indices.contains(ip.section) else { return nil }
        let g = model.groups[ip.section]
        return g.nodes.indices.contains(ip.item) ? g.nodes[ip.item] : nil
    }

    private func indexPath(forName name: String) -> IndexPath? {
        for (s, g) in model.groups.enumerated() {
            if let i = g.nodes.firstIndex(where: { $0.item.name == name }) { return IndexPath(item: i, section: s) }
        }
        return nil
    }

    private func indexPath(for url: URL) -> IndexPath? {
        let target = url.standardizedFileURL
        for (s, g) in model.groups.enumerated() {
            if let i = g.nodes.firstIndex(where: { $0.url.standardizedFileURL == target }) { return IndexPath(item: i, section: s) }
        }
        return nil
    }

    /// Item after `ip` in reading order, across sections.
    private func indexPath(after ip: IndexPath) -> IndexPath? {
        var next = IndexPath(item: ip.item + 1, section: ip.section)
        while model.groups.indices.contains(next.section) {
            if model.groups[next.section].nodes.indices.contains(next.item) { return next }
            next = IndexPath(item: 0, section: next.section + 1)
        }
        return nil
    }

    // MARK: - FileViewing

    func reloadData() {
        let selected = selectedItems.map(\.name)
        layout.headerReferenceSize = model.isGrouped ? NSSize(width: 0, height: GroupHeaderView.height) : .zero
        collectionView.reloadData()
        if !selected.isEmpty { select(names: selected) }
    }

    var selectedItems: [FileItem] {
        collectionView.selectionIndexPaths.sorted().compactMap { node(at: $0)?.item }
    }

    var clickedItems: [FileItem] {
        guard let ip = collectionView.clickedIndexPath, let item = node(at: ip)?.item else { return [] }
        return collectionView.selectionIndexPaths.contains(ip) ? selectedItems : [item]
    }

    func select(name: String?) {
        guard let name else { collectionView.deselectAll(nil); onSelectionChanged?(); return }
        select(names: [name])
    }

    func select(names: [String]) {
        var paths = Set<IndexPath>()
        for name in names {
            if let ip = indexPath(forName: name) { paths.insert(ip) }
        }
        collectionView.selectionIndexPaths = paths
        if let first = paths.sorted().first { collectionView.scrollToItems(at: [first], scrollPosition: .nearestHorizontalEdge) }
        onSelectionChanged?()
    }

    /// Clamped both ways: NSClipView.scroll(to:) does not constrain, and a
    /// value captured mid rubber-band (negative) or from a longer listing
    /// would otherwise leave blank space above or below the rows.
    var scrollOffset: CGFloat {
        get { max(0, scrollView.contentView.bounds.origin.y) }
        set {
            scrollView.layoutSubtreeIfNeeded()
            let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.height)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(max(newValue, 0), maxY)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    func openSelection() { selectedItems.forEach { onOpen?($0) } }

    func beginRename(item: FileItem) {
        guard let ip = indexPath(for: item.url) else { return }
        collectionView.selectionIndexPaths = [ip]
        collectionView.scrollToItems(at: [ip], scrollPosition: .nearestHorizontalEdge)
        guard let cell = collectionView.item(at: ip) as? FileCollectionItem else { return }
        cell.beginEditingName(delegate: self, baseNameOnly: !item.isNavigable)
    }

    func itemAfterSelection() -> FileItem? {
        guard let last = collectionView.selectionIndexPaths.sorted().last, let next = indexPath(after: last) else { return nil }
        return node(at: next)?.item
    }

    func setIconSize(_ size: CGFloat, showPreviews: Bool) {
        let changed = size != iconSize || showPreviews != self.showPreviews
        iconSize = size
        self.showPreviews = showPreviews
        guard changed else { return }
        applyItemSize()
        reloadData()
    }

    func frameOnScreen(for url: URL) -> NSRect {
        guard let ip = indexPath(for: url), let window = collectionView.window,
              let frame = collectionView.layoutAttributesForItem(at: ip)?.frame else { return .zero }
        return window.convertToScreen(collectionView.convert(frame, to: nil))
    }

    func forwardKey(_ event: NSEvent) { collectionView.keyDown(with: event) }

    // MARK: - Layout

    private func applyItemSize() {
        let width = max(iconSize + 28, 96)
        let labelHeight: CGFloat = iconSize < 48 ? 30 : 34
        layout.itemSize = NSSize(width: width, height: iconSize + 8 + labelHeight)
    }

    private func refreshSelectionEmphasis() {
        for ip in collectionView.indexPathsForVisibleItems() {
            (collectionView.item(at: ip) as? FileCollectionItem)?.refreshAppearance()
        }
    }

    // MARK: - Data source

    func numberOfSections(in collectionView: NSCollectionView) -> Int { model.groups.count }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        model.groups.indices.contains(section) ? model.groups[section].nodes.count : 0
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) -> NSView {
        let header = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: Self.headerID, for: indexPath) as! GroupHeaderView
        header.title = model.groups.indices.contains(indexPath.section) ? model.groups[indexPath.section].title : ""
        return header
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: Self.itemID, for: indexPath) as! FileCollectionItem
        guard let node = node(at: indexPath) else { return cell }
        let item = node.item
        cell.representedObject = node
        cell.configure(item: item, iconSize: iconSize, faded: cutURLs.contains(item.url))
        cell.onDoubleClick = { [weak self] in self?.onOpen?(item) }
        cell.onMiddleClick = { [weak self] in self?.onOpenInNewTab?(item) }
        if showPreviews, iconSize >= ZoomLevel.previewThreshold, ThumbnailProvider.canPreview(item) {
            let scale = collectionView.window?.backingScaleFactor ?? 2
            if let cached = ThumbnailProvider.shared.thumbnail(for: item, size: iconSize, scale: scale, completion: { [weak cell] image in
                guard let image, let cell, (cell.representedObject as? FileNode) === node else { return }
                cell.setThumbnail(image)
            }) {
                cell.setThumbnail(cached)
            }
        }
        return cell
    }

    // MARK: - Delegate

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { onSelectionChanged?() }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { onSelectionChanged?() }

    // Drag source
    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool { true }
    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        node(at: indexPath)?.url as NSURL?
    }

    private func droppedFileURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// Onto a folder icon → into that folder; anywhere else → into the listed directory.
    private func dropDestination(_ indexPath: IndexPath, _ op: NSCollectionView.DropOperation) -> URL? {
        if op == .on, let item = node(at: indexPath)?.item, item.isNavigable { return item.url }
        return model.url
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
                        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        let ip = proposedIndexPath.pointee as IndexPath
        let onFolder = dropOperation.pointee == .on && node(at: ip)?.item.isNavigable == true
        if !onFolder {
            // No insertion gap: the whole grid is the target.
            dropOperation.pointee = .before
            let last = max(model.groups.count - 1, 0)
            proposedIndexPath.pointee = NSIndexPath(forItem: model.groups.indices.contains(last) ? model.groups[last].nodes.count : 0, inSection: last)
        }
        guard let dest = dropDestination(ip, onFolder ? .on : .before) else { return [] }
        return FileListViewController.dropOperation(for: droppedFileURLs(draggingInfo), into: dest,
                                                    sourceMask: draggingInfo.draggingSourceOperationMask)
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        let urls = droppedFileURLs(draggingInfo)
        guard let dest = dropDestination(indexPath, dropOperation) else { return false }
        let op = FileListViewController.dropOperation(for: urls, into: dest, sourceMask: draggingInfo.draggingSourceOperationMask)
        guard !op.isEmpty else { return false }
        onDropFiles?(urls, dest, op)
        return true
    }

    // MARK: - Rename (label editing)

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        field.isEditable = false
        guard let cell = collectionView.indexPathsForVisibleItems()
                .compactMap({ collectionView.item(at: $0) as? FileCollectionItem })
                .first(where: { $0.label === field }),
              let node = cell.representedObject as? FileNode else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if newName.isEmpty || newName == node.item.name || newName.contains("/") {
            field.stringValue = node.item.name
            cell.refreshAppearance()
            return
        }
        onRenameCommitted?(node.item, newName)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            view.window?.makeFirstResponder(collectionView)     // ends editing; text reverts in didEndEditing
            return true
        }
        return false
    }
}

/// The grid with the keys and clicks a file view needs, ⌘-scroll / pinch zoom,
/// and a context menu that targets what was clicked.
final class FileCollectionView: NSCollectionView {
    var onReturn: (() -> Void)?
    var onSpace: (() -> Void)?
    var onZoom: ((Int) -> Void)?
    var onBecomeFirstResponder: (() -> Void)?
    var onResignFirstResponder: (() -> Void)?
    private(set) var clickedIndexPath: IndexPath?
    private var wheelAccumulator: CGFloat = 0
    private var magnifyAccumulator: CGFloat = 0

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onBecomeFirstResponder?() }
        return ok
    }
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onResignFirstResponder?() }
        return ok
    }

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
        switch event.keyCode {
        case 36, 76 where plain: onReturn?()
        case 49 where plain:     onSpace?()
        default:                 super.keyDown(with: event)
        }
    }

    /// ⌘-scroll zooms (Dolphin's Ctrl-wheel); ordinary scrolling passes through.
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else { return super.scrollWheel(with: event) }
        wheelAccumulator += event.scrollingDeltaY
        if abs(wheelAccumulator) >= 8 {
            onZoom?(wheelAccumulator > 0 ? 1 : -1)
            wheelAccumulator = 0
        }
    }

    override func magnify(with event: NSEvent) {
        magnifyAccumulator += event.magnification
        if abs(magnifyAccumulator) >= 0.12 {
            onZoom?(magnifyAccumulator > 0 ? 1 : -1)
            magnifyAccumulator = 0
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        if let ip = indexPathForItem(at: p) {
            if !selectionIndexPaths.contains(ip) {
                selectionIndexPaths = [ip]
                delegate?.collectionView?(self, didSelectItemsAt: [ip])
            }
            clickedIndexPath = ip
        } else {
            clickedIndexPath = nil
        }
        return menu
    }
}

/// One icon: image above a two-line label; Finder-style selection (a tint
/// behind the icon, a filled pill behind the label).
final class FileCollectionItem: NSCollectionViewItem {

    let iconView = NSImageView()
    let label = NSTextField(wrappingLabelWithString: "")
    var onDoubleClick: (() -> Void)?
    var onMiddleClick: (() -> Void)?
    private var iconSize: CGFloat = 64
    private var faded = false

    private final class ItemView: NSView {
        weak var owner: FileCollectionItem?
        var selected = false { didSet { needsDisplay = true } }
        var emphasized = true { didSet { needsDisplay = true } }
        var iconFrame = NSRect.zero
        var labelFrame = NSRect.zero

        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            guard selected else { return }
            let tint: NSColor = emphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor
            tint.withAlphaComponent(emphasized ? 0.28 : 0.35).setFill()
            NSBezierPath(roundedRect: iconFrame.insetBy(dx: -6, dy: -6), xRadius: 8, yRadius: 8).fill()
            tint.setFill()
            NSBezierPath(roundedRect: labelFrame.insetBy(dx: -4, dy: -1), xRadius: 6, yRadius: 6).fill()
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { owner?.onDoubleClick?(); return }
            super.mouseDown(with: event)
        }
        override func otherMouseDown(with event: NSEvent) {
            if event.buttonNumber == 2 { owner?.onMiddleClick?() } else { super.otherMouseDown(with: event) }
        }
    }

    override func loadView() {
        let v = ItemView()
        v.owner = self
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.imageAlignment = .alignCenter
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        label.cell?.truncatesLastVisibleLine = true
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.isBordered = false
        label.focusRingType = .none
        v.addSubview(iconView)
        v.addSubview(label)
        view = v
    }

    override var isSelected: Bool { didSet { refreshAppearance() } }
    override var highlightState: NSCollectionViewItem.HighlightState { didSet { refreshAppearance() } }

    func configure(item: FileItem, iconSize: CGFloat, faded: Bool) {
        self.iconSize = iconSize
        self.faded = faded
        iconView.image = item.icon(size: iconSize)
        label.stringValue = item.name
        label.font = .systemFont(ofSize: iconSize < 48 ? 11 : 12)
        view.toolTip = item.name
        layoutSubviews()
        refreshAppearance()
    }

    func setThumbnail(_ image: NSImage) {
        iconView.image = image
    }

    private func layoutSubviews() {
        guard let v = view as? ItemView else { return }
        let w = v.bounds.width
        let iconFrame = NSRect(x: (w - iconSize) / 2, y: 4, width: iconSize, height: iconSize)
        iconView.frame = iconFrame
        let labelHeight = iconSize < 48 ? 30 : 34
        let labelFrame = NSRect(x: 4, y: iconFrame.maxY + 4, width: w - 8, height: CGFloat(labelHeight))
        label.frame = labelFrame
        v.iconFrame = iconFrame
        v.labelFrame = label.frame.insetBy(dx: max(0, (w - 8 - textWidth()) / 2), dy: 0)
    }

    private func textWidth() -> CGFloat {
        let size = (label.stringValue as NSString).size(withAttributes: [.font: label.font ?? .systemFont(ofSize: 12)])
        return min(size.width + 4, view.bounds.width - 8)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutSubviews()
    }

    func refreshAppearance() {
        guard let v = view as? ItemView else { return }
        let emphasized = view.window?.firstResponder === collectionView && (view.window?.isKeyWindow ?? false)
        v.emphasized = emphasized
        v.selected = isSelected || highlightState == .asDropTarget
        label.textColor = (isSelected && emphasized) ? .alternateSelectedControlTextColor : .labelColor
        view.alphaValue = faded ? 0.45 : 1
        v.needsDisplay = true
    }

    /// Inline rename: make the label editable for the duration of the edit.
    func beginEditingName(delegate: NSTextFieldDelegate, baseNameOnly: Bool) {
        label.delegate = delegate
        label.isEditable = true
        label.isSelectable = true
        view.window?.makeFirstResponder(label)
        guard let editor = label.currentEditor() else { return }
        let name = label.stringValue
        let base = baseNameOnly ? (name as NSString).deletingPathExtension : name
        editor.selectedRange = NSRange(location: 0, length: (base as NSString).length)
    }
}


/// Finder's group header in icon view: a sticky title strip above each section.
final class GroupHeaderView: NSView, NSCollectionViewElement {
    static let height: CGFloat = 28
    private let label = NSTextField(labelWithString: "")
    var title: String = "" { didSet { label.stringValue = title } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .bold)
        label.textColor = .secondaryLabelColor
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 12, y: (bounds.height - 16) / 2, width: bounds.width - 24, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.withAlphaComponent(0.92).setFill(); bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 12, y: 0, width: bounds.width - 24, height: 1).fill()
    }
}
