import AppKit

/// Details view: a view-based NSOutlineView over a DirectoryModel. Folders
/// expand in place with a disclosure triangle, like Finder's list view.
/// Owns nothing about navigation or file operations — it reports intent
/// upward through closures and is the Quick Look panel's data source.
final class FileListViewController: NSViewController, FileViewing, NSOutlineViewDataSource, NSOutlineViewDelegate,
                                    NSTextFieldDelegate {

    var viewController: NSViewController { self }
    var focusView: NSView { tableView }

    let model: DirectoryModel
    /// An NSOutlineView; the name is kept because it is a table to everyone else.
    let tableView = FileOutlineView()
    let scrollView = NSScrollView()

    var isReadOnly = false {
        didSet {
            tableView.allowsRenaming = !isReadOnly
            updateDragOperations()
        }
    }
    private var draggingReadOnlyItems = false

    private func updateDragOperations() {
        let copyOnly = isReadOnly || draggingReadOnlyItems
        tableView.setDraggingSourceOperationMask(copyOnly ? .copy : [.copy, .move], forLocal: true)
        tableView.setDraggingSourceOperationMask(copyOnly ? .copy : [.copy, .move, .link], forLocal: false)
    }

    /// Called once per item the user asked to open (double-click, ⌘↓).
    var onOpen: ((FileItem) -> Void)?
    /// ⌘-double-click or middle-click on a folder.
    var onOpenInNewTab: ((FileItem) -> Void)?
    /// Inline rename finished with a different, non-empty name.
    var onRenameCommitted: ((FileItem, String) -> Void)?
    var onSelectionChanged: (() -> Void)?
    /// The list took keyboard focus (used to activate its pane in a split).
    var onFocus: (() -> Void)?
    var onQuickLook: (() -> Void)?
    /// Files dropped into a folder: (urls, destination, .copy or .move).
    var onDropFiles: (([URL], URL, NSDragOperation) -> Void)?
    var onZoomGesture: ((Int) -> Void)?

    var contextMenu: NSMenu? {
        get { tableView.menu }
        set { tableView.menu = newValue }
    }

    private(set) var iconSize: CGFloat = 16
    private(set) var showPreviews = true
    var thumbnailLoader: ThumbnailProvider.Loader = { item, size, scale, completion in
        ThumbnailProvider.shared.thumbnail(for: item, size: size, scale: scale, completion: completion)
    }
    private var thumbnailGeneration = UUID()

    /// Items marked by ⌘X are drawn faded until pasted or the pasteboard changes.
    var cutURLs: Set<URL> = [] {
        didSet {
            guard cutURLs != oldValue else { return }
            let selected = selectedItems.map(\.url)
            reloadData()
            select(urls: selected)
        }
    }

    private var shownGeneration = -1
    private var renameTarget: (field: NSTextField, item: FileItem)?

    /// A result batch can reorder/reuse rows while an editor is open.
    private func cancelResultRename() {
        guard model.isSearchResults, let target = renameTarget else { return }
        renameTarget = nil
        _ = target.field.abortEditing()
        target.field.isEditable = false
    }

    private enum Column: String, CaseIterable {
        case name, dateModified, size, kind, location

        var id: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }
        var title: String {
            switch self {
            case .name: return "Name"
            case .dateModified: return "Date Modified"
            case .size: return "Size"
            case .kind: return "Kind"
            case .location: return "Location"
            }
        }
        var sortKey: DirectoryModel.SortKey {
            switch self {
            case .name: return .name
            case .dateModified: return .dateModified
            case .size: return .size
            case .kind: return .kind
            case .location: return .name
            }
        }
        var width: CGFloat {
            switch self {
            case .name: return 320
            case .dateModified: return 170
            case .size: return 90
            case .kind: return 170
            case .location: return 320
            }
        }
    }

    init(model: DirectoryModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView()

        for column in Column.allCases {
            let col = NSTableColumn(identifier: column.id)
            col.title = column.title
            col.width = column.width
            // Keep filenames useful in a split pane; metadata can scroll.
            col.minWidth = column == .name ? 180 : 60
            col.resizingMask = [.userResizingMask, .autoresizingMask]
            if column != .location { col.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true) }
            col.isHidden = column == .location && !model.isSearchResults
            tableView.addTableColumn(col)
            if column == .name { tableView.outlineTableColumn = col }
        }
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.style = .fullWidth
        tableView.rowSizeStyle = .custom          // .default ignores rowHeight, which the zoom drives
        tableView.rowHeight = Self.rowHeight(forIconSize: iconSize)   // setIconSize may have run before loadView
        tableView.indentationPerLevel = 16
        tableView.indentationMarkerFollowsCell = true
        tableView.autoresizesOutlineColumn = false
        tableView.floatsGroupRows = true          // Finder's sticky group headers
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked(_:))
        setSort(key: model.sortKey, ascending: model.ascending)
        tableView.registerForDraggedTypes([.fileURL])
        updateDragOperations()

        tableView.onMiddleClickRow = { [weak self] row in
            guard let self, let item = self.item(atRow: row) else { return }
            self.onOpenInNewTab?(item)
        }
        tableView.onReturn = { [weak self] in
            guard let self, let row = self.tableView.selectedRowIndexes.first,
                  self.tableView.selectedRowIndexes.count == 1 else { return }
            self.beginRename(row: row)
        }
        tableView.onSpace = { [weak self] in self?.onQuickLook?() }
        tableView.onRenameRequest = { [weak self] row in self?.beginRename(row: row) }
        tableView.onBecomeFirstResponder = { [weak self] in self?.onFocus?() }
        tableView.onZoom = { [weak self] step in self?.onZoomGesture?(step) }
        tableView.onBackingScaleChanged = { [weak self] in
            guard let self, self.showPreviews, self.iconSize >= ZoomLevel.previewThreshold else { return }
            let selection = self.selectedItems.map(\.url)
            self.reloadData()
            self.select(urls: selection)
        }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        view.pinToEdges(scrollView)
    }

    // MARK: - Public

    /// Folders the user has expanded, tracked from the outline view's own
    /// notifications. Kept here rather than read back from the view because
    /// by the time reloadData() runs the model has already changed, and the
    /// view's cached row count would make it query rows that no longer exist.
    private var expandedURLs: Set<URL> = []
    var expandedFolderURLs: [URL] { Array(expandedURLs) }

    /// Reload, keeping folders that were expanded expanded. When the change is
    /// a fresh listing (not just a re-sort) their contents are re-listed too.
    func reloadData() {
        thumbnailGeneration = UUID()
        cancelResultRename()
        tableView.tableColumn(withIdentifier: Column.location.id)?.isHidden = !model.isSearchResults
        let locationIndex = tableView.column(withIdentifier: Column.location.id)
        let desiredIndex = model.isSearchResults ? 1 : tableView.tableColumns.count - 1
        if locationIndex >= 0, locationIndex != desiredIndex { tableView.moveColumn(locationIndex, toColumn: desiredIndex) }
        if model.isSearchResults { expandedURLs = [] }
        let refresh = model.generation != shownGeneration
        shownGeneration = model.generation
        // Shorter paths first so a parent is refreshed before its children.
        let nodes = expandedURLs.sorted { $0.path.count < $1.path.count }.compactMap { model.node(for: $0) }
        // Refresh BEFORE reloadData: the outline view keeps the same node
        // objects expanded across a reload and re-reads their children right
        // then, so the fresh listing has to be in place already.
        if refresh { for n in nodes { model.loadChildren(of: n, refresh: true) } }
        tableView.reloadData()
        if model.isGrouped { for g in model.groups { tableView.expandItem(g) } }   // groups are always open
        for n in nodes where tableView.row(forItem: n) >= 0 { tableView.expandItem(n) }
        expandedURLs = Set(nodes.map { $0.url.standardizedFileURL })
    }

    func node(atRow row: Int) -> FileNode? { tableView.item(atRow: row) as? FileNode }
    func item(atRow row: Int) -> FileItem? { node(atRow: row)?.item }

    var selectedItems: [FileItem] {
        tableView.selectedRowIndexes.compactMap { item(atRow: $0) }
    }

    var clickedItems: [FileItem] {
        let clicked = tableView.clickedRow
        guard clicked >= 0, let item = item(atRow: clicked) else { return [] }
        return tableView.selectedRowIndexes.contains(clicked) ? selectedItems : [item]
    }

    func itemAfterSelection() -> FileItem? {
        guard let last = tableView.selectedRowIndexes.last else { return nil }
        return item(atRow: last + 1)
    }

    func beginRename(item: FileItem) {
        guard let node = model.node(for: item.url) else { return }
        let row = tableView.row(forItem: node)
        if row >= 0 { beginRename(row: row) }
    }

    /// 16→24 (Finder's list row), 32→40, 64→72.
    static func rowHeight(forIconSize size: CGFloat) -> CGFloat { max(24, size + 8) }

    /// Dolphin's details-view zoom: bigger icons, taller rows, previews from 32pt.
    func setIconSize(_ size: CGFloat, showPreviews: Bool) {
        let changed = size != iconSize || showPreviews != self.showPreviews
        iconSize = size
        self.showPreviews = showPreviews
        guard changed else { return }
        tableView.rowHeight = Self.rowHeight(forIconSize: size)
        reloadData()
    }

    func frameOnScreen(for url: URL) -> NSRect {
        guard let node = model.node(for: url), let window = tableView.window else { return .zero }
        let row = tableView.row(forItem: node)
        guard row >= 0 else { return .zero }
        return window.convertToScreen(tableView.convert(tableView.frameOfCell(atColumn: 0, row: row), to: nil))
    }

    func forwardKey(_ event: NSEvent) { tableView.keyDown(with: event) }

    func expand(_ node: FileNode) { tableView.expandItem(node) }
    func collapse(_ node: FileNode) { tableView.collapseItem(node) }
    func isExpanded(_ node: FileNode) -> Bool { tableView.isItemExpanded(node) }

    /// Select by name and scroll into view. Top-level matches win over nested
    /// ones; passing nil clears the selection.
    func select(name: String?) {
        guard let name else { tableView.deselectAll(nil); return }
        select(names: [name])
        if tableView.selectedRowIndexes.isEmpty { tableView.deselectAll(nil) }
    }

    func select(names: [String]) {
        var rows = IndexSet()
        for name in names {
            if let node = model.nodes.first(where: { $0.item.name == name }) {
                let r = tableView.row(forItem: node)
                if r >= 0 { rows.insert(r); continue }
            }
            if let r = (0..<tableView.numberOfRows).first(where: { item(atRow: $0)?.name == name }) {
                rows.insert(r)
            }
        }
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first { tableView.scrollRowToVisible(first) }
    }

    func select(urls: [URL]) {
        let targets = Set(urls.map { $0.standardizedFileURL })
        let rows = IndexSet((0..<tableView.numberOfRows).filter {
            item(atRow: $0).map { targets.contains($0.url.standardizedFileURL) } ?? false
        })
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first { tableView.scrollRowToVisible(first) }
    }

    /// AppKit may place the real top at a negative y to accommodate its table
    /// header. History stores distance from that top, not raw clip coordinates.
    private var topScrollOrigin: CGFloat {
        let clip = scrollView.contentView
        var proposed = clip.bounds
        proposed.origin.y = min(0, tableView.frame.minY)
            - max(1, clip.bounds.height) - abs(clip.contentInsets.top)
        return clip.constrainBoundsRect(proposed).origin.y
    }

    /// Native bounds constraints account for headers, insets and document size.
    /// Clamping raw y to zero hides the first row after a refresh restores it.
    var scrollOffset: CGFloat {
        get { max(0, scrollView.contentView.bounds.origin.y - topScrollOrigin) }
        set {
            scrollView.layoutSubtreeIfNeeded()
            let clip = scrollView.contentView
            var proposed = clip.bounds
            proposed.origin.y = topScrollOrigin + max(0, newValue)
            clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
            scrollView.reflectScrolledClipView(clip)
        }
    }

    @objc func openSelection(_ sender: Any?) {
        for item in selectedItems { onOpen?(item) }
    }

    func openSelection() { openSelection(nil) }

    /// Drive sorting through the table so the header indicator stays in sync.
    func setSort(key: DirectoryModel.SortKey, ascending: Bool) {
        model.setSort(key: key, ascending: ascending)
        let column = Column.allCases.first { $0.sortKey == key } ?? .name
        tableView.sortDescriptors = [NSSortDescriptor(key: column.rawValue, ascending: ascending)]
    }

    // MARK: - Rename

    /// Start editing the name cell, with the base name (not the extension)
    /// selected — Finder's behaviour. The field is made editable only for the
    /// duration of the edit, so an ordinary click never starts one by itself.
    func beginRename(row: Int) {
        guard !isReadOnly, let item = item(atRow: row), item.canAccess, !item.isArchiveEntry else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.textField else { return }
        renameTarget = (field, item)
        field.stringValue = item.name
        field.isEditable = true
        tableView.editColumn(0, row: row, with: nil, select: true)
        guard let editor = field.currentEditor() else { field.isEditable = false; return }
        let base = item.isNavigable ? item.name : (item.name as NSString).deletingPathExtension
        if !base.isEmpty, base.count < item.name.count || item.isNavigable {
            editor.selectedRange = NSRange(location: 0, length: (base as NSString).length)
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        field.isEditable = false
        guard let target = renameTarget, target.field === field else { return }
        renameTarget = nil
        let item = target.item
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if isReadOnly || item.isArchiveEntry || !item.canAccess || newName.isEmpty || newName == item.name || newName.contains("/") {
            field.stringValue = item.displayName            // revert
            return
        }
        onRenameCommitted?(item, newName)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)),
              let field = control as? NSTextField, let target = renameTarget, target.field === field else { return false }
        let item = target.item
        textView.string = item.name
        field.stringValue = item.name
        view.window?.makeFirstResponder(tableView)
        return true
    }

    // MARK: - Actions

    @objc private func doubleClicked(_ sender: Any?) {
        tableView.cancelPendingRename()
        let row = tableView.clickedRow
        // Double-clicking empty space or a column header should not open the selection.
        guard row >= 0, let item = item(atRow: row) else { return }
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            onOpenInNewTab?(item)
            return
        }
        if tableView.selectedRowIndexes.contains(row) {
            openSelection(sender)
        } else {
            onOpen?(item)
        }
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let group = item as? GroupNode { return group.nodes.count }
        guard let node = item as? FileNode else { return model.isGrouped ? model.groups.count : model.nodes.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let group = item as? GroupNode { return group.nodes[index] }
        guard let node = item as? FileNode else { return model.isGrouped ? model.groups[index] : model.nodes[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if item is GroupNode { return true }
        return !model.isSearchResults && ((item as? FileNode)?.item.isNavigable ?? false)
    }

    // Group rows: Finder-style headers — not selectable, no disclosure, always open.
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is GroupNode }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { !(item is GroupNode) }
    func outlineView(_ outlineView: NSOutlineView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        IndexSet(proposed.filter { !(outlineView.item(atRow: $0) is GroupNode) })   // rubber bands skip headers too
    }
    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { !(item is GroupNode) }
    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool { !(item is GroupNode) }
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        item is GroupNode ? 26 : tableView.rowHeight
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        model.loadChildren(of: node)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        expandedURLs.insert(node.url.standardizedFileURL)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        expandedURLs.remove(node.url.standardizedFileURL)
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = outlineView.sortDescriptors.first, let key = d.key,
              let column = Column(rawValue: key) else { return }
        model.setSort(key: column.sortKey, ascending: d.ascending)
    }

    // Archive entries export validated snapshot URLs with a copy-only mask.
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let entry = (item as? FileNode)?.item, entry.canAccess,
              let url = entry.readableContentURL else { return nil }
        return url as NSURL
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        draggingReadOnlyItems = isReadOnly || draggedItems.contains { ($0 as? FileNode)?.item.isArchiveEntry == true }
        updateDragOperations()
        tableView.noteDragSessionBegan()
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        tableView.noteDragSessionEnded()
        draggingReadOnlyItems = false
        updateDragOperations()
    }

    /// Where a drop would land: onto a folder row, between an expanded
    /// folder's children (= into that folder), or into the listed directory.
    func dropDestination(item: Any?, childIndex: Int) -> (url: URL, node: FileNode?)? {
        guard !isReadOnly else { return nil }
        if let node = item as? FileNode {
            return node.item.isNavigable ? (node.url, node) : nil
        }
        return model.url.map { ($0, nil) }          // root gap or a group row: the listed directory
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let urls = info.fileURLs
        guard let dest = dropDestination(item: item, childIndex: index) else { return [] }
        // Highlight the folder (or the whole list), never an insertion line.
        outlineView.setDropItem(dest.node, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return FileOperations.dropOperation(for: urls, into: dest.url, sourceMask: info.draggingSourceOperationMask)
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        let urls = info.fileURLs
        guard let dest = dropDestination(item: item, childIndex: index) else { return false }
        let operation = FileOperations.dropOperation(for: urls, into: dest.url, sourceMask: info.draggingSourceOperationMask)
        guard !operation.isEmpty else { return false }
        onDropFiles?(urls, dest.url, operation)
        return true
    }

    // MARK: - NSOutlineViewDelegate

    private static let groupCellID = NSUserInterfaceItemIdentifier("group")

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? GroupNode {
            let cell = (outlineView.makeView(withIdentifier: Self.groupCellID, owner: self) as? NSTableCellView)
                ?? NSTableCellView.make(identifier: Self.groupCellID, withIcon: false)
            cell.textField?.stringValue = group.title
            cell.textField?.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .bold)
            cell.textField?.textColor = .secondaryLabelColor
            return cell
        }
        guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue),
              let node = item as? FileNode else { return nil }
        let item = node.item

        // The name cell's icon constraints depend on the zoom, so its reuse
        // identifier carries the size and pools never mix.
        let id = column == .name ? NSUserInterfaceItemIdentifier("name-\(Int(iconSize))") : column.id
        let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView)
            ?? NSTableCellView.make(identifier: id, withIcon: column == .name,
                                    alignment: column == .size ? .right : .natural, iconSize: iconSize)
        cell.alphaValue = cutURLs.contains(item.url) ? 0.45 : 1
        cell.toolTip = model.isSearchResults ? item.url.path : nil

        switch column {
        case .name:
            cell.imageView?.image = item.icon(size: iconSize)
            let requestID = UUID()
            cell.objectValue = requestID
            if item.canAccess, showPreviews, iconSize >= ZoomLevel.previewThreshold, ThumbnailProvider.canPreview(item) {
                let scale = outlineView.window?.backingScaleFactor ?? 2
                let generation = thumbnailGeneration
                if let cached = thumbnailLoader(item, iconSize, scale, { [weak self, weak cell] image in
                    guard let self, self.showPreviews, self.thumbnailGeneration == generation,
                          (self.tableView.window?.backingScaleFactor ?? 2) == scale,
                          let image, let cell, (cell.objectValue as? UUID) == requestID else { return }
                    cell.imageView?.image = image
                }) {
                    cell.imageView?.image = cached
                }
            }
            cell.textField?.stringValue = item.displayName
            cell.textField?.textColor = item.isHidden ? .secondaryLabelColor : .labelColor
            cell.textField?.isEditable = false          // beginRename turns it on
            cell.textField?.delegate = self
        case .dateModified:
            cell.textField?.stringValue = item.displayDate
            cell.textField?.textColor = .secondaryLabelColor
        case .size:
            cell.textField?.stringValue = item.displaySize
            cell.textField?.textColor = .secondaryLabelColor
        case .location:
            cell.textField?.lineBreakMode = .byTruncatingMiddle
            cell.textField?.stringValue = item.url.deletingLastPathComponent().path
            cell.textField?.textColor = .secondaryLabelColor
        case .kind:
            cell.textField?.stringValue = item.kindDescription
            cell.textField?.textColor = .secondaryLabelColor
        }
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        (item as? FileNode)?.item.name
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        tableView.cancelPendingRename()
        onSelectionChanged?()
    }
}

