import AppKit

/// Column view: Finder's "as Columns", built on `NSBrowser` — which is what
/// Finder itself uses (`TColumnView : NSBrowser`, ColumnView.nib).
///
/// A selected folder opens its contents in the column to the right, and the
/// chain follows the selection; a selected file shows a preview in the last
/// column, reusing the docked pane's renderer. **Selecting never navigates
/// the pane.** The pane's `currentURL` stays the column root; only opening a
/// folder (double-click, ⌘↓ — Return renames, as everywhere else) moves it. That is a deliberate difference
/// from Finder, where the deepest selected folder becomes the location: per-
/// folder view properties are re-applied on every navigation, and a child
/// folder remembered as icons would tear the columns down mid-chain (D84).
///
/// The browser is fed from `DirectoryModel`'s node tree, so filtering and
/// sorting are the model's, and the root column is the same listing the list
/// and icon views show.
/// The one thing a plain `NSBrowser` cannot do for us: the zoom gestures every
/// file view supports arrive at the browser, not at its view controller.
final class ColumnBrowser: NSBrowser {
    var onCommandScroll: ((CGFloat) -> Void)?
    var onMagnify: ((CGFloat) -> Void)?
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { onCommandScroll?(event.scrollingDeltaY) }
        else { super.scrollWheel(with: event) }
    }
    override func magnify(with event: NSEvent) { onMagnify?(event.magnification) }

    /// Escape while renaming cancels the edit. The field editor forwards
    /// `cancelOperation:` up its responder chain, which passes through here
    /// before reaching the pane; `abortEditing` ends the session without
    /// committing. When nothing is being edited the event continues up the
    /// chain as before (the pane clears its filter on Escape).
    override func cancelOperation(_ sender: Any?) {
        // In item mode the editing session belongs to the column's inner
        // table view, not to the browser itself, so ask whoever owns the
        // field editor — that control's abortEditing ends it uncommitted.
        let owner = (window?.fieldEditor(false, for: nil)?.delegate as? NSControl)
        if owner?.abortEditing() == true || abortEditing() {
            window?.makeFirstResponder(self)
        } else {
            // See BrowserViewController.cancelOperation: NSResponder has no
            // implementation to call, so hand it on with tryToPerform.
            nextResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: sender)
        }
    }
}

final class ColumnViewController: NSViewController, FileViewing, NSBrowserDelegate {

    let model: DirectoryModel
    let browser = ColumnBrowser()
    private let preview = PreviewPanelController()

    var isReadOnly = false {
        didSet { updateDragMasks() }
    }
    /// Set while a drag carries archive entries, which can only ever be copied.
    private var draggingReadOnlyItems = false { didSet { updateDragMasks() } }
    private func updateDragMasks() {
        let copyOnly = isReadOnly || draggingReadOnlyItems
        browser.setDraggingSourceOperationMask(DragAndDrop.sourceMask(readOnly: copyOnly, local: true), forLocal: true)
        browser.setDraggingSourceOperationMask(DragAndDrop.sourceMask(readOnly: copyOnly, local: false), forLocal: false)
    }
    var allowsRenaming = true

    var viewController: NSViewController { self }
    var focusView: NSView { browser }

    var onOpen: ((FileItem) -> Void)?
    var onOpenInNewTab: ((FileItem) -> Void)?
    var onRenameCommitted: ((FileItem, String) -> Void)?
    var onSelectionChanged: (() -> Void)?
    var onFocus: (() -> Void)?
    var onQuickLook: (() -> Void)?
    var onDropFiles: (([URL], URL, NSDragOperation) -> Void)?
    var onSpringLoad: ((URL) -> Void)?
    var onZoomGesture: ((Int) -> Void)?

    var contextMenu: NSMenu? {
        get { browser.menu }
        set { browser.menu = newValue }
    }
    var cutURLs: Set<URL> = [] {
        didSet { if cutURLs != oldValue { reloadData() } }
    }

    private(set) var iconSize: CGFloat = 22
    private(set) var showPreviews = true
    private var zoomGesture = ZoomGestureAccumulator()

