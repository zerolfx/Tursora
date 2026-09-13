import AppKit

/// Spring-loaded folders. Hovering a drag over a folder row or icon opens it
/// after the system's own spring-loading delay (`com.apple.springing.delay`,
/// which AppKit reads and times for every `NSSpringLoadingDestination`), so
/// the user can drill into a tree without dropping first.
///
/// The views only report: each one resolves what is under the pointer and asks
/// its controller, and the controller performs the navigation. No view touches
/// the filesystem, and spring loading never moves or copies anything — the
/// drop that may follow still goes through `FileOperations.dropOperation` and
/// `BrowserViewController.dropFiles`.
protocol SpringLoadingHost: AnyObject {
    /// Whether the target under `point` may spring open, given the drag.
    func springLoadingOptions(at point: NSPoint, urls: [URL], sourceMask: NSDragOperation) -> NSSpringLoadingOptions
    /// Open the target under `point`: navigate the pane, select the place or
    /// expand the node. Answers false when nothing there may spring open.
    @discardableResult
    func activateSpringLoading(at point: NSPoint, urls: [URL], sourceMask: NSDragOperation) -> Bool
}

/// Shared plumbing: AppKit's spring-loading callbacks in view coordinates,
/// with the drag's own URLs and narrowed mask, plus the guard that nothing
/// fires once the drag has left or ended.
extension NSView {
    fileprivate func springLoadingOptions(_ host: SpringLoadingHost?, _ info: NSDraggingInfo) -> NSSpringLoadingOptions {
        guard let host else { return .disabled }
        let urls = info.fileURLs
        guard !urls.isEmpty else { return .disabled }
        return host.springLoadingOptions(at: convert(info.draggingLocation, from: nil),
                                         urls: urls, sourceMask: info.draggingSourceOperationMask)
    }

    fileprivate func springLoadingActivate(_ host: SpringLoadingHost?, _ activated: Bool, _ info: NSDraggingInfo) {
        // `false` is the de-activation half of a continuous spring load and the
        // end of a drag; neither should navigate.
        guard activated, let host else { return }
        let urls = info.fileURLs
        guard !urls.isEmpty else { return }
        host.activateSpringLoading(at: convert(info.draggingLocation, from: nil),
                                   urls: urls, sourceMask: info.draggingSourceOperationMask)
    }
}

// MARK: - The three view classes

extension FileOutlineView: NSSpringLoadingDestination {
    private var springHost: SpringLoadingHost? { dataSource as? SpringLoadingHost }

    public func springLoadingEntered(_ draggingInfo: any NSDraggingInfo) -> NSSpringLoadingOptions {
        springLoadingOptions(springHost, draggingInfo)
    }
    public func springLoadingUpdated(_ draggingInfo: any NSDraggingInfo) -> NSSpringLoadingOptions {
        springLoadingOptions(springHost, draggingInfo)
    }
    public func springLoadingActivated(_ activated: Bool, draggingInfo: any NSDraggingInfo) {
        springLoadingActivate(springHost, activated, draggingInfo)
    }
    public func springLoadingHighlightChanged(_ draggingInfo: any NSDraggingInfo) {}
}

extension FileCollectionView: NSSpringLoadingDestination {
    private var springHost: SpringLoadingHost? { delegate as? SpringLoadingHost }

    public func springLoadingEntered(_ draggingInfo: any NSDraggingInfo) -> NSSpringLoadingOptions {
        springLoadingOptions(springHost, draggingInfo)
    }
    public func springLoadingUpdated(_ draggingInfo: any NSDraggingInfo) -> NSSpringLoadingOptions {
        springLoadingOptions(springHost, draggingInfo)
    }
    public func springLoadingActivated(_ activated: Bool, draggingInfo: any NSDraggingInfo) {
        springLoadingActivate(springHost, activated, draggingInfo)
    }
    public func springLoadingHighlightChanged(_ draggingInfo: any NSDraggingInfo) {}
}

/// Both the Places sidebar and the folder tree use this outline view; its data
/// source is whichever controller owns it.
extension SidebarOutlineView: NSSpringLoadingDestination {
    private var springHost: SpringLoadingHost? { dataSource as? SpringLoadingHost }

    public func springLoadingEntered(_ draggingInfo: any NSDraggingInfo) -> NSSpringLoadingOptions {
        springLoadingOptions(springHost, draggingInfo)
    }
    public func springLoadingUpdated(_ draggingInfo: any NSDraggingInfo) -> NSSpringLoadingOptions {
        springLoadingOptions(springHost, draggingInfo)
    }
    public func springLoadingActivated(_ activated: Bool, draggingInfo: any NSDraggingInfo) {
        springLoadingActivate(springHost, activated, draggingInfo)
    }
    public func springLoadingHighlightChanged(_ draggingInfo: any NSDraggingInfo) {}
}

// MARK: - The details list

extension FileListViewController: SpringLoadingHost {
    /// The folder under `point`, or nil when nothing there may spring open.
    func springLoadingTarget(atRow row: Int, urls: [URL], sourceMask: NSDragOperation) -> URL? {
        guard let item = item(atRow: row) else { return nil }
        return DragAndDrop.canSpringLoad(into: item.url, isNavigable: item.isNavigable, isReadOnly: isReadOnly,
                                         urls: urls, sourceMask: sourceMask) ? item.url : nil
    }

    func springLoadingOptions(at point: NSPoint, urls: [URL], sourceMask: NSDragOperation) -> NSSpringLoadingOptions {
        springLoadingTarget(atRow: tableView.row(at: point), urls: urls, sourceMask: sourceMask) == nil
            ? .disabled : .enabled
    }

