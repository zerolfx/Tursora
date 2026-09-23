import AppKit

/// Icon view: an NSCollectionView grid of the directory's top level, with
/// Dolphin-style zoom (icon size) and Quick Look thumbnails as previews.
final class IconGridViewController: NSViewController, FileViewing, NSCollectionViewDataSource,
                                    NSCollectionViewDelegateFlowLayout, NSTextFieldDelegate {

    let model: DirectoryModel
    let collectionView = FileCollectionView()
    let scrollView = NSScrollView()
    var isReadOnly = false {
        didSet { updateDragOperations() }
    }
    var allowsRenaming = true
    private var draggingReadOnlyItems = false

    private func updateDragOperations() {
        let copyOnly = isReadOnly || draggingReadOnlyItems
        collectionView.setDraggingSourceOperationMask(DragAndDrop.sourceMask(readOnly: copyOnly, local: true), forLocal: true)
        collectionView.setDraggingSourceOperationMask(DragAndDrop.sourceMask(readOnly: copyOnly, local: false), forLocal: false)
    }
    private var layout = NSCollectionViewFlowLayout()
    private var layoutSignature: [Int] = []

    var viewController: NSViewController { self }
    var focusView: NSView { collectionView }

    var onOpen: ((FileItem) -> Void)?
    var onOpenInNewTab: ((FileItem) -> Void)?
    var onRenameCommitted: ((FileItem, String) -> Void)?
    var onSelectionChanged: (() -> Void)?
    var onFocus: (() -> Void)?
    var onQuickLook: (() -> Void)?
    var onDropFiles: (([URL], URL, NSDragOperation) -> Void)?
    /// A spring-loaded folder the pane should open (see UI/SpringLoading.swift).
    var onSpringLoad: ((URL) -> Void)?
    var onZoomGesture: ((Int) -> Void)?

    var contextMenu: NSMenu? {
        get { collectionView.menu }
        set { collectionView.menu = newValue }
    }
    var cutURLs: Set<URL> = [] {
        didSet { if cutURLs != oldValue { reloadData() } }
    }

    private(set) var iconSize: CGFloat = 64
    private(set) var showPreviews = true
    var thumbnailLoader: ThumbnailProvider.Loader = { item, size, scale, completion in
        ThumbnailProvider.shared.thumbnail(for: item, size: size, scale: scale, completion: completion)
    }
    private var thumbnailGeneration = UUID()
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
        updateDragOperations()
        collectionView.onReturn = { [weak self] in
            guard let self, let item = self.selectedItems.first, self.selectedItems.count == 1 else { return }
            self.beginRename(item: item)
        }
        collectionView.onSpace = { [weak self] in self?.onQuickLook?() }
        collectionView.onOpenRequest = { [weak self] in self?.openSelection() }
        collectionView.onZoom = { [weak self] step in self?.onZoomGesture?(step) }
        collectionView.onBecomeFirstResponder = { [weak self] in
            self?.onFocus?()
            self?.refreshSelectionEmphasis()
        }
        collectionView.onResignFirstResponder = { [weak self] in self?.refreshSelectionEmphasis() }
        collectionView.onBackingScaleChanged = { [weak self] in
            guard let self, self.showPreviews, self.iconSize >= ZoomLevel.previewThreshold else { return }
            self.reloadData()
        }

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

    private var shownItems: [IndexPath: FileItem] = [:]
    private var renameTarget: (field: NSTextField, item: FileItem)?

    // MARK: - FileViewing

    func reloadData() {
        thumbnailGeneration = UUID()
        let selected = selectedItems.map(\.url)
        let interrupted = captureRename()
        shownItems = [:]
        for (section, group) in model.groups.enumerated() {
            for (index, node) in group.nodes.enumerated() { shownItems[IndexPath(item: index, section: section)] = node.item }
        }
        collectionView.reloadData()
        let signature = [model.isGrouped ? 1 : 0] + model.groups.map { $0.nodes.count }
        if layoutSignature != signature {
            // A reused offscreen flow layout can keep stale section counts on
            // macOS 26 even after invalidation. Replace it when topology changes.
            layoutSignature = signature
            layout = NSCollectionViewFlowLayout()
            layout.minimumInteritemSpacing = 8
            layout.minimumLineSpacing = 12
            layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
            layout.sectionHeadersPinToVisibleBounds = true
            applyItemSize()
            collectionView.collectionViewLayout = layout
        } else { applyItemSize(); layout.invalidateLayout() }
        collectionView.needsLayout = true
        if !selected.isEmpty { select(urls: selected) }
        if let interrupted {
            DispatchQueue.main.async { [weak self] in self?.restoreRename(interrupted) }
        }
    }

    var selectedItems: [FileItem] {
        collectionView.selectionIndexPaths.sorted().compactMap { shownItems[$0] }
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

    func select(urls: [URL]) {
        let paths = Set(urls.compactMap { indexPath(for: $0) })
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

    var isRenaming: Bool { renameTarget != nil }

    /// Capture an open edit so a reload can re-open it, and end it without
    /// committing. `NSCollectionView.reloadData` discards the item that owns
    /// the field editor, which would otherwise end the edit by itself and let
    /// `controlTextDidEndEditing` commit a half-typed name.
    func captureRename() -> InlineRenameState? {
        guard let target = renameTarget else { return nil }
        let editor = target.field.currentEditor()
        let state = InlineRenameState(url: target.item.url.standardizedFileURL,
                                      text: editor?.string ?? target.field.stringValue,
                                      selection: editor?.selectedRange ?? NSRange(location: 0, length: 0))
        endRename(commit: false)
        return state
    }

    /// Re-open a captured edit, deferred by the caller to the next run-loop
    /// pass so the pane's own `select(urls:)` has already run.
    func restoreRename(_ state: InlineRenameState) {
        guard !isReadOnly, allowsRenaming,
              let item = model.items.first(where: { $0.url.standardizedFileURL == state.url }) else { return }
        beginRename(item: item)
        guard let target = renameTarget, let editor = target.field.currentEditor() else { return }
        editor.string = state.text
        target.field.stringValue = state.text
        editor.selectedRange = state.selection.clamped(toLength: (state.text as NSString).length)
    }

    /// Ends an open inline rename, applying the typed name or discarding it.
    func endRename(commit: Bool) {
        guard let target = renameTarget else { return }
        // Committing goes through the window so `controlTextDidEndEditing`
        // runs and applies the typed name; `renameTarget` must still be set.
        if commit { target.field.window?.endEditing(for: target.field); return }
        renameTarget = nil
        _ = target.field.abortEditing()
        target.field.stringValue = target.item.displayName
        target.field.isEditable = false
    }

    func beginRename(item: FileItem) {
        guard !isReadOnly, allowsRenaming, item.canAccess, !item.isArchiveEntry, let ip = indexPath(for: item.url) else { return }
        collectionView.selectionIndexPaths = [ip]
        collectionView.scrollToItems(at: [ip], scrollPosition: .nearestHorizontalEdge)
        // `item(at:)` "returns nil if the CollectionView isn't currently
        // maintaining an NSCollectionViewItem instance for the given
        // indexPath" (NSCollectionView.h) — true for an item that has just
        // been inserted, or one outside the visible rect, until layout runs.
        collectionView.layoutSubtreeIfNeeded()
        guard let cell = collectionView.item(at: ip) as? FileCollectionItem else { return }
        renameTarget = (cell.label, item)
        cell.label.stringValue = item.name
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
        let available = scrollView.contentSize.width
        let preferred = max(iconSize + 28, 96)
        let width = available > 0 ? min(preferred, max(1, available - 24)) : preferred
        let drawnIconSize = min(iconSize, max(1, width - 16))
        let labelHeight: CGFloat = (iconSize < 48 ? 30 : 34) + (model.isSearchResults ? 30 : 0)
        let size = NSSize(width: width, height: drawnIconSize + 8 + labelHeight)
        if layout.itemSize != size { layout.itemSize = size }
        let header = model.isGrouped ? NSSize(width: max(1, available), height: GroupHeaderView.height) : .zero
        if layout.headerReferenceSize != header { layout.headerReferenceSize = header }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyItemSize()
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
        cell.configure(item: item, iconSize: iconSize, faded: cutURLs.contains(item.url), showsLocation: model.isSearchResults)
        cell.onDoubleClick = { [weak self] in self?.onOpen?(item) }
        cell.onMiddleClick = { [weak self] in self?.onOpenInNewTab?(item) }
        if item.canAccess, showPreviews, iconSize >= ZoomLevel.previewThreshold, ThumbnailProvider.canPreview(item) {
            let scale = collectionView.window?.backingScaleFactor ?? 2
            let generation = thumbnailGeneration
            let requestID = cell.thumbnailRequestID
            if let cached = thumbnailLoader(item, iconSize, scale, { [weak self, weak cell] image in
                guard let self, self.showPreviews, self.thumbnailGeneration == generation,
                      (self.collectionView.window?.backingScaleFactor ?? 2) == scale,
                      let image, let cell, (cell.representedObject as? FileNode) === node else { return }
                cell.setThumbnail(image, for: requestID)
            }) {
                cell.setThumbnail(cached, for: requestID)
            }
        }
        return cell
    }

    // MARK: - Delegate

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { onSelectionChanged?() }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { onSelectionChanged?() }

    // Drag source
    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        indexPaths.contains { node(at: $0)?.item.canAccess == true }
    }
    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard let item = node(at: indexPath)?.item, item.canAccess,
              let url = item.publishedContentURL else { return nil }
        return url as NSURL
    }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                        willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
        draggingReadOnlyItems = isReadOnly || indexPaths.contains { node(at: $0)?.item.isArchiveEntry == true }
        updateDragOperations()
    }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                        endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
        draggingReadOnlyItems = false
        updateDragOperations()
    }

    /// Onto a folder icon → into that folder; anywhere else → into the listed directory.
    private func dropDestination(_ indexPath: IndexPath, _ op: NSCollectionView.DropOperation) -> URL? {
        guard !isReadOnly else { return nil }
        if op == .on, let item = node(at: indexPath)?.item, item.isNavigable { return item.url }
        return model.url
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
                        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        guard !isReadOnly else { return [] }
        let ip = proposedIndexPath.pointee as IndexPath
        let onFolder = dropOperation.pointee == .on && node(at: ip)?.item.isNavigable == true
        if !onFolder {
            // No insertion gap: the whole grid is the target.
            dropOperation.pointee = .before
            let last = max(model.groups.count - 1, 0)
            proposedIndexPath.pointee = NSIndexPath(forItem: model.groups.indices.contains(last) ? model.groups[last].nodes.count : 0, inSection: last)
        }
        guard let dest = dropDestination(ip, onFolder ? .on : .before) else { return [] }
        return DragAndDrop.validationOperation(for: draggingInfo.fileURLs, into: dest,
                                               sourceMask: draggingInfo.draggingSourceOperationMask)
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        let urls = draggingInfo.fileURLs
        guard let dest = dropDestination(indexPath, dropOperation) else { return false }
        let op = FileOperations.dropOperation(for: urls, into: dest, sourceMask: draggingInfo.draggingSourceOperationMask)
        guard !op.isEmpty else { return false }
        onDropFiles?(urls, dest, op)
        return true
    }

    /// The item at an index path, for spring loading and other collaborators
    /// outside this file.
    func item(at indexPath: IndexPath) -> FileItem? { node(at: indexPath)?.item }

    // MARK: - Rename (label editing)

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        field.isEditable = false
        guard let target = renameTarget, target.field === field else { return }
        renameTarget = nil
        let item = target.item
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if isReadOnly || !allowsRenaming || item.isArchiveEntry || !item.canAccess || newName.isEmpty || newName == item.name || newName.contains("/") {
            field.stringValue = item.displayName
            return
        }
        onRenameCommitted?(item, newName)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if let field = control as? NSTextField, let target = renameTarget, target.field === field {
                textView.string = target.item.name
                field.stringValue = target.item.name
            }
            view.window?.makeFirstResponder(collectionView)
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
    /// Return rebound to Open (`ShortcutCatalog.openID`), which ships unbound.
    var onOpenRequest: (() -> Void)?
    var onZoom: ((Int) -> Void)?
    var onBecomeFirstResponder: (() -> Void)?
    var onResignFirstResponder: (() -> Void)?
    var onBackingScaleChanged: (() -> Void)?
    private(set) var clickedIndexPath: IndexPath?
    private var backingScale = BackingScaleTracker()
    private var zoomGesture = ZoomGestureAccumulator()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if backingScale.update(from: window) { onBackingScaleChanged?() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if backingScale.update(from: window) { onBackingScaleChanged?() }
    }

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
        if ShortcutDispatcher.handleFileView(event, onRename: onReturn, onQuickLook: onSpace,
                                            onOpen: onOpenRequest) { return }
        super.keyDown(with: event)
    }

    /// ⌘-scroll zooms (Dolphin's Ctrl-wheel); ordinary scrolling passes through.
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else { return super.scrollWheel(with: event) }
        if let step = zoomGesture.step(scrollingDeltaY: event.scrollingDeltaY) { onZoom?(step) }
    }

    override func magnify(with event: NSEvent) {
        if let step = zoomGesture.step(magnification: event.magnification) { onZoom?(step) }
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
    let locationLabel = NSTextField(wrappingLabelWithString: "")
    var onDoubleClick: (() -> Void)?
    var onMiddleClick: (() -> Void)?
    private var iconSize: CGFloat = 64
    private(set) var thumbnailRequestID = UUID()
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
        locationLabel.alignment = .center
        locationLabel.font = .systemFont(ofSize: 10)
        locationLabel.textColor = .secondaryLabelColor
        locationLabel.maximumNumberOfLines = 2
        locationLabel.lineBreakMode = .byTruncatingMiddle
        v.addSubview(locationLabel)
        view = v
    }

    override var isSelected: Bool { didSet { refreshAppearance() } }
    override var highlightState: NSCollectionViewItem.HighlightState { didSet { refreshAppearance() } }

    func configure(item: FileItem, iconSize: CGFloat, faded: Bool, showsLocation: Bool = false) {
        thumbnailRequestID = UUID()
        self.iconSize = iconSize
        self.faded = faded
        iconView.image = item.icon(size: iconSize)
        label.stringValue = item.displayName
        label.font = .systemFont(ofSize: iconSize < 48 ? 11 : 12)
        locationLabel.isHidden = !showsLocation
        locationLabel.stringValue = (item.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        view.toolTip = showsLocation ? item.url.path : item.name
        layoutSubviews()
        refreshAppearance()
    }

    @discardableResult
    func setThumbnail(_ image: NSImage, for requestID: UUID) -> Bool {
        guard thumbnailRequestID == requestID else { return false }
        iconView.image = image
        return true
    }

    private func layoutSubviews() {
        guard let v = view as? ItemView else { return }
        let w = v.bounds.width
        let drawnSize = min(iconSize, max(1, w - 16))
        let iconFrame = NSRect(x: (w - drawnSize) / 2, y: 4, width: drawnSize, height: drawnSize)
        iconView.frame = iconFrame
        let labelHeight = iconSize < 48 ? 30 : 34
        let labelFrame = NSRect(x: 4, y: iconFrame.maxY + 4, width: w - 8, height: CGFloat(labelHeight))
        label.frame = labelFrame
        locationLabel.frame = NSRect(x: 4, y: labelFrame.maxY, width: w - 8, height: 28)
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
