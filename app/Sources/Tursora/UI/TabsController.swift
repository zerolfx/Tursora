import AppKit

/// Owns the tabs of one window: a strip and one
/// TabPage per tab (each with one or two panes). Closed tabs are kept whole
/// so ⌘⇧T brings them back with their history and split intact.
final class TabsController: NSViewController {

    let viewPropertiesStore: DirectoryViewPropertiesStore
    let provider: FileProvider
    weak var host: BrowserHost? { didSet { pages.forEach { $0.host = host } } }

    let tabBar = TabBarView()
    /// Window shortcuts address the active pane's own navigator.
    var addressBar: BreadcrumbBar { current.addressBar }
    private let container = NSView()
    private let splitDropOverlay = SplitDropOverlay()

    private(set) var pages: [TabPage] = []
    private(set) var currentIndex = 0
    private var closedTabs: [TabPage] = []
    private let maxClosedTabs = 10

    /// Fires for the current tab's *active pane* — drives window title and sidebar.
    var onCurrentLocationChanged: ((URL) -> Void)?
    /// Fires when tabs/panes are added, removed, switched or activated — drives validation.
    var onTabsChanged: (() -> Void)?
    var onWorkspaceSessionChanged: (() -> Void)?

    var count: Int { pages.count }
    var currentPage: TabPage { pages[currentIndex] }
    var current: BrowserViewController { currentPage.active }
    var canReopenClosedTab: Bool { !closedTabs.isEmpty }
    var onCloseLastTab: (() -> Void)?
    var onDetachTab: ((TabSnapshot) -> Bool)?
    /// Tests can supply the sheet result without opening a modal UI headlessly.
    var renameTabTitleProvider: ((String, @escaping (String?) -> Void) -> Void)?

    init(provider: FileProvider, initialURL: URL, host: BrowserHost?,
         viewPropertiesStore: DirectoryViewPropertiesStore = .shared) {
        self.viewPropertiesStore = viewPropertiesStore
        self.provider = provider
        self.host = host
        super.init(nibName: nil, bundle: nil)
        tabBar.onSelect = { [weak self] i in self?.selectTab(at: i) }
        tabBar.onClose = { [weak self] i in
            guard let self, self.pages.indices.contains(i) else { return }
            self.performTabAction(.close, on: self.pages[i])
        }
        tabBar.menuForTab = { [weak self] i in self?.tabContextMenu(at: i) }
        tabBar.onAdd = { [weak self] in
            guard let self else { return }
            self.performTabAction(.newTab, on: self.currentPage)
        }
        tabBar.onMove = { [weak self] from, to in self?.moveTab(from: from, to: to) }
        tabBar.onDragOutside = { [weak self] index, windowPoint in self?.updateSplitOverlay(for: index, at: windowPoint) }
        tabBar.dropOperationForTab = { [weak self] index, urls, mask in
            guard let self else { return [] }
            if let index, self.pages.indices.contains(index), let dest = self.pages[index].active.currentURL {
                guard self.pages[index].active.canModifyCurrentLocation else { return [] }
                return FileOperations.dropOperation(for: urls, into: dest, sourceMask: mask)
            }
            // Empty strip space: folders open as new tabs.
            return urls.allSatisfy { self.directoryForTabDrop($0) != nil } ? .generic : []
        }
        tabBar.onFilesDroppedOnTab = { [weak self] index, urls, op in self?.filesDropped(urls, onTabAt: index, op: op) }
        tabBar.onAutoActivateTab = { [weak self] index in self?.selectTab(at: index) }
        tabBar.onDropOutside = { [weak self] index, windowPoint in
            guard let self else { return }
            let side = self.canSplit(withTab: index) ? self.splitSide(at: windowPoint) : nil
            self.splitDropOverlay.show(nil)
            if let side { self.splitCurrentPage(withTab: index, side: side) } else { self.refreshChrome() }
        }
        newTab(at: initialURL)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView()
        let stack = NSStackView(views: [tabBar, container])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.distribution = .fill
        view.pinToEdges(stack)
        NSLayoutConstraint.activate([
            tabBar.heightAnchor.constraint(equalToConstant: TabBarView.height),
        ])
        for row in [tabBar, container] {
            row.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }
        container.setContentHuggingPriority(.defaultLow, for: .vertical)
        for p in pages { attach(p) }
        container.pinToEdges(splitDropOverlay)
        splitDropOverlay.isHidden = true
        applyVisibility()
        refreshChrome()
    }

    // MARK: - Tab operations