    /// What each column is actually showing. NSBrowser's index paths were
    /// computed against the listing it loaded; resolving them against the live
    /// model after a sort, filter or hidden-files change points at the wrong
    /// rows (the icon grid keeps the same kind of snapshot as `shownItems`).
    private var shown: [ObjectIdentifier: [FileNode]] = [:]
    /// The model generation the open columns were listed from, so a change
    /// broadcast re-lists every open column rather than only the root.
    private var shownGeneration = -1
    /// The folder the open columns belong to. A pane can navigate to an
    /// ancestor of the current chain, and then the old chain is still
    /// reachable by path — re-selecting into it would reopen a chain the user
    /// just left, with a folder selected they never clicked.
    private var shownRootURL: URL?
    /// Set for the one `select` the pane performs after a navigation, whose
    /// URLs belong to the folder just left; honouring it would reopen the old
    /// chain the moved-root rule exists to drop.
    private var rootJustMoved = false
    /// Nodes `reloadData` has just re-listed, so the column loads that follow
    /// it read the model's cache instead of hitting the disk again.
    private var refreshedThisPass: Set<ObjectIdentifier> = []

    /// A stable object for the browser's root; `DirectoryModel` has no node
    /// for the listed folder itself, only for its contents.
    private let root = NSObject()

    init(model: DirectoryModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        // NSBrowser picks item mode or the legacy matrix mode from its
        // delegate, and `setRowHeight:` throws in matrix mode. The pane wires
        // a view — including its icon size — before it mounts it, so the
        // delegate must be in place from construction, not from loadView.
        browser.delegate = self
        browser.onCommandScroll = { [weak self] delta in
            guard let self, let step = self.zoomGesture.step(scrollingDeltaY: delta) else { return }
            self.onZoomGesture?(step)
        }
        browser.onMagnify = { [weak self] amount in
            guard let self, let step = self.zoomGesture.step(magnification: amount) else { return }
            self.onZoomGesture?(step)
        }
        // The docked pane's close button has no meaning inside a column, and
        // NSBrowser sizes a preview column through the autoresizing mask.
        preview.showsCloseButton = false
        preview.sizesItselfByAutoresizing = true
    }

