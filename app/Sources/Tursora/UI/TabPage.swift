import AppKit

enum PaneSide { case left, right }

/// One tab: one or two browsing panes side by side — Dolphin's split view.
/// Each pane owns its path bar. Window commands follow the active pane;
/// clicking anywhere in a pane activates it.
final class TabPage: NSViewController, NSSplitViewDelegate {

    let viewPropertiesStore: DirectoryViewPropertiesStore
    let provider: FileProvider
    weak var host: BrowserHost? { didSet { panes.forEach { $0.host = host } } }

    private(set) var panes: [BrowserViewController] = []
    private(set) var activeIndex = 0
    var customTitle: String?
    var active: BrowserViewController { panes[activeIndex] }
    var isSplit: Bool { panes.count == 2 }
    var inactive: BrowserViewController? { isSplit ? panes[1 - activeIndex] : nil }
    var activeSide: PaneSide { activeIndex == 0 ? .left : .right }

    let splitView = NSSplitView()
    var onActivePaneChanged: ((BrowserViewController) -> Void)?
    var onPaneLocationChanged: ((BrowserViewController, URL) -> Void)?
    var onWorkspaceSessionChanged: (() -> Void)?
    private(set) var workspaceSplitFraction: Double = 0.5
    private var isApplyingSplitFraction = false
    private var lastAppliedSplitPosition: CGFloat?
    private var clickMonitor: Any?

