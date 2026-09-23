import AppKit

/// Quick-navigation sidebar: a source-list NSOutlineView over PlacesModel.
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSSplitViewDelegate {

    let places: PlacesModel
    let outlineView = SidebarOutlineView()
    private let folderProvider: FileProvider
    private let panelsSplit = NSSplitView()
    private(set) var foldersPanel: FoldersPanelController?
    private(set) var foldersVisible = false
    var foldersFraction: Double = 0.45
    var onFoldersChanged: (() -> Void)?
    private var foldersLocation: URL?
    private var isArrangingPanels = false

    var onSelectPlace: ((URL) -> Void)?
    var onOpenInNewTab: ((URL) -> Void)?
    var onOpenInOtherPane: ((URL) -> Void)?
    /// Files dropped onto a place: (urls, destination folder, .move or .copy).
    var onDropFiles: (([URL], URL, NSDragOperation) -> Void)?
    /// A place a drag hovered long enough to spring open (see UI/SpringLoading.swift).
    var onSpringLoad: ((URL) -> Void)?
    private let contextMenu = NSMenu()
    private static let placeType = NSPasteboard.PasteboardType("com.tursora.place")
    private static let dndDebug = ProcessInfo.processInfo.environment["TURSORA_DND_DEBUG"] != nil

    private final class SectionNode {
        let title: String
        let children: [PlaceNode]
        init(_ s: PlacesModel.Section) {
            title = s.title
            children = s.places.map(PlaceNode.init)
        }
    }
    private final class PlaceNode {
        let place: PlacesModel.Place
        init(_ p: PlacesModel.Place) { place = p }
    }

    // Source-list cells stretch their standard imageView to the row height.
    // An independent symbol view keeps every glyph on the same square canvas.
    private final class PlaceCell: NSTableCellView {
        let symbolView = NSImageView()
        init(identifier: NSUserInterfaceItemIdentifier) {
            super.init(frame: .zero)
            self.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            symbolView.translatesAutoresizingMaskIntoConstraints = false
            symbolView.imageScaling = .scaleProportionallyUpOrDown
            addSubview(symbolView)
            addSubview(label)
            textField = label
            NSLayoutConstraint.activate([
                symbolView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
                symbolView.widthAnchor.constraint(equalToConstant: 18),
                symbolView.heightAnchor.constraint(equalToConstant: 18),
                label.leadingAnchor.constraint(equalTo: symbolView.trailingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        required init?(coder: NSCoder) { fatalError() }
    }

    /// The location of the place on `row`, for collaborators outside this file
    /// (spring loading); nil for section headers and empty rows.
    func placeURL(atRow row: Int) -> URL? {
        guard row >= 0, row < outlineView.numberOfRows else { return nil }
        return (outlineView.item(atRow: row) as? PlaceNode)?.place.url
    }

    func symbolView(atRow row: Int) -> NSImageView? {
        (outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? PlaceCell)?.symbolView
    }

    private var nodes: [SectionNode] = []
    private var isSyncingSelection = false
    private static let headerID = NSUserInterfaceItemIdentifier("header")
    private static let placeID = NSUserInterfaceItemIdentifier("place")

    init(places: PlacesModel, provider: FileProvider = LocalFileProvider()) {
        self.places = places
        self.folderProvider = provider
        super.init(nibName: nil, bundle: nil)
        rebuildNodes()
        NotificationCenter.default.addObserver(self, selector: #selector(placesChanged),
                                               name: PlacesModel.didChange, object: places)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func placesChanged() {
        let selected = (outlineView.item(atRow: outlineView.selectedRow) as? PlaceNode)?.place.url
        rebuildNodes()
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        if let selected { syncSelection(to: selected) }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func rebuildNodes() {
        nodes = places.sections.map(SectionNode.init)
    }

    override func loadView() {
        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        view = background
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.floatsGroupRows = false
        outlineView.rowSizeStyle = .default
        outlineView.dataSource = self
        outlineView.delegate = self
        contextMenu.delegate = self
        outlineView.menu = contextMenu
        outlineView.contextMenuForRow = { [weak self] row in self?.contextMenu(forRow: row) }
        outlineView.registerForDraggedTypes([.fileURL, ArchiveEntryPromiseProvider.internalType, Self.placeType])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)

        let scroll = NSScrollView()
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        panelsSplit.isVertical = false
        panelsSplit.dividerStyle = .thin
        panelsSplit.delegate = self
        panelsSplit.addArrangedSubview(scroll)
        view.pinToEdges(panelsSplit)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        outlineView.expandItem(nil, expandChildren: true)
    }

    /// Row of the first visible place with this URL, or -1. Also used by the smoke test.
    func row(for url: URL) -> Int {
        let target = url.standardizedFileURL
        for section in nodes {
            for node in section.children where node.place.url.standardizedFileURL == target {
                let row = outlineView.row(forItem: node)
                if row >= 0 { return row }
            }
        }
        return -1
    }

    /// Highlight the place matching `url`, or clear the highlight if none does.
    func syncSelection(to url: URL) {
        foldersLocation = url
        foldersPanel?.follow(url)
        isSyncingSelection = true
        defer { isSyncingSelection = false }
        let row = row(for: url)
        if row >= 0 { outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        else { outlineView.deselectAll(nil) }
    }

    /// Places remains at the top; the optional folder tree has its own scroll
    /// area and divider, without narrowing either file pane.
    func setFoldersPanelVisible(_ visible: Bool, active: Bool = true) {
        _ = view
        guard foldersVisible != visible else {
            foldersPanel?.setActive(visible && active)
            return
        }
        isArrangingPanels = true
        defer { isArrangingPanels = false }
        foldersVisible = visible
        if visible {
            if foldersPanel == nil {
                let panel = FoldersPanelController(provider: folderProvider)
                panel.onOpen = { [weak self] url in self?.onSelectPlace?(url) }
                panel.onOpenInNewTab = { [weak self] url in self?.onOpenInNewTab?(url) }
                panel.onOpenInOtherPane = { [weak self] url in self?.onOpenInOtherPane?(url) }
                panel.onDropFiles = { [weak self] urls, destination, operation in self?.onDropFiles?(urls, destination, operation) }
                panel.onClose = { [weak self] in self?.setFoldersPanelVisible(false); self?.onFoldersChanged?() }
                panel.onOptionsChanged = { [weak self] in self?.onFoldersChanged?() }
                addChild(panel)
                foldersPanel = panel
            }
            guard let panel = foldersPanel else { return }
            panel.view.frame = NSRect(x: 0, y: 0, width: view.bounds.width, height: max(140, view.bounds.height * foldersFraction))
            panelsSplit.addArrangedSubview(panel.view)
            view.layoutSubtreeIfNeeded()
            panelsSplit.setPosition(panelsSplit.bounds.height * (1 - foldersFraction), ofDividerAt: 0)
            panel.follow(foldersLocation ?? folderProvider.homeURL)
            panel.setActive(active)
        } else if let panel = foldersPanel {
            panel.setActive(false)
            panelsSplit.removeArrangedSubview(panel.view)
            panel.view.removeFromSuperview()
            panelsSplit.adjustSubviews()
            if let responder = view.window?.firstResponder as? NSView, responder.isDescendant(of: panel.view) {
                view.window?.makeFirstResponder(outlineView)
            }
        }
    }

    func setFoldersActive(_ active: Bool) { foldersPanel?.setActive(foldersVisible && active) }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { min(100, splitView.bounds.height * 0.3) }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { max(100, splitView.bounds.height - 140) }
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard foldersVisible, !isArrangingPanels, let panel = foldersPanel, panelsSplit.bounds.height > 0 else { return }
        let fraction = min(0.8, max(0.2, panel.view.frame.height / panelsSplit.bounds.height))
        if abs(foldersFraction - fraction) > 0.005 { foldersFraction = fraction; onFoldersChanged?() }
    }

    // MARK: - Context menu

    private var contextPlace: PlacesModel.Place?

    private func contextMenu(forRow row: Int) -> NSMenu? {
        contextPlace = row >= 0 ? (outlineView.item(atRow: row) as? PlaceNode)?.place : nil
        menuNeedsUpdate(contextMenu)
        return contextMenu.items.isEmpty ? nil : contextMenu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let place = contextPlace else { return }
        func add(_ title: String, _ action: Selector) {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
            mi.target = self
            // clickedRow is transient during menu tracking and model reloads.
            // Every action keeps the place that was actually right-clicked.
            mi.representedObject = place
            menu.addItem(mi)
        }
        add("Open", #selector(ctxOpen(_:)))
        add("Open in New Tab", #selector(ctxOpenInNewTab(_:)))
        add("Open in Other Pane", #selector(ctxOpenInOtherPane(_:)))
        if place.isRemovable {
            menu.addItem(.separator())
            add("Remove from Favourites", #selector(ctxRemove(_:)))
            add("Reset Favourites", #selector(ctxResetFavourites(_:)))
        }
        if places.isEjectable(place.url) {
            menu.addItem(.separator())
            add("Eject “\(place.name)”", #selector(ctxEject(_:)))
        }
    }

    @objc private func ctxOpen(_ sender: NSMenuItem) {
        if let place = sender.representedObject as? PlacesModel.Place { onSelectPlace?(place.url) }
    }
    @objc private func ctxOpenInNewTab(_ sender: NSMenuItem) {
        if let place = sender.representedObject as? PlacesModel.Place { onOpenInNewTab?(place.url) }
    }
    @objc private func ctxOpenInOtherPane(_ sender: NSMenuItem) {
        if let place = sender.representedObject as? PlacesModel.Place { onOpenInOtherPane?(place.url) }
    }
    @objc private func ctxRemove(_ sender: NSMenuItem) {
        guard let place = sender.representedObject as? PlacesModel.Place, place.isRemovable else { return }
        places.removeFavourite(place.url)
    }
    @objc private func ctxResetFavourites(_ sender: NSMenuItem) {
        guard let place = sender.representedObject as? PlacesModel.Place,
              place.isRemovable, places.isFavourite(place.url) else { return }
        places.resetFavourites()
    }
    @objc private func ctxEject(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? PlacesModel.Place, places.isEjectable(p.url) else { return }
        do { try NSWorkspace.shared.unmountAndEjectDevice(at: p.url) }
        catch {
            if SmokeTest.isRequested { print("Eject failed: \(error.localizedDescription)") }
            else if let window = view.window { NSAlert(error: error).beginSheetModal(for: window) }
        }
    }

    // MARK: - Drag & drop: reorder favourites, add folders, drop files onto places

    private var favouritesSection: SectionNode? { nodes.first }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        // Any favourite (built-in or not) can be dragged; volumes cannot.
        guard let node = item as? PlaceNode, favouritesSection?.children.contains(where: { $0 === node }) == true else { return nil }
        let pb = NSPasteboardItem()
        pb.setString(node.place.url.path, forType: Self.placeType)
        return pb
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let pb = info.draggingPasteboard
        guard let fav = favouritesSection else { return [] }

        if pb.types?.contains(Self.placeType) == true {
            // Reordering a user favourite: keep it inside the user part of Favourites.
            let point = outlineView.convert(info.draggingLocation, from: nil)
            let target = reorderTargetIndex(item: item, childIndex: index, pointerY: point.y)
            if Self.dndDebug {
                let desc = (item as? PlaceNode).map { "place(\($0.place.name))" } ?? ((item as? SectionNode).map { "section(\($0.title))" } ?? "nil")
                print("[dnd] validate item=\(desc) childIndex=\(index) y=\(point.y) → target=\(target)")
            }
            outlineView.setDropItem(fav, dropChildIndex: target)
            return .move
        }

        let urls = info.fileURLs
        guard !urls.isEmpty else { return [] }

        if let node = item as? PlaceNode, index == NSOutlineViewDropOnItemIndex {
            // Dropping files onto a place: move on the same volume, copy otherwise; ⌥ forces copy.
            if urls.contains(where: { $0.standardizedFileURL == node.place.url.standardizedFileURL }) { return [] }
            let wantsCopy = info.draggingSourceOperationMask == .copy
                || !FileOperations.sameVolume(urls[0], node.place.url)
            return wantsCopy ? .copy : .move
        }
        // Dropping folders between favourites adds them at that position.
        let allFolders = urls.allSatisfy { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        if allFolders, item as? SectionNode === fav || item is PlaceNode {
            let target = reorderTargetIndex(item: item, childIndex: index, pointerY: outlineView.convert(info.draggingLocation, from: nil).y)
            outlineView.setDropItem(fav, dropChildIndex: target)
            return .link
        }
        return []
    }

    /// Where a dragged favourite would be inserted, as a child index of the
    /// Favourites section. Hovering *on* a row means "before it" in the row's
    /// upper half and "after it" in the lower half — otherwise only the thin
    /// gaps between rows would count and everything else would land at the end.
    func reorderTargetIndex(item: Any?, childIndex: Int, pointerY: CGFloat) -> Int {
        guard let fav = favouritesSection else { return 0 }
        var target: Int
        if let node = item as? PlaceNode, let pos = fav.children.firstIndex(where: { $0 === node }) {
            let row = outlineView.row(forItem: node)
            let mid = row >= 0 ? outlineView.rect(ofRow: row).midY : pointerY
            target = pointerY < mid ? pos : pos + 1          // flipped view: y grows downward
        } else if item as? SectionNode === fav, childIndex >= 0 {
            target = childIndex
        } else {
            target = fav.children.count
        }
        return min(max(target, 0), fav.children.count)
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        let pb = info.draggingPasteboard
        if let path = pb.string(forType: Self.placeType) {
            let url = URL(fileURLWithPath: path)
            guard let from = places.favouriteIndex(of: url) else {
                if Self.dndDebug { print("[dnd] accept: \(path) is not a favourite") }
                return false
            }
            var to = max(index, 0)
            if from < to { to -= 1 }
            if Self.dndDebug {
                print("[dnd] accept childIndex=\(index) from=\(from) to=\(to) order=\(places.sections[0].places.map(\.name))")
            }
            places.moveFavourite(from: from, to: to)
            return true
        }
        let urls = info.fileURLs
        guard !urls.isEmpty else { return false }
        if let node = item as? PlaceNode, index == NSOutlineViewDropOnItemIndex {
            let op: NSDragOperation = (info.draggingSourceOperationMask == .copy
                || !FileOperations.sameVolume(urls[0], node.place.url)) ? .copy : .move
            onDropFiles?(urls, node.place.url, op)
            return true
        }
        var at = index == NSOutlineViewDropOnItemIndex ? nil : Optional(index)
        for url in urls {
            places.addFavourite(url, at: at)
            if at != nil { at! += 1 }
        }
        return true
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return nodes.count }
        if let section = item as? SectionNode { return section.children.count }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let section = item as? SectionNode { return section.children[index] }
        return nodes[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is SectionNode
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is SectionNode
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is PlaceNode
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let section = item as? SectionNode {
            let cell = (outlineView.makeView(withIdentifier: Self.headerID, owner: self) as? NSTableCellView)
                ?? NSTableCellView.make(identifier: Self.headerID, withIcon: false)
            cell.textField?.stringValue = section.title
            return cell
        }
        guard let node = item as? PlaceNode else { return nil }
        let cell = (outlineView.makeView(withIdentifier: Self.placeID, owner: self) as? PlaceCell)
            ?? PlaceCell(identifier: Self.placeID)
        cell.textField?.stringValue = node.place.name
        cell.symbolView.image = NSImage(systemSymbolName: node.place.symbolName,
                                        accessibilityDescription: node.place.name)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
        cell.symbolView.contentTintColor = .controlAccentColor
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection,
              let node = outlineView.item(atRow: outlineView.selectedRow) as? PlaceNode else { return }
        onSelectPlace?(node.place.url)
    }
}

/// A context click identifies its row without navigating there first. AppKit's
/// clickedRow is not a persistent menu target, so capture the hit before tracking.
final class SidebarOutlineView: NSOutlineView {
    var contextMenuForRow: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuForRow?(row(at: convert(event.locationInWindow, from: nil)))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menu(for: event) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event) }
        else { super.mouseDown(with: event) }
    }
}
