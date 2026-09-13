import AppKit

/// Folder navigation is independent of Places and of either file view's filter.
final class FoldersPanelController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let model: FolderTreeModel
    let outlineView = SidebarOutlineView()
    let scrollView = NSScrollView()
    let statusLabel = NSTextField(labelWithString: "")
    var onOpen: ((URL) -> Void)?
    var onOpenInNewTab: ((URL) -> Void)?
    var onOpenInOtherPane: ((URL) -> Void)?
    var onDropFiles: (([URL], URL, NSDragOperation) -> Void)?
    var onClose: (() -> Void)?
    var onOptionsChanged: (() -> Void)?
    private var isSynchronizing = false
    private var currentLocation: URL?
    private var expanded: Set<String> = []
    private var revealScheduled = false
    private var explicitRevealPending = false
    private var lastViewportSize = NSSize.zero

    init(provider: FileProvider) {
        model = FolderTreeModel(provider: provider)
        super.init(nibName: nil, bundle: nil)
        model.onChange = { [weak self] in self?.reloadTree() }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        view = background
        let title = NSTextField(labelWithString: "Folders")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        let options = NSButton(image: NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Folder Tree Options")!, target: self, action: #selector(showOptions(_:)))
        options.isBordered = false
        options.toolTip = "Folder Tree Options"
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Hide Folders")!, target: self, action: #selector(closePanel(_:)))
        close.isBordered = false
        close.toolTip = "Hide Folders"
        let column = NSTableColumn(identifier: .init("folder"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .default
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.setAccessibilityLabel("Folders")
        outlineView.contextMenuForRow = { [weak self] row in self?.contextMenu(forRow: row) }
        outlineView.registerForDraggedTypes([.fileURL])
        let scroll = scrollView
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        for child in [title, options, close, scroll, statusLabel] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            title.trailingAnchor.constraint(lessThanOrEqualTo: options.leadingAnchor, constant: -4),
            options.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            options.widthAnchor.constraint(equalToConstant: 20),
            options.heightAnchor.constraint(equalToConstant: 20),
            options.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -4),
            close.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 20),
            close.heightAnchor.constraint(equalToConstant: 20),
            close.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -9),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -4),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            statusLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),
        ])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let size = scrollView.contentView.bounds.size
        if size != lastViewportSize {
            lastViewportSize = size
            scheduleSelectionReveal()
        }
    }

    func setActive(_ active: Bool) {
        _ = view
        model.setActive(active)
        if active { follow(currentLocation) }
    }

    func follow(_ url: URL?) {
        currentLocation = url
        model.follow(url) { [weak self] path in
            guard let self else { return }
            self.isSynchronizing = true
            defer { self.isSynchronizing = false }
            for node in path.dropLast() {
                self.expanded.insert(node.url.path)
                self.outlineView.expandItem(node)
            }
            if let last = path.last {
                let row = self.outlineView.row(forItem: last)
                if row >= 0 {
                    self.outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    self.scheduleSelectionReveal(explicit: true)
                    return
                }
            }
            self.outlineView.deselectAll(nil)
        }
    }

    private func reloadTree() {
        guard isViewLoaded else { return }
        isSynchronizing = true
        defer { isSynchronizing = false }
        let selectedRow = outlineView.selectedRow
        let selectionWasVisible = selectedRow >= 0 && selectedRow < outlineView.numberOfRows
            && scrollView.documentVisibleRect.intersects(outlineView.rect(ofRow: selectedRow))
        let selected = (outlineView.item(atRow: outlineView.selectedRow) as? FolderTreeModel.Node)?.url.path
        outlineView.reloadData()
        outlineView.deselectAll(nil)
        if let root = model.root { expanded.insert(root.url.path) }
        for node in model.loadedNodes where expanded.contains(node.url.path) { outlineView.expandItem(node) }
        if let selected, let node = model.loadedNodes.first(where: { $0.url.path == selected }) {
            let row = outlineView.row(forItem: node)
            if row >= 0 { outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        }
        statusLabel.stringValue = model.lastError ?? (model.loadedNodes.contains(where: \.isLoading) ? "Loading folders…" : (model.root?.url.path ?? ""))
        statusLabel.toolTip = model.lastError ?? model.root?.url.path
        if selectionWasVisible || explicitRevealPending { scheduleSelectionReveal() }
    }

    private func scheduleSelectionReveal(explicit: Bool = false) {
        if explicit { explicitRevealPending = true }
        guard !revealScheduled, model.isActive, outlineView.selectedRow >= 0 else { return }
        revealScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.revealScheduled = false
            defer { self.explicitRevealPending = false }
            guard self.model.isActive, self.isViewLoaded else { return }
            // Sidebar divider placement and outline expansion can both change
            // geometry after the follow callback. Scroll against the final clip
            // viewport; ordinary manual scrolling does not change its size.
            self.view.window?.contentView?.layoutSubtreeIfNeeded()
            self.scrollView.layoutSubtreeIfNeeded()
            let row = self.outlineView.selectedRow
            guard row >= 0, row < self.outlineView.numberOfRows,
                  self.scrollView.contentView.bounds.height > 0 else { return }
            self.outlineView.scrollRowToVisible(row)
            let rowRect = self.outlineView.rect(ofRow: row)
            let visible = self.scrollView.documentVisibleRect
            var origin = self.scrollView.contentView.bounds.origin
            if rowRect.maxY > visible.maxY { origin.y += rowRect.maxY - visible.maxY }
            else if rowRect.minY < visible.minY { origin.y -= visible.minY - rowRect.minY }
            let proposed = NSRect(origin: origin, size: self.scrollView.contentView.bounds.size)
            self.scrollView.contentView.scroll(to: self.scrollView.contentView.constrainBoundsRect(proposed).origin)
            self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let node = item as? FolderTreeModel.Node { return node.children?.count ?? 0 }
        return model.root == nil ? 0 : 1
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? FolderTreeModel.Node { return node.children![index] }
        return model.root!
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? FolderTreeModel.Node else { return false }
        return node.children == nil || !(node.children?.isEmpty ?? true)
    }
    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        // AppKit also consults this permission hook for accessibility queries.
        // Only a completed expansion may change state or start enumeration.
        item is FolderTreeModel.Node
    }
    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isSynchronizing, let node = notification.userInfo?["NSObject"] as? FolderTreeModel.Node else { return }
        expanded.insert(node.url.path)
        // Finish the AppKit expansion before a Loading update reloads rows.
        DispatchQueue.main.async { [weak self, weak node] in
            guard let self, let node else { return }
            self.model.load(node)
        }
    }
    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isSynchronizing, let node = notification.userInfo?["NSObject"] as? FolderTreeModel.Node else { return }
        expanded.remove(node.url.path)
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FolderTreeModel.Node else { return nil }
        let id = NSUserInterfaceItemIdentifier("tree-folder")
        let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView)
            ?? NSTableCellView.make(identifier: id, withIcon: true)
        cell.textField?.stringValue = node.name
        cell.imageView?.image = NSImage(systemSymbolName: node.url.path == "/" ? "internaldrive" : "folder", accessibilityDescription: nil)
        cell.imageView?.contentTintColor = .controlAccentColor
        cell.toolTip = node.error.map { "\(node.url.path)\n\($0)" } ?? node.url.path
        return cell
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSynchronizing, let node = outlineView.item(atRow: outlineView.selectedRow) as? FolderTreeModel.Node else { return }
        onOpen?(node.url)
    }

    func contextMenu(forRow row: Int) -> NSMenu {
        let menu = NSMenu()
        if let node = outlineView.item(atRow: row) as? FolderTreeModel.Node {
            for (title, action) in [("Open", #selector(openFolder(_:))), ("Open in New Tab", #selector(openNewTab(_:))), ("Open in Other Pane", #selector(openOtherPane(_:)))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                item.representedObject = node.url
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        for (title, action, checked) in [("Show Hidden Folders", #selector(toggleHidden(_:)), model.showsHiddenFolders), ("Limit to Home Directory", #selector(toggleHome(_:)), model.limitsToHome)] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.state = checked ? .on : .off
            menu.addItem(item)
        }
        let refresh = NSMenuItem(title: "Refresh Folders", action: #selector(refreshFolders(_:)), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)
        return menu
    }
    @objc private func showOptions(_ sender: NSButton) { contextMenu(forRow: -1).popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender) }
    @objc private func closePanel(_ sender: Any?) { onClose?() }
    @objc private func openFolder(_ sender: NSMenuItem) { if let url = sender.representedObject as? URL { onOpen?(url) } }
    @objc private func openNewTab(_ sender: NSMenuItem) { if let url = sender.representedObject as? URL { onOpenInNewTab?(url) } }
    @objc private func openOtherPane(_ sender: NSMenuItem) { if let url = sender.representedObject as? URL { onOpenInOtherPane?(url) } }
    @objc private func toggleHidden(_ sender: Any?) { model.showsHiddenFolders.toggle(); follow(currentLocation); onOptionsChanged?() }
    @objc private func toggleHome(_ sender: Any?) { model.limitsToHome.toggle(); follow(currentLocation); onOptionsChanged?() }
    @objc private func refreshFolders(_ sender: Any?) { model.refresh() }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let node = item as? FolderTreeModel.Node, index == NSOutlineViewDropOnItemIndex else { return [] }
        return FileOperations.dropOperation(for: info.fileURLs, into: node.url, sourceMask: info.draggingSourceOperationMask)
    }
    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let urls = info.fileURLs
        guard let node = item as? FolderTreeModel.Node, index == NSOutlineViewDropOnItemIndex, !urls.isEmpty else { return false }
        let operation = FileOperations.dropOperation(for: urls, into: node.url, sourceMask: info.draggingSourceOperationMask)
        guard !operation.isEmpty else { return false }
        onDropFiles?(urls, node.url, operation)
        return true
    }
}