    init(provider: FileProvider, initialURL: URL, host: BrowserHost?,
         viewPropertiesStore: DirectoryViewPropertiesStore = .shared) {
        self.viewPropertiesStore = viewPropertiesStore
        self.provider = provider
        self.host = host
        super.init(nibName: nil, bundle: nil)
        panes = [makePane(at: initialURL)]
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { removeMonitor() }

    override func loadView() {
        view = NSView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        view.pinToEdges(splitView)
        for p in panes { attach(p) }
        updateIndicators()
        if isSplit { installMonitor() }
    }

    // MARK: - Split operations

    /// Open a second pane (at `url`, or a copy of the active location) and make it active.
    @discardableResult
    func split(with url: URL? = nil, side: PaneSide = .right) -> BrowserViewController {
        if isSplit { return inactive! }
        let pane = makePane(at: url ?? active.currentURL ?? provider.homeURL)
        insert(pane, side: side)
        return pane
    }

    /// Take over a pane that belonged to another tab (tab dragged into the split).
    func adopt(_ pane: BrowserViewController, side: PaneSide) {
        guard !isSplit else { return }
        pane.host = host
        wire(pane)
        insert(pane, side: side)
    }

    /// Detach the active pane without closing it, so another page can adopt it.
    func releaseActivePane() -> BrowserViewController {
        let pane = active
        pane.addressBar.endEditing(returnFocus: false)
        if isViewLoaded { detach(pane) }
        panes.removeAll { $0 === pane }
        activeIndex = 0
        removeMonitor()
        return pane
    }

    func closePane(_ pane: BrowserViewController) {
        guard isSplit, let i = panes.firstIndex(where: { $0 === pane }) else { return }
        let wasActive = pane === active
        pane.addressBar.endEditing(returnFocus: false)
        pane.searchPanel.cancelPendingSearch()
        panes.remove(at: i)
        if isViewLoaded { detach(pane) }
        removeMonitor()
        activeIndex = 0
        workspaceSplitFraction = 0.5
        updateIndicators()
        onActivePaneChanged?(active)
        onWorkspaceSessionChanged?()
        if wasActive, isViewLoaded, !view.isHidden { view.window?.makeFirstResponder(active.focusView) }
    }

    func closeActivePane() { closePane(active) }

    func activate(_ pane: BrowserViewController) {
        guard let i = panes.firstIndex(where: { $0 === pane }) else { return }
        let changed = i != activeIndex
        if changed { active.addressBar.endEditing(returnFocus: false) }
        activeIndex = i
        updateIndicators()
        if changed { onActivePaneChanged?(pane) }
    }

    func activateOther() {
        guard let other = inactive else { return }
        activate(other)
        view.window?.makeFirstResponder(other.focusView)
    }

    // MARK: - Private

    private func makePane(at url: URL) -> BrowserViewController {
        let pane = BrowserViewController(provider: provider, initialURL: url, viewPropertiesStore: viewPropertiesStore)
        pane.host = host
        wire(pane)
        return pane
    }

    private func wire(_ pane: BrowserViewController) {
        pane.onWorkspaceSessionChanged = { [weak self] in self?.onWorkspaceSessionChanged?() }
        pane.addressBar.onBeginEditing = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.activate(pane)
        }
        pane.addressBar.onEndEditing = { [weak self, weak pane] in
            guard let self, let pane, self.active === pane,
                  self.isViewLoaded, !self.view.isHiddenOrHasHiddenAncestor else { return }
            self.view.window?.makeFirstResponder(pane.focusView)
        }
        pane.onLocationChanged = { [weak self, weak pane] url in
            guard let self, let pane else { return }
            self.onPaneLocationChanged?(pane, url)
        }
        pane.onFocus = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.activate(pane)
        }
    }

    private func insert(_ pane: BrowserViewController, side: PaneSide) {
        let index = side == .left ? 0 : panes.count
        panes.insert(pane, at: index)
        if isViewLoaded {
            attach(pane, at: index)
            equalize()
        }
        installMonitor()
        activate(pane)
        updateIndicators()
        onWorkspaceSessionChanged?()
        if !(activeIndex == index) { onActivePaneChanged?(pane) }
        view.window?.makeFirstResponder(pane.focusView)
    }

    private func attach(_ pane: BrowserViewController, at index: Int? = nil) {
        addChild(pane)
        // NSSplitView treats a zero-sized subview as collapsed and keeps it
        // that way, so give the pane a real frame before it goes in.
        let w = max(splitView.bounds.width, 400)
        pane.view.frame = NSRect(x: 0, y: 0, width: panes.count > 1 ? w / 2 : w, height: max(splitView.bounds.height, 300))
        pane.view.autoresizingMask = [.width, .height]
        if let index, index < splitView.arrangedSubviews.count {
            splitView.insertArrangedSubview(pane.view, at: index)
        } else {
            splitView.addArrangedSubview(pane.view)
        }
    }

    private func detach(_ pane: BrowserViewController) {
        splitView.removeArrangedSubview(pane.view)
        pane.view.removeFromSuperview()
        pane.removeFromParent()
        // Hand the freed space to whatever is left right away, not at the next layout pass.
        splitView.adjustSubviews()
        if let only = splitView.arrangedSubviews.first, splitView.arrangedSubviews.count == 1 {
            only.frame = splitView.bounds
        }
        splitView.layoutSubtreeIfNeeded()
    }

    private func equalize() {
        isApplyingSplitFraction = true
        defer { isApplyingSplitFraction = false }
        splitView.layoutSubtreeIfNeeded()
        splitView.adjustSubviews()
        workspaceSplitFraction = 0.5
        applySplitFraction()
    }

    /// Keep the requested ratio across narrow windows and hidden-tab layouts.
    /// A temporary minimum-width constraint must not replace the saved ratio.
    func setWorkspaceSplitFraction(_ fraction: Double) {
        workspaceSplitFraction = fraction.isFinite ? min(0.99, max(0.01, fraction)) : 0.5
        guard isViewLoaded else { return }
        isApplyingSplitFraction = true
        defer { isApplyingSplitFraction = false }
        applySplitFraction()
    }

    private func applySplitFraction() {
        guard splitView.arrangedSubviews.count == 2, splitView.bounds.width > 0 else { return }
        let width = max(0, splitView.bounds.width - splitView.dividerThickness)
        let minimum = min(CGFloat(160), width / 2)
        let left = min(width - minimum, max(minimum, width * workspaceSplitFraction))
        lastAppliedSplitPosition = left
        splitView.arrangedSubviews[0].frame = NSRect(x: 0, y: 0, width: left, height: splitView.bounds.height)
        splitView.arrangedSubviews[1].frame = NSRect(x: left + splitView.dividerThickness, y: 0,
                                                    width: width - left, height: splitView.bounds.height)
    }

    // MARK: - NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        isApplyingSplitFraction = true
        defer { isApplyingSplitFraction = false }
        if splitView.arrangedSubviews.count == 2 {
            applySplitFraction()
        } else if let only = splitView.arrangedSubviews.first {
            only.frame = splitView.bounds
        }
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !isApplyingSplitFraction, isSplit, splitView.arrangedSubviews.count == 2 else { return }
        let width = splitView.bounds.width - splitView.dividerThickness
        guard width > 0 else { return }
        let left = splitView.arrangedSubviews[0].frame.width
        // AppKit can send its resize notification after the delegate returns.
        // Distinguish that completed layout from the user's divider movement.
        if let applied = lastAppliedSplitPosition, abs(left - applied) < 0.01 { return }
        let fraction = Double(left / width)
        guard fraction.isFinite, abs(fraction - workspaceSplitFraction) > 0.0001 else { return }
        workspaceSplitFraction = min(0.99, max(0.01, fraction))
        lastAppliedSplitPosition = left
        onWorkspaceSessionChanged?()
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, 160)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.width - 160)
    }

    private func updateIndicators() {
        for (i, p) in panes.enumerated() {
            p.setActiveIndicator(isSplit ? (i == activeIndex) : nil)
        }
    }

    /// A click anywhere in a pane — status bar, empty list space — activates
    /// it, not only clicks that give the table keyboard focus.
    private func installMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] e in
            guard let self, self.isSplit, !self.view.isHiddenOrHasHiddenAncestor,
                  e.window === self.view.window else { return e }
            for p in self.panes where p.isViewLoaded {
                if p.view.bounds.contains(p.view.convert(e.locationInWindow, from: nil)) {
                    self.activate(p)
                    break
                }
            }
            return e
        }
    }

    private func removeMonitor() {
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = nil
    }
}