    /// Restore fresh navigation contexts, never the closed-tab undo/history pool.
    func restoreWorkspaceTabs(_ states: [WorkspaceTabState], selectedIndex: Int) {
        let restorable = states.filter { !$0.panes.isEmpty }
        guard !restorable.isEmpty else { return }
        for page in pages + closedTabs {
            page.panes.forEach {
                $0.addressBar.endEditing(returnFocus: false)
                $0.suspendPendingNavigation()
                $0.searchPanel.cancelPendingSearch()
                $0.searchSession.cancel()
            }
        }
        if isViewLoaded { pages.forEach(detach) }
        closedTabs = []
        pages = restorable.map { makePage(at: $0.panes[0].workspaceRestorationURL) }
        currentIndex = max(0, min(selectedIndex, pages.count - 1))
        for (page, state) in zip(pages, restorable) {
            page.restoreWorkspaceTab(state)
            if isViewLoaded { attach(page) }
        }
        applyVisibility()
        refreshChrome()
        onCurrentLocationChanged?(current.chromeLocationURL)
        view.window?.makeFirstResponder(current.focusView)
    }

    @discardableResult
    func newTab(at url: URL, activate: Bool = true) -> BrowserViewController {
        let page = makePage(at: url)
        pages.append(page)
        if isViewLoaded { attach(page) }
        if activate { selectTab(at: pages.count - 1) } else { refreshChrome() }
        return page.active
    }

    /// Returns false when this was the last tab (caller decides what to do).
    @discardableResult
    func closeTab(at index: Int) -> Bool {
        guard pages.count > 1, pages.indices.contains(index) else { return false }
        let previous = currentPage
        let page = pages.remove(at: index)
        page.panes.forEach { $0.addressBar.endEditing(returnFocus: false) }
        detach(page)
        closedTabs.append(page)
        page.panes.forEach {
            $0.suspendPendingNavigation()
            $0.searchPanel.cancelPendingSearch()
        }
        if closedTabs.count > maxClosedTabs { closedTabs.removeFirst() }
        // Closing a background page must not change the current page. When
        // closing the current one, prefer its right neighbour, then its left.
        if let surviving = pages.firstIndex(where: { $0 === previous }) {
            currentIndex = surviving
            applyVisibility()
            refreshChrome()
        } else {
            currentIndex = -1   // force selectTab to apply
            selectTab(at: min(index, pages.count - 1))
        }
        return true
    }

    @discardableResult
    func closeCurrentTab() -> Bool { closeTab(at: currentIndex) }

    @discardableResult
    func reopenClosedTab() -> Bool {
        guard let page = closedTabs.popLast() else { return false }
        pages.append(page)
        if isViewLoaded { attach(page) }
        selectTab(at: pages.count - 1)
        page.panes.forEach { $0.resumePendingNavigation() }
        for pane in page.panes where pane.searchPanel.isShowingOptions {
            if pane.searchPanel.currentRequest != pane.searchSession.request {
                pane.searchPanel.scheduleSearch()
            }
        }
        return true
    }

    func selectTab(at index: Int) {
        guard pages.indices.contains(index) else { return }
        let changed = index != currentIndex
        if changed, pages.indices.contains(currentIndex) {
            currentPage.panes.forEach { $0.addressBar.endEditing(returnFocus: false) }
        }
        currentIndex = index
        applyVisibility()
        refreshChrome()
        guard changed else { return }
        onCurrentLocationChanged?(current.chromeLocationURL)
        view.window?.makeFirstResponder(current.focusView)
    }

    func setTitle(_ title: String?, for page: TabPage) {
        guard pages.contains(where: { $0 === page }) else { return }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        page.customTitle = trimmed.isEmpty ? nil : trimmed
        refreshChrome()
    }

    func selectNext() { selectTab(at: (currentIndex + 1) % pages.count) }
    func selectPrevious() { selectTab(at: (currentIndex - 1 + pages.count) % pages.count) }

    func moveTab(from: Int, to: Int) {
        guard pages.indices.contains(from), pages.indices.contains(to), from != to else { return }
        let wasCurrent = currentPage                 // `currentPage` is index-based; read it before mutating
        let p = pages.remove(at: from)
        pages.insert(p, at: to)
        currentIndex = pages.firstIndex { $0 === wasCurrent } ?? to
        refreshChrome()
    }

    /// Files dropped on a tab go into that tab's active pane; on empty strip
    /// space each folder becomes a new (background) tab, as in Dolphin.
    func filesDropped(_ urls: [URL], onTabAt index: Int?, op: NSDragOperation) {
        if let index, pages.indices.contains(index) {
            let pane = pages[index].active
            guard pane.canModifyCurrentLocation, let dest = pane.currentURL else { return }
            pane.dropFiles(urls, to: dest, op: op)
        } else {
            for url in urls {
                guard let directory = directoryForTabDrop(url) else { continue }
                newTab(at: directory, activate: false)
            }
        }
    }

    private func directoryForTabDrop(_ url: URL) -> URL? {
        let logical = ArchiveWorkspace.shared.logicalURL(for: url)
        return PathCompleter.resolveDirectory(logical.path, cwd: provider.homeURL, home: provider.homeURL)
    }

    // MARK: - Split view

    var isSplit: Bool { currentPage.isSplit }

