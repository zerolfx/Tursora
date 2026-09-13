import AppKit
import Quartz

/// What a browsing pane needs from the window that hosts it.
protocol BrowserHost: AnyObject {
    var places: PlacesModel { get }
    var isSplit: Bool { get }
    func openInNewTab(_ url: URL, activate: Bool)
    func openInNewWindow(_ url: URL)
    func openInOtherPane(_ url: URL)
    func transferToOtherPane(_ urls: [URL], move: Bool)
    func selectionDidChange(in pane: BrowserViewController)
    func viewModeDidChange(in pane: BrowserViewController)
    func focusSearch(in pane: BrowserViewController)
}

extension BrowserHost {
    func focusSearch(in pane: BrowserViewController) {}
}

/// One browsing pane: its own path navigator, directory model, history, and
/// file views. A tab owns one or two independently navigable panes.
final class BrowserViewController: NSViewController, NSMenuDelegate, NSMenuItemValidation,
                                   QLPreviewPanelDataSource, QLPreviewPanelDelegate {

    let provider: FileProvider
    let model: DirectoryModel
    let history = NavigationHistory()
    /// The details list (always present; the default view).
    let fileList: FileListViewController
    /// The icon grid, created on first use.
    private(set) lazy var iconGrid: IconGridViewController = {
        let g = IconGridViewController(model: model)
        wire(g)
        return g
    }()
    /// Whichever of the two is showing.
    private(set) var fileView: FileViewing
    var focusView: NSView { fileView.focusView }
    let statusBar = StatusBarView()
    let addressBar = BreadcrumbBar()
    weak var host: BrowserHost?

    private(set) var viewMode: ViewMode = .details
    private(set) var zoomIndex: Int = 0
    private(set) var showsPreviews: Bool = true
    let viewPropertiesStore: DirectoryViewPropertiesStore
    var rememberedViewProperties = DirectoryViewProperties()
    var isApplyingViewProperties = false
    var lastAppliedViewProperties: DirectoryViewProperties?
    var viewPropertiesObserver: NSObjectProtocol?
    private(set) var viewPropertiesKey: String?
    var groupKey: GroupKey { model.groupKey }
    var usesGroups: Bool { model.groupKey != .none }

    /// ⌘X state is app-wide: cut in one tab, paste in another.
    private static var cutState: (changeCount: Int, urls: [URL])?

    var onLocationChanged: ((URL) -> Void)?
    /// Includes pending navigation, before a ZIP has finished preparing.
    var onWorkspaceSessionChanged: (() -> Void)?
    /// The pane took focus or was clicked — the tab page activates it.
    var onFocus: (() -> Void)?

    let searchSession = SearchSession()
    let searchPanel = SearchPanelController()
    var isSearching = false
    var searchReloadCompletions: [() -> Void] = []
    var searchSelection: [URL] = []
    var searchPanelHeight: NSLayoutConstraint?
    private(set) var currentURL: URL?
    private var workspaceNavigationURL: URL
    /// Startup panes need a name before loading succeeds. File actions still
    /// use currentURL, and an existing listing keeps its own location on failure.
    var chromeLocationURL: URL { currentURL ?? workspaceNavigationURL }
    var workspacePaneState: WorkspacePaneState {
        WorkspacePaneState(url: ArchiveWorkspace.shared.logicalURL(for: workspaceNavigationURL),
                           search: isSearching ? searchSession.request : nil)
    }
    private var navigationGeneration = 0
    private(set) var isPreparingArchive = false
    private var archivePreparation: ArchivePreparationSubscription?
    private var openingArchive: (source: URL, target: URL)?
    private var failedArchive: (source: URL, target: URL)?
    private var suspendedNavigation: URL?
    var failedArchiveURL: URL? { failedArchive?.target }
    let archiveNotice = ArchiveNavigationNotice()
    private let archiveNoticeHost = NSView()
    private var archiveNoticeHeight: NSLayoutConstraint?
    var fileOpener: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    var archiveFileOpener: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    var archiveSourceURL: URL? { currentURL.flatMap { ArchiveWorkspace.shared.session(for: $0)?.archiveURL } }
    var isBrowsingArchive: Bool { archiveSourceURL != nil }
    var canModifyCurrentLocation: Bool { canModifySelectedItems && !isSearching }
    var canModifySelectedItems: Bool { currentURL != nil && !isBrowsingArchive && !isPreparingArchive }
    var archiveStatus: String? { isBrowsingArchive ? "ZIP · Read-only" : nil }
    var readableSelectionURLs: [URL] { readableURLs(fileView.selectedItems) }
    var canPreviewSelection: Bool { !readableSelectionURLs.isEmpty && !isPreparingArchive }
    var canOpenSelection: Bool { canPreviewSelection }
    private func readableURLs(_ items: [FileItem]) -> [URL] {
        items.compactMap(\.readableContentURL)
    }
    private func isArchiveContent(_ url: URL) -> Bool {
        guard let session = ArchiveWorkspace.shared.session(for: url) else { return false }
        return url.resolvingSymlinksInPath().standardizedFileURL != session.archiveURL.resolvingSymlinksInPath().standardizedFileURL
    }
    private let activeIndicator = AdaptiveLayerView()
    var activeIndicatorForTesting: AdaptiveLayerView { activeIndicator }
    private var indicatorHeight: NSLayoutConstraint?
    private var lastError: Error?
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let contextMenu = FileContextMenu()
    /// Holds whichever file view is current.
    private let viewHost = NSView()
    private var watcher: DirectoryWatcher?
    private var refreshDebounce: DispatchWorkItem?

    init(provider: FileProvider, initialURL: URL,
         viewPropertiesStore: DirectoryViewPropertiesStore = .shared) {
        workspaceNavigationURL = ArchiveWorkspace.shared.logicalURL(for: initialURL)
        self.viewPropertiesStore = viewPropertiesStore
        let initialProperties = viewPropertiesStore.properties(forKey: Self.persistenceKey(for: initialURL))
        self.rememberedViewProperties = initialProperties
        self.viewMode = initialProperties.viewMode
        self.zoomIndex = initialProperties.zoomIndex(for: initialProperties.viewMode)
        self.showsPreviews = initialProperties.showPreviews
        let routedProvider = ArchiveFileProvider(base: provider)
        self.provider = routedProvider
        self.model = DirectoryModel(provider: routedProvider)
        self.fileList = FileListViewController(model: model)
        self.fileView = fileList
        model.groupKey = initialProperties.groupKey
        model.showHidden = initialProperties.showHidden
        model.setSort(key: initialProperties.sortKey, ascending: initialProperties.ascending)
        super.init(nibName: nil, bundle: nil)
        addressBar.homeURL = provider.homeURL
        addressBar.url = initialURL
        addressBar.onNavigate = { [weak self] url in
            guard let self else { return }
            self.onFocus?()
            self.navigate(to: url)
            self.view.window?.makeFirstResponder(self.focusView)
        }
        wire(fileList)
        configureSearch()
        // Match the persisted mode before loadView mounts a child. Calling
        // setViewMode here would return early because viewMode already matches.
        if viewMode == .icons { fileView = iconGrid }
        contextMenu.delegate = self
        statusBar.onZoomChanged = { [weak self] index in self?.setZoomIndex(index) }
        NotificationCenter.default.addObserver(self, selector: #selector(directoriesChanged(_:)),
                                               name: .tursoraDirectoriesChanged, object: nil)

        model.onChange = { [weak self] in
            guard let self else { return }
            let selected = self.fileView.selectedItems.map(\.url)
            self.fileView.reloadData()
            self.fileView.select(urls: selected)
            self.errorLabel.isHidden = self.lastError == nil
            self.updateStatus()
            self.persistViewProperties()
        }
        model.onError = { [weak self] error in
            guard let self else { return }
            self.lastError = error
            self.errorLabel.stringValue = "Cannot open this folder.\n\(error.localizedDescription)"
        }
        observeViewProperties()
        // Deferred so the owner can wire onLocationChanged first.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.navigationGeneration == 0 else { return }
            self.navigate(to: initialURL)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit {
        archivePreparation?.cancel()
        NotificationCenter.default.removeObserver(self)
        if let viewPropertiesObserver { NotificationCenter.default.removeObserver(viewPropertiesObserver) }
    }

    // MARK: - Keeping the listing current

    /// Folders whose contents are on screen: the directory plus any expanded subfolders.
    var displayedDirectories: [URL] {
        if isSearching {
            return Array(Set(model.allNodes.map { $0.url.deletingLastPathComponent() }))
                + [searchSession.request?.effectiveRootURL].compactMap { $0 }
        }
        var out: [URL] = []
        if let currentURL { out.append(currentURL) }
        out += fileList.expandedFolderURLs
        return out
    }

    /// FSEvents reports real paths (/private/var/…) even when we watch through
    /// a symlink (/var/…), so compare with symlinks resolved on both sides.
    private func isDisplaying(_ path: String) -> Bool {
        if isSearching, let root = searchSession.request?.effectiveRootURL.resolvingSymlinksInPath().path {
            let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            return real == root || real.hasPrefix(root == "/" ? "/" : root + "/")
        }
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let dirs = Set(displayedDirectories.map { $0.resolvingSymlinksInPath().path })
        return dirs.contains(real) || dirs.contains((real as NSString).deletingLastPathComponent)
    }

    /// FSEvents saw changes; refresh if any touch what this pane shows.
    private func fileSystemChanged(_ paths: [String]) {
        guard paths.contains(where: isDisplaying) else { return }
        scheduleRefresh()
    }

    /// Old URL → new URL for items renamed since the last refresh, so the
    /// selection follows them instead of being dropped.
    private var pendingRenames: [URL: URL] = [:]

    @objc private func directoriesChanged(_ note: Notification) {
        guard let dirs = note.userInfo?["directories"] as? [URL],
              dirs.contains(where: { isDisplaying($0.standardizedFileURL.path) }) else { return }
        if let from = note.userInfo?["renamedFrom"] as? URL, let to = note.userInfo?["renamedTo"] as? URL,
           isDisplaying(from.deletingLastPathComponent().path) {
            pendingRenames[from.standardizedFileURL] = to.standardizedFileURL
        }
        scheduleRefresh()
    }

    /// Coalesce bursts (a copy of many files is many events) into one reload.
    func scheduleRefresh(after delay: TimeInterval = 0.15) {
        refreshDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshPreservingSelection() }
        refreshDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// A reload that keeps what the user has selected and where they scrolled —
    /// for changes that happened *around* them, not ones they asked for.
    func refreshPreservingSelection() {
        if !isSearching, !model.isSearchResults, let currentURL,
           Self.persistenceKey(for: currentURL) != viewPropertiesKey {
            load(currentURL)
            return
        }
        let renames = pendingRenames
        pendingRenames = [:]
        let urls = fileView.selectedItems.map { renames[$0.url.standardizedFileURL] ?? $0.url }
        let offset = fileView.scrollOffset
        model.reload { [weak self] in
            guard let self else { return }
            self.fileView.select(urls: urls)
            self.fileView.scrollOffset = offset
        }
    }

    /// Hook a file view (list or grid) up to the browser.
    private func wire(_ v: FileViewing) {
        v.isReadOnly = isBrowsingArchive || isPreparingArchive
        v.onOpen = { [weak self] item in self?.open(item) }
        v.onOpenInNewTab = { [weak self] item in
            guard item.isNavigable else { return }
            self?.host?.openInNewTab(item.url, activate: false)
        }
        v.onRenameCommitted = { [weak self] item, name in self?.rename(item, to: name) }
        v.onSelectionChanged = { [weak self] in
            self?.updateStatus()
            if let self { NotificationCenter.default.post(name: .tursoraSelectionChanged, object: self) }
            if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible { panel.reloadData() }
        }
        v.onFocus = { [weak self] in self?.onFocus?() }
        v.onQuickLook = { [weak self] in self?.toggleQuickLook() }
        v.onDropFiles = { [weak self] urls, dest, op in self?.dropFiles(urls, to: dest, op: op) }
        v.onZoomGesture = { [weak self] step in self?.zoom(by: step) }
        v.contextMenu = contextMenu
        v.setIconSize(ZoomLevel.sizes(for: viewMode)[zoomIndex], showPreviews: showsPreviews)
    }

    override func loadView() {
        let v = SwipeView()
        v.onSwipe = { [weak self] dx in
            // Trackpad "swipe between pages": right-to-left content motion = forward.
            if dx > 0 { self?.goBack() } else if dx < 0 { self?.goForward() }
        }
        view = v
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        activeIndicator.translatesAutoresizingMaskIntoConstraints = false
        viewHost.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(activeIndicator)
        addressBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(addressBar)
        NSLayoutConstraint.activate([
            addressBar.topAnchor.constraint(equalTo: activeIndicator.bottomAnchor),
            addressBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            addressBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            addressBar.heightAnchor.constraint(equalToConstant: BreadcrumbBar.height),
        ])
        addChild(searchPanel)
        searchPanel.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(searchPanel.view)
        searchPanel.view.isHidden = true
        let searchHeight = searchPanel.view.heightAnchor.constraint(equalToConstant: 0)
        searchPanelHeight = searchHeight
        NSLayoutConstraint.activate([
            searchPanel.view.topAnchor.constraint(equalTo: addressBar.bottomAnchor),
            searchPanel.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            searchPanel.view.trailingAnchor.constraint(equalTo: view.trailingAnchor), searchHeight,
        ])
        archiveNoticeHost.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(archiveNoticeHost)
        let noticeHeight = archiveNoticeHost.heightAnchor.constraint(equalToConstant: 0)
        archiveNoticeHeight = noticeHeight
        archiveNotice.cancelButton.target = self
        archiveNotice.cancelButton.action = #selector(cancelArchiveOpening(_:))
        archiveNotice.retryButton.target = self
        archiveNotice.retryButton.action = #selector(retryArchiveOpening(_:))
        archiveNotice.enclosingFolderButton.target = self
        archiveNotice.enclosingFolderButton.action = #selector(openArchiveEnclosingFolder(_:))
        view.addSubview(viewHost)
        view.addSubview(statusBar)
        let h = activeIndicator.heightAnchor.constraint(equalToConstant: 0)
        indicatorHeight = h
        NSLayoutConstraint.activate([
            activeIndicator.topAnchor.constraint(equalTo: view.topAnchor),
            activeIndicator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            activeIndicator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            h,
            archiveNoticeHost.topAnchor.constraint(equalTo: searchPanel.view.bottomAnchor),
            archiveNoticeHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            archiveNoticeHost.trailingAnchor.constraint(equalTo: view.trailingAnchor), noticeHeight,
            viewHost.topAnchor.constraint(equalTo: archiveNoticeHost.bottomAnchor),
            viewHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            viewHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            viewHost.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: StatusBarView.height),
        ])

        errorLabel.alignment = .center
        errorLabel.textColor = .secondaryLabelColor
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(errorLabel)
        NSLayoutConstraint.activate([
            errorLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            errorLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.7),
        ])
        mount(fileView)
        syncZoomSlider()
    }

    // MARK: - Name filter (driven by the window's toolbar search field)

    /// Filter-bar text for this pane; empty = unfiltered. Per pane, like Dolphin.
    var nameFilter: String {
        get { model.nameFilter }
        set { model.nameFilter = newValue; onFilterChanged?(newValue) }
    }
    var isFiltering: Bool { !model.nameFilter.isEmpty }
    /// Summary of the current directory name filter.
    var filterSummary: String {
        guard isFiltering else { return "" }
        return "\(model.items.count) of \(model.unfilteredCount) items"
    }
    var onFilterChanged: ((String) -> Void)?

    private func mount(_ v: FileViewing) {
        addChild(v.viewController)
        viewHost.pinToEdges(v.viewController.view)
    }

    // MARK: - View mode, zoom, previews

    func setViewMode(_ mode: ViewMode) {
        guard mode != viewMode else { return }
        let selected = fileView.selectedItems.map(\.url)
        let hadFocus = view.window?.firstResponder === fileView.focusView
        fileView.viewController.view.removeFromSuperview()
        fileView.viewController.removeFromParent()
        viewMode = mode
        zoomIndex = rememberedViewProperties.zoomIndex(for: mode)
        fileView = mode == .icons ? iconGrid : fileList
        fileView.isReadOnly = isBrowsingArchive || isPreparingArchive
        if isViewLoaded { mount(fileView) }
        fileView.setIconSize(ZoomLevel.sizes(for: mode)[zoomIndex], showPreviews: showsPreviews)
        fileView.reloadData()
        fileView.select(urls: selected)
        syncZoomSlider()
        if hadFocus { view.window?.makeFirstResponder(fileView.focusView) }
        host?.viewModeDidChange(in: self)
        persistViewProperties()
    }

    var iconSize: CGFloat { ZoomLevel.sizes(for: viewMode)[zoomIndex] }

    func setZoomIndex(_ index: Int) {
        let clamped = ZoomLevel.clamp(index, for: viewMode)
        guard clamped != zoomIndex else { return }
        zoomIndex = clamped
        rememberedViewProperties.setZoomIndex(clamped, for: viewMode)
        fileView.setIconSize(iconSize, showPreviews: showsPreviews)
        syncZoomSlider()
        persistViewProperties()
    }

    func zoom(by step: Int) { setZoomIndex(zoomIndex + step) }

    func setShowsPreviews(_ on: Bool) {
        showsPreviews = on
        fileView.setIconSize(iconSize, showPreviews: on)
        persistViewProperties()
    }

    private func syncZoomSlider() {
        statusBar.setZoom(index: zoomIndex, count: ZoomLevel.sizes(for: viewMode).count)
    }

    // MARK: - Groups (Finder's View ▸ Use Groups / Group By)

    func setGroupKey(_ key: GroupKey) {
        if key != .none { rememberedViewProperties.lastGroupKey = key }
        model.groupKey = key
        persistViewProperties()
    }

    /// ⌃⌘0: off → back to the last key used (Kind at first); on → off.
    @objc func toggleGroups(_ sender: Any?) {
        setGroupKey(usesGroups ? .none : rememberedViewProperties.lastGroupKey)
    }

    @objc func groupBy(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = GroupKey(rawValue: raw) else { return }
        setGroupKey(key)
    }

    @objc func viewAsIcons(_ sender: Any?) { setViewMode(.icons) }
    @objc func viewAsList(_ sender: Any?) { setViewMode(.details) }
    @objc func zoomIn(_ sender: Any?) { zoom(by: 1) }
    @objc func zoomOut(_ sender: Any?) { zoom(by: -1) }
    @objc func zoomActualSize(_ sender: Any?) { setZoomIndex(ZoomLevel.defaultIndex(for: viewMode)) }
    @objc func togglePreviews(_ sender: Any?) { setShowsPreviews(!showsPreviews) }

    // MARK: - Quick Look (shared by both views)

    func toggleQuickLook() {
        guard canPreviewSelection else { return }
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible { panel.orderOut(nil) } else { panel.makeKeyAndOrderFront(nil) }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self; panel.delegate = self }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil; panel.delegate = nil }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { readableSelectionURLs.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let urls = readableSelectionURLs
        return urls.indices.contains(index) ? urls[index] as NSURL : nil
    }

    /// Arrow keys in the panel move the selection, so ↑/↓ browse previews.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, [123, 124, 125, 126].contains(event.keyCode) else { return false }
        fileView.forwardKey(event)
        return true
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let url = item.previewItemURL else { return .zero }
        return fileView.frameOnScreen(for: ArchiveWorkspace.shared.logicalURL(for: url))
    }

    /// nil = not in a split (no indicator); true/false = active/inactive pane.
    func setActiveIndicator(_ active: Bool?) {
        _ = view
        indicatorHeight?.constant = active == nil ? 0 : 3
        activeIndicator.semanticBackgroundColor = active == true ? .controlAccentColor : .clear
    }

    func prepareSearchDisplay() {
        saveViewState()
        navigationGeneration += 1
        clearArchiveNotice()
        refreshDebounce?.cancel()
        watcher = nil
        lastError = nil
        errorLabel.isHidden = true
        pendingSelection = nil
    }

    // MARK: - Navigation

    var canGoBack: Bool { isPreparingArchive || isSearching || history.canGoBack }
    var canGoForward: Bool { history.canGoForward }
    var canGoUp: Bool { (currentURL ?? failedArchive?.source ?? openingArchive?.source).map { $0.path != "/" } ?? false }

    func navigate(to url: URL) {
        saveViewState()
        leaveSearchContext()
        stopArchivePreparation()
        clearArchiveNotice()
        suspendedNavigation = nil
        let workspace = ArchiveWorkspace.shared
        let logical = workspace.logicalURL(for: url)
        workspaceNavigationURL = logical
        navigationGeneration += 1
        let generation = navigationGeneration
        pendingSelection = nil
        isPreparingArchive = false
        fileView.isReadOnly = isBrowsingArchive
        onWorkspaceSessionChanged?()
        if workspace.session(for: logical) != nil {
            enterPreparedArchive(logical)
        } else if AppPreferences.experimentalZIPBrowsingEnabled, let archive = workspace.archiveURL(containing: logical) {
            isPreparingArchive = true
            fileView.isReadOnly = true
            openingArchive = (archive, logical)
            statusBar.beginBusy()
            archiveNotice.showOpening(archive)
            mountArchiveNotice()
            updateStatus()
            archivePreparation = workspace.prepare(archive: archive) { [weak self] result in
                guard let self, self.navigationGeneration == generation else { return }
                self.stopArchivePreparation()
                switch result {
                case .success: self.enterPreparedArchive(logical)
                case .failure(let error): self.showArchiveError(error, archive: archive, target: logical)
                }
            }
        } else {
            history.push(logical)
            load(logical)
        }
    }

    private func enterPreparedArchive(_ requested: URL) {
        let logical = ArchiveWorkspace.shared.logicalURL(for: requested)
        do {
            let physical = try ArchiveWorkspace.shared.readableURL(for: logical)
            guard FileItem(url: physical)?.isNavigable == true else { throw ArchiveBrowsingSession.SessionError.notDirectory }
            history.push(logical)
            load(logical)
        } catch {
            showArchiveError(error, archive: ArchiveWorkspace.shared.archiveURL(containing: logical) ?? logical,
                             target: logical)
        }
    }

    private func mountArchiveNotice() {
        _ = view
        lastError = nil
        errorLabel.isHidden = true
        guard archiveNotice.superview == nil else { return }
        archiveNoticeHeight?.isActive = false
        archiveNoticeHost.pinToEdges(archiveNotice)
    }

    private func clearArchiveNotice() {
        failedArchive = nil
        archiveNotice.removeFromSuperview()
        archiveNoticeHeight?.isActive = true
    }

    private func stopArchivePreparation() {
        archivePreparation?.cancel()
        archivePreparation = nil
        openingArchive = nil
        if isPreparingArchive { statusBar.endBusy() }
        isPreparingArchive = false
        fileView.isReadOnly = isBrowsingArchive
    }

    @objc func cancelArchiveOpening(_ sender: Any?) {
        guard let openingArchive else { return }
        navigationGeneration += 1
        stopArchivePreparation()
        clearArchiveNotice()
        if let currentURL {
            workspaceNavigationURL = ArchiveWorkspace.shared.logicalURL(for: currentURL)
            onWorkspaceSessionChanged?()
            updateStatus()
        } else {
            navigate(to: openingArchive.source.deletingLastPathComponent())
        }
        view.window?.makeFirstResponder(focusView)
    }

    override func cancelOperation(_ sender: Any?) {
        if isPreparingArchive { cancelArchiveOpening(sender) }
        else { super.cancelOperation(sender) }
    }

    @objc func retryArchiveOpening(_ sender: Any?) {
        if let failedArchive { navigate(to: failedArchive.target) }
    }

    @objc func openArchiveEnclosingFolder(_ sender: Any?) {
        if let failedArchive { navigate(to: failedArchive.source.deletingLastPathComponent()) }
    }

    /// Closed tabs retain controllers for Reopen Closed Tab. Stop the worker
    /// now, then retry the requested location only if that tab is reopened.
    func suspendPendingNavigation() {
        if let openingArchive { suspendedNavigation = openingArchive.target }
        else if navigationGeneration == 0 { suspendedNavigation = workspaceNavigationURL }
        navigationGeneration += 1
        stopArchivePreparation()
        if suspendedNavigation != nil { clearArchiveNotice() }
    }

    func resumePendingNavigation() {
        if let suspendedNavigation { navigate(to: suspendedNavigation) }
    }

    private func showArchiveError(_ error: Error, archive: URL? = nil, target: URL? = nil) {
        // Failed navigation leaves the existing directory on screen. Persist
        // that location, so a subsequent search keeps its true browsing origin.
        // With no prior directory (startup), retain the requested ZIP to retry.
        if let currentURL { workspaceNavigationURL = ArchiveWorkspace.shared.logicalURL(for: currentURL) }
        if let archive, let target {
            failedArchive = (archive, target)
            archiveNotice.showFailure(archive, error: error)
            mountArchiveNotice()
        } else {
            lastError = error
            errorLabel.stringValue = error.localizedDescription
            errorLabel.isHidden = false
            errorLabel.toolTip = error.localizedDescription
        }
        updateStatus()
        onWorkspaceSessionChanged?()
    }

    func goBack() {
        if isPreparingArchive { cancelArchiveOpening(nil); return }
        if isSearching { closeSearch(); return }
        saveViewState()
        if let url = history.goBack() { load(url) }
    }

    func goForward() {
        saveViewState()
        if let url = history.goForward() { load(url) }
    }

    func goUp() {
        guard let location = currentURL ?? failedArchive?.source ?? openingArchive?.source, canGoUp else { return }
        let leftName = location.lastPathComponent
        navigate(to: location.deletingLastPathComponent())
        // Coming up out of a folder, the folder we left is the natural selection.
        pendingSelection = leftName
    }

    func goHome() { navigate(to: provider.homeURL) }

    /// Jump to any history slot (from the back/forward long-press menus).
    func goToHistory(slot: Int) {
        saveViewState()
        if let url = history.go(to: slot) { load(url) }
    }

    /// Entries behind (back) or ahead (forward) of the current one, nearest first.
    func historyMenu(back: Bool) -> NSMenu {
        let menu = NSMenu()
        let entries = back ? history.backEntries() : history.forwardEntries()
        for (slot, entry) in entries {
            let item = NSMenuItem(title: provider.displayName(for: entry.url), action: #selector(historyMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.tag = slot
            item.toolTip = (entry.url.path as NSString).abbreviatingWithTildeInPath
            let icon = NSWorkspace.shared.icon(forFile: entry.url.path); icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        return menu
    }

    @objc private func historyMenuItem(_ sender: NSMenuItem) { goToHistory(slot: sender.tag) }

    func reload() {
        if failedArchive != nil { retryArchiveOpening(nil); return }
        if isPreparingArchive { return }
        if isSearching { restartSearch(); return }
        if let currentURL, Self.persistenceKey(for: currentURL) != viewPropertiesKey {
            load(currentURL)
            return
        }
        saveViewState()
        model.reload { [weak self] in self?.restoreViewState() }
    }

    var showsHiddenFiles: Bool {
        get { model.showHidden }
        set { model.showHidden = newValue }
    }

    func openSelection() { fileView.openSelection() }

    // MARK: - Simple file operations available before M5

    /// Creates "untitled folder" (or "untitled folder 2", …) and selects it.
    @discardableResult
    func newFolder() -> URL? {
        guard canModifyCurrentLocation, let currentURL else { return nil }
        var name = "untitled folder"
        var n = 2
        while FileManager.default.fileExists(atPath: currentURL.appendingPathComponent(name).path) {
            name = "untitled folder \(n)"; n += 1
        }
        let url = currentURL.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            report(error, context: "new folder")
            return nil
        }
        pendingSelection = name
        model.reload { [weak self] in self?.restoreViewState() }
        DirectoryChanges.post([currentURL])
        return url
    }

    // MARK: - File operations (M5)

    private var selectedURLs: [URL] { fileView.selectedItems.map(\.url) }
    private var undo: UndoManager? { view.window?.undoManager }
    /// Optional process-local pacing for packaged-app verification. It never
    /// changes the data path, totals or persisted preferences.
    var transferOptions: TransferOptions = {
        var options = TransferOptions()
        if let raw = ProcessInfo.processInfo.environment["TURSORA_TRANSFER_TEST_DELAY_MS"],
           let milliseconds = Double(raw), milliseconds.isFinite, milliseconds > 0 {
            options.chunkDelay = min(milliseconds, 1000) / 1000
        }
        return options
    }()
    private(set) var lastTransferTask: TransferTask?
    /// Allows isolated controller tests to inspect the same recovery error shown
    /// by the application without opening a modal error sheet.
    var transferReplayErrorReporter: ((Error) -> Void)?

    /// Errors go to stdout in smoke-test mode — a modal sheet would hang a
    /// headless run (and hide the message from the log).
    func report(_ error: Error, context: String = "") {
        if SmokeTest.isRequested {
            print("ERROR \(context): \(error)")
        } else {
            presentError(error)
        }
    }

    func updateStatus() {
        statusBar.update(itemCount: model.items.count,
                         totalCount: model.nameFilter.isEmpty ? nil : model.unfilteredCount,
                         selectedCount: fileView.selectedItems.count, directory: isBrowsingArchive || isSearching ? nil : currentURL,
                         archiveStatus: archiveStatus, searchStatus: isSearching ? "Search Results" : nil)
        host?.selectionDidChange(in: self)
    }

    private func reloadSelecting(_ names: [String]) {
        if isSearching { restartSearch(); return }
        model.reload { [weak self] in self?.fileView.select(names: names) }
    }

    // Edit menu — reached via the responder chain when the list has focus.

    @objc func copy(_ sender: Any?) { putOnPasteboard(selectedURLs, cut: false) }
    @objc func cut(_ sender: Any?) { putOnPasteboard(selectedURLs, cut: true) }

    private func putOnPasteboard(_ urls: [URL], cut: Bool) {
        guard !urls.isEmpty, !isPreparingArchive else { return }
        if cut && (!canModifySelectedItems || urls.contains(where: isArchiveContent)) { return }
        let urls = urls.compactMap { isArchiveContent($0) ? try? ArchiveWorkspace.shared.readableURL(for: $0) : $0 }
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        Self.cutState = cut ? (pb.changeCount, urls) : nil
        fileList.cutURLs = cut ? Set(urls) : []
        if viewMode == .icons { iconGrid.cutURLs = fileList.cutURLs }
    }

    @objc func paste(_ sender: Any?) {
        guard canModifyCurrentLocation, let dest = currentURL else { return }
        let pb = NSPasteboard.general
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return }
        let pasteboardGeneration = pb.changeCount
        let isCut = Self.cutState?.changeCount == pb.changeCount
        transfer(urls, to: dest, kind: isCut ? .move : .copy) { [weak self] in
            // A later Copy/Cut belongs to a different operation.
            if isCut && pb.changeCount == pasteboardGeneration {
                Self.cutState = nil; pb.clearContents(); self?.fileList.cutURLs = []
                if self?.viewMode == .icons { self?.iconGrid.cutURLs = [] }
            }
        }
    }

    @objc func duplicate(_ sender: Any?) {
        guard canModifySelectedItems, let destination = currentURL else { return }
        transfer(selectedURLs, to: destination, kind: .copy, actionName: "Duplicate", duplicateInPlace: true)
    }

    @objc func moveToTrash(_ sender: Any?) { trash(selectedURLs) }

    func trash(_ urls: [URL]) {
        guard canModifySelectedItems, !urls.isEmpty,
              !urls.contains(where: isArchiveContent) else { return }
        // Dolphin selects the next item after deleting; Finder selects nothing. Dolphin wins here.
        let nextURL = fileView.itemAfterSelection()?.url
        do {
            let pairs = try FileOperations.trash(urls)
            if SmokeTest.isRequested { for p in pairs { print("   trashed \(p.original.lastPathComponent) → \(p.trashed.path)") } }
            registerUndoMove(pairs.map { (from: $0.original, to: $0.trashed) }, actionName: "Move to Trash")
            reloadSelectingURLs(nextURL.map { [$0] } ?? [])
            DirectoryChanges.post(DirectoryChanges.affected(sources: urls))
        } catch {
            report(error, context: "trash")
            reload()
        }
    }

    @objc func deletePermanently(_ sender: Any?) {
        guard canModifySelectedItems else { return }
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = urls.count == 1
            ? "Are you sure you want to delete “\(urls[0].lastPathComponent)”?"
            : "Are you sure you want to delete the \(urls.count) selected items?"
        alert.informativeText = "This item will be deleted immediately. You can’t undo this action."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if SmokeTest.isRequested { print("ERROR delete: confirmation unavailable during smoke test"); return }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try FileOperations.delete(urls) } catch { report(error, context: "delete") }
        reload()
        DirectoryChanges.post(DirectoryChanges.affected(sources: urls))
    }

    @objc func renameSelection(_ sender: Any?) {
        guard canModifySelectedItems else { return }
        guard let item = fileView.selectedItems.first, fileView.selectedItems.count == 1 else { return }
        fileView.beginRename(item: item)
    }

    static func compressionTitle(for urls: [URL]) -> String {
        urls.count == 1 ? "Compress “\(urls[0].lastPathComponent)”" : urls.isEmpty ? "Compress" : "Compress \(urls.count) Items"
    }
    var compressionTitle: String { Self.compressionTitle(for: selectedURLs) }
    var canExtractSelection: Bool {
        canModifyCurrentLocation && !fileView.selectedItems.isEmpty && fileView.selectedItems.allSatisfy { !$0.isDirectory && FileOperations.canExtractArchive($0.url) }
    }

    @objc func compressSelection(_ sender: Any?) {
        compress(selectedURLs)
    }

    @objc func extractSelection(_ sender: Any?) {
        guard canExtractSelection else { return }
        extract(selectedURLs)
    }

    func compress(_ urls: [URL], completion: (() -> Void)? = nil) {
        guard canModifyCurrentLocation, !urls.isEmpty, let destination = currentURL else { completion?(); return }
        statusBar.beginBusy()
        FileOperations.compress(urls: urls, to: destination) { [weak self] result in
            guard let self else { completion?(); return }
            self.finishArchive(result, destination: destination, actionName: "Compress")
            self.statusBar.endBusy()
            completion?()
        }
    }

    func extract(_ archives: [URL], completion: (() -> Void)? = nil) {
        guard canModifyCurrentLocation, !archives.isEmpty else { completion?(); return }
        let startingURL = currentURL
        statusBar.beginBusy()
        var created: [URL] = []
        var failures: [FileOperations.Failure] = []
        func next(_ index: Int) {
            guard index < archives.count else {
                self.statusBar.endBusy()
                self.registerUndoTrash(created, actionName: "Extract")
                if self.currentURL == startingURL {
                    self.model.reload { [weak self] in self?.fileView.select(urls: created) }
                }
                else { self.reload() }
                DirectoryChanges.post(DirectoryChanges.affected(sources: created))
                FileOperations.report(failures, in: self.view.window)
                completion?()
                return
            }
            let archive = archives[index]
            FileOperations.extract(archive: archive, to: archive.deletingLastPathComponent()) { result in
                switch result {
                case .success(let url): created.append(url)
                case .failure(let error): failures.append(.init(url: archive, error: error))
                }
                next(index + 1)
            }
        }
        next(0)
    }

    private func finishArchive(_ result: Result<URL, Error>, destination: URL, actionName: String) {
        switch result {
        case .success(let url):
            registerUndoTrash([url], actionName: actionName)
            if currentURL?.standardizedFileURL == destination.standardizedFileURL {
                model.reload { [weak self] in self?.fileView.select(urls: [url]) }
            }
            DirectoryChanges.post([destination])
        case .failure(let error): report(error, context: actionName.lowercased())
        }
    }

    @objc func quickLook(_ sender: Any?) { toggleQuickLook() }

    func rename(_ item: FileItem, to name: String) {
        guard canModifySelectedItems, !item.isArchiveEntry else { return }
        do {
            let newURL = try FileOperations.rename(item.url, to: name)
            registerUndoRename(from: newURL, to: item.name, actionName: "Rename")
            reloadSelectingURLs([newURL])
            DirectoryChanges.post(DirectoryChanges.affected(sources: [item.url]), renamed: (from: item.url, to: newURL))
        } catch {
            report(error, context: "rename")
            reload()
        }
    }

    /// Drop or sidebar-drop: op is .copy or .move.
    func dropFiles(_ urls: [URL], to destination: URL, op: NSDragOperation) {
        guard !ArchiveWorkspace.shared.containsArchiveLocation(destination) else { return }
        transfer(urls, to: destination, kind: op == .copy ? .copy : .move)
    }

    private func transfer(_ urls: [URL], to destination: URL, kind: FileOperations.Kind,
                          actionName: String? = nil, duplicateInPlace: Bool = false,
                          then: (() -> Void)? = nil) {
        guard !ArchiveWorkspace.shared.containsArchiveLocation(destination), !urls.isEmpty else { return }
        if kind == .move && urls.contains(where: isArchiveContent) { return }
        let urls = urls.compactMap { isArchiveContent($0) ? try? ArchiveWorkspace.shared.readableURL(for: $0) : $0 }
        guard !urls.isEmpty else { return }
        statusBar.beginBusy()
        let window = view.window
        let capturedUndo = window?.undoManager
        let name = actionName ?? (kind == .copy ? "Copy" : "Move")
        var options = transferOptions
        options.duplicateInPlace = duplicateInPlace
        let task = TransferTask(sources: urls, destination: destination, kind: kind)
        lastTransferTask = task
        let tasks = TransferTasksWindowController.shared
        tasks.track(task, ownerWindow: window,
                    title: duplicateInPlace ? "Duplicate \(task.sources.count) item\(task.sources.count == 1 ? "" : "s")" : nil,
                    destinationDescription: duplicateInPlace ? "Beside each original" : nil)
        FileOperations.transfer(urls, to: destination, kind: kind,
            conflict: { _ in .init(resolution: .cancel) }, task: task, options: options,
            asyncConflict: { conflict, reply in tasks.resolveConflict(for: task, conflict: conflict, reply: reply) }
        ) { [self] result in
            // Retain this pane and its original undo manager through completion,
            // even if the originating tab was closed or another pane is active.
            self.statusBar.endBusy()
            if let journal = result.journal, let capturedUndo {
                self.registerTransferUndo(journal, undo: capturedUndo, actionName: name)
            }
            let created = result.created + result.moved.map(\.to)
            if self.isSearching || destination.standardizedFileURL == self.currentURL?.standardizedFileURL {
                self.reloadSelectingURLs(created)
            } else {
                self.reload()
            }
            then?()
            // The source folder is usually another pane, tab or window: tell it.
            DirectoryChanges.post(DirectoryChanges.affected(sources: urls, destination: destination)
                                  + (result.journal?.affectedDirectories ?? []))
            if SmokeTest.isRequested { FileOperations.report(result.failures, in: window) }
        }
    }

    private func registerTransferUndo(_ journal: TransferJournal, undo: UndoManager, actionName: String) {
        asUndoGroup(undo, actionName: actionName) {
            undo.registerUndo(withTarget: self) { [weak undo] me in
                guard let undo else { return }
                do {
                    let inverse = try FileOperations.replay(journal)
                    me.registerTransferUndo(inverse, undo: undo, actionName: actionName)
                    me.reload()
                    DirectoryChanges.post(journal.affectedDirectories)
                } catch {
                    if let reporter = me.transferReplayErrorReporter { reporter(error) }
                    else { me.report(error, context: "undo \(actionName.lowercased())") }
                }
            }
        }
    }

    // Undo — registered on the window's undo manager so Edit ▸ Undo just works.

    /// Every file operation becomes its own undo group. Registrations arrive
    /// from async completions, and NSUndoManager's automatic per-event group
    /// can still be open from an earlier operation — observed in testing: a
    /// Copy and a later Move landed in one group and were undone together,
    /// which trashed the file the Move had just restored. So: close any stale
    /// automatic group (undo() itself does the same), then group explicitly.
    private func asUndoGroup(_ undo: UndoManager, actionName: String, _ register: () -> Void) {
        if !undo.isUndoing, !undo.isRedoing {
            while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        }
        undo.beginUndoGrouping()
        register()
        undo.setActionName(actionName)
        undo.endUndoGrouping()
        // With groupsByEvent on, NSUndoManager wraps a top-level group of ours
        // in an event group that stays open until the run loop turns. Close it
        // now so the operation is complete and self-contained immediately.
        if !undo.isUndoing, !undo.isRedoing {
            while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        }
        if SmokeTest.isRequested { print("   [undo] \(actionName) registered (undoing=\(undo.isUndoing), top=\(undo.undoActionName), level=\(undo.groupingLevel))") }
    }

    private func registerUndoMove(_ pairs: [(from: URL, to: URL)], actionName: String) {
        guard !pairs.isEmpty, let undo else { return }
        asUndoGroup(undo, actionName: actionName) {
            undo.registerUndo(withTarget: self) { me in
                var reversed: [(from: URL, to: URL)] = []
                for (from, to) in pairs {
                    do { try FileManager.default.moveItem(at: to, to: from); reversed.append((from: to, to: from)) }
                    catch { me.report(error, context: "undo move \(to.path) → \(from.path)") }
                }
                me.registerUndoMove(reversed, actionName: actionName)     // redo
                me.reloadSelectingURLs(reversed.map(\.to))
                DirectoryChanges.post(pairs.flatMap { [$0.from.deletingLastPathComponent(), $0.to.deletingLastPathComponent()] })
            }
        }
    }

    private func registerUndoTrash(_ urls: [URL], actionName: String) {
        guard !urls.isEmpty, let undo else { return }
        asUndoGroup(undo, actionName: actionName) {
            undo.registerUndo(withTarget: self) { me in
                do {
                    let pairs = try FileOperations.trash(urls)
                    me.registerUndoMove(pairs.map { (from: $0.original, to: $0.trashed) }, actionName: actionName)
                } catch { me.report(error, context: "undo copy (trash)") }
                me.reload()
                DirectoryChanges.post(DirectoryChanges.affected(sources: urls))
            }
        }
    }

    private func registerUndoRename(from url: URL, to oldName: String, actionName: String) {
        guard let undo else { return }
        asUndoGroup(undo, actionName: actionName) {
            undo.registerUndo(withTarget: self) { me in
                do {
                    let newName = url.lastPathComponent
                    let back = try FileOperations.rename(url, to: oldName)
                    me.registerUndoRename(from: back, to: newName, actionName: actionName)
                    me.reloadSelectingURLs([back])
                    DirectoryChanges.post(DirectoryChanges.affected(sources: [url, back]), renamed: (from: url, to: back))
                } catch { me.report(error, context: "undo rename"); me.reload() }
            }
        }
    }

    // MARK: - Menu validation for the file operations

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let hasSelection = !fileView.selectedItems.isEmpty
        switch item.action {
        case #selector(copy(_:)), #selector(quickLook(_:)): return canPreviewSelection
        case #selector(cut(_:)), #selector(duplicate(_:)), #selector(moveToTrash(_:)), #selector(deletePermanently(_:)):
            return canModifySelectedItems && hasSelection
        case #selector(renameSelection(_:)):
            return canModifySelectedItems && fileView.selectedItems.count == 1
        case #selector(ctxRevealEnclosingFolder(_:)):
            return isSearching && contextTargets(for: item).count == 1
        case #selector(compressSelection(_:)):
            item.title = compressionTitle; return canModifyCurrentLocation && hasSelection
        case #selector(extractSelection(_:)): return canExtractSelection
        case #selector(viewAsIcons(_:)):
            item.state = viewMode == .icons ? .on : .off; return true
        case #selector(viewAsList(_:)):
            item.state = viewMode == .details ? .on : .off; return true
        case #selector(togglePreviews(_:)):
            item.state = showsPreviews ? .on : .off; return true

        case #selector(toggleGroups(_:)):
            item.state = usesGroups ? .on : .off; return true
        case #selector(groupBy(_:)):
            item.state = (item.representedObject as? String) == groupKey.rawValue ? .on : .off; return true
        case #selector(zoomIn(_:)):  return zoomIndex < ZoomLevel.sizes(for: viewMode).count - 1
        case #selector(zoomOut(_:)): return zoomIndex > 0
        case #selector(copyToOtherPane(_:)): return canPreviewSelection && host?.isSplit == true
        case #selector(moveToOtherPane(_:)): return canModifySelectedItems && hasSelection && host?.isSplit == true
        case #selector(paste(_:)):
            return canModifyCurrentLocation && NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        default:
            return true
        }
    }

    // MARK: - Get Info (⌘I), Show Inspector (⌥⌘I), Get Summary Info (⌃⌘I)

    /// Finder's targets: the selection, or the folder itself when nothing is selected.
    var infoTargets: [URL] {
        guard !isBrowsingArchive else { return [] }
        let selected = selectedURLs
        if !selected.isEmpty { return selected }
        return isSearching ? [] : currentURL.map { [$0] } ?? []
    }

    @objc func getInfo(_ sender: Any?) { InfoWindowController.show(for: infoTargets, relativeTo: view.window) }
    @objc func getSummaryInfo(_ sender: Any?) { InfoWindowController.showSummary(for: infoTargets, relativeTo: view.window) }
    @objc func showInspector(_ sender: Any?) {
        guard !isBrowsingArchive else { return }
        InfoWindowController.showInspector(relativeTo: view.window)
    }
    @objc private func ctxCompress(_ sender: Any?) { compress(contextTargets(for: sender).map(\.url)) }
    @objc private func ctxExtract(_ sender: Any?) { extract(contextTargets(for: sender).map(\.url)) }
    @objc private func ctxGetInfo(_ s: Any?) {
        guard !isBrowsingArchive else { return }
        let targets = contextTargets(for: s).map(\.url)
        InfoWindowController.show(for: targets.isEmpty ? infoTargets : targets, relativeTo: view.window)
    }

    // MARK: - Context menu

    private var pendingSelection: String?

    /// A result batch can move rows while a menu tracks. Keep the exact items
    /// used to construct that menu, rather than resolving its clicked row again.
    private var frozenContextTargets: [FileItem]?
    private weak var trackingContextMenu: NSMenu?
    private var contextTargets: [FileItem] { frozenContextTargets ?? fileView.clickedItems }

    private func contextTargets(for sender: Any?) -> [FileItem] {
        var menu = (sender as? NSMenuItem)?.menu
        while let current = menu {
            if let context = current as? FileContextMenu { return context.targetItems }
            menu = current.supermenu
        }
        return contextTargets
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === contextMenu else { return }
        let targets = trackingContextMenu == nil ? fileView.clickedItems
            : (trackingContextMenu as? FileContextMenu)?.targetItems ?? contextTargets
        contextMenu.targetItems = targets
        menu.removeAllItems()
        for item in buildContextMenu(for: targets).items {
            menu.addItem(item.copy() as! NSMenuItem)
        }
    }

    func menuWillOpen(_ menu: NSMenu) { trackingContextMenu = menu }

    func menuDidClose(_ menu: NSMenu) {
        if trackingContextMenu === menu { trackingContextMenu = nil }
        // AppKit closes the menu before dispatching its selected action. The
        // next menu construction replaces this snapshot; closing must not.
    }

    /// Builds a menu and freezes its full-URL action targets for dispatch.
    func buildContextMenu(for items: [FileItem]) -> NSMenu {
        frozenContextTargets = items
        let menu = FileContextMenu()
        menu.targetItems = items
        menu.delegate = self
        func add(_ title: String, _ action: Selector?, _ key: String = "", enabled: Bool = true,
                 state: NSControl.StateValue = .off, symbol: String? = nil) {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
            mi.target = self; mi.isEnabled = enabled; mi.state = state
            mi.image = MenuIcons.image(symbol)
            menu.addItem(mi)
        }
        if isBrowsingArchive {
            let readable = !readableURLs(items).isEmpty
            let folders = items.filter(\.isNavigable)
            if !items.isEmpty {
                add("Open", #selector(ctxOpen(_:)), enabled: readable)
                if let single = items.first, items.count == 1, !single.isNavigable,
                   let url = single.readableContentURL { menu.addItem(openWithMenuItem(for: url)) }
                if !folders.isEmpty {
                    add("Open in New Tab", #selector(ctxOpenInNewTab(_:)))
                    if folders.count == 1 {
                        add("Open in New Window", #selector(ctxOpenInNewWindow(_:)))
                        add(host?.isSplit == true ? "Open in Other Pane" : "Open in New Pane", #selector(ctxOpenInOtherPane(_:)))
                    }
                }
                add("Quick Look", #selector(ctxQuickLook(_:)), enabled: readable, symbol: "eye")
                add("Copy", #selector(ctxCopy(_:)), enabled: readable, symbol: "doc.on.doc")
                if host?.isSplit == true { add("Copy to Other Pane", #selector(ctxCopyToOtherPane(_:)), enabled: readable) }
                add(items.count == 1 ? "Copy Path" : "Copy Paths", #selector(ctxCopyPath(_:)))
                menu.addItem(.separator())
            }
            add("Reload", #selector(ctxReload(_:)), symbol: "arrow.clockwise")
            add("Show Hidden Files", #selector(ctxToggleHidden(_:)), state: showsHiddenFiles ? .on : .off)
            menu.addItem(sortMenuItem())
            return menu
        }
        if isSearching, !items.isEmpty {
            add("Reveal in Enclosing Folder", #selector(ctxRevealEnclosingFolder(_:)), enabled: items.count == 1)
            menu.addItem(.separator())
        }
        if items.isEmpty, isSearching {
            add("Search…", #selector(showSearchAction(_:)))
            add("Reload", #selector(ctxReload(_:)))
            add("Close Search", #selector(closeSearchAction(_:)))
            menu.addItem(sortMenuItem())
            return menu
        }
        if items.isEmpty {
            add("New Folder", #selector(ctxNewFolder(_:)), symbol: "folder.badge.plus")
            add("Get Info", #selector(ctxGetInfo(_:)), symbol: "info.circle")
            add("Paste", #selector(paste(_:)), enabled: validateMenuItem(NSMenuItem(title: "", action: #selector(paste(_:)), keyEquivalent: "")),
                symbol: "document.on.clipboard|doc.on.clipboard")
            menu.addItem(.separator())
            add("Reload", #selector(ctxReload(_:)), symbol: "arrow.clockwise")
            add("Show Hidden Files", #selector(ctxToggleHidden(_:)), state: showsHiddenFiles ? .on : .off)
            menu.addItem(sortMenuItem())
            if let currentURL, let host {
                menu.addItem(.separator())
                let fav = host.places.isFavourite(currentURL)
                add(fav ? "Remove from Favourites" : "Add to Favourites", #selector(ctxToggleFavourite(_:)), symbol: fav ? "star.slash" : "star")
            }
            return menu
        }

        let folders = items.filter(\.isNavigable)
        let single = items.count == 1 ? items[0] : nil

        add("Open", #selector(ctxOpen(_:)))
        if let single, !single.isNavigable {
            menu.addItem(openWithMenuItem(for: single.url))
        }
        if !folders.isEmpty {
            add(folders.count == 1 ? "Open in New Tab" : "Open in \(folders.count) New Tabs", #selector(ctxOpenInNewTab(_:)))
            if folders.count == 1 {
                add("Open in New Window", #selector(ctxOpenInNewWindow(_:)))
                add(host?.isSplit == true ? "Open in Other Pane" : "Open in New Pane", #selector(ctxOpenInOtherPane(_:)))
            }
        }
        if host?.isSplit == true {
            menu.addItem(.separator())
            add("Copy to Other Pane", #selector(ctxCopyToOtherPane(_:)))
            add("Move to Other Pane", #selector(ctxMoveToOtherPane(_:)))
        }
        menu.addItem(.separator())
        add("Quick Look", #selector(ctxQuickLook(_:)), symbol: "eye")
        add("Get Info", #selector(ctxGetInfo(_:)), symbol: "info.circle")
        if items.count == 1 { add("Rename", #selector(ctxRename(_:)), symbol: "pencil") }
        add("Duplicate", #selector(ctxDuplicate(_:)), symbol: "plus.square.on.square")
        if canModifyCurrentLocation {
            add(Self.compressionTitle(for: items.map(\.url)), #selector(ctxCompress(_:)), symbol: "doc.zipper")
        }
        if canModifyCurrentLocation, items.allSatisfy({ !$0.isDirectory && FileOperations.canExtractArchive($0.url) }) {
            add("Extract", #selector(ctxExtract(_:)), symbol: "doc.zipper")
        }
        add("Move to Trash", #selector(ctxTrash(_:)), symbol: "trash")
        menu.addItem(.separator())
        add("Cut", #selector(ctxCut(_:)), symbol: "scissors")
        add("Copy", #selector(ctxCopy(_:)), symbol: "document.on.document|doc.on.doc")
        menu.addItem(.separator())
        add(items.count == 1 ? "Copy Path" : "Copy Paths", #selector(ctxCopyPath(_:)), symbol: "document.on.document|doc.on.doc")
        if let single, single.isNavigable, let host {
            menu.addItem(.separator())
            let fav = host.places.isFavourite(single.url)
            add(fav ? "Remove from Favourites" : "Add to Favourites", #selector(ctxToggleFavourite(_:)), symbol: fav ? "star.slash" : "star")
        }
        return menu
    }

    private func openWithMenuItem(for url: URL) -> NSMenuItem {
        let item = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        if let defaultApp {
            apps.removeAll { $0 == defaultApp }
            apps.insert(defaultApp, at: 0)
        }
        for (i, app) in apps.prefix(20).enumerated() {
            let name = FileManager.default.displayName(atPath: app.path)
            let mi = NSMenuItem(title: i == 0 && defaultApp != nil ? "\(name) (default)" : name,
                                action: #selector(ctxOpenWith(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = app
            let icon = NSWorkspace.shared.icon(forFile: app.path); icon.size = NSSize(width: 16, height: 16)
            mi.image = icon
            sub.addItem(mi)
            if i == 0, defaultApp != nil, apps.count > 1 { sub.addItem(.separator()) }
        }
        if apps.isEmpty {
            let none = NSMenuItem(title: "No Applications", action: nil, keyEquivalent: ""); none.isEnabled = false
            sub.addItem(none)
        }
        item.submenu = sub
        return item
    }

    private func sortMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (title, key) in [("Name", DirectoryModel.SortKey.name), ("Date Modified", .dateModified),
                             ("Size", .size), ("Kind", .kind)] {
            let mi = NSMenuItem(title: title, action: #selector(ctxSort(_:)), keyEquivalent: "")
            mi.target = self; mi.representedObject = key.rawValue
            mi.state = model.sortKey == key ? .on : .off
            sub.addItem(mi)
        }
        sub.addItem(.separator())
        let asc = NSMenuItem(title: "Ascending", action: #selector(ctxToggleSortOrder(_:)), keyEquivalent: "")
        asc.target = self; asc.state = model.ascending ? .on : .off
        sub.addItem(asc)
        item.submenu = sub
        return item
    }

    @objc private func ctxRevealEnclosingFolder(_ s: Any?) {
        let targets = contextTargets(for: s)
        if targets.count == 1, let item = targets.first { revealSearchResult(item.url) }
    }

    @objc private func ctxOpen(_ s: Any?) { contextTargets(for: s).forEach(open) }
    @objc private func ctxQuickLook(_ s: Any?) { selectContextTargets(contextTargets(for: s)); toggleQuickLook() }
    @objc private func ctxRename(_ s: Any?) {
        guard canModifySelectedItems else { return }
        if let item = contextTargets(for: s).first { fileView.beginRename(item: item) }
    }
    @objc private func ctxDuplicate(_ s: Any?) { selectContextTargets(contextTargets(for: s)); duplicate(nil) }
    @objc private func ctxTrash(_ s: Any?) { trash(contextTargets(for: s).map(\.url)) }
    @objc private func ctxCut(_ s: Any?) { putOnPasteboard(contextTargets(for: s).map(\.url), cut: true) }
    @objc private func ctxCopy(_ s: Any?) { putOnPasteboard(contextTargets(for: s).map(\.url), cut: false) }
    /// Context actions that reuse selection-based commands first make the targets the selection.
    func selectContextTargets(_ items: [FileItem]) {
        fileView.select(urls: items.map(\.url))
    }
    @objc private func ctxOpenWith(_ s: NSMenuItem) {
        guard let app = s.representedObject as? URL else { return }
        NSWorkspace.shared.open(readableURLs(contextTargets(for: s)), withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration())
    }
    @objc private func ctxOpenInNewTab(_ s: Any?) {
        for f in contextTargets(for: s).filter(\.isNavigable) { host?.openInNewTab(f.url, activate: false) }
    }
    @objc private func ctxOpenInOtherPane(_ s: Any?) {
        if let f = contextTargets(for: s).first(where: \.isNavigable) { host?.openInOtherPane(f.url) }
    }
    @objc private func ctxCopyToOtherPane(_ s: Any?) { host?.transferToOtherPane(readableURLs(contextTargets(for: s)), move: false) }
    @objc private func ctxMoveToOtherPane(_ s: Any?) { if canModifySelectedItems { host?.transferToOtherPane(contextTargets(for: s).map(\.url), move: true) } }
    @objc func copyToOtherPane(_ s: Any?) { host?.transferToOtherPane(readableSelectionURLs, move: false) }
    @objc func moveToOtherPane(_ s: Any?) { if canModifySelectedItems { host?.transferToOtherPane(selectedURLs, move: true) } }
    @objc private func ctxOpenInNewWindow(_ s: Any?) {
        if let f = contextTargets(for: s).first(where: \.isNavigable) { host?.openInNewWindow(f.url) }
    }
    @objc private func ctxCopyPath(_ s: Any?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(contextTargets(for: s).map(\.url.path).joined(separator: "\n"), forType: .string)
    }
    @objc private func ctxToggleFavourite(_ s: Any?) {
        guard !isBrowsingArchive else { return }
        guard let host else { return }
        let url = contextTargets(for: s).first(where: \.isNavigable)?.url ?? currentURL
        guard let url else { return }
        host.places.isFavourite(url) ? host.places.removeFavourite(url) : host.places.addFavourite(url)
    }
    @objc private func ctxNewFolder(_ s: Any?) { newFolder() }
    @objc private func ctxReload(_ s: Any?) { reload() }
    @objc private func ctxToggleHidden(_ s: Any?) { showsHiddenFiles.toggle() }
    @objc private func ctxSort(_ s: NSMenuItem) {
        guard let raw = s.representedObject as? String, let key = DirectoryModel.SortKey(rawValue: raw) else { return }
        fileList.setSort(key: key, ascending: model.ascending)
    }
    @objc private func ctxToggleSortOrder(_ s: Any?) {
        fileList.setSort(key: model.sortKey, ascending: !model.ascending)
    }

    // MARK: - Private

    private func load(_ url: URL) {
        leaveSearchContext()
        navigationGeneration += 1
        stopArchivePreparation()
        clearArchiveNotice()
        suspendedNavigation = nil
        let destinationKey = Self.persistenceKey(for: url)
        let sameLocation = currentURL?.standardizedFileURL == url.standardizedFileURL
        let retargeted = sameLocation && viewPropertiesKey != destinationKey
        let changingDirectory = !sameLocation || retargeted
        if retargeted {
            history.recordViewState(selectedName: nil, scrollOffset: 0)
            pendingSelection = nil
        }
        if changingDirectory { pendingRenames = [:] }
        currentURL = url
        workspaceNavigationURL = ArchiveWorkspace.shared.logicalURL(for: url)
        addressBar.url = url
        viewPropertiesKey = destinationKey
        restoreViewProperties()
        fileList.isReadOnly = isBrowsingArchive
        if viewMode == .icons { iconGrid.isReadOnly = isBrowsingArchive }
        lastError = nil
        errorLabel.isHidden = true
        refreshDebounce?.cancel()
        if changingDirectory, isFiltering { nameFilter = "" }     // Dolphin: clear on directory change
        watcher = isBrowsingArchive ? nil : DirectoryWatcher(directory: url) { [weak self] paths in self?.fileSystemChanged(paths) }
        model.load(url) { [weak self] in self?.restoreViewState() }
        onLocationChanged?(url)
        NotificationCenter.default.post(name: .tursoraSelectionChanged, object: self)
    }

    private func open(_ item: FileItem) {
        guard !isPreparingArchive else { return }
        guard item.canAccess else { showArchiveError(ArchiveBrowsingSession.SessionError.unavailableItem); return }
        if item.isArchiveEntry {
            if item.isNavigable { navigate(to: item.url) }
            else if let copy = item.readableContentURL {
                if !archiveFileOpener(copy) { showArchiveError(ArchiveBrowsingSession.SessionError.unavailableItem) }
            } else { showArchiveError(ArchiveBrowsingSession.SessionError.unavailableItem) }
            return
        }
        if item.isNavigable {
            navigate(to: item.url)
        } else {
            if FileOperations.canExtractArchive(item.url) {
                if AppPreferences.experimentalZIPBrowsingEnabled {
                    navigate(to: item.url)
                } else {
                    if isSearching { navigate(to: item.url.deletingLastPathComponent()) }
                    extract([item.url])
                }
            }
            else { _ = fileOpener(item.url) }
        }
    }

    private func saveViewState() {
        guard !isSearching, !model.isSearchResults else { return }
        history.recordViewState(selectedName: fileView.selectedItems.first?.name,
                                scrollOffset: fileView.scrollOffset)
    }

    private func restoreViewState() {
        if let pendingSelection {
            self.pendingSelection = nil
            fileView.select(name: pendingSelection)
            return
        }
        guard let entry = history.current else { return }
        if let name = entry.selectedName {
            fileView.select(name: name)
        } else {
            fileView.select(name: nil)
            fileView.scrollOffset = entry.scrollOffset
        }
    }
}

/// Retaining a built menu also retains its targets, including Open With's
/// submenu actions; constructing another menu cannot retarget an older item.
private final class FileContextMenu: NSMenu {
    var targetItems: [FileItem] = []
}

/// Content view that turns trackpad page-swipes into history navigation.
private final class SwipeView: NSView {
    var onSwipe: ((CGFloat) -> Void)?
    override func swipe(with event: NSEvent) { onSwipe?(event.deltaX) }
    override var acceptsFirstResponder: Bool { false }
}