    deinit { preview.shutdown(); if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) } }

    /// ⌘-scroll zooms in every file view. A column that overflows consumes
    /// the wheel in its own scroll view before the browser sees it, so the
    /// event is taken one step earlier, only for this window and this view.
    private var scrollMonitor: Any?
    override func viewWillAppear() {
        super.viewWillAppear()
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // A background tab's column view keeps its window and its geometry
            // (tabs are hidden, not removed), so it would otherwise zoom itself
            // and swallow the wheel meant for the visible pane.
            guard let self, event.modifierFlags.contains(.command), event.window === self.view.window,
                  !self.view.isHiddenOrHasHiddenAncestor,
                  self.browser.bounds.contains(self.browser.convert(event.locationInWindow, from: nil)) else { return event }
            if let step = self.zoomGesture.step(scrollingDeltaY: event.scrollingDeltaY) { self.onZoomGesture?(step) }
            return nil
        }
    }

    /// Off screen, nothing should keep playing in the preview column.
    override func viewDidDisappear() {
        super.viewDidDisappear()
        preview.show(nil)
    }

    /// Back on screen — a tab switch, say — the selected file is previewed
    /// again; NSBrowser only asks for the preview on a selection change.
    override func viewDidAppear() {
        super.viewDidAppear()
        let items = selectedItems
        if items.count == 1, !items[0].isNavigable {
            preview.show(items[0].isArchiveEntry ? items[0].readableContentURL : items[0].url, force: true)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - View

    override func loadView() {
        view = NSView()
        browser.translatesAutoresizingMaskIntoConstraints = false
        browser.target = self
        browser.action = #selector(browserClicked(_:))
        browser.doubleAction = #selector(browserDoubleClicked(_:))
        browser.allowsMultipleSelection = true
        browser.allowsEmptySelection = true
        browser.hasHorizontalScroller = true
        browser.autohidesScroller = true
        browser.columnResizingType = .userColumnResizing
        browser.minColumnWidth = 100                      // Finder's ColumnView.nib
        browser.setDefaultColumnWidth(245)                // Finder's ColumnViewOptions.ColumnWidth
        browser.maxVisibleColumns = 6                     // Finder's ColumnView.nib
        browser.takesTitleFromPreviousColumn = false
        browser.isTitled = false
        browser.setCellClass(NSBrowserCell.self)
        browser.registerForDraggedTypes([.fileURL])
        updateDragMasks()
        view.addSubview(browser)
        NSLayoutConstraint.activate([
            browser.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            browser.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            browser.topAnchor.constraint(equalTo: view.topAnchor),
            browser.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        applyRowHeight()
        browser.loadColumnZero()
    }

    private func applyRowHeight() {
        // Before the view exists there is nothing to size; loadView reapplies.
        guard isViewLoaded else { return }
        browser.rowHeight = max(18, iconSize + 2)
    }

    // MARK: - FileViewing

    func reloadData() {
        guard isViewLoaded else { return }        // loadView loads column zero itself
        // Read the selection against the snapshot the browser was built from,
        // BEFORE anything is re-listed; that is the only moment the index paths
        // still mean what NSBrowser thinks they mean.
        // A navigation replaces the root. The old chain is not this folder's
        // chain, so nothing is carried over: no selection to restore and no
        // chain to drill back into.
        let movedRoot = shownRootURL != model.url
        let selected = movedRoot ? [] : selectedItems.map(\.url)
        let openFolders = movedRoot ? [] : displayedDirectoryURLs
        let changed = model.generation != shownGeneration
        refreshedThisPass = []
        // The bookkeeping runs whether or not the model changed: a zoom step
        // reloads without a generation bump, and without this every open
        // column would be listed from disk again on the way back down.
        if !movedRoot {
            shownGeneration = model.generation
            // Parent before child, which is column order, so a deeper node
            // survives its parent's merge and is then refreshed itself. Only
            // folders still in the model's tree: on a navigation the chain of
            // the folder being left is gone and must not be listed again.
            for column in 1..<(browser.lastColumn + 1) {
                if let node = browser.parentForItems(inColumn: column) as? FileNode, model.node(for: node.url) != nil {
                    if changed { model.loadChildren(of: node, refresh: true) }
                    refreshedThisPass.insert(ObjectIdentifier(node))
                }
            }
            // The selected file may have changed on disk; `show` short-circuits
            // on an unchanged URL, so forget it and let the re-drill re-read.
            if changed { preview.show(nil) }
        }
        shownGeneration = model.generation
        shownRootURL = model.url
        shown = [:]
        browser.loadColumnZero()
        rootJustMoved = movedRoot
        if movedRoot { syncPreviewToSelection(); onSelectionChanged?() } else { select(urls: selected) }
        // A deleted selection must not collapse the chain to the root: drill
        // back to the deepest open folder that still exists.
        if browser.selectionIndexPaths.isEmpty {
            for folder in openFolders.reversed() where model.node(for: folder) != nil {
                select(urls: [folder]); break
            }
        }
        // The marker means "listed during this pass"; leaving it set would make
        // a column reopened later serve the listing it had at the last reload.
        refreshedThisPass = []
        if SmokeTest.isRequested {
            print("columns reload diagnosis: movedRoot=\(movedRoot) selected=\(selected.map(\.lastPathComponent)) open=\(openFolders.map(\.lastPathComponent)) "
                  + "changed=\(changed) inTree=\(openFolders.map { model.node(for: $0) != nil }) after=\(browser.selectionIndexPaths) columns=\(browser.lastColumn + 1)")
        }
    }

    var selectedItems: [FileItem] {
        browser.selectionIndexPaths.compactMap { node(at: $0)?.item }
    }

    var clickedItems: [FileItem] {
        guard browser.clickedRow >= 0, browser.clickedColumn >= 0,
              let clicked = browser.item(atRow: browser.clickedRow, inColumn: browser.clickedColumn) as? FileNode
        else { return [] }
        let selected = selectedItems
        return selected.contains { $0.url == clicked.url } ? selected : [clicked.item]
    }

    /// Scroll state is the horizontal column offset; a column view has no
    /// meaningful single vertical offset.
    var scrollOffset: CGFloat {
        get { CGFloat(browser.firstVisibleColumn) }
        set { browser.scrollColumnToVisible(max(0, Int(newValue))) }
    }

    func select(name: String?) {
        guard let name else { select(urls: []); return }
        if let node = model.nodes.first(where: { $0.item.name == name }) { select(urls: [node.url]) }
    }

    func select(names: [String]) {
        let wanted = Set(names)
        select(urls: model.nodes.filter { wanted.contains($0.item.name) }.map(\.url))
    }

    func select(urls: [URL]) {
        if rootJustMoved {
            rootJustMoved = false
            guard urls.contains(where: { $0.deletingLastPathComponent().standardizedFileURL == model.url?.standardizedFileURL })
            else { return }
        }
        var paths = urls.compactMap { indexPath(for: $0) }
        // NSBrowser selects within one column. A list selection spanning an
        // expanded folder arrives at mixed depths; keep the first item's column.
        if let parent = paths.first?.dropLast() { paths = paths.filter { $0.dropLast() == parent } }
        guard let first = paths.first else {
            // "Deselect" keeps the structure, as deselectAll keeps the list's
            // expanded folders. An open column IS a selected folder row in the
            // column before it, so only a selected FILE is cleared; folder rows
            // stay, which also makes a repeated deselect a no-op rather than a
            // climb up the chain one column per call (D84).
            let column = browser.selectedColumn
            if column >= 0, selectedItems.contains(where: { !$0.isNavigable }) {
                browser.selectRowIndexes(IndexSet(), inColumn: column)
            }
            syncPreviewToSelection()
            onSelectionChanged?()
            return
        }
        // NSBrowser validates a path against the columns it has LOADED and
        // throws for a deeper one — "expecting a maximum 0 rows" — and each
        // assignment opens at most one further column. So drill down the way a
        // user does: select a row, which loads the next column, and repeat.
        // Every step is checked against the column's real row count first, so
        // an invalid path is dropped rather than handed to AppKit to throw on.
        let last = first.count - 1
        for depth in 0..<last {
            let row = first[depth]
            guard row < rowCount(inColumn: depth) else { return }
            browser.selectRow(row, inColumn: depth)
        }
        let rows = IndexSet(paths.map { $0[last] }.filter { $0 < rowCount(inColumn: last) })
        guard !rows.isEmpty else { return }
        browser.selectRowIndexes(rows, inColumn: last)
        browser.scrollColumnToVisible(last)
        syncPreviewToSelection()
        // Setting the paths programmatically fires no action; the pane still
        // needs to know, as it does when a table changes its selection.
        onSelectionChanged?()
    }

    /// NSBrowser removes the preview column when the leaf is deselected, but
    /// the controller behind it keeps its Quick Look item — and a video keeps
    /// playing — until told otherwise.
    private func syncPreviewToSelection() {
        // NSBrowser shows a preview column for exactly one selected leaf; the
        // controller behind it must let go in every other case.
        let items = selectedItems
        if !(items.count == 1 && !items[0].isNavigable) { preview.show(nil) }
    }

    func openSelection() {
        for item in selectedItems { onOpen?(item) }
    }

    func beginRename(item: FileItem) {
        guard allowsRenaming, let path = indexPath(for: item.url), let last = path.last else { return }
        // The drawn title may hide the extension, and it carries the icon as a
        // leading attachment; the editor must show neither. Seeding the cell
        // first is not enough on its own — `editItem` redraws the row, and
        // `willDisplayCell` puts the drawn title straight back — so the field
        // editor is seeded again afterwards, which is the text the user edits.
        if let cell = browser.loadedCell(atRow: last, column: path.count - 1) as? NSCell {
            cell.stringValue = item.name
        }
        browser.editItem(at: path, with: nil, select: true)
        if let editor = view.window?.firstResponder as? NSTextView, editor.string != item.name {
            editor.string = item.name
            editor.setSelectedRange(NSRange(location: 0, length: (item.name as NSString).length))
        }
    }

    func itemAfterSelection() -> FileItem? {
        guard let path = browser.selectionIndexPaths.last, let last = path.last else { return nil }
        let column = path.count - 1
        // `item(atRow:inColumn:)` hands the row straight to the delegate
        // without a bounds check, so the next row must be known to exist.
        guard last + 1 < rowCount(inColumn: column) else { return nil }
        return (browser.item(atRow: last + 1, inColumn: column) as? FileNode)?.item
    }

    func setIconSize(_ size: CGFloat, showPreviews: Bool) {
        iconSize = size
        self.showPreviews = showPreviews
        applyRowHeight()
        if isViewLoaded { reloadData() }
    }

    func frameOnScreen(for url: URL) -> NSRect {
        guard let path = indexPath(for: url), let row = path.last, let window = view.window else { return .zero }
        let column = path.count - 1
        let frame = browser.frame(ofRow: row, inColumn: column)
        return window.convertToScreen(browser.convert(frame, to: nil))
    }

    func forwardKey(_ event: NSEvent) { browser.keyDown(with: event) }

    /// Every open column's folder, so directory-change broadcasts for deeper
    /// columns are not filtered out by the pane.
    var displayedDirectoryURLs: [URL] {
        (0..<browser.lastColumn + 1).compactMap { column -> URL? in
            guard column > 0, let node = browser.parentForItems(inColumn: column) as? FileNode,
                  node.item.isNavigable else { return nil }   // the preview column's parent is a file
            return node.url
        }
    }

    /// An item-based browser has no row-count API; a column's rows are its
    /// parent item's children, which is what the delegate reported.
    private func rowCount(inColumn column: Int) -> Int {
        children(of: browser.parentForItems(inColumn: column) ?? root).count
    }

    // MARK: - Node lookup

    private func node(at path: IndexPath) -> FileNode? {
        var parent: Any = root
        var current: FileNode?
        for index in path {
            let children = self.children(of: parent)
            guard index < children.count else { return nil }
            current = children[index]
            parent = children[index]
        }
        return current
    }

    private func children(of item: Any) -> [FileNode] {
        let key = ObjectIdentifier(item as AnyObject)
        // A snapshot is only good for a column that is open right now: it is
        // what that column's rows are. A closed column's entry is stale by
        // definition — the folder may have changed since — so reopening it,
        // or walking into it to select, lists the folder afresh.
        let isRoot = item as AnyObject === root
        let isOpen = isRoot || (0...max(0, browser.lastColumn)).contains {
            (browser.parentForItems(inColumn: $0) as AnyObject?) === (item as AnyObject)
        }
        if isOpen, let list = shown[key] { return list }
        let list: [FileNode]
        if isRoot { list = model.nodes }
        else if let node = item as? FileNode {
            // `reloadData` already listed the open columns this pass; asking
            // again would hit the disk two more times per column, once for
            // the row count and once while the rows are built.
            list = model.loadChildren(of: node, refresh: !refreshedThisPass.contains(key))
        }
        else { list = [] }
        shown[key] = list
        return list
    }

    /// The path to `url` through the loaded tree, or nil when it is not
    /// under the column root.
    private func indexPath(for url: URL) -> IndexPath? {
        let target = url.standardizedFileURL
        var path = IndexPath()
        // Walk what the browser shows, not the live model: an open column's
        // rows are its snapshot, and an index must match those rows. A folder
        // that is not open has no snapshot and is listed afresh on the way
        // down, so a file created in it since is found.
        var level = children(of: root)
        while true {
            if let index = level.firstIndex(where: { $0.url.standardizedFileURL == target }) {
                path.append(index)
                return path
            }
            guard let ancestor = level.enumerated().first(where: {
                target.path.hasPrefix($0.element.url.standardizedFileURL.path + "/") && $0.element.item.isNavigable
            }) else { return nil }
            path.append(ancestor.offset)
            level = children(of: ancestor.element)
            if level.isEmpty { return nil }
        }
    }

    // MARK: - NSBrowserDelegate (item based)

    func rootItem(for browser: NSBrowser) -> Any? { root }

    func browser(_ browser: NSBrowser, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: item ?? root).count
    }

    func browser(_ browser: NSBrowser, child index: Int, ofItem item: Any?) -> Any {
        let list = children(of: item ?? root)
        // AppKit can probe a row past the end (a lookup at `row + 1`, a column
        // mid-collapse). A file manager must not trap for that; the root
        // sentinel is never a FileNode, so every consumer reads it as nothing.
        guard index >= 0, index < list.count else { return root }
        return list[index]
    }

    func browser(_ browser: NSBrowser, isLeafItem item: Any?) -> Bool {
        guard let node = item as? FileNode else { return false }
        return !node.item.isNavigable
    }

    func browser(_ browser: NSBrowser, objectValueForItem item: Any?) -> Any? {
        (item as? FileNode)?.item.name
    }

    /// An item-based `NSBrowser` draws its rows with `NSTextFieldCell`, not
    /// `NSBrowserCell` — `setCellClass` and `cellPrototype` are both ignored in
    /// this mode, measured. A text cell has no `image`, so the icon is an
    /// attachment at the head of the title, which is also how the row picks up
    /// `displayName` (the show-extensions preference) and the dimming a cut
    /// item needs. Casting to `NSBrowserCell` here silently disabled all three.
    func browser(_ sender: NSBrowser, willDisplayCell cell: Any, atRow row: Int, column: Int) {
        guard let cell = cell as? NSCell,
              let node = sender.item(atRow: row, inColumn: column) as? FileNode else { return }
        let cut = cutURLs.contains(node.url.standardizedFileURL)
        let title = NSMutableAttributedString(attachment: iconAttachment(for: node.item))
        title.append(NSAttributedString(string: "  " + node.item.displayName, attributes: [
            .font: NSFont.systemFont(ofSize: max(11, min(13, iconSize * 0.55))),
            .foregroundColor: cut ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]))
        cell.attributedStringValue = title
    }

    /// The row's icon, drawn as the first character of the title.
    private func iconAttachment(for item: FileItem) -> NSTextAttachment {
        let attachment = NSTextAttachment()
        // An archive entry's URL is logical: nothing exists at that path, so
        // its icon comes from its type rather than from the filesystem.
        attachment.image = item.isArchiveEntry
            ? NSWorkspace.shared.icon(for: item.contentType ?? (item.isDirectory ? .folder : .data))
            : NSWorkspace.shared.icon(forFile: item.contentURL.path)
        // An attachment sits on the text baseline, so a square the height of a
        // row would hang below it; the negative y drops it back to the row's
        // vertical centre. Sizing is done here and never on the image itself,
        // which NSWorkspace shares and caches.
        let side = max(12, iconSize - 4)
        attachment.bounds = NSRect(x: 0, y: (side - iconSize) / 2 - 3, width: side, height: side)
        return attachment
    }

    /// The last column previews a selected file, reusing the docked pane's
    /// Markdown renderer and Quick Look fallback.
    func browser(_ browser: NSBrowser, previewViewControllerForLeafItem item: Any) -> NSViewController? {
        guard let node = item as? FileNode else { return nil }
        _ = preview.view
        // An archive entry previews through its path-validated temporary copy.
        preview.show(node.item.isArchiveEntry ? node.item.readableContentURL : node.url)
        return preview
    }

    func browser(_ browser: NSBrowser, shouldEditItem item: Any?) -> Bool {
        allowsRenaming && !isReadOnly && (item as? FileNode) != nil
    }

    func browser(_ browser: NSBrowser, setObjectValue object: Any?, forItem item: Any?) {
        guard let node = item as? FileNode, let name = object as? String,
              !name.isEmpty, name != node.item.name else { return }
        onRenameCommitted?(node.item, name)
    }

    // Drag out
    func browser(_ browser: NSBrowser, writeRowsWith rowIndexes: IndexSet, inColumn column: Int,
                 to pasteboard: NSPasteboard) -> Bool {
        let items = rowIndexes.compactMap { (browser.item(atRow: $0, inColumn: column) as? FileNode)?.item }
        // Other apps get real paths: an archive entry's logical URL exists
        // nowhere on disk, so it is written as its readable copy, and such a
        // drag can only ever copy.
        let urls = items.compactMap { $0.isArchiveEntry ? $0.readableContentURL : $0.url }
        guard !urls.isEmpty else { return false }
        draggingReadOnlyItems = items.contains(where: \.isArchiveEntry)
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        return true
    }

    // Drop onto a folder row, or onto a column's background (its folder)
    func browser(_ browser: NSBrowser, validateDrop info: NSDraggingInfo, proposedRow row: UnsafeMutablePointer<Int>,
                 column: UnsafeMutablePointer<Int>, dropOperation: UnsafeMutablePointer<NSBrowser.DropOperation>)
        -> NSDragOperation {
        guard !isReadOnly,
              let destination = dropTarget(row: row.pointee, column: column.pointee, operation: dropOperation.pointee),
              let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
        else { return [] }
        // A ⌘ drag reaches a destination with its mask narrowed to .generic, so
        // the answer must be given within that mask or AppKit refuses the drop
        // (D70). This layer is what every other destination answers through;
        // acceptDrop below recomputes with the raw rule and hands .move on.
        // The highlight must also point where the drop will actually land:
        // anywhere but a folder row means the column's own folder.
        if !(dropOperation.pointee == .on && row.pointee >= 0
             && (browser.item(atRow: row.pointee, inColumn: column.pointee) as? FileNode)?.item.isNavigable == true) {
            row.pointee = -1
            dropOperation.pointee = .on
        }
        return DragAndDrop.validationOperation(for: urls, into: destination, sourceMask: info.draggingSourceOperationMask)
    }

    func browser(_ browser: NSBrowser, acceptDrop info: NSDraggingInfo, atRow row: Int, column: Int,
                 dropOperation: NSBrowser.DropOperation) -> Bool {
        guard let destination = dropTarget(row: row, column: column, operation: dropOperation),
              let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty
        else { return false }
        let operation = FileOperations.dropOperation(for: urls, into: destination, sourceMask: info.draggingSourceOperationMask)
        guard !operation.isEmpty else { return false }
        onDropFiles?(urls, destination, operation)
        return true
    }

    private func dropTarget(row: Int, column: Int, operation: NSBrowser.DropOperation) -> URL? {
        if operation == .on, row >= 0, let node = browser.item(atRow: row, inColumn: column) as? FileNode,
           node.item.isNavigable { return node.url }
        if column == 0 { return model.url }
        // The preview column's parent is a leaf. A package is a directory on
        // disk, so without this guard a drop over the preview of a selected
        // .app would move files inside the bundle and break its signature;
        // over a plain file it would be accepted and then fail. The sibling
        // views and `displayedDirectoryURLs` already apply the same guard.
        guard let parent = browser.parentForItems(inColumn: column) as? FileNode,
              parent.item.isNavigable else { return nil }
        return parent.url
    }

    // MARK: - Actions

    @objc private func browserClicked(_ sender: Any?) {
        onFocus?()
        syncPreviewToSelection()
        onSelectionChanged?()
    }

    @objc private func browserDoubleClicked(_ sender: Any?) {
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            // ⌘ toggles the row's selection on the first click; the target is
            // the row under the cursor, as in the list view.
            guard browser.clickedRow >= 0, browser.clickedColumn >= 0,
                  let node = browser.item(atRow: browser.clickedRow, inColumn: browser.clickedColumn) as? FileNode
            else { return }
            if node.item.isNavigable { onOpenInNewTab?(node.item) } else { onOpen?(node.item) }
            return
        }
        for item in selectedItems { onOpen?(item) }
    }

    // Testing hooks
    var openColumnCountForTesting: Int { browser.lastColumn + 1 }
    func selectedIndexPathsForTesting() -> [IndexPath] { browser.selectionIndexPaths }
    var isPreviewColumnShowingMarkdownForTesting: Bool { preview.isShowingMarkdown }
    var isPreviewColumnEmptyForTesting: Bool { preview.shownURL == nil }
    var previewedURLForTesting: URL? { preview.shownURL }
    var previewAutoresizesForTesting: Bool { _ = preview.view; return preview.autoresizesForTesting }
    func simulateClickForTesting() { browserClicked(nil) }
    var isPreviewCloseButtonHiddenForTesting: Bool { _ = preview.view; return preview.isCloseButtonHiddenForTesting }
}