    /// Dolphin's toggle: open a second pane, or close the *active* one.
    func toggleSplit() {
        if currentPage.isSplit { currentPage.closeActivePane() } else { currentPage.split() }
        afterPaneChange()
    }

    /// "Open in new pane": split with the folder, or point the other pane at it.
    func openInOtherPane(_ url: URL) {
        if let other = currentPage.inactive {
            other.navigate(to: url)
            currentPage.activate(other)
            view.window?.makeFirstResponder(other.focusView)
        } else {
            currentPage.split(with: url)
        }
        afterPaneChange()
    }

    func focusOtherPane() {
        currentPage.activateOther()
        afterPaneChange()
    }

    func canSplit(withTab index: Int) -> Bool {
        pages.indices.contains(index) && index != currentIndex && !currentPage.isSplit && !pages[index].isSplit
    }

    /// A tab dragged onto the content area becomes the other pane of the current tab.
    @discardableResult
    func splitCurrentPage(withTab index: Int, side: PaneSide) -> Bool {
        guard canSplit(withTab: index) else { return false }
        let page = pages.remove(at: index)
        if index < currentIndex { currentIndex -= 1 }
        let pane = page.releaseActivePane()
        detach(page)
        currentPage.adopt(pane, side: side)
        afterPaneChange()
        return true
    }

    /// Which half of the content area a window point falls in (nil = middle band, no split).
    func splitSide(at windowPoint: NSPoint?) -> PaneSide? {
        guard let windowPoint, isViewLoaded else { return nil }
        let p = container.convert(windowPoint, from: nil)
        guard container.bounds.contains(p), container.bounds.width > 0 else { return nil }
        let f = p.x / container.bounds.width
        return f < 0.35 ? .left : (f > 0.65 ? .right : nil)
    }

    private func updateSplitOverlay(for index: Int, at windowPoint: NSPoint?) {
        splitDropOverlay.show(canSplit(withTab: index) ? splitSide(at: windowPoint) : nil)
    }

    private func afterPaneChange() {
        refreshChrome()
        onCurrentLocationChanged?(current.chromeLocationURL)
    }

    // MARK: - Private

    private func makePage(at url: URL) -> TabPage {
        let page = TabPage(provider: provider, initialURL: url, host: host, viewPropertiesStore: viewPropertiesStore)
        page.onWorkspaceSessionChanged = { [weak self, weak page] in
            guard let self, let page, self.pages.contains(where: { $0 === page }) else { return }
            if page.panes.contains(where: { $0.currentURL == nil }) {
                self.refreshChrome()
                if page === self.currentPage {
                    self.onCurrentLocationChanged?(page.active.chromeLocationURL)
                }
            } else { self.onWorkspaceSessionChanged?() }
        }
        page.onPaneLocationChanged = { [weak self, weak page] pane, url in
            guard let self, let page, self.pages.contains(where: { $0 === page }) else { return }
            self.refreshChrome()
            if page === self.currentPage, pane === page.active {
                self.onCurrentLocationChanged?(url)
            }
        }
        page.onActivePaneChanged = { [weak self, weak page] pane in
            guard let self, let page, self.pages.contains(where: { $0 === page }) else { return }
            self.refreshChrome()
            guard page === self.currentPage else { return }
            self.onCurrentLocationChanged?(pane.chromeLocationURL)
        }
        return page
    }

    private func attach(_ page: TabPage) {
        addChild(page)
        container.pinToEdges(page.view)
        page.view.isHidden = page !== pages[max(0, min(currentIndex, pages.count - 1))]
    }

    private func detach(_ page: TabPage) {
        page.view.removeFromSuperview()
        page.removeFromParent()
    }

    /// Only the current tab's view is visible. Safe to call any time.
    private func applyVisibility() {
        guard isViewLoaded else { return }
        for (i, p) in pages.enumerated() { p.view.isHidden = i != currentIndex }
        container.addSubview(splitDropOverlay)     // keep the overlay on top
    }

    private func refreshChrome() {
        let titles = pages.map(\.tabTitle)
        tabBar.reload(titles: titles, selected: currentIndex, toolTips: pages.map(\.tabToolTip))
        onTabsChanged?()
        onWorkspaceSessionChanged?()
    }
}

/// Translucent accent block over the half of the content area a dragged tab
/// would split into.
final class SplitDropOverlay: NSView {
    private(set) var side: PaneSide?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }    // never intercept the mouse

    func show(_ side: PaneSide?) {
        self.side = side
        isHidden = side == nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let side else { return }
        let half = NSRect(x: side == .left ? 0 : bounds.midX, y: 0, width: bounds.width / 2, height: bounds.height)
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: half.insetBy(dx: 6, dy: 6), xRadius: 8, yRadius: 8).fill()
        NSColor.controlAccentColor.withAlphaComponent(0.6).setStroke()
        let p = NSBezierPath(roundedRect: half.insetBy(dx: 6, dy: 6), xRadius: 8, yRadius: 8)
        p.lineWidth = 2; p.stroke()
    }
}