    @discardableResult
    func activateSpringLoading(at point: NSPoint, urls: [URL], sourceMask: NSDragOperation) -> Bool {
        activateSpringLoading(atRow: tableView.row(at: point), urls: urls, sourceMask: sourceMask)
    }

    /// The entry a headless run uses: AppKit owns the hover timer, so the test
    /// asks for the activation the timer would have produced.
    @discardableResult
    func activateSpringLoading(atRow row: Int, urls: [URL],
                               sourceMask: NSDragOperation = [.copy, .move, .generic]) -> Bool {
        guard let url = springLoadingTarget(atRow: row, urls: urls, sourceMask: sourceMask) else { return false }
        onSpringLoad?(url)
        return true
    }
}

// MARK: - The icon grid

extension IconGridViewController: SpringLoadingHost {
    func springLoadingTarget(at indexPath: IndexPath, urls: [URL], sourceMask: NSDragOperation) -> URL? {
        guard let item = item(at: indexPath) else { return nil }
        return DragAndDrop.canSpringLoad(into: item.url, isNavigable: item.isNavigable, isReadOnly: isReadOnly,
                                         urls: urls, sourceMask: sourceMask) ? item.url : nil
    }

    func springLoadingOptions(at point: NSPoint, urls: [URL], sourceMask: NSDragOperation) -> NSSpringLoadingOptions {
        guard let ip = collectionView.indexPathForItem(at: point) else { return .disabled }
        return springLoadingTarget(at: ip, urls: urls, sourceMask: sourceMask) == nil ? .disabled : .enabled
    }

    @discardableResult
    func activateSpringLoading(at point: NSPoint, urls: [URL], sourceMask: NSDragOperation) -> Bool {
        guard let ip = collectionView.indexPathForItem(at: point) else { return false }
        return activateSpringLoading(at: ip, urls: urls, sourceMask: sourceMask)
    }

    /// The entry a headless run uses, addressing the grid by index path.
    @discardableResult
    func activateSpringLoading(at indexPath: IndexPath, urls: [URL],
                               sourceMask: NSDragOperation = [.copy, .move, .generic]) -> Bool {
        guard let url = springLoadingTarget(at: indexPath, urls: urls, sourceMask: sourceMask) else { return false }
        onSpringLoad?(url)
        return true
    }
}

// MARK: - The Places sidebar

extension SidebarViewController: SpringLoadingHost {
    /// A place springs open by becoming the pane's location.
    func springLoadingTarget(atRow row: Int, urls: [URL], sourceMask: NSDragOperation) -> URL? {
        guard let url = placeURL(atRow: row) else { return nil }
        // Volumes and folders are navigable; a place that is a file is not.
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        return DragAndDrop.canSpringLoad(into: url, isNavigable: isFolder, isReadOnly: false,
                                         urls: urls, sourceMask: sourceMask) ? url : nil
    }

    func springLoadingOptions(at point: NSPoint, urls: [URL], sourceMask: NSDragOperation) -> NSSpringLoadingOptions {
        springLoadingTarget(atRow: outlineView.row(at: point), urls: urls, sourceMask: sourceMask) == nil
            ? .disabled : .enabled
    }

    @discardableResult
    func activateSpringLoading(at point: NSPoint, urls: [URL], sourceMask: NSDragOperation) -> Bool {
        activateSpringLoading(atRow: outlineView.row(at: point), urls: urls, sourceMask: sourceMask)
    }

    @discardableResult
    func activateSpringLoading(atRow row: Int, urls: [URL],
                               sourceMask: NSDragOperation = [.copy, .move, .generic]) -> Bool {
        guard let url = springLoadingTarget(atRow: row, urls: urls, sourceMask: sourceMask) else { return false }
        onSpringLoad?(url)
        return true
    }
}

// MARK: - The folder tree

extension FoldersPanelController: SpringLoadingHost {
    /// A folder-tree node springs open by expanding in place, so the drag can
    /// carry on into a child without the pane navigating anywhere.
    func springLoadingTarget(atRow row: Int, urls: [URL], sourceMask: NSDragOperation) -> URL? {
        guard let node = outlineView.item(atRow: row) as? FolderTreeModel.Node else { return nil }
        return DragAndDrop.canSpringLoad(into: node.url, isNavigable: true, isReadOnly: false,
                                         urls: urls, sourceMask: sourceMask) ? node.url : nil
    }

    func springLoadingOptions(at point: NSPoint, urls: [URL], sourceMask: NSDragOperation) -> NSSpringLoadingOptions {
        springLoadingTarget(atRow: outlineView.row(at: point), urls: urls, sourceMask: sourceMask) == nil
            ? .disabled : .enabled
    }

    @discardableResult
    func activateSpringLoading(at point: NSPoint, urls: [URL], sourceMask: NSDragOperation) -> Bool {
        activateSpringLoading(atRow: outlineView.row(at: point), urls: urls, sourceMask: sourceMask)
    }

    /// Expanding is the whole behaviour here: the tree opens the node so the
    /// drag can carry on into a child, and no pane navigates.
    @discardableResult
    func activateSpringLoading(atRow row: Int, urls: [URL],
                               sourceMask: NSDragOperation = [.copy, .move, .generic]) -> Bool {
        guard springLoadingTarget(atRow: row, urls: urls, sourceMask: sourceMask) != nil,
              let node = outlineView.item(atRow: row) as? FolderTreeModel.Node else { return false }
        outlineView.expandItem(node)
        return true
    }
}
