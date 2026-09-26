import AppKit

extension BrowserViewController {
    /// Parent folders inside the listing, in the order the outline must load
    /// them. Keep the filesystem root's single slash as the boundary prefix.
    static func workspaceSelectionAncestors(of url: URL, under root: URL) -> [URL] {
        let prefix = root.path == "/" ? "/" : root.path + "/"
        guard url.path.hasPrefix(prefix) else { return [] }
        var parent = url.deletingLastPathComponent()
        var ancestors: [URL] = []
        while parent.path != root.path && parent.path.hasPrefix(prefix) {
            ancestors.append(parent)
            parent.deleteLastPathComponent()
        }
        return ancestors.reversed()
    }

    var capturedWorkspaceViewState: WorkspacePaneViewState {
        WorkspacePaneViewState(mode: viewMode,
            selectedURLs: fileView.selectedItems.map { ArchiveWorkspace.shared.logicalURL(for: $0.url) },
            scrollOffset: Double(fileView.scrollOffset),
            columnScrollOffsets: viewMode == .columns ? columnView.workspaceColumnOffsets : [:],
            listHorizontalScrollOffset: viewMode == .details ? Double(fileList.horizontalScrollOffset) : nil).sanitized()
    }

    @objc func workspaceScrollChanged(_ note: Notification) {
        guard !isRestoringWorkspaceView, isViewLoaded,
              let clip = note.object as? NSClipView,
              clip.isDescendant(of: fileView.viewController.view) else { return }
        onWorkspaceSessionChanged?()
    }

    /// Wait for the real listing (or final search results), and abandon the
    /// snapshot if navigation has superseded its location. No file is opened.
    @discardableResult
    func restorePendingWorkspaceView() -> Bool {
        guard let pending = pendingWorkspaceView else { return false }
        guard pending.location.standardizedFileURL == workspacePaneState.url.standardizedFileURL else {
            pendingWorkspaceView = nil
            return false
        }
        guard pending.search == isSearching, !isPreparingArchive, !hasListingError,
              model.generation > 0, !searchSession.status.isSearching else { return false }
        if pending.search {
            // A failed/offline search has no complete result set to restore
            // into. Retain its snapshot for a successful retry.
            guard case .finished = searchSession.status else { return false }
        }
        let state = pending.state
        pendingWorkspaceView = nil
        isRestoringWorkspaceView = true
        defer { isRestoringWorkspaceView = false }
        if viewMode == .details, !isSearching, let root = model.url {
            // Re-open ancestors of selected descendants in an expanded list.
            // Missing ancestors stop this branch without changing location.
            for url in state.selectedURLs {
                for ancestor in Self.workspaceSelectionAncestors(of: url, under: root) {
                    guard let node = model.node(for: ancestor), node.item.isNavigable else { break }
                    fileList.tableView.expandItem(node)
                }
            }
        }
        fileView.select(urls: state.selectedURLs)
        view.window?.contentView?.layoutSubtreeIfNeeded()
        if state.mode == viewMode {
            fileView.scrollOffset = CGFloat(state.scrollOffset)
            if viewMode == .details {
                fileList.horizontalScrollOffset = CGFloat(state.listHorizontalScrollOffset ?? 0)
            }
            if viewMode == .columns { columnView.restoreWorkspaceColumnOffsets(state.columnScrollOffsets) }
        }
        return true
    }
}

extension ColumnViewController {
    /// Match public scroll views to the browser's public column geometry;
    /// this does not depend on AppKit's private view class names.
    private var workspaceColumnScrollViews: [(String, NSScrollView)] {
        guard isViewLoaded, let root = model.url else { return [] }
        func scrollViews(in view: NSView) -> [NSScrollView] {
            view.subviews.flatMap { child -> [NSScrollView] in
                if let scroll = child as? NSScrollView { return [scroll] + scrollViews(in: scroll) }
                return scrollViews(in: child)
            }
        }
        let candidates = scrollViews(in: browser)
        return (0...max(0, browser.lastColumn)).compactMap { column in
            let directory: URL
            if column == 0 { directory = root }
            else if let node = browser.parentForItems(inColumn: column) as? FileNode, node.item.isNavigable {
                directory = node.url
            } else { return nil }
            let frame = browser.frame(ofColumn: column)
            guard let scroll = candidates.first(where: {
                let rect = browser.convert($0.bounds, from: $0)
                return abs(rect.midX - frame.midX) < 4 && abs(rect.width - frame.width) < 8
            }) else { return nil }
            return (ArchiveWorkspace.shared.logicalURL(for: directory).path, scroll)
        }
    }

    var workspaceColumnOffsets: [String: Double] {
        Dictionary(workspaceColumnScrollViews.map { ($0.0, Double(max(0, $0.1.contentView.bounds.minY))) },
                   uniquingKeysWith: { first, _ in first })
    }

    func restoreWorkspaceColumnOffsets(_ offsets: [String: Double]) {
        for (path, scroll) in workspaceColumnScrollViews {
            guard let offset = offsets[path], offset.isFinite else { continue }
            let clip = scroll.contentView
            var bounds = clip.bounds
            bounds.origin.y = CGFloat(max(0, offset))
            clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
            scroll.reflectScrolledClipView(clip)
        }
    }
}
