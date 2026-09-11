import AppKit

/// Owns the tabs of one window: a strip, a shared address bar, and one
/// TabPage per tab (each with one or two panes). Closed tabs are kept whole
/// so ⌘⇧T brings them back with their history and split intact.
final class TabsController: NSViewController {

    let provider: FileProvider
    weak var host: BrowserHost? { didSet { pages.forEach { $0.host = host } } }

    let tabBar = TabBarView()
    let scopeBar = SearchScopeBar()
    let addressBar = BreadcrumbBar()
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

    var count: Int { pages.count }
    var currentPage: TabPage { pages[currentIndex] }
    var current: BrowserViewController { currentPage.active }
    var canReopenClosedTab: Bool { !closedTabs.isEmpty }

    init(provider: FileProvider, initialURL: URL, host: BrowserHost?) {
        self.provider = provider
        self.host = host
        super.init(nibName: nil, bundle: nil)
        addressBar.homeURL = provider.homeURL
        addressBar.onNavigate = { [weak self] url in self?.current.navigate(to: url) }
        addressBar.onEndEditing = { [weak self] in
            guard let self else { return }
            self.view.window?.makeFirstResponder(self.current.focusView)
        }
        tabBar.onSelect = { [weak self] i in self?.selectTab(at: i) }
        tabBar.onClose = { [weak self] i in self?.closeTab(at: i) }
        tabBar.onAdd = { [weak self] in
            guard let self else { return }
            self.newTab(at: self.current.currentURL ?? self.provider.homeURL)
        }
        tabBar.onMove = { [weak self] from, to in self?.moveTab(from: from, to: to) }
        tabBar.onDragOutside = { [weak self] index, windowPoint in self?.updateSplitOverlay(for: index, at: windowPoint) }
        tabBar.dropOperationForTab = { [weak self] index, urls, mask in
            guard let self else { return [] }
            if let index, self.pages.indices.contains(index), let dest = self.pages[index].active.currentURL {
                return FileListViewController.dropOperation(for: urls, into: dest, sourceMask: mask)
            }
            // Empty strip space: folders open as new tabs.
            return urls.allSatisfy { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true } ? .generic : []
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
        scopeBar.isHidden = true
        let stack = NSStackView(views: [scopeBar, tabBar, addressBar, container])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .width
        stack.distribution = .fill
        view.pinToEdges(stack)
        NSLayoutConstraint.activate([
            scopeBar.heightAnchor.constraint(equalToConstant: SearchScopeBar.height),
            tabBar.heightAnchor.constraint(equalToConstant: TabBarView.height),
            addressBar.heightAnchor.constraint(equalToConstant: BreadcrumbBar.height),
        ])
        container.setContentHuggingPriority(.defaultLow, for: .vertical)
        for p in pages { attach(p) }
        container.pinToEdges(splitDropOverlay)
        splitDropOverlay.isHidden = true
        applyVisibility()
        refreshChrome()
    }

    // MARK: - Tab operations

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
        let page = pages.remove(at: index)
        detach(page)
        closedTabs.append(page)
        if closedTabs.count > maxClosedTabs { closedTabs.removeFirst() }
        // Prefer the tab to the right, like Safari; fall back to the left.
        let next = index < pages.count ? index : pages.count - 1
        currentIndex = -1   // force selectTab to apply
        selectTab(at: next)
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
        return true
    }

    func selectTab(at index: Int) {
        guard pages.indices.contains(index) else { return }
        let changed = index != currentIndex
        currentIndex = index
        applyVisibility()
        refreshChrome()
        guard changed else { return }
        if addressBar.isEditing { addressBar.endEditing() }
        if let url = current.currentURL { onCurrentLocationChanged?(url) }
        view.window?.makeFirstResponder(current.focusView)
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
            guard let dest = pane.currentURL else { return }
            pane.dropFiles(urls, to: dest, op: op)
        } else {
            for url in urls where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                newTab(at: url, activate: false)
            }
        }
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
        addressBar.url = current.currentURL
        if let url = current.currentURL { onCurrentLocationChanged?(url) }
    }

    // MARK: - Private

    private func makePage(at url: URL) -> TabPage {
        let page = TabPage(provider: provider, initialURL: url, host: host)
        page.onPaneLocationChanged = { [weak self, weak page] pane, url in
            guard let self, let page else { return }
            self.refreshChrome()
            if page === self.currentPage, pane === page.active {
                self.addressBar.url = url
                self.onCurrentLocationChanged?(url)
            }
        }
        page.onActivePaneChanged = { [weak self, weak page] pane in
            guard let self, let page, page === self.currentPage else { return }
            self.addressBar.url = pane.currentURL
            if let url = pane.currentURL { self.onCurrentLocationChanged?(url) }
            self.onTabsChanged?()
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
        let titles = pages.map { page -> String in
            guard let url = page.active.currentURL else { return "…" }
            return provider.displayName(for: url)
        }
        tabBar.reload(titles: titles, selected: currentIndex)
        tabBar.isHidden = pages.count == 1
        if pages.indices.contains(currentIndex) {
            addressBar.url = current.currentURL
        }
        onTabsChanged?()
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