/// NSOutlineView with the keys and clicks Finder gives a file list: Return
/// renames, Space previews, middle click opens a folder in a new tab, and a
/// click on the name of the single selected row starts a rename after the
/// double-click interval — unless a double-click, drag or selection change
/// arrives first.
final class FileOutlineView: NSOutlineView {
    var allowsRenaming = true {
        didSet { if !allowsRenaming { cancelPendingRename() } }
    }
    var onMiddleClickRow: ((Int) -> Void)?
    var onReturn: (() -> Void)?
    var onSpace: (() -> Void)?
    var onRenameRequest: ((Int) -> Void)?
    var onBecomeFirstResponder: (() -> Void)?
    var onZoom: ((Int) -> Void)?
    var onBackingScaleChanged: (() -> Void)?
    private var backingScale = BackingScaleTracker()
    private var zoomGesture = ZoomGestureAccumulator()
    private var pendingRename: DispatchWorkItem?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if backingScale.update(from: window) { onBackingScaleChanged?() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if backingScale.update(from: window) { onBackingScaleChanged?() }
    }

    /// ⌘-scroll zooms (Dolphin's Ctrl-wheel); ordinary scrolling passes through.
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else { return super.scrollWheel(with: event) }
        if let step = zoomGesture.step(scrollingDeltaY: event.scrollingDeltaY) { onZoom?(step) }
    }

    override func magnify(with event: NSEvent) {
        if let step = zoomGesture.step(magnification: event.magnification) { onZoom?(step) }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onBecomeFirstResponder?() }
        return ok
    }

    override func keyDown(with event: NSEvent) {
        if ShortcutDispatcher.handleFileView(event, onRename: onReturn, onQuickLook: onSpace) { return }
        super.keyDown(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseDown(with: event) }
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { onMiddleClickRow?(row) }
    }

    override func mouseDown(with event: NSEvent) {
        cancelPendingRename()
        dragSessionBegan = false
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        let candidate = renameCandidate(row: row, point: point, event: event)
        let downAt = NSEvent.mouseLocation                    // screen coordinates, timing-independent
        super.mouseDown(with: event)      // selection, drag, double-click
        let travelled = hypot(NSEvent.mouseLocation.x - downAt.x, NSEvent.mouseLocation.y - downAt.y)
        guard renameAllowedAfterMouseUp(candidate: candidate, pointerTravelled: travelled) else { return }
        scheduleRename(row: row)
    }

    /// Set by the data source when a drag session starts or ends. Whether that
    /// happens before or after mouseDown returns must not matter, so it both
    /// blocks a rename that is not yet scheduled and cancels one that is.
    private var dragSessionBegan = false
    func noteDragSessionBegan() {
        dragSessionBegan = true
        cancelPendingRename()
    }
    func noteDragSessionEnded() { cancelPendingRename() }

    /// A rename may follow a click only if no drag session began and the
    /// pointer did not move past the drag threshold between down and up.
    func renameAllowedAfterMouseUp(candidate: Bool, pointerTravelled: CGFloat) -> Bool {
        defer { dragSessionBegan = false }
        return allowsRenaming && candidate && !dragSessionBegan && pointerTravelled <= 3
    }

    /// Finder's rule: a plain single click on the *name* of the one row that
    /// is already the sole selection.
    func renameCandidate(row: Int, point: NSPoint, event: NSEvent) -> Bool {
        guard allowsRenaming, row >= 0, event.clickCount == 1,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
              selectedRowIndexes == IndexSet(integer: row),
              column(at: point) == 0,
              let cell = view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView,
              let field = cell.textField else { return false }
        return field.frame.contains(convert(point, to: cell))
    }

    func scheduleRename(row: Int, after delay: TimeInterval = NSEvent.doubleClickInterval) {
        guard allowsRenaming else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.allowsRenaming, !self.dragSessionBegan,
                  self.selectedRowIndexes == IndexSet(integer: row) else { return }
            self.pendingRename = nil
            self.onRenameRequest?(row)
        }
        pendingRename = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    var hasPendingRename: Bool { pendingRename != nil }

    func cancelPendingRename() {
        pendingRename?.cancel()
        pendingRename = nil
    }
}
